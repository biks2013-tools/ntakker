// macrec-ui/Views/Transcription/LiveTranscriptPanel.swift — see
// project-design.md §LT-8.1 / §LT-8.5 and plan-003 Phase G,
// updated for plan-004 Phase H (rest-batch event shape).
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

import MacrecCore
import MacrecUIKit
import SwiftUI

struct LiveTranscriptPanel: View {
    @Environment(\.recordingController) private var recordingController

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
                    HStack {
                        Text("Transcript")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TranscriptionStatusBadge()
                    }
                    if let err = lastError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
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
                        }
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                        .onChange(of: segments.count) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: segments.last?.lastUpdated) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
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
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
            }
            Text(segment.text)
                .font(.system(size: 11))
                .foregroundStyle(segment.isSettled ? .primary : .secondary)
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
