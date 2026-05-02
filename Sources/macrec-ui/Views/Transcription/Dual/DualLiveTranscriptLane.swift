// macrec-ui/Views/Transcription/Dual/DualLiveTranscriptLane.swift —
// plan-010 Phase G / Lane L-9 (Wave 6). See project-design.md §DT-8
// ("Dual-lane live transcript display") and DT-ADR-8 / OQ-5 resolution.
//
// Single-channel lane component used by `DualLiveTranscriptView` to
// render ONE side of the dual live-transcript view (Channel A above
// Channel B per §DT-8 ASCII mockup). The lane owns:
//
//   * A small caption header showing the channel's user-facing label
//     ("EN — Channel A (Apple on-device)" or "EL — Channel B (Apple
//     Cloud)") derived from `DualSidecarLabel.channelLabel(for:)` so
//     the label-source is unified with the sidecar writers.
//   * A `ScrollView` with `ScrollViewReader`-driven auto-scroll-to-
//     bottom on every new segment or in-place revision. Scroll state
//     is INDEPENDENT of the other lane (DT-ADR-8): each lane owns its
//     own `ScrollViewReader`, so a slow-streaming Channel B does not
//     drag Channel A's auto-scroll.
//   * A per-segment row that mirrors the existing single-mode
//     `LiveTranscriptPanel.segmentView(_:)` typography exactly:
//     italic-secondary while partial (no `durationSec`), plain-primary
//     once finalized, optional uppercase BCP-47 language chip when
//     `segment.language` is non-nil.
//
// The lane component is layout-agnostic: it makes no assumption about
// whether it sits in a `VStack` (the v1 stacked layout, DT-ADR-8) or a
// `HStack` (rejected for v1 — popover too narrow — but the component
// would compose either way). The composing view (`DualLiveTranscriptView`)
// owns the layout decision.
//
// Frozen contract (Wave 6, Lane L-9):
//   * `init(channel: DualChannelTag, segments: [TranscriptSegment])`
//   * Segments are pre-filtered by the caller — the lane does NOT
//     re-filter; it renders whatever array it receives. The filtering
//     responsibility lives in `DualLiveTranscriptView` so the lane
//     stays trivially testable / reusable.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// One channel's worth of the dual-mode live-transcript display.
/// Renders a header caption + scrollable segment list with independent
/// auto-scroll-to-bottom.
struct DualLiveTranscriptLane: View {
    @Environment(\.palette) private var palette

    /// Routing tag identifying which channel this lane represents.
    /// Used to drive the header caption via `DualSidecarLabel`.
    let channel: DualChannelTag

    /// Segments belonging to this channel, pre-filtered by the parent
    /// view (`DualLiveTranscriptView`). Order is the order in the
    /// underlying `RecordingController.transcriptSegments` array
    /// (timestamp-ascending), preserved by `Array.filter`.
    let segments: [TranscriptSegment]

    /// User-facing header caption. Combines the language abbreviation
    /// from `DualSidecarLabel.channelLabel(for:)` (`"EN"` / `"EL"`)
    /// with the channel role + provider name so the user can tell at a
    /// glance which lane they're looking at and which provider is
    /// producing it.
    private var headerText: String {
        let label = DualSidecarLabel.channelLabel(for: channel)
        switch channel {
        case .channelA:
            return "\(label) — Channel A (Apple on-device)"
        case .channelB:
            return "\(label) — Channel B (Apple Cloud)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerText)
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(segments) { segment in
                            segmentView(segment)
                                .id(segment.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.fieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.separator, lineWidth: 0.5)
                )
                .onChange(of: segments.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: segments.last?.lastUpdated) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    /// Per-segment row. Matches the single-mode rendering in
    /// `LiveTranscriptPanel.segmentView(_:)` byte-for-byte (modulo the
    /// surrounding HStack — same fonts, same chip styling, same
    /// italic-while-partial / plain-when-settled treatment) so the
    /// dual-mode display does not visually regress.
    @ViewBuilder
    private func segmentView(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if let lang = segment.language, !lang.isEmpty {
                Text(lang.prefix(2).uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(palette.chipBackground)
                    .cornerRadius(3)
            }
            Text(segment.text)
                .font(.system(size: 11))
                .foregroundStyle(segment.isSettled ? palette.value : palette.secondary)
                .italic(!segment.isSettled)
        }
    }

    /// Scroll the lane to the bottom (the latest segment). No-op when
    /// the lane is empty. Independent of the sibling lane's scroll
    /// position (DT-ADR-8): each lane owns its own `ScrollViewReader`.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let target = segments.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}
