// macrec-ui/RootView.swift — see project-design.md §15.1, §15.2,
// §15.4 and plan-002-toolbar-ui.md §3 Phase E.
//
// Top-level SwiftUI body that the `NSPopover` hosts via
// `NSHostingController<RootView>`.
//
// PHASE E — composes the real popover form. Every sub-view lives in
// `Sources/macrec-ui/Views/` and reads
// `@Environment(\.recordingController)` to pull state from the shared
// `RecordingController`. The popover is small (~360 pt wide); the form
// is a vertical stack with row-shaped composite cells.
//
// Layout (top-to-bottom):
//   0. ErrorBanner                  — only when latestError != nil
//                                     (Phase G; self-conditions, returns
//                                     EmptyView when no error)
//   1. PermissionStatusView         — top-of-popover indicator block
//   2. FilenameField + FormatPicker — composed in one row
//   3. LayoutPicker + FolderPicker  — composed in one row
//   4. MicrophonePicker             — full-width row
//   5. LevelMeterView               — only while recording / paused
//   6. ElapsedTimeView              — only while recording / paused
//   7. ControlBar                   — always visible
//   8. SavedToDisclosure            — only when segments non-empty
//
// Per the design (§15.12 Threading): every view is implicitly
// `@MainActor` (SwiftUI default on macOS 14+); no explicit annotation
// is required on the view itself. The environment-supplied
// `RecordingController` is itself `@MainActor`-isolated so any reads
// here are safe.
//
// Phase F (quit-while-recording) and Phase G (error mapping) both edit
// this file. To keep merge-friendly, Phase E confines its changes to:
//   * replacing the body composition;
//   * keeping the `@Environment(\.recordingController)` declaration in
//     the same position so Phase F/G's environment additions can sit
//     beside it without conflicts.

import MacrecUIKit
import SwiftUI

/// Top-level popover content view. Hosted by
/// `PopoverController.popover.contentViewController =
/// NSHostingController<RootView>(rootView: RootView())`.
struct RootView: View {
    @Environment(\.recordingController) private var recordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ErrorBanner()
                .animation(
                    .easeInOut(duration: 0.2),
                    value: recordingController?.latestError != nil
                )

            PermissionStatusView()

            Divider()

            HStack(spacing: 8) {
                FilenameField()
                FormatPicker()
                    .frame(width: 110)
            }

            HStack(spacing: 8) {
                LayoutPicker()
                    .frame(width: 150)
                Spacer(minLength: 0)
                FolderPicker()
            }

            MicrophonePicker()

            if showsLiveStats {
                Divider()
                LevelMeterView()
                ElapsedTimeView()
            }

            Divider()

            ControlBar()

            if showsSavedDisclosure {
                Divider()
                SavedToDisclosure()
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    /// Live stats (level meters + elapsed clock) appear while there is
    /// an active or paused session. Phases F/G are not affected by
    /// this gate — they only mutate the alert / quit pipeline.
    private var showsLiveStats: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .recording, .paused, .pausing, .resuming, .splitting, .stopping:
            return true
        default:
            return false
        }
    }

    /// Saved-files disclosure appears only when segments have been
    /// produced. The disclosure view itself also no-ops on empty.
    private var showsSavedDisclosure: Bool {
        !(recordingController?.completedSegments.isEmpty ?? true)
    }
}
