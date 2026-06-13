// NtakkerCore/Transcription/StreamingTranscriptionPipeline.swift —
// see docs/design/plan-005-apple-speech-streaming.md §"Phase E".
//
// Phase E (plan-005) — second pipeline class alongside the plan-004
// batch pipeline that lives directly on `TranscriptionManager`. This
// pipeline drives streaming-mode `TranscriptionProvider`s: it opens
// one `StreamingTranscriptionSession` per active `SourceTag`,
// fans audio ingests out per source, drains each session's
// `events` AsyncStream, and lifts every per-utterance partial /
// final into `TranscriptionEvent`s consumed by the UI and the
// sidecar writer.
//
// Coexistence rule (Constraint #7 in the Phase E brief):
// `TranscriptionManager` keeps its existing batch-pipeline state and
// methods intact for `--transcribe gemini`. The manager dispatches
// to this class only when `provider.supportedModes.contains(.streaming)`.
//
// Per-utterance bookkeeping:
//   * `nextSegmentIndex` is the source of truth for sidecar segment
//     indices. It increments every time a new utterance id is seen.
//   * `indexForUtteranceId` maps the per-utterance UUID emitted by the
//     `StreamingTranscriptionSession` to its segment index, so that
//     successive partials and the eventual final all carry the same
//     index in the public `TranscriptionEvent`s.
//   * The first partial for an utterance produces `.segmentAppended`;
//     subsequent partials produce `.segmentUpdated`; the final
//     produces `.segmentFinalized` (the only event variant that the
//     Phase F sidecar writer streaming-policy persists).

import Foundation
import Logging

