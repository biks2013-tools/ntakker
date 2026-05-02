// macrec-ui/Views/Transcription/Dual/DualTranscriptionMetricsView.swift
// — see project-design.md §DT-4 (per-channel metrics polling pattern)
// and §DT-8 (UI mockup). Plan-010 Wave 5 / Lane L-11.
//
// Per-channel metrics footer for the dual-transcription panel. Stacked
// layout (one row per channel, A above B) showing the same fields as
// the single-mode `TranscriptionMetricsView` but split across the two
// channels of the in-flight `DualTranscriptionManager`:
//
//   * `chunksSent`         — number of provider round-trips
//   * `billableSeconds`    — accumulated audio duration sent to the
//                             provider (FR-58 cost basis)
//   * `lastRttMs`          — most-recent provider round-trip latency
//   * `errorCount`         — count of non-fatal provider errors
//
// Data source: `RecordingController.dualMetrics` (a `DualChannelMetrics?`
// slot) populated by `RecordingController.applyDualMetrics(_:)` from
// the SessionCoordinator-side metrics-poll Task once the dispatcher
// reference is plumbed through (see `PLAN-010-PENDING-L11-WIRING`).
// Until that wiring lands, `dualMetrics` stays nil and this view
// renders `EmptyView()` — there is no placeholder text. The absence of
// metrics simply means nothing to display yet.
//
// Typography mirrors `TranscriptionMetricsView` so the dual footer
// matches the single-mode footer's visual rhythm: `font(.system(size: 9))`
// in `.tertiary` foreground style.
//
// Frozen contract (plan-010 Wave 5 / Lane L-11): no-arg init. The
// `DualTranscriptionControls` view (Lane L-8) embeds this view at the
// bottom of its body via `DualTranscriptionMetricsView()`.

import MacrecCore
import MacrecUIKit
import SwiftUI

struct DualTranscriptionMetricsView: View {
    @Environment(\.recordingController) private var recordingController

    var body: some View {
        if let dual = recordingController?.dualMetrics {
            VStack(alignment: .leading, spacing: 2) {
                channelRow(label: "A", metrics: dual.channelA)
                channelRow(label: "B", metrics: dual.channelB)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        } else {
            EmptyView()
        }
    }

    /// Render one channel's metrics row. The compact format follows the
    /// single-mode footer convention (`secondsLabel` in
    /// `TranscriptionMetricsView`) so the user sees consistent fields
    /// in single and dual modes; the leading channel tag (`A` / `B`)
    /// disambiguates the two rows.
    @ViewBuilder
    private func channelRow(label: String, metrics: TranscriptionMetrics) -> some View {
        HStack(spacing: 10) {
            Label(
                String(
                    format: "Ch %@ · %.1f s · %d chunks · %d errors",
                    label,
                    metrics.billableSeconds,
                    metrics.chunksSent,
                    metrics.errorCount
                ),
                systemImage: "waveform"
            )
            Spacer()
            if metrics.lastRttMs > 0 {
                Text("rtt: \(metrics.lastRttMs) ms")
            }
        }
    }
}
