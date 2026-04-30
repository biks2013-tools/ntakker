// macrec-ui/Views/Header/SaveToChip.swift — plan-008 Unit E
// (project-design §UR-4.8 / UR-ADR-9).
//
// Compact "Save to" chip rendered inside the popover's metadata strip.
// Displays the trailing path component of the persisted output folder
// (e.g. "Recordings") next to a small "Choose…" link that opens the
// same `NSOpenPanel` flow that `FolderPicker` used to host. UR-ADR-9
// consolidates the folder controls into the metadata strip — the row
// that lived in the General section is removed.
//
// The popover-behavior swap (`.transient → .semitransient → .transient`)
// from the original `FolderPicker` is preserved verbatim so a click
// inside the modal panel does not dismiss the popover (R-27,
// project-design §15.11).
//
// The chip reads the same canonical `@AppStorage("com.macrec.ui.outputFolder")`
// key, so the existing `ControlBar.startTapped()` composition picks up
// the user's choice without further wiring. Folder-bootstrapping (R-32 /
// FR-36 — resolve `~/Recordings/` and create on first launch) is also
// preserved through the same `DefaultRecordingFolder.resolve()` helper.

import AppKit
import Logging
import MacrecCore
import MacrecUIKit
import SwiftUI

/// Metadata-strip chip showing the save folder + a Choose… link.
/// Reads the same `@AppStorage` slot the legacy `FolderPicker` used so
/// the existing `ControlBar.startTapped()` composition continues to
/// resolve the persisted path.
struct SaveToChip: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.popoverBehavior) private var popoverBehavior
    @Environment(\.palette) private var palette

    /// Persisted absolute folder path. Empty when the user has not yet
    /// chosen a folder; `onAppear` bootstraps to `~/Recordings/`
    /// (R-32 / FR-36) so the chip always shows a path.
    @AppStorage("com.macrec.ui.outputFolder") private var folderPath: String = ""

    private let logger = Logger(label: "macrec.ui.saveToChip")

    /// Lock the chip while a session is in flight — the engine has
    /// already baked the output URL into the active `RecordingSession`
    /// so changing the folder mid-session would mislead the user
    /// (AC-UI-8 spirit).
    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// Display label — the trailing path component (e.g. "Recordings")
    /// when a folder is chosen, else a short prompt. The full path is
    /// surfaced via `.help(...)`.
    private var displayName: String {
        guard !folderPath.isEmpty else {
            return String(localized: "Choose…")
        }
        return URL(fileURLWithPath: folderPath).lastPathComponent
    }

    private var helpText: String {
        folderPath.isEmpty
            ? String(localized: "Pick the folder where recordings are saved.")
            : folderPath
    }

    var body: some View {
        Button(action: openPanel) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .imageScale(.small)
                    .foregroundStyle(palette.accent)
                Text(displayName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Choose…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.chipBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .help(helpText)
        .onAppear {
            if folderPath.isEmpty {
                folderPath = DefaultRecordingFolder.resolve()
                logger.debug("bootstrapped default folder: \(folderPath)")
            }
        }
    }

    /// Open the folder-only `NSOpenPanel`. Swap popover behavior to
    /// `.semitransient` for the duration of the modal so a click in
    /// the panel does not dismiss us (R-27).
    private func openPanel() {
        logger.debug("opening folder picker (chip)")

        popoverBehavior?(.semitransient)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = String(localized: "Choose Recording Folder")
        panel.prompt = String(localized: "Choose")
        if !folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: folderPath)
        }

        let response = panel.runModal()
        popoverBehavior?(.transient)

        if response == .OK, let url = panel.url {
            folderPath = url.path
            logger.debug("folder selected: \(url.path)")
        } else {
            logger.debug("folder picker cancelled")
        }
    }
}