/// Per-session streaming orchestrator. Mirrors the role of the
/// batch pipeline that lives inline on `TranscriptionManager` for
/// REST/batch providers, but drives a streaming provider via the
/// `StreamingTranscriptionSession` surface introduced in Phase A.
///
/// Lifetime:
///   1. Construct with a streaming-capable `provider`, the recording's
///      `source` routing, the resolved `options`, an optional sidecar
///      `writer`, and a logger.
///   2. Call `start()` once to receive the public event stream and
///      kick off per-source session opens.
///   3. Push downsampled samples via `ingest(_:from:)`.
///   4. (Optional) `rotateSidecar(toAudioURL:format:)` when the
///      `RecordingSession` rotates segments (`pause-on-split`).
///   5. Call `stop()` to drain sessions, close the sidecar, and
///      finish the public event stream.
@available(macOS 26.0, *)
final actor StreamingTranscriptionPipeline {
    private let provider: any TranscriptionProvider
    private let source: TranscriptionSource
    private let options: TranscriptionOptions
    private var sidecarWriter: TranscriptSidecarWriter?
    private let logger: Logger

    private var sessions: [SourceTag: any StreamingTranscriptionSession] = [:]
    private var drainTasks: [Task<Void, Never>] = []
    /// F19 (EVAL 2026-06-12): the per-source session-open tasks, kept
    /// so `stop()` can cancel opens still in flight (a WS connect or
    /// an Apple asset download can outlive a short recording).
    private var openTasks: [Task<Void, Never>] = []
    private var nextSegmentIndex: Int = 0
    private var indexForUtteranceId: [UUID: Int] = [:]
    private var eventsContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var metrics = TranscriptionMetrics()
    private var stopped: Bool = false

    /// Per-source sidecar infix (`.system` / `.microphone`) carried so
    /// `rotateSidecar(...)` reproduces the same tagged path the initial
    /// writer was opened with (EVAL 2026-06-12 finding F24). `nil` for
    /// single-source / mixed recordings.
    private let sidecarSourceTag: SourceTag?

    init(
        provider: any TranscriptionProvider,
        source: TranscriptionSource,
        options: TranscriptionOptions,
        sidecarWriter: TranscriptSidecarWriter?,
        logger: Logger,
        sidecarSourceTag: SourceTag? = nil
    ) {
        self.provider = provider
        self.source = source
        self.options = options
        self.sidecarWriter = sidecarWriter
        self.logger = logger
        self.sidecarSourceTag = sidecarSourceTag
    }

    // MARK: - Public surface

    /// Begin the streaming pipeline. Returns the event stream the
    /// caller must consume. Yields `.privacyDisclosure` synchronously
    /// before any session opens so the UI banner lands before any
    /// transcript text. Calling `start()` more than once is a
    /// programmer error.
    func start() -> AsyncStream<TranscriptionEvent> {
        let (stream, cont) = AsyncStream.makeStream(
            of: TranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        self.eventsContinuation = cont

        cont.yield(.privacyDisclosure(providerDisplayName: provider.displayName))

        for tag in source.activeSourceTags() {
            openTasks.append(Task { [provider, options, weak self] in
                do {
                    let s = try await provider.openStreamingSession(
                        source: tag, options: options)
                    await self?.attach(session: s, for: tag)
                } catch {
                    cont.yield(
                        .error(detail: "openStreamingSession failed: \(error.localizedDescription)")
                    )
                }
            })
        }
        return stream
    }

    /// Forward already-downsampled 16 kHz mono Float32 samples to the
    /// session for the given source tag. Fire-and-forget: if the
    /// session for `tag` has not attached yet (the session-open is
    /// still in flight) the samples are dropped — the caller's
    /// upstream buffer should already be paced enough that this is
    /// benign. After `stop()` the call is also a no-op.
    func ingest(_ samples: [Float], from tag: SourceTag) async {
        guard !stopped else { return }
        guard let session = sessions[tag] else { return }
        await session.ingest(samples)
    }

    /// Replace the current sidecar writer with one targeting a new
    /// audio URL — used when `RecordingSession` rotates segments
    /// (`pause-on-split`) and the in-flight transcript needs to follow
    /// the audio file. Closes the existing writer first; resets the
    /// per-utterance index map so the new sidecar starts segment
    /// numbering at zero.
    func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {
        await sidecarWriter?.close()
        // Plan-005 Phase F: streaming pipeline persists only
        // `.segmentFinalized` events; pass the streaming policy
        // explicitly so the writer's per-mode dispatch ignores
        // the noisy partial events the streaming pipeline still
        // emits to the UI on `.segmentAppended` / `.segmentUpdated`.
        // F24: reproduce the per-source tagged path the initial writer
        // used so both-mode children never rotate onto the same file.
        sidecarWriter = try TranscriptSidecarWriter(
            outputPath: SidecarPathBuilder.sidecarURL(
                forRecording: toAudioURL, format: format,
                sourceTag: sidecarSourceTag),
            format: format,
            policy: .streaming
        )
        nextSegmentIndex = 0
        indexForUtteranceId.removeAll()
    }

    /// Drain all sessions, wait for their per-source drain tasks to
    /// exit, close the sidecar writer, and finish the public event
    /// stream. Idempotent.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        // F19: cancel session-opens still in flight. Cancellation is
        // cooperative — an open that completes anyway is caught by the
        // `stopped` guard in `attach` and finished immediately.
        for t in openTasks { t.cancel() }
        openTasks.removeAll()
        for (_, s) in sessions {
            await s.finish()
        }
        for t in drainTasks {
            await t.value
        }
        await sidecarWriter?.close()
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    /// Snapshot of the streaming-pipeline metrics in
    /// `TranscriptionMetrics` shape — the same struct the batch
    /// pipeline emits so the UI and the `RecordingSession` summary
    /// can read both pipelines uniformly.
    func currentMetrics() -> TranscriptionMetrics { metrics }

    // MARK: - Private

    /// Wire a freshly-opened `StreamingTranscriptionSession` into the
    /// pipeline: register it under its source tag and spawn the
    /// per-session drain task that lifts streaming events into public
    /// `TranscriptionEvent`s.
    private func attach(session: any StreamingTranscriptionSession,
                        for tag: SourceTag) {
        // F19 (EVAL 2026-06-12): if the user stopped the recording
        // while this session's open was still in flight, `stop()` has
        // already run — registering the session now would leak it
        // forever (live WebSocket + keepalive timer for Soniox, an
        // endlessly rotating SFSpeechRecognitionTask for Apple Cloud).
        // Finish it immediately instead.
        guard !stopped else {
            logger.info("streaming session for \(tag.rawValue) opened after stop() — finishing immediately")
            Task { await session.finish() }
            return
        }
        sessions[tag] = session
        let task = Task { [weak self] in
            for await event in session.events {
                await self?.handle(event, from: tag)
            }
        }
        drainTasks.append(task)
    }

    /// Translate one `StreamingTranscriptionEvent` into the public
    /// `TranscriptionEvent` surface, persisting finalised segments
    /// to the sidecar writer and updating the per-utterance index
    /// bookkeeping.
    private func handle(_ event: StreamingTranscriptionEvent,
                        from tag: SourceTag) async {
        switch event {
        case .partial(let uttId, let text, let conf, let speaker):
            if let idx = indexForUtteranceId[uttId] {
                let seg = TranscriptSegment(
                    id: uttId,
                    timestamp: Date(),
                    text: text,
                    source: tag,
                    confidence: conf,
                    model: provider.id,
                    speaker: speaker
                )
                eventsContinuation?.yield(.segmentUpdated(index: idx, segment: seg))
            } else {
                let idx = nextSegmentIndex
                nextSegmentIndex += 1
                indexForUtteranceId[uttId] = idx
                let seg = TranscriptSegment(
                    id: uttId,
                    timestamp: Date(),
                    text: text,
                    source: tag,
                    confidence: conf,
                    model: provider.id,
                    speaker: speaker
                )
                eventsContinuation?.yield(.segmentAppended(index: idx, segment: seg))
            }

        case .final(let uttId, let text, let conf, let range, let language, let speaker):
            let idx: Int
            if let existing = indexForUtteranceId[uttId] {
                idx = existing
            } else {
                idx = nextSegmentIndex
                nextSegmentIndex += 1
                indexForUtteranceId[uttId] = idx
            }
            let durationSec = range.upperBound.timeIntervalSince(range.lowerBound)
            let seg = TranscriptSegment(
                id: uttId,
                timestamp: range.lowerBound,
                lastUpdated: range.upperBound,
                text: text,
                source: tag,
                confidence: conf,
                model: provider.id,
                durationSec: durationSec,
                language: language,
                speaker: speaker
            )
            eventsContinuation?.yield(.segmentFinalized(index: idx, segment: seg))
            await sidecarWriter?.write(.segmentFinalized(index: idx, segment: seg))
            metrics.chunksSent += 1

        case .metrics:
            // Streaming-only metrics shape; the batch-pipeline UI
            // surface does not yet model these. Drop for v1; Phase H
            // will route them once the UI grows the corresponding
            // affordances.
            return

        case .error(let detail):
            metrics.errorCount += 1
            eventsContinuation?.yield(.error(detail: detail))
            logger.warning("streaming session error: \(detail)")
        }
    }
}
