// ntakker/MarkdownPaneExporter.swift
//
// Tiny shared helper used by the per-pane "save" affordance in both
// `LiveTranscriptPanel` (transcript) and `AskingModeView` (Q&A). The
// button hands this helper a string of already-rendered Markdown plus
// a default filename; the helper presents an `NSSavePanel`, writes the
// chosen URL atomically, and bridges the `\.popoverBehavior`
// `.semitransient` swap (R-27) so the menu-bar popover does not
// dismiss while the panel is up — same dance `FolderPicker.openPanel()`
// performs for `NSOpenPanel`.

import AppKit
import Foundation
import os
import UniformTypeIdentifiers

@MainActor
enum MarkdownPaneExporter {

    private static let log = Logger(
        subsystem: "com.local.ntakker",
        category: "MarkdownPaneExporter"
    )

    /// Present a `.md` `NSSavePanel` and atomically write `contents`
    /// to the chosen URL. Returns the URL on success, `nil` if the
    /// user cancelled (or if a write error was surfaced via the
    /// `errorMessage` closure).
    ///
    /// - Parameters:
    ///   - contents: The rendered Markdown body to persist verbatim.
    ///   - defaultFilename: Pre-populated name in the panel
    ///     (e.g. `"transcript.md"`, `"qa.md"`).
    ///   - title: Panel title shown to the user.
    ///   - behaviorSetter: The `\.popoverBehavior` closure injected at
    ///     the popover root. While present, swap to `.semitransient`
    ///     for the duration of the modal and restore `.transient`
    ///     immediately after — otherwise a click anywhere in the panel
    ///     dismisses the popover (R-27).
    ///   - errorMessage: Optional sink for a localized error string the
    ///     caller can surface in its own UI. Called only when the write
    ///     fails after the user picked a destination.
    @discardableResult
    static func presentSave(
        contents: String,
        defaultFilename: String,
        title: String,
        behaviorSetter: PopoverBehaviorSetter?,
        errorMessage: ((String) -> Void)? = nil
    ) -> URL? {
        behaviorSetter?(.semitransient)
        defer { behaviorSetter?(.transient) }

        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = String(localized: "Save")
        panel.nameFieldStringValue = defaultFilename
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // `ntakker` is `LSUIElement=true` (menu-bar accessory). Without
        // an explicit activate the app stays in the background; a modal
        // NSSavePanel then opens but cannot become key — every keystroke
        // (including the user typing the file's name) is met with the
        // "no responder" system beep. Activating immediately before
        // `runModal()` lets AppKit promote the panel to the key window
        // for the duration of the modal.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            log.debug("save panel cancelled for \(defaultFilename, privacy: .public)")
            return nil
        }

        do {
            guard let data = contents.data(using: .utf8) else {
                throw NSError(
                    domain: "MarkdownPaneExporter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"]
                )
            }
            try data.write(to: url, options: [.atomic])
            log.info("wrote \(url.path, privacy: .public) (\(data.count, privacy: .public) bytes)")
            return url
        } catch {
            log.error("write \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            errorMessage?(error.localizedDescription)
            return nil
        }
    }
}
