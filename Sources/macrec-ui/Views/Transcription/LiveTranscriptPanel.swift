// macrec-ui/Views/Transcription/LiveTranscriptPanel.swift — see
// project-design.md §LT-8.1 / §LT-8.5 and plan-003 Phase G,
// updated for plan-004 Phase H (rest-batch event shape) and
// plan-010 Phase G / Lane L-9 (Wave 6 — dual-lane display branch).
//
// Renders the live `transcriptSegments` array straight from the
// `RecordingController`. Each segment is the coalesced output of one
// or more provider calls — text grows in place via
// `TranscriptionEvent.segmentUpdated`. The panel auto-scrolls on every
// new or updated segment. Hidden entirely when transcription is idle
// and no segments have accumulated.
//
// Cap: `RecordingController.maxLiveTranscriptSegments` segments
// retained (oldest dropped). Sidecar file remains the persistent
// record for everything that scrolls off the top.
//
// Mode branch (plan-010 Lane L-9 / DT-INV — single-mode unchanged):
//   * Reads the persisted `LiveTranscriptionMode` from
//     `@AppStorage(RecordingController.transcriptionModeStorageKey)`
//     (the same source the controls in `LiveTranscriptionSection`
//     read from).
//   * `.single` → renders the existing flat-list panel below
//     (BYTE-FOR-BYTE UNCHANGED — this is DT-INV: the
//     `LiveTranscriptPanelSingleModeTests` regression suite asserts
//     no structural drift).
//   * `.dual` → renders `DualLiveTranscriptView()` (Lane L-9 view
//     that composes two stacked `DualLiveTranscriptLane`s with
//     independent auto-scroll per lane, per DT-ADR-8 / OQ-5).
//   The branch happens INSIDE the existing `Group { ... }.frame(...)`
//   wrapper so the panel still occupies its slot identically in both
//   modes.

import MacrecCore
import MacrecUIKit
import SwiftUI

