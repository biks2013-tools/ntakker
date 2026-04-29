// Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift
//
// Plan-006 Phase D / Unit D1: Soniox token batch -> StreamingTranscription
// event aggregator.
//
// Soniox emits tokens in batches; an utterance is composed of many
// non-final tokens (each batch may revise prior non-finals) followed
// by either an `<end>` marker (endpoint-detected) or a `<fin>` marker
// (server processed `{"type":"finalize"}`). On marker, the aggregator
// flushes its buffer as a single `.final` event and resets.
//
// The aggregator does NOT know wall-clock time itself — the caller
// passes `now` so tests can be deterministic. When a token batch lacks
// `start_ms` / `end_ms` we fall back to `now ... now`.

import Foundation

/// Buffers Soniox tokens and emits `StreamingTranscriptionEvent`
/// values. Marker tokens "<end>" and "<fin>" trigger a final emission
/// and reset.
public actor SonioxTokenAggregator {

    private var currentUtteranceId: UUID?
    private var buffer: [SonioxToken] = []

    public init() {}

    /// Process one server-message batch. Returns events to emit.
    /// The caller is responsible for actually forwarding them on its
    /// event continuation.
    public func ingest(
        _ batch: [SonioxToken],
        now: Date = Date()
    ) -> [StreamingTranscriptionEvent] {
        var events: [StreamingTranscriptionEvent] = []
        for token in batch {
            if token.isMarker {
                if let event = flush(now: now) {
                    events.append(event)
                }
                continue
            }

            if currentUtteranceId == nil {
                currentUtteranceId = UUID()
            }
            buffer.append(token)

            if token.isFinal {
                if let event = flush(now: now) {
                    events.append(event)
                }
            } else {
                let id = currentUtteranceId ?? UUID()
                currentUtteranceId = id
                events.append(
                    .partial(
                        utteranceId: id,
                        text: concatenatedText(buffer),
                        confidence: token.confidence.map(Float.init)
                    )
                )
            }
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

        let event = StreamingTranscriptionEvent.final(
            utteranceId: id,
            text: text,
            confidence: avgConfidence,
            range: range,
            language: language
        )
        buffer.removeAll(keepingCapacity: true)
        currentUtteranceId = nil
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
