// ntakker/Views/Transcription/SourceLane.swift — plan-012 Phase C5.
//
// Single source-tagged transcript lane. Extracted from
// LiveTranscriptPanel.singleBody so the source-split panel
// (Phase C6) can compose two of these without forking the rendering
// logic. The single-mode singleBody also delegates to one of these
// (with no source filter) so there's exactly one rendering code
// path for the segment list.
//
// 2026-10-21: lanes can be collapsed from their header, and the two
// lanes of the split view can scroll together (`LaneScrollSync`).
// A lane follows the live text only while it is at the bottom.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Lets the two lanes of the source-split transcript scroll together
/// (2026-10-21): the lane the user scrolls asks the other one to show
/// the line that lines up in time with its own top line, or to go to
/// the bottom when it is at the bottom.
@MainActor @Observable
final class LaneScrollSync {
    struct Request: Equatable {
        let target: SourceTag
        /// `nil` → the bottom (follow the live text).
        let segmentID: UUID?
        let serial: Int
    }

    private(set) var request: Request?
    /// Bumped to ask the leading lane to align the other one now
    /// (when scrolling together is switched on).
    private(set) var alignSerial = 0
    private var serial = 0

    func scroll(_ target: SourceTag, to segmentID: UUID?) {
        guard request?.target != target || request?.segmentID != segmentID else { return }
        serial += 1
        request = Request(target: target, segmentID: segmentID, serial: serial)
    }

    func align() { alignSerial += 1 }
}

struct SourceLane: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    /// `nil` → render every segment (used by singleBody in non-split mode).
    /// non-nil → filter to segments whose `source` matches.
    let filter: SourceTag?

    /// Optional header label rendered above the scroll view (e.g.
    /// "System audio" / "Microphone"). `nil` for the unfiltered case
    /// so singleBody stays visually byte-equivalent to pre-plan-012.
    let headerLabel: String?

    /// When set, the header collapses / expands the lane.
    var collapsed: Binding<Bool>? = nil

    /// When set, scrolling this lane scrolls `partner` to the line
    /// that lines up in time (the lanes scroll together).
    var sync: LaneScrollSync? = nil
    var partner: SourceTag? = nil
    /// The lane that aligns the other when scrolling together is
    /// switched on.
    var leads = false

    @State private var visibleIDs: Set<UUID> = []
    /// The lane shows the latest line and keeps up with the live text.
    /// Changed only by the user's scrolling (or the partner lane's
    /// request), never by a resize or a new line.
    @State private var followLive = true
    /// Where the lane is right now (from its scroll geometry).
    @State private var atBottom = true
    @State private var userScrolling = false

    private var segments: [TranscriptSegment] {
        let all = recordingController?.transcriptSegments ?? []
        guard let filter else { return all }
        return SourceLaneFilter.segments(all, for: filter)
    }

    private var isCollapsed: Bool { collapsed?.wrappedValue ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let headerLabel {
                header(headerLabel)
            }
            if !isCollapsed {
                lane
            }
        }
    }

    @ViewBuilder
    private func header(_ label: String) -> some View {
        if let collapsed {
            Button {
                collapsed.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 10)
                    Text(label)
                    if collapsed.wrappedValue, !segments.isEmpty {
                        Text(segments.count == 1 ? "· 1 line" : "· \(segments.count) lines")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(palette.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .help(collapsed.wrappedValue
                  ? String(localized: "Show the \(label) text")
                  : String(localized: "Hide the \(label) text"))
        } else {
            Text(label)
                .font(.caption2)
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 8)
        }
    }

    private var lane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(segments) { segment in
                        SegmentChipRow(segment: segment)
                            .id(segment.id)
                    }
                }
                .scrollTargetLayout()
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
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { ids in
                visibleIDs = Set(ids)
                if userScrolling { drivePartner() }
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24
            } action: { _, bottom in
                atBottom = bottom
                if userScrolling {
                    followLive = bottom
                    drivePartner()
                }
            }
            // Dragging the divider or collapsing the other lane
            // changes the height: a lane that follows stays at the end.
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, _ in
                if followLive { scrollToBottom(proxy: proxy, animated: false) }
            }
            .onScrollPhaseChange { _, phase in
                // Only the lane the user scrolls drives the other; a
                // lane moved by code never answers back.
                userScrolling = phase == .interacting || phase == .decelerating
            }
            // Open (and re-open after collapsing) at the latest line,
            // so the lane follows the live text from the start.
            .onAppear {
                followLive = true
                DispatchQueue.main.async { scrollToBottom(proxy: proxy, animated: false) }
            }
            // Follow the live text only while the lane is at the
            // bottom, so a lane scrolled back to read stays put.
            .onChange(of: segments.count) { _, _ in
                if followLive { scrollToBottom(proxy: proxy) }
            }
            .onChange(of: segments.last?.lastUpdated) { _, _ in
                if followLive { scrollToBottom(proxy: proxy) }
            }
            .onChange(of: sync?.request) { _, request in
                guard let request, request.target == filter else { return }
                followLive = request.segmentID == nil
                if let id = request.segmentID {
                    proxy.scrollTo(id, anchor: .top)
                } else {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onChange(of: sync?.alignSerial) { _, _ in
                if leads { drivePartner() }
            }
        }
    }

    /// Scrolling together: show the partner lane's line that lines up
    /// with this lane's top line, or its bottom when this lane is at
    /// the bottom.
    private func drivePartner() {
        guard let sync, let partner else { return }
        if followLive {
            sync.scroll(partner, to: nil)
            return
        }
        let shown = segments
        guard let top = shown.first(where: { visibleIDs.contains($0.id) }) else { return }
        let others = SourceLaneFilter.segments(recordingController?.transcriptSegments ?? [], for: partner)
        guard let target = SourceSplitLayout.alignedSegmentID(in: others, at: top.timestamp) else { return }
        sync.scroll(partner, to: target)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target = segments.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

/// Per-segment chip row, extracted from the existing
/// `LiveTranscriptPanel.segmentView(_:)` helper. Renders the language
/// chip and the speaker chip (Phase A8) alongside the segment text.
struct SegmentChipRow: View {
    @Environment(\.palette) private var palette
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let lang = segment.language, !lang.isEmpty {
                Text(lang.prefix(2).uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(palette.chipBackground).cornerRadius(3)
            }
            if let speakerLabel = SpeakerSidecarLabel.label(for: segment.speaker) {
                Text(speakerLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(palette.chipBackground).cornerRadius(3)
            }
            Text(segment.text)
                .font(.system(size: 11))
                .foregroundStyle(segment.isSettled ? palette.value : palette.secondary)
                .italic(!segment.isSettled)
        }
    }
}
