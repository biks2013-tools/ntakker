// macrec-ui/Views/Transcription/Dual/DualLiveTranscriptView.swift —
// plan-010 Phase G / Lane L-9 (Wave 6). See project-design.md §DT-8
// ("Dual-lane live transcript display") and DT-ADR-8 / OQ-5 resolution.
//
// Composing view that renders the dual-mode live-transcript display.
// Layout (DT-ADR-8 / OQ-5 resolution): STACKED LANES — Channel A on
// top, Channel B on the bottom — each with INDEPENDENT auto-scroll
// (each lane owns its own `ScrollViewReader`).
//
// Layout decision rationale (project-design §DT-8 / DT-ADR-8):
//   * Side-by-side was REJECTED: the popover (~360 pt wide) is too
//     narrow for two readable text columns, especially with mixed
//     scripts (Greek + Latin in the v1 default configuration).
//   * Single chronological feed with channel chips was REJECTED: the
//     two channels lag at different rates (Apple on-device is faster
//     than Apple Cloud), so the stream visually "jumps" as late
//     Channel B segments arrive after newer Channel A segments —
//     reading either channel becomes painful.
//   * STACKED LANES (this implementation): preserves channel identity,
//     gives each language its own column-width budget, and lets each
//     side scroll at its own pace. The two lanes share the panel's
//     vertical space equally (the parent `LiveTranscriptPanel`
//     applies `.frame(maxHeight: .infinity)` to the dual view, and
//     this view distributes that height 50/50 between the lanes).
//
// Filtering policy (frozen by §DT-8):
//   * Channel A segments = `transcriptSegments.filter { model == "apple" }`
//   * Channel B segments = `transcriptSegments.filter { model == "apple-cloud" }`
//   * Segments with any other `model` (or nil) are NOT rendered in
//     dual mode — they are out-of-band (e.g. residual single-mode
//     segments captured before a mode switch). The single-mode panel
//     remains the only place that renders the unfiltered flat list.
//
// The mapping `model → DualChannelTag` flows through
// `DualSidecarLabel.channelTag(forModel:)` (added by L-6) so the
// filter logic and the sidecar writer's model-to-channel mapping
// share ONE source of truth — if a future wave renames a provider
// model id, only `DualSidecarLabel` changes.
//
// Frozen contract (Wave 6, Lane L-9):
//   * `init()` (no-arg). Reads `recordingController.transcriptSegments`
//     from the SwiftUI environment.
//   * Branch entry-point: `LiveTranscriptPanel` instantiates this view
//     when the persisted `LiveTranscriptionMode` is `.dual`.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Dual-mode live-transcript display. Renders two `DualLiveTranscriptLane`
/// instances stacked vertically (Channel A on top, Channel B on the
/// bottom, per the §DT-8 ASCII mockup) with independent auto-scroll
/// per lane (DT-ADR-8).
struct DualLiveTranscriptView: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    /// Full segment buffer from the controller. Defaults to an empty
    /// array when the controller is absent (test contexts, previews).
    private var allSegments: [TranscriptSegment] {
        recordingController?.transcriptSegments ?? []
    }

    /// Channel A partition — segments whose `model` value maps to
    /// `.channelA` per `DualSidecarLabel.channelTag(forModel:)`. v1
    /// mapping: `"apple"` → Channel A.
    private var channelASegments: [TranscriptSegment] {
        allSegments.filter {
            DualSidecarLabel.channelTag(forModel: $0.model) == .channelA
        }
    }

    /// Channel B partition — segments whose `model` value maps to
    /// `.channelB` per `DualSidecarLabel.channelTag(forModel:)`. v1
    /// mapping: `"apple-cloud"` → Channel B.
    private var channelBSegments: [TranscriptSegment] {
        allSegments.filter {
            DualSidecarLabel.channelTag(forModel: $0.model) == .channelB
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            DualLiveTranscriptLane(
                channel: .channelA,
                segments: channelASegments
            )
            .frame(maxHeight: .infinity)

            // Subtle horizontal divider between the two lanes — uses
            // the palette's separator stroke colour to stay consistent
            // with the rest of the panel's chrome.
            Rectangle()
                .fill(palette.separator)
                .frame(height: 0.5)

            DualLiveTranscriptLane(
                channel: .channelB,
                segments: channelBSegments
            )
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
