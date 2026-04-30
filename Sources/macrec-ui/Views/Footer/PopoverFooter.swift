// macrec-ui/Views/Footer/PopoverFooter.swift — plan-008 Unit E
// (project-design §UR-4.12 / §UR-5).
//
// Pinned footer band rendered at the bottom of the popover. Hosts the
// `ReadyPill` on the leading edge and the lifecycle button cluster on
// the trailing edge. The button cluster is the existing
// `ControlBar()` view — Unit I already added the
// `transcriptionEnabled` gate inside `ControlBar.startTapped()` and
// the visibility matrix (Start / Pause / Resume / Stop / Split) lives
// there too. We deliberately do NOT re-host the start action here:
// the user's must-preserve invariant ("Stop is always reachable while
// recording") is encoded inside `ControlBar`'s state machine and
// duplicating that logic in the footer would split the source of
// truth.
//
// Visual chrome: a thin top-divider so the footer band reads as a
// pinned region, then 12/10pt padding so the cluster has air around
// it. The mockup `.footer` rule does not draw a divider, but the live
// SwiftUI implementation benefits from one because the popover lacks
// the mockup's gap-and-shadow framing (the popover background is
// AppKit-vibrant, not the page-level gradient).

import MacrecCore
import SwiftUI

/// Pinned footer band — `ReadyPill` + lifecycle controls.
struct PopoverFooter: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(palette.separator)
            HStack(spacing: 10) {
                ReadyPill(state: recordingController?.state ?? .idle)
                Spacer()
                ControlBar()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}