struct LiveTranscriptPanel: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    /// Persisted live-transcription mode (Single / Dual) — read here
    /// directly via `@AppStorage` so the panel reactively re-renders
    /// when the user flips the mode switch in `LiveTranscriptionSection`,
    /// without needing a controller-side `Notification` round-trip.
    /// Bad / missing values collapse to `.single` (matches
    /// `RecordingController.loadTranscriptionMode`).
    @AppStorage(RecordingController.transcriptionModeStorageKey)
    private var transcriptionModeRaw: String = LiveTranscriptionMode.single.rawValue

    private var transcriptionMode: LiveTranscriptionMode {
        LiveTranscriptionMode(rawValue: transcriptionModeRaw) ?? .single
    }

    /// Persisted source picker (com.macrec.ui.transcribeSource) —
    /// used by the Phase C6 three-way branch to switch into the
    /// SourceSplitTranscriptView when single-mode + `.both` is
    /// selected. Matches the same key used by ControlBar /
    /// TranscriptionSourcePicker so they stay in sync.
    @AppStorage("com.macrec.ui.transcribeSource")
    private var transcribeSourceRaw: String = TranscriptionSource.mixed.rawValue

    private var transcribeSource: TranscriptionSource {
        TranscriptionSource(rawValue: transcribeSourceRaw) ?? .mixed
    }

    /// Floor on the inner scroll-view height so even on a small
    /// popover there is room for two or three lines of transcript.
    /// The previous build had a fixed 200pt cap; the user reported
    /// that resizing the popover left the extra height as empty
    /// padding above and below the content. Removing the cap (and
    /// letting the inner ScrollView grow to `.infinity`) makes the
    /// transcript absorb the extra vertical space — the parent
    /// `RootView` now applies `.frame(maxHeight: .infinity)` to this
    /// panel so the slot reaches the full popover interior.
    private static let minBodyHeight: CGFloat = 80

    private var segments: [TranscriptSegment] {
        recordingController?.transcriptSegments ?? []
    }

    private var status: TranscriptionUIState {
        recordingController?.transcriptionStatus ?? .idle
    }

    private var lastError: String? {
        recordingController?.lastTranscriptionError
    }

    /// Visibility gate. Per design §LT-8.1 the panel is hidden when
    /// there is no content and transcription has not started.
    private var shouldShow: Bool {
        if !segments.isEmpty { return true }
        switch status {
        case .idle:
            return false
        default:
            return true
        }
    }

    var body: some View {
        // Three-way branch — plan-012 Phase C6.
        //   * .dual         → existing dualBody (plan-010, byte-equiv).
        //   * .sourceSplit  → NEW sourceSplitBody (single mode + .both).
        //   * .single       → existing singleBody (DT-INV preserved
        //                     for .system / .mic / .mixed).
        let branch = LiveTranscriptPanelBranchSelector.branch(
            mode: transcriptionMode,
            source: transcribeSource
        )
        switch branch {
        case .dual:        dualBody
        case .sourceSplit: sourceSplitBody
        case .single:      singleBody
        }
    }

    /// Source-split body — plan-012 Phase C6. Wraps the new
    /// SourceSplitTranscriptView in the same chrome (Transcript
    /// header, optional Clear button, status badge, error banner)
    /// and outer .frame(...) modifier as singleBody so the panel
    /// claims its vertical slot identically across all three modes.
    private var sourceSplitBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Transcript")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                Spacer()
                if !segments.isEmpty {
                    Button {
                        recordingController?.clearTranscriptSegments()
                    } label: {
                        Image(systemName: "trash")
                            .imageScale(.small)
                            .foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Clear transcript (sidecar files are unaffected)"))
                    .accessibilityLabel(String(localized: "Clear transcript"))
                }
                TranscriptionStatusBadge()
            }
            if let err = lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 4)
            }
            SourceSplitTranscriptView()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.groupBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.groupStroke, lineWidth: 0.5)
        )
        .frame(
            minHeight: Self.minBodyHeight,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    /// Dual-mode body — Lane L-9 entry point. Wraps
    /// `DualLiveTranscriptView` in the same `groupBackground` chrome
    /// + outer `.frame(...)` modifier as the single-mode body so the
    /// panel claims its vertical slot identically in both modes.
    private var dualBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Transcript")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                Spacer()
                if !segments.isEmpty {
                    Button {
                        recordingController?.clearTranscriptSegments()
                    } label: {
                        Image(systemName: "trash")
                            .imageScale(.small)
                            .foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Clear transcript (sidecar file is unaffected)"))
                    .accessibilityLabel(String(localized: "Clear transcript"))
                }
                TranscriptionStatusBadge()
            }
            if let err = lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 4)
            }
            DualLiveTranscriptView()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.groupBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.groupStroke, lineWidth: 0.5)
        )
        .frame(
            minHeight: Self.minBodyHeight,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    /// Single-mode body — verbatim extraction of the pre-plan-010
    /// panel body (DT-INV: byte-for-byte unchanged). DO NOT modify
    /// this view's contents in dual-mode lanes; modifications here
    /// must be co-changed in `dualBody` so the two modes stay
    /// visually consistent.
    private var singleBody: some View {
        // The panel ALWAYS claims its slot, whether transcription is
        // idle (Color.clear placeholder) or active (full content).
        // Without this, the parent's `.frame(maxHeight: .infinity)`
        // wraps an `EmptyView` when transcription is idle — and
        // EmptyView does not take space, so the parent VStack ends up
        // shorter than the popover frame and SwiftUI's default
        // `.center` alignment on `.frame(height:)` produces empty
        // padding above and below the controls. Filling the slot with
        // a flexible `Color.clear` keeps the layout pinned regardless
        // of whether the transcript has content yet.
        Group {
            if shouldShow {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Transcript")
                            .font(.caption)
                            .foregroundStyle(palette.secondary)
                        Spacer()
                        if !segments.isEmpty {
                            Button {
                                recordingController?.clearTranscriptSegments()
                            } label: {
                                Image(systemName: "trash")
                                    .imageScale(.small)
                                    .foregroundStyle(palette.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Clear transcript (sidecar file is unaffected)"))
                            .accessibilityLabel(String(localized: "Clear transcript"))
                        }
                        TranscriptionStatusBadge()
                    }
                    if let err = lastError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(palette.secondary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 4)
                    }
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.groupBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.groupStroke, lineWidth: 0.5)
                )
            } else {
                // Idle placeholder — invisible but flexible. Claims
                // the parent's `.frame(maxHeight: .infinity)` slot so
                // the bottom band stays pinned to the bottom and the
                // controls stay pinned to the top instead of being
                // centered.
                Color.clear
            }
        }
        .frame(
            minHeight: Self.minBodyHeight,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    @ViewBuilder
    private func segmentView(_ segment: TranscriptSegment) -> some View {
        // Plan-005 Phase H:
        //   * Optional BCP-47 language chip (first two letters,
        //     uppercased) when the streaming pipeline has tagged the
        //     segment with a winning locale. v1.5 always shows the chip
        //     when present — gating on >= 2 distinct languages would
        //     require plumbing `activeLanguages` through the controller
        //     and is deferred.
        //   * "Settled" visual treatment: italic-secondary while the
        //     segment is still partial (no `durationSec`); plain-primary
        //     once `.segmentFinalized` has stamped the duration.
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
            // Plan-012 Phase A8: speaker chip — rendered next to the
            // language chip when the segment carries a non-nil
            // speaker (currently only Soniox with diarization enabled).
            // Uses SpeakerSidecarLabel for the display string so the
            // chip and the sidecar files agree on the convention
            // (e.g. "spk:1" → "S1").
            if let speakerLabel = SpeakerSidecarLabel.label(for: segment.speaker) {
                Text(speakerLabel)
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

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let target = segments.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

// MARK: - TranscriptSegment + isSettled (UI-only — Phase H)

extension TranscriptSegment {
    /// True once the streaming pipeline has emitted a
    /// `.segmentFinalized` event for this segment. We piggy-back on
    /// `durationSec` because the streaming pipeline's finalize handler
    /// is the only producer that stamps a non-nil duration.
    var isSettled: Bool { durationSec != nil }
}
