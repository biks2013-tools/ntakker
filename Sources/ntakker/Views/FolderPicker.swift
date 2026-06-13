// ntakker/Views/FolderPicker.swift — see project-design.md §15.4,
// §15.11 (popover-behavior swap) and plan-002-toolbar-ui.md §3 Phase E
// (FR-36, R-27, R-32).
//
// "Choose Folder…" button. Opens a folder-only `NSOpenPanel`. While the
// panel is up the popover behavior is swapped to `.semitransient` so a
// click inside the panel does not dismiss our popover (R-27,
// investigation Topic 1 gotcha). Once the panel returns, behavior is
// restored to `.transient`.
//
// Persistence: the chosen folder URL is stored as a `String` (its
// `path` representation) under the canonical
// `com.ntakker-cli.ui.outputFolder` UserDefaults key per FR-36. The value
// survives popover open/close.
//
// FR-36 default folder (R-32 fix): when no folder has been persisted
// (`folderPath == ""`), `DefaultRecordingFolder.resolve()` resolves the
// default to `~/Recordings/`, creates the directory if it does not yet
// exist, and persists the resolved path back into the same `@AppStorage`
// key on first launch so subsequent launches show the path explicitly.
// `ControlBar` calls the same helper at view-build time so the Start
// button is enabled on first launch (no friction-y "pick a folder
// first" gate).
//
// Disabled while non-`.idle` (AC-UI-8 spirit — output folder is part of
// the active session's URL composition).

import AppKit
import Logging
import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Resolves the default output folder used by `FolderPicker` and
/// `ControlBar` when no folder has been persisted. Pure helper —
/// callable from any view's `body`. The implementation is conservative:
/// it tries `~/Recordings/`, then `~/Documents/`, then
/// `NSTemporaryDirectory()`, returning the first path that either
/// already exists as a directory or that we successfully create.
enum DefaultRecordingFolder {

    /// Resolve a usable default output folder. The function is
    /// idempotent — repeated calls return the same path on the same
    /// host (modulo first-time directory creation).
    ///
    /// - Returns: The absolute path string suitable for storing into
    ///   `@AppStorage("com.ntakker-cli.ui.outputFolder")` and for handing to
    ///   `URL(fileURLWithPath:isDirectory:)`.
    static func resolve() -> String {
        let logger = Logger(label: "ntakker-cli.ui.defaultFolder")
        let fm = FileManager.default

        let candidates: [URL] = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]

        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate.path
            }
            // Try to create. Only the first candidate (`~/Recordings/`)
            // is expected to need creation; the others should exist on
            // any sane macOS install.
            do {
                try fm.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.info("created default recording folder at \(candidate.path)")
                return candidate.path
            } catch {
                logger.warning(
                    "failed to create default recording folder at \(candidate.path): \(error.localizedDescription)"
                )
                // Fall through to the next candidate.
            }
        }
        // All candidates failed (including TemporaryDirectory, which
        // would be extraordinary). Return the first as a best effort —
        // the engine factory will surface a clear `outputParentMissing`
        // error if the path is genuinely unusable.
        return candidates.first!.path
    }
}

/// Folder selector. Click → modal `NSOpenPanel` → updates `@AppStorage`.
struct FolderPicker: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.popoverBehavior) private var popoverBehavior

    /// Persisted absolute folder path. Empty when the user has not yet
    /// chosen a folder; the controller composes a default at `start()`.
    @AppStorage("com.ntakker-cli.ui.outputFolder") private var folderPath: String = ""

    /// Component-scoped logger for the side-effect of opening the panel.
    private let logger = Logger(label: "ntakker-cli.ui.folderPicker")

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// Truncated display label for the button — last two path
    /// components when the path is long, else the full path. An empty
    /// path renders the placeholder "Choose…".
    private var buttonLabel: String {
        guard !folderPath.isEmpty else {
            return String(localized: "Choose Folder…")
        }
        let url = URL(fileURLWithPath: folderPath)
        let comps = url.pathComponents
        if comps.count <= 3 {
            return folderPath
        }
        // Show "…/parent/leaf" so long /Users/<name>/… paths stay short.
        let tail = comps.suffix(2).joined(separator: "/")
        return "…/\(tail)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "Folder"))
            Spacer(minLength: 0)
            Button(buttonLabel) {
                openPanel()
            }
            .disabled(isLocked)
            .help(folderPath.isEmpty
                  ? String(localized: "Pick the folder where recordings are saved.")
                  : folderPath)
        }
        .onAppear {
            // FR-36 default-folder bootstrap (R-32). On first launch
            // `folderPath` is empty; resolve `~/Recordings/`, create it
            // if missing, and persist the resolved path so the picker
            // shows it explicitly from this point on.
            if folderPath.isEmpty {
                folderPath = DefaultRecordingFolder.resolve()
                logger.debug("bootstrapped default folder: \(folderPath)")
            }
        }
    }

    /// Show the folder-only `NSOpenPanel`. Swaps the popover behavior
    /// for the duration of the modal so the popover does not dismiss
    /// (R-27).
    private func openPanel() {
        logger.debug("opening folder picker")

        // Swap to .semitransient so a click in the panel does not
        // dismiss the popover (R-27).
        popoverBehavior?(.semitransient)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = String(localized: "Choose Recording Folder")
        panel.prompt = String(localized: "Choose")

        // Pre-populate with the previously-selected folder when one
        // exists so the panel opens where the user expects.
        if !folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: folderPath)
        }

        // `runModal` blocks the main thread; that is fine — the popover
        // is in `.semitransient` mode for the duration.
        let response = panel.runModal()

        // Restore .transient *before* updating @AppStorage so a click
        // outside the popover after the panel closes dismisses us as
        // expected.
        popoverBehavior?(.transient)

        if response == .OK, let url = panel.url {
            folderPath = url.path
            logger.debug("folder selected: \(url.path)")
        } else {
            logger.debug("folder picker cancelled")
        }
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
