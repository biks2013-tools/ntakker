// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift
//
// Plan-006 Phase D / Unit D1: Soniox token batch -> StreamingTranscription
// event aggregator.
//
// Soniox emits tokens in batches. Each batch contains a mix of:
//   * **non-final** tokens (provisional — they will be REVISED by the
//     next batch's non-finals; see `SonioxToken.isFinal` doc); and
//   * **final** tokens (committed words/syllables — these will never
//     change).
// An utterance ends when a marker token arrives:
//   * `text == "<end>"` — endpoint detector fired (auto)
//   * `text == "<fin>"` — server processed `{"type":"finalize"}`
// Both markers carry `is_final: true` and typically `confidence: 1.0`.
//
// Algorithm (corrected 2026-05-01 to match the real Soniox protocol):
//
//   1. At the start of every `ingest(_:)` call, DROP all non-final
//      tokens left in the buffer — they are about to be revised by
//      this new batch's non-finals. Finals are kept (they are
//      committed and immutable).
//
//   2. Append every non-marker token from the new batch to the buffer.
//      Non-final and final tokens are both appended; finals accumulate
//      across batches inside an utterance.
//
//   3. On a marker token (`<end>` or `<fin>`), flush the buffer as
//      ONE `.final` event and reset.
//
//   4. After processing the whole batch, if any new content was added
//      and no marker fired, emit ONE `.partial` event reflecting the
//      new buffer state. (Earlier versions emitted one `.partial` per
//      non-final token, which produced a partial-storm and made the
//      live UI flicker; one-per-batch matches the server's update
//      cadence.)
//
//   5. `drain()` flushes whatever is in the buffer at session close,
//      so a recording terminated before any `<end>`/`<fin>` arrived
//      still surfaces a final event.
//
// The aggregator does NOT know wall-clock time itself — the caller
// passes `now` so tests can be deterministic. When a token batch
// lacks `start_ms` / `end_ms` we fall back to `now ... now`.

import Foundation

