// ntakker/StatusItemController.swift — see project-design.md §15.1,
// §15.2, §15.13 and plan-002-toolbar-ui.md §3 Phase C (FR-41), §3 Phase H.
//
// Owns the `NSStatusItem` and maps `SessionState` → menu-bar icon.
//
// Per investigation Topic 1 Option 1B "Recommendation" (the locked
// design), the four FR-41 visual states map to system symbols:
//
//   .idle      → "circle"                       (hollow ring; ready)
//   .recording → "record.circle.fill"           (filled red dot)
//   .paused    → "pause.circle.fill"            (pause glyph)
//   .failed    → "exclamationmark.triangle.fill" (warning triangle)
//
// All images are template images (`isTemplate = true`) so they tint
// correctly under both light and dark menu-bar appearance — investigation
// Topic 1 gotcha #3.
//
// IMPORTANT (R-26): the `NSStatusItem` itself is NOT held by this
// controller. It is created and retained by `AppDelegate` as a stored
// property (so the icon does not vanish when an init scope returns —
// investigation Topic 1 gotcha #4). This controller takes the existing
// `NSStatusItem` reference by parameter and configures its `.button`.
//
// The Phase C contract for `setState(_:)` is "update the icon on the
// existing button". The actual subscription to
// `RecordingController.stateStream` (the loop that calls `setState`
// repeatedly) is wired by `AppDelegate` in Phase D once
// `RecordingController` exists. For now `setState` simply exists and
// is callable — the `AppDelegate` calls it once with `.idle` at startup
// to set the initial icon.
//
// Phase H click routing: the controller distinguishes a NORMAL click
// (left- or right-mouse button without modifiers) from an OPTION-CLICK
// (any modifier set contains `.option`). Normal click invokes
// `onClick`; option-click invokes `onOptionClick`. The default popover
// behavior is unchanged for normal clicks; option-click fires the
// hidden `UILoggingMenu` (NFR-16). Modifier detection reads
// `NSApp.currentEvent.modifierFlags` because target/action does not
// receive the originating `NSEvent`.

import AppKit
import Logging
import NtakkerCore

/// Owns the menu-bar icon's visual state and the click handler.
///
/// Lifecycle: instantiated once by `AppDelegate` in
/// `applicationDidFinishLaunching(_:)`. Holds a strong reference to the
/// click callback (an `@escaping` closure that forwards into the
/// `PopoverController.toggle(relativeTo:)` flow).
///
/// The `NSStatusItem` itself lives on `AppDelegate` (R-26 — strong
/// stored property required so AppKit does not GC the menu-bar entry).
@MainActor
final class StatusItemController {
    /// The status item we configure. Owned by `AppDelegate`; we hold
    /// a reference here for convenience (`AppDelegate` already retains
    /// it, so this second reference does not change ownership).
    private let statusItem: NSStatusItem

    /// Normal-click callback. Invoked when the user clicks the
    /// status-bar button WITHOUT the option modifier held. `AppDelegate`
    /// provides a closure that forwards into
    /// `PopoverController.toggle(relativeTo:)`.
    private let onClick: () -> Void

    /// Option-click callback (Phase H, NFR-16). Invoked when the user
    /// clicks while holding the Option key. `AppDelegate` provides a
    /// closure that pops the hidden `UILoggingMenu`. Optional: when
    /// `nil`, an option-click falls through to `onClick`.
    private let onOptionClick: (() -> Void)?

    private let logger: Logger

    /// AppKit `target/action` requires an `NSObject` subclass; we use a
    /// thin proxy that bridges the selector call back into the Swift
    /// closure stored on `self`.
    private let actionProxy: ActionProxy

