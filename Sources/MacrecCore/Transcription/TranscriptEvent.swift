// Sources/MacrecCore/Transcription/TranscriptEvent.swift
//
// Filename kept as TranscriptEvent.swift for repo-blame continuity, but the
// type defined here is now TranscriptionEvent (plan-004 Phase A.5 rename).
//
import Foundation

public enum TranscriptionEvent: Sendable, Codable, Equatable {
    /// A new segment was created and appended at `index`.
    case segmentAppended(index: Int, segment: TranscriptSegment)

    /// The segment at `index` was updated in place (text grew via the coalescer).
    case segmentUpdated(index: Int, segment: TranscriptSegment)

    /// Stable, finalised segment. Sidecar writers (streaming policy) persist on this only.
    case segmentFinalized(index: Int, segment: TranscriptSegment)

    /// Privacy disclosure that fires exactly once per session the first time a
    /// non-`none` provider is about to send audio.
    case privacyDisclosure(providerDisplayName: String)

    /// Per-flush metric snapshot.
    case metricsTick(metrics: TranscriptionMetrics)

    /// Non-fatal provider/sidecar error.
    case error(detail: String)

    /// Plan-010 Phase B / §DT-3 — per-channel non-fatal error from
    /// dual-mode transcription. Emitted by `DualTranscriptionManager`'s
    /// per-channel drain `Task` when its underlying pipeline terminates
    /// or errors. The other channel keeps streaming; the merged stream
    /// is not finished (only `stop()` finishes it). The `channel` tag
    /// lets `RecordingController` route the error to the correct lane
    /// error-display surface in the dual-mode UI.
    ///
    /// This case is additive — exhaustive switches over
    /// `TranscriptionEvent` in single-mode code continue to compile
    /// (Swift warning only, not error). Lane L-5 will add `@unknown
    /// default` arms where the codebase scan flagged them.
    case dualChannelError(channel: DualChannelTag, detail: String)
}

public struct TranscriptionMetrics: Sendable, Codable, Equatable {
    public var chunksSent: Int = 0
    public var billableSeconds: Double = 0
    public var lastRttMs: Int = 0
    public var errorCount: Int = 0
    public var bufferOverflowCount: Int = 0

    public init() {}
}
