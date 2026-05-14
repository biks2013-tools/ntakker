// macrec-ui/Settings/SettingsWindowController.swift
//
// Modal Settings window controller.
//
// Background: prior to this file, Settings was hosted in SwiftUI's
// `Settings { … }` scene (see `MacrecUIApp.swift`). That scene produces
// a non-modal `NSWindow` — the user could continue to drive the popover
// (start/stop recordings, change layout, etc.) while Settings was open,
// which led to surprising mid-recording state changes when API keys or
// provider selections were mutated in parallel.
//
// This controller replaces that flow with an **AppKit `NSWindow` run
// modally via `NSApp.runModal(for:)`**. While the modal session is
// active, all other windows in the app — including the popover — stop
// receiving user events. The recording engine itself is unaffected:
// it runs off background tasks and dispatch queues that the AppKit
// modal event loop does not block, so the elapsed-time HUD keeps
// ticking and audio capture continues. Only USER INTERACTION with
// other surfaces is blocked.
//
// Lifecycle: the controller is instantiated once by `AppDelegate` in
// `applicationDidFinishLaunching(_:)` and retained for the lifetime of
// the app. `show()` is idempotent — calling it while the window is
// already on screen is a no-op (the existing modal session continues).
//
// Dismissal paths handled cleanly:
//   * Standard close button (red traffic light) — `windowWillClose`
//     observer calls `NSApp.stopModal()`.
//   * Cmd-W — routed by `NSWindow.performClose(_:)` → same path as the
//     close button.
//   * Esc — `cancelOperation(_:)` overridden on a custom `NSWindow`
//     subclass to call `performClose(nil)`.
//
// Threading: `NSWindow` and `NSApp.runModal` are main-thread-only. The
// controller is `@MainActor`.

import AppKit
import Logging
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject {

    /// Lazily-created window. Held across `show()` calls so re-opening
    /// preserves user state (selected sidebar category, scroll position,
    /// in-progress text edits within Settings sections — all of which
    /// otherwise reset on a freshly built NSHostingController).
    private var window: SettingsModalWindow?

    /// True while `NSApp.runModal(for:)` is executing for our window.
    /// Used to make `show()` idempotent (a second click on the gear
    /// button while Settings is already visible should be a no-op
    /// rather than starting a nested modal session).
    private var isShowing = false

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Bring up the Settings window modally. Blocks the main event loop
    /// for other windows until the user dismisses Settings.
    ///
    /// Idempotent: if Settings is already on screen, brings the window
    /// forward but does NOT start a nested modal session.
    func show() {
        if isShowing, let existing = window {
            logger.debug("show: Settings already presented; bringing forward")
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = window ?? makeWindow()
        self.window = window

        logger.info("show: presenting Settings modally")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isShowing = true
        // `runModal(for:)` blocks until `NSApp.stopModal()` is called
        // (we wire that to `windowWillClose` below). AppKit's modal
        // event loop still pumps Tasks and timers on the main actor,
        // so the recording state observer in AppDelegate keeps working.
        NSApp.runModal(for: window)
        isShowing = false

        // Hide the window so the next `show()` re-centers it (and so
        // it does not linger as an invisible-but-allocated NSWindow on
        // some screen the user has since unplugged).
        window.orderOut(nil)
        logger.debug("show: modal session ended")
    }

    /// Programmatic close path — used by the QuitFlow if a quit is
    /// confirmed while Settings is open. Safe to call when Settings is
    /// not visible.
    func close() {
        guard isShowing, let window else { return }
        logger.debug("close: dismissing Settings modal")
        window.performClose(nil)
    }

    // MARK: - Window construction

    private func makeWindow() -> SettingsModalWindow {
        let hosting = NSHostingController(
            rootView: AppearanceHostingRoot {
                SettingsRootView()
            }
        )
        // SettingsRootView already declares its own minimum frame
        // (720 x 540). Mirror it here so the initial NSWindow content
        // size matches what SwiftUI will lay out, avoiding an ugly
        // resize on first paint.
        hosting.preferredContentSize = NSSize(width: 720, height: 540)

        let window = SettingsModalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = String(localized: "Settings")
        // Reuse the window between presentations so SwiftUI state in
        // the sidebar/detail views is preserved. `runModal` requires
        // the window to be retained outside the modal session, so we
        // must NOT let AppKit release it on close.
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

// MARK: - NSWindowDelegate — drive the modal session

extension SettingsWindowController: NSWindowDelegate {

    /// Called when the user clicks the close button, hits Cmd-W, or
    /// Esc (routed through `SettingsModalWindow.cancelOperation`).
    /// Stop the modal session so `NSApp.runModal(for:)` returns and
    /// the rest of the app becomes interactable again.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // `stopModal` is a no-op if we are not currently running
            // a modal session — safe to call defensively.
            NSApp.stopModal()
        }
    }
}

// MARK: - Custom NSWindow that closes on Esc

/// `NSWindow` subclass whose only purpose is to honor the Esc key as
/// a dismiss gesture, matching macOS conventions for modal dialogs
/// (System Settings, Software Update, Sign In sheets, etc.).
///
/// `NSResponder.cancelOperation(_:)` is the AppKit hook the OS calls
/// when Esc (or Cmd-.) is pressed on the key window. The default
/// implementation does nothing for plain `NSWindow`s; we override it
/// to perform the standard close, which routes through the same
/// `windowWillClose` path as the title-bar close button.
@MainActor
final class SettingsModalWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