    /// Configure an existing `NSStatusItem` with the click handler and
    /// initial icon. The caller (AppDelegate) is responsible for
    /// retaining the status item itself.
    ///
    /// - Parameters:
    ///   - statusItem: A status item already vended by
    ///     `NSStatusBar.system.statusItem(withLength:)`. Strong-retained
    ///     by `AppDelegate` (R-26).
    ///   - onClick: Click callback for normal (non-option) clicks.
    ///     Invoked on the main actor.
    ///   - onOptionClick: Optional click callback for OPTION-clicks
    ///     (Phase H, NFR-16). When `nil`, an option-click falls through
    ///     to `onClick`. Invoked on the main actor.
    ///   - logger: Component-scoped logger (label `ntakker-cli.ui.statusItem`).
    init(statusItem: NSStatusItem,
         onClick: @escaping () -> Void,
         onOptionClick: (() -> Void)? = nil,
         logger: Logger) {
        self.statusItem = statusItem
        self.onClick = onClick
        self.onOptionClick = onOptionClick
        self.logger = logger
        self.actionProxy = ActionProxy()

        // Wire the action proxy back to our click router. The proxy
        // holds a weak reference to `self` so we don't create a retain
        // cycle (AppDelegate retains us; we retain the proxy; the
        // proxy weakly references us).
        actionProxy.handler = { [weak self] in
            self?.handleClick()
        }

        configureButton()
        // Initial icon: idle. Phase D's RecordingController.stateStream
        // subscriber will start sending real state transitions.
        setState(.idle)

        logger.debug("StatusItemController initialized (initial icon=idle)")
    }

    /// Wire the status item's button: target/action for clicks.
    private func configureButton() {
        guard let button = statusItem.button else {
            // `NSStatusItem.button` is documented non-nil for variable-length
            // status items. If it is nil here, the menu bar UI is broken
            // before we begin — log and bail (no fallback per project rules).
            logger.error("statusItem.button is nil — menu-bar icon cannot be configured")
            return
        }
        button.target = actionProxy
        button.action = #selector(ActionProxy.handle(_:))
        // Accept both left- and right-clicks. Right-click currently
        // mirrors left-click (both toggle the popover); option-click
        // is intercepted by `handleClick()` below to surface the
        // hidden `UILoggingMenu` (Phase H, NFR-16).
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Click router. Reads `NSApp.currentEvent.modifierFlags` to
    /// distinguish OPTION-clicks (Phase H, NFR-16) from normal clicks.
    /// Target/action does NOT pass the originating `NSEvent` to the
    /// selector, so we have to fish it out of `NSApp.currentEvent`.
    private func handleClick() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option), let onOptionClick {
            logger.debug("handleClick: option-click → onOptionClick")
            onOptionClick()
        } else {
            logger.debug("handleClick: normal click → onClick")
            onClick()
        }
    }

    /// Map a `SessionState` to a system-symbol template image and apply
    /// it to the status-item button.
    ///
    /// FR-41 mapping (per investigation Topic 1 §"Recommendation"):
    ///
    /// | SessionState                      | SF Symbol                       |
    /// |-----------------------------------|---------------------------------|
    /// | `.idle` / `.stopped`              | `circle`                        |
    /// | `.starting` / `.recording` / `.splitting` / `.stopping` | `record.circle.fill` |
    /// | `.pausing` / `.paused` / `.resuming` | `pause.circle.fill`          |
    /// | `.failed`                          | `exclamationmark.triangle.fill` |
    ///
    /// All images are configured with `isTemplate = true` so they tint
    /// correctly under both light- and dark-mode menu bars.
    func setState(_ state: SessionState) {
        let symbolName = symbolName(for: state)
        let accessibility = state.description

        guard let image = NSImage(systemSymbolName: symbolName,
                                  accessibilityDescription: accessibility) else {
            logger.error("NSImage(systemSymbolName:) returned nil for \(symbolName)")
            return
        }
        image.isTemplate = true

        statusItem.button?.image = image
        logger.debug("setState: \(state.description) → \(symbolName)")
    }

    /// Pure mapping. Kept private so callers always use `setState(_:)`.
    private func symbolName(for state: SessionState) -> String {
        switch state {
        case .idle, .stopped:
            return "circle"
        case .starting, .recording, .splitting, .stopping:
            return "record.circle.fill"
        case .pausing, .paused, .resuming:
            return "pause.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - ActionProxy
//
// AppKit's target/action mechanism requires an `NSObject` subclass with
// an `@objc`-exposed selector. We bridge to a Swift closure here so the
// rest of the controller stays in idiomatic Swift.

private final class ActionProxy: NSObject {
    var handler: (() -> Void)?

    @objc func handle(_ sender: Any?) {
        handler?()
    }
}
