// MacrecCore/Transcription/Dual/DualChannelMetrics.swift — see project-design.md §DT-3, plan-010-dual-transcription.md §Phase B
//
// Phase B / Lane L-3 (plan-010) — per-channel split of the existing
// `TranscriptionMetrics` snapshot.
//
// Design rationale (§DT-3 / DT-ADR-5):
//   * `TranscriptionMetrics` itself is reused unchanged (`chunksSent`,
//     `billableSeconds`, `lastRttMs`, `errorCount`, `bufferOverflowCount`).
//     The dual feature does not change the per-pipeline metrics shape.
//   * The protocol-conforming `currentMetrics() -> TranscriptionMetrics`
//     on `DualTranscriptionManager` returns a field-wise sum of the two
//     channels' snapshots so the existing single-mode badge consumer
//     keeps working unchanged (NFR-1 — single-mode preservation).
//   * `currentDualMetrics() -> DualChannelMetrics` is the dual-only
//     surface (NOT on the `TranscriptionDispatcher` protocol) consumed
//     by `RecordingController` after a `is DualTranscriptionManager`
//     downcast to populate the per-channel UI display.

import Foundation

/// Per-channel split of a recording session's transcription metrics.
///
/// `Sendable` so the value can cross actor boundaries (Manager → UI).
/// `Equatable` for value-comparison in tests. `Codable` for hypothetical
/// future export of a metrics summary alongside the sidecar.
public struct DualChannelMetrics: Sendable, Equatable, Codable {

    /// Snapshot of Channel A's pipeline-level metrics (Apple on-device
    /// in v1).
    public let channelA: TranscriptionMetrics

    /// Snapshot of Channel B's pipeline-level metrics (Apple Cloud in
    /// v1).
    public let channelB: TranscriptionMetrics

    public init(
        channelA: TranscriptionMetrics,
        channelB: TranscriptionMetrics
    ) {
        self.channelA = channelA
        self.channelB = channelB
    }
}
