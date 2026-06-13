// ntakker/Views/Transcription/SourceLane.swift — plan-012 Phase C5.
//
// Single source-tagged transcript lane. Extracted from
// LiveTranscriptPanel.singleBody so the source-split panel
// (Phase C6) can compose two of these without forking the rendering
// logic. The single-mode singleBody also delegates to one of these
// (with no source filter) so there's exactly one rendering code
// path for the segment list.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

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

    private var segments: [TranscriptSegment] {
        let all = recordingController?.transcriptSegments ?? []
        guard let filter else { return all }
        return SourceLaneFilter.segments(all, for: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let headerLabel {
                Text(headerLabel)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(segments) { segment in
                            SegmentChipRow(segment: segment)
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
                .onChange(of: segments.count) { _, _ in scrollToBottom(proxy: proxy) }
                .onChange(of: segments.last?.lastUpdated) { _, _ in scrollToBottom(proxy: proxy) }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let target = segments.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
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
