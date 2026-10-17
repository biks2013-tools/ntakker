// ntakker/UILoggingMenu.swift — see project-design.md §15.13 (logging),
// plan-002-toolbar-ui.md §3 Phase H, and NFR-16 (hidden debug toggle).
//
// DEBUG-ONLY hidden affordance. NOT surfaced in normal UI. The user
// must hold the Option (⌥) key while clicking the menu-bar icon to
// reveal this menu. A normal (non-option) click toggles the popover
// as usual — see `StatusItemController.handleClick()`.
//
// The menu is intentionally minimalistic: three radio-style items
// (`Log level: info`, `Log level: debug`, `Log level: trace`). Picking
// one re-bootstraps the underlying swift-log handler at the new level
// via `LoggerFactory.bootstrap(subsystem:fileURL:levelString:)`. The
// re-bootstrap is idempotent on (subsystem, fileURL): the second-and-
// later calls only mutate the shared level cell — they do NOT
// re-invoke `LoggingSystem.bootstrap` (which traps).
//
// NOTE on placement: this file is NOT a SwiftUI view. It is an AppKit
// `NSMenu` constructed and shown imperatively from `AppDelegate` when
// the user option-clicks the status-item button. SwiftUI's `MenuBarExtra`
// would be a more idiomatic fit, but project-design ADR 032 locks the
// shell to `NSStatusItem + NSPopover` so we stay on AppKit here for
// consistency.

import AppKit
import Logging
import NtakkerCore

/// Hidden debug-only menu surfaced via OPTION-click on the status-bar
/// icon. Lets the developer flip the swift-log verbosity at runtime
/// without restarting the app (NFR-16).
///
/// Usage from `AppDelegate`:
///
///     let menu = UILoggingMenu(
///         subsystem: "com.giorgosmarinos.ntakker",
///         fileURL: logFileURL,
///         currentLevel: "info",
///         logger: loggingMenuLogger
///     )
///     // ...
///     // On option-click:
///     menu.show(from: statusItem)
@MainActor
final class UILoggingMenu {

    // MARK: - Stored configuration
    //
    // The (subsystem, fileURL) tuple is the same as the one passed to
    // `LoggerFactory.bootstrap` at app launch. Re-bootstrapping with
    // identical values does not reopen the file — the bootstrap guard
    // short-circuits to "just update the level". We retain the values
    // here so the menu does not need to know about AppDelegate.

    private let subsystem: String
    private let fileURL: URL?
    private let logger: Logger

    /// Currently-applied level string. Updated whenever the user picks
    /// a new item, used to render the checkmark on the next menu open.
    private(set) var currentLevel: String

    /// Bridge from AppKit `target/action` to a Swift closure. Same
    /// pattern as `StatusItemController.ActionProxy`. Held strongly so
    /// AppKit's weak menu-item target retention does not drop it.
    private let actionProxy: MenuActionProxy

    /// The actual `NSMenu`. Rebuilt lazily on every `show(...)` so the
    /// "current level" checkmark stays in sync.
    private var menu: NSMenu?

    /// Construct a logging menu bound to a specific bootstrap target.
    ///
    /// - Parameters:
    ///   - subsystem: macOS unified-logging subsystem string used by
    ///     the original `LoggerFactory.bootstrap` call (typically
    ///     `"com.giorgosmarinos.ntakker"`).
    ///   - fileURL: same file URL used by the original bootstrap, or
    ///     `nil` if the app launched without a file backend.
    ///   - currentLevel: the level string applied at launch (so the
    ///     menu's first render shows the right checkmark). One of
    ///     `info | debug | trace`.
    ///   - logger: a `Logger` (label `ntakker-cli.ui.loggingMenu`) so the
    ///     menu can audit-trail its own re-bootstraps.
    init(
        subsystem: String,
        fileURL: URL?,
        currentLevel: String,
        logger: Logger
    ) {
        self.subsystem = subsystem
        self.fileURL = fileURL
        self.currentLevel = currentLevel
        self.logger = logger
        self.actionProxy = MenuActionProxy()
        actionProxy.handler = { [weak self] level in
            self?.applyLevel(level)
        }
    }

    /// Pop the menu attached to `statusItem`. AppKit's contract: assign
    /// the menu to the status item, call `popUpMenu`/`button.performClick`,
    /// then nil it back out so the status item's normal target/action
    /// click handler still runs on the next click.
    ///
    /// We use `NSStatusItem.menu` + `button.performClick` rather than
    /// `NSMenu.popUp(positioning:at:in:)` because the former renders
    /// with the standard menu-bar offset (right under the icon) without
    /// any geometry math.
    func show(from statusItem: NSStatusItem) {
        let menu = buildMenu()
        self.menu = menu

        // Temporarily attach the menu so AppKit shows it under the
        // status item. We immediately clear it after — see comment
        // below.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach so the next click goes back to our target/action
        // handler (which routes to `popoverController.toggle` for
        // normal clicks). Without this, every subsequent click would
        // re-show this menu.
        statusItem.menu = nil
    }

    // MARK: - Internals

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "ntakker logging")

        // Header (disabled). Makes it obvious the menu is debug-only.
        let header = NSMenuItem(title: "Debug — log level", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for level in ["info", "debug", "trace"] {
            let item = NSMenuItem(
                title: "Log level: \(level)",
                action: #selector(MenuActionProxy.handle(_:)),
                keyEquivalent: ""
            )
            item.target = actionProxy
            item.representedObject = level
            // Checkmark on the active level.
            item.state = (level == currentLevel) ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func applyLevel(_ level: String) {
        do {
            try LoggerFactory.bootstrap(
                subsystem: subsystem,
                fileURL: fileURL,
                levelString: level
            )
            currentLevel = level
            logger.info("UI log level changed to \(level)")
        } catch {
            // The button only fires on the three known strings, so this
            // path is unreachable in practice — but the throwing API
            // forces us to handle it. Surface and keep the previous
            // level.
            logger.error("UILoggingMenu.applyLevel rejected: \(error)")
        }
    }
}

// MARK: - MenuActionProxy

/// AppKit `target/action` bridge. The selector receives the menu item;
/// we read `representedObject` to learn which level was picked, then
/// call back into the Swift closure on `UILoggingMenu`.
private final class MenuActionProxy: NSObject {
    var handler: ((String) -> Void)?

    @objc func handle(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let level = item.representedObject as? String else {
            return
        }
        handler?(level)
    }
}