/// Buffers Soniox tokens and emits `StreamingTranscriptionEvent`
/// values. Marker tokens "<end>" and "<fin>" trigger a final emission
/// and reset.
public actor SonioxTokenAggregator {

    private var currentUtteranceId: UUID?
    private var buffer: [SonioxToken] = []

    /// The diarisation label currently associated with the in-flight
    /// utterance, or `nil` when no token in the active utterance has
    /// carried a speaker yet. Adopted from the first non-nil token.
    /// Carried through tokens with `speaker == nil`. Reset on marker
    /// flush. A new non-nil token whose label DIFFERS from
    /// `activeSpeaker` triggers an in-utterance flush so the
    /// previous-speaker fragment is surfaced as its own `.final`
    /// before the new speaker begins accumulating. (plan-012 Phase A4)
    private var activeSpeaker: String?

    public init() {}

    /// Process one server-message batch. Returns events to emit.
    /// The caller is responsible for actually forwarding them on its
    /// event continuation.
    public func ingest(
        _ batch: [SonioxToken],
        now: Date = Date()
    ) -> [StreamingTranscriptionEvent] {
        var events: [StreamingTranscriptionEvent] = []

        // Walk the new batch. Markers flush. Non-markers (final or
        // non-final) accumulate into the buffer. We do NOT flush on
        // per-token `is_final: true` — those are word-level commits,
        // not utterance terminators. Only `<end>` / `<fin>` terminate
        // utterances.
        //
        // Discard rule (LAZY): the previous batch's non-finals are
        // dropped just before the FIRST new content token of the
        // current batch is appended. A batch consisting solely of a
        // marker (e.g. `[<end>]`) therefore preserves the buffered
        // non-finals so the marker can flush them — exactly what the
        // server intends when it endpoint-fires after a long silence.
        // A batch carrying any new content (final or non-final) is
        // taken as a revision of the prior provisional guesses, so
        // those prior non-finals are dropped before the new tokens
        // are appended.
        var didDiscardPriorNonFinals = false
        var batchHadNewContent = false

        for token in batch {
            if token.isMarker {
                if let event = flush(now: now) {
                    events.append(event)
                }
                continue
            }

            // Speaker-boundary handling (plan-012 Phase A4):
            // If THIS token carries a speaker AND we already have an
            // active speaker AND they differ, flush the buffered
            // material as a final tagged with the OLD speaker before
            // we append the new token. This produces one
            // `TranscriptSegment` per speaker even when the server
            // does not insert an `<end>` marker between speakers.
            if let incoming = token.speaker,
               let active = activeSpeaker,
               incoming != active {
                if let event = flush(now: now) {
                    events.append(event)
                }
                // flush() reset activeSpeaker; adopt the new label.
                activeSpeaker = incoming
                // The buffer was just emptied so the discard step is
                // already satisfied for this batch — but we still need
                // to make sure subsequent non-final tokens within the
                // same batch see the discard flag set so we don't drop
                // the just-appended new-speaker token on the next
                // iteration.
                didDiscardPriorNonFinals = true
            } else if activeSpeaker == nil, let incoming = token.speaker {
                // No active speaker yet — adopt the first non-nil
                // label without flushing (the active partial has not
                // had any speaker stamped yet).
                activeSpeaker = incoming
            }
            // When token.speaker == nil we deliberately leave
            // activeSpeaker untouched so the prevailing label keeps
            // flowing through silent / unlabelled tokens.

            if !didDiscardPriorNonFinals {
                // First new content token in this batch — the prior
                // batch's non-finals are now stale. Finals stay
                // (they are committed and immutable).
                buffer.removeAll { !$0.isFinal }
                didDiscardPriorNonFinals = true
            }

            if currentUtteranceId == nil {
                currentUtteranceId = UUID()
            }
            buffer.append(token)
            batchHadNewContent = true
        }

        // Emit one partial reflecting the post-batch state, unless
        // we just flushed (in which case the buffer is empty and
        // any further partial would be misleading).
        if batchHadNewContent, let id = currentUtteranceId, !buffer.isEmpty {
            let lastConfidence = buffer.last?.confidence.map(Float.init)
            events.append(
                .partial(
                    utteranceId: id,
                    text: concatenatedText(buffer),
                    confidence: lastConfidence,
                    speaker: activeSpeaker
                )
            )
        }

        return events
    }

    /// Force a final emission even if no marker arrived (used at
    /// session close). Returns `[]` when the buffer is empty.
    public func drain(now: Date = Date()) -> [StreamingTranscriptionEvent] {
        if let event = flush(now: now) {
            return [event]
        }
        return []
    }

    // MARK: - Internals

    /// Flush the current buffer into a single `.final` event. Returns
    /// `nil` if the buffer is empty (and therefore nothing to emit).
    private func flush(now: Date) -> StreamingTranscriptionEvent? {
        guard !buffer.isEmpty else {
            currentUtteranceId = nil
            activeSpeaker = nil
            return nil
        }
        let id = currentUtteranceId ?? UUID()
        let text = concatenatedText(buffer)
        let confidences = buffer.compactMap(\.confidence)
        let avgConfidence: Float?
        if confidences.isEmpty {
            avgConfidence = nil
        } else {
            let sum = confidences.reduce(0.0, +)
            avgConfidence = Float(sum / Double(confidences.count))
        }
        let language = buffer.last?.language ?? "und"
        let range = computeRange(buffer: buffer, now: now)
        let speaker = activeSpeaker

        let event = StreamingTranscriptionEvent.final(
            utteranceId: id,
            text: text,
            confidence: avgConfidence,
            range: range,
            language: language,
            speaker: speaker
        )
        buffer.removeAll(keepingCapacity: true)
        currentUtteranceId = nil
        activeSpeaker = nil
        return event
    }

    private func concatenatedText(_ tokens: [SonioxToken]) -> String {
        return tokens
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map the buffer's start_ms / end_ms span to a `ClosedRange<Date>`
    /// anchored on `now`. If timestamps are missing entirely we fall
    /// back to `now ... now`.
    private func computeRange(
        buffer: [SonioxToken],
        now: Date
    ) -> ClosedRange<Date> {
        let startsMs = buffer.compactMap(\.startMs)
        let endsMs = buffer.compactMap(\.endMs)
        guard let minStart = startsMs.min(),
              let maxEnd = endsMs.max(),
              maxEnd >= minStart else {
            return now ... now
        }
        // Anchor the timestamp range on `now` representing the END of
        // the utterance (the moment the final is being emitted).
        let durationMs = maxEnd - minStart
        let start = now.addingTimeInterval(-Double(durationMs) / 1000.0)
        let end = now
        guard end >= start else {
            return now ... now
        }
        return start ... end
    }
}
