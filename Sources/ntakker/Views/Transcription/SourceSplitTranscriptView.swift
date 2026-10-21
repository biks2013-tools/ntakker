// ntakker/Views/Transcription/SourceSplitTranscriptView.swift —
// plan-012 Phase C6. Two-lane stacked view used when single-mode +
// `--transcribe-source both` is active. Each lane is a SourceLane
// with the matching SourceTag filter and a friendly header.
//
// 2026-10-21: the divider between the lanes can be dragged (double-
// click restores 50/50), each lane collapses from its header, and the
// lanes scroll together or independently (the panel header's toggle).
// All four choices are remembered.

import AppKit
import NtakkerCore
import NtakkerUIKit
import SwiftUI

struct SourceSplitTranscriptView: View {
    static let systemFractionKey = "com.ntakker-cli.ui.sourceSplit.systemFraction"
    static let systemCollapsedKey = "com.ntakker-cli.ui.sourceSplit.systemCollapsed"
    static let micCollapsedKey = "com.ntakker-cli.ui.sourceSplit.micCollapsed"
    static let syncScrollKey = "com.ntakker-cli.ui.sourceSplit.syncScroll"

    @Environment(\.palette) private var palette

    @AppStorage(Self.systemFractionKey) private var systemFraction = SourceSplitLayout.defaultFraction
    @AppStorage(Self.systemCollapsedKey) private var systemCollapsed = false
    @AppStorage(Self.micCollapsedKey) private var micCollapsed = false
    @AppStorage(Self.syncScrollKey) private var syncScroll = true

    @State private var scrollSync = LaneScrollSync()
    @State private var dragStart: Double?

    private static let handleHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let bothOpen = !systemCollapsed && !micCollapsed
            let available = max(geo.size.height - Self.handleHeight, 1)
            VStack(spacing: 0) {
                SourceLane(
                    filter: .system,
                    headerLabel: String(localized: "System audio"),
                    collapsed: $systemCollapsed,
                    sync: bothOpen && syncScroll ? scrollSync : nil,
                    partner: .microphone,
                    leads: true
                )
                .frame(height: bothOpen ? available * SourceSplitLayout.clamped(systemFraction) : nil)
                .frame(maxHeight: bothOpen || systemCollapsed ? nil : .infinity, alignment: .top)

                if bothOpen {
                    divider(available: available)
                } else {
                    Spacer().frame(height: 6)
                }

                SourceLane(
                    filter: .microphone,
                    headerLabel: String(localized: "Microphone"),
                    collapsed: $micCollapsed,
                    sync: bothOpen && syncScroll ? scrollSync : nil,
                    partner: .system
                )
                .frame(maxHeight: micCollapsed ? nil : .infinity, alignment: .top)

                if systemCollapsed && micCollapsed {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: syncScroll) { _, on in
            if on { scrollSync.align() }
        }
    }

    /// The drag handle between the lanes.
    private func divider(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(palette.separator)
                .frame(width: 36, height: 4)
        }
        .frame(height: Self.handleHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? SourceSplitLayout.clamped(systemFraction)
                    dragStart = start
                    systemFraction = SourceSplitLayout.fraction(
                        start: start, translation: value.translation.height, available: available)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) {
            systemFraction = SourceSplitLayout.defaultFraction
        }
        .help(String(localized: "Drag to share the space between System audio and Microphone; double-click for half and half"))
        .accessibilityLabel(String(localized: "Divider between System audio and Microphone"))
    }
}
