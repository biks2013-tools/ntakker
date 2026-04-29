// macrec-ui/Views/Transcription/TranscriptionMetricsView.swift — see
// project-design.md §LT-8.4 and plan-003 Phase G, updated for plan-004
// Phase H (rest-batch metrics).
//
// Footer beneath `LiveTranscriptPanel` that surfaces the running
// metrics for the active transcription pipeline. The rest-batch
// `TranscriptionMetrics` shape (defined in MacrecCore) exposes:
//
//   * `chunksSent`         — number of provider round-trips
//   * `billableSeconds`    — accumulated audio duration sent to the
//                             provider, used for the indicative cost
//                             estimate (FR-58)
//   * `lastRttMs`          — most-recent provider round-trip latency
//   * `errorCount`         — count of non-fatal provider errors
//   * `bufferOverflowCount` — how many times the SourceBuffer dropped
//                              audio (back-pressure signal)
//
// Cost model (FR-58): a coarse heuristic — `billableSeconds` × an
// indicative per-minute rate (`indicativeCostPerMinute`). The label
// calls this "estimate" so users do not treat it as billing-grade.

import MacrecCore
import MacrecUIKit
import SwiftUI

struct TranscriptionMetricsView: View {
    @Environment(\.recordingController) private var recordingController

    /// Indicative per-minute streaming cost in USD for the v1 provider
    /// (Gemini rest-batch). Surfaced verbatim in the footer.
    private static let indicativeCostPerMinute: Double = 0.05

    private var metrics: TranscriptionMetrics {
        recordingController?.transcriptionMetrics ?? TranscriptionMetrics()
    }

    private var isVisible: Bool {
        // Show when transcription has produced any state. Hidden in
        // the pure-idle / never-started case.
        let s = recordingController?.transcriptionStatus ?? .idle
        if case .idle = s {
            return metrics.chunksSent > 0 || metrics.billableSeconds > 0
        }
        return true
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 10) {
                Label(secondsLabel, systemImage: "waveform")
                Spacer()
                if metrics.lastRttMs > 0 {
                    Text("rtt: \(metrics.lastRttMs) ms")
                }
                Spacer()
                Text("est. \(estimatedCostString)")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .help("Indicative cost — uses a flat $\(Self.indicativeCostPerMinute)/min rate. Final billing is provider-determined.")
        }
    }

    private var secondsLabel: String {
        return String(
            format: "%.1f s · %d chunks · %d errors · %d overflow",
            metrics.billableSeconds,
            metrics.chunksSent,
            metrics.errorCount,
            metrics.bufferOverflowCount
        )
    }

    private var estimatedCostString: String {
        let cost = (metrics.billableSeconds * Self.indicativeCostPerMinute) / 60.0
        return String(format: "$%.4f", cost)
    }
}
