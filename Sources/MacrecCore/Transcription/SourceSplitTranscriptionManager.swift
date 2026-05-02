// MacrecCore/Transcription/SourceSplitTranscriptionManager.swift
//
// Plan-012 Phase C — true `--transcribe-source both` support. Lifts
// the v1 limitation documented in docs/tools/macrec.md by composing
// two single-source `TranscriptionManager` instances (one per
// SourceTag) behind the existing `TranscriptionDispatcher` façade.
//
// Why composition (not modify TranscriptionManager): keeps the
// existing single-source code path byte-equivalent for non-`both`
// modes and makes dual-source strictly additive. Each inner manager
// owns its own provider instance, sidecar writer, and metrics struct.
//
// Phase C1 (this file's first cut):
//   * Routes `ingest(_:from:)` / `ingestFrame(_:from:)` by SourceTag
//     — `.system` to the systemManager, `.microphone` to the
//     microphoneManager. SourceTag has only those two cases (it is a
//     typealias for CaptureSourceTag).
//   * `currentMetrics()` returns the field-wise merge of both
//     children via `TranscriptionMetrics.merge`.
//   * `stop()` and `rotateSidecar(...)` fan out to both children.
//   * `start()` returns the system child's stream as a placeholder —
//     true two-stream merge lands in Phase C2.

import Foundation
import Logging

public actor SourceSplitTranscriptionManager: TranscriptionDispatcher {

    private let systemManager: TranscriptionManager
    private let microphoneManager: TranscriptionManager
    private let logger: Logger

    /// Test-only struct exposing the per-source ingest call counts so
    /// routing can be asserted without spinning up real providers.
    /// `microphone` matches the SourceTag case name (NOT `mic`).
    public struct IngestCounts: Sendable, Equatable {
        public let system: Int
        public let microphone: Int
    }
    private var systemIngestCount = 0
    private var microphoneIngestCount = 0

    public init(
        systemManager: TranscriptionManager,
        microphoneManager: TranscriptionManager,
        logger: Logger = Logger(label: "macrec.transcription.source-split")
    ) {
        self.systemManager = systemManager
        self.microphoneManager = microphoneManager
        self.logger = logger
    }

    // MARK: - TranscriptionDispatcher

    public func start() async throws -> AsyncStream<TranscriptionEvent> {
        // Phase C2 — merge the two child streams into one so consumers
        // see events from both system and microphone children on a
        // single AsyncStream. Two forwarding tasks drain each child
        // and yield into the merged continuation; the continuation
        // finishes only after BOTH children's streams have ended
        // (tracked by the actor-isolated finish counter).
        let systemStream = await systemManager.start()
        let microphoneStream = await microphoneManager.start()

        return AsyncStream<TranscriptionEvent> { continuation in
            let counter = SourceSplitMergeFinishCounter()

            Task {
                for await event in systemStream {
                    continuation.yield(event)
                }
                if await counter.markFinished() { continuation.finish() }
            }
            Task {
                for await event in microphoneStream {
                    continuation.yield(event)
                }
                if await counter.markFinished() { continuation.finish() }
            }
        }
    }

    public func ingest(_ samples: [Float], from tag: SourceTag) async {
        switch tag {
        case .system:
            systemIngestCount += 1
            await systemManager.ingest(samples, from: .system)
        case .microphone:
            microphoneIngestCount += 1
            await microphoneManager.ingest(samples, from: .microphone)
        }
    }

    public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async {
        switch tag {
        case .system:
            systemIngestCount += 1
            await systemManager.ingestFrame(frame, from: .system)
        case .microphone:
            microphoneIngestCount += 1
            await microphoneManager.ingestFrame(frame, from: .microphone)
        }
    }

    public func stop() async {
        await systemManager.stop()
        await microphoneManager.stop()
    }

    public func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {
        try await systemManager.rotateSidecar(toAudioURL: toAudioURL, format: format)
        try await microphoneManager.rotateSidecar(toAudioURL: toAudioURL, format: format)
    }

    public func currentMetrics() async -> TranscriptionMetrics {
        let s = await systemManager.currentMetrics()
        let m = await microphoneManager.currentMetrics()
        return TranscriptionMetrics.merge([s, m])
    }

    // MARK: - Test-only

    public func testInternalIngestCounts() -> IngestCounts {
        IngestCounts(system: systemIngestCount, microphone: microphoneIngestCount)
    }
}

/// Tracks "both children have finished" state for the merge in
/// `SourceSplitTranscriptionManager.start()`. Actor-isolated so the
/// two forwarding tasks don't race on the boolean flip. Plan-012
/// Phase C2.
private actor SourceSplitMergeFinishCounter {
    private var done = 0
    func markFinished() -> Bool {
        done += 1
        return done >= 2
    }
}
