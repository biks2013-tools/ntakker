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
}

public struct TranscriptionMetrics: Sendable, Codable, Equatable {
    public var chunksSent: Int = 0
    public var billableSeconds: Double = 0
    public var lastRttMs: Int = 0
    public var errorCount: Int = 0
    public var bufferOverflowCount: Int = 0

    public init() {}
}
