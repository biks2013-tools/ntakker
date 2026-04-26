// macrec-ui/PopoverController.swift — see project-design.md §15.1, §15.2,
// §15.11 (folder picker swap), and plan-002-toolbar-ui.md §3 Phase C.
//
// Owns the `NSPopover` that hosts the SwiftUI body.
//
// Per investigation Topic 1 Option 1B (the locked design), the popover's
// `contentViewController` is an `NSHostingController<RootView>`. The
// popover behavior starts as `.transient` (closes on click outside the
// popover — the standard "system menu" feel). Phase E's `FolderPicker`
// switches it to `.semitransient` for the lifetime of the modal
// `NSOpenPanel` so the picker does not dismiss the popover, then
// restores `.transient` once the panel is dismissed (R-27).
//
// `toggle(relativeTo:)` is the click-handler entrypoint: if the popover
// is shown, close it; otherwise show it anchored to the supplied
// `NSStatusBarButton` with a `.minY` preferred edge (the popover's arrow
// points up at the status bar — standard placement).
//
// Threading: `NSPopover` is a main-thread-only AppKit class; this whole
// type is `@MainActor`. The popover's content view (`RootView`) is also
// `@MainActor` (SwiftUI default on macOS 14+).

import AppKit
import Logging
import MacrecUIKit
import SwiftUI

/// Owns the menu-bar `NSPopover` that hosts the SwiftUI body.
///
/// Lifecycle: instantiated once by `AppDelegate` in
/// `applicationDidFinishLaunching(_:)`; held by a strong reference for
/// the lifetime of the app.
@MainActor
final class PopoverController {
    /// The actual AppKit popover. Stored as a strong reference; the
    /// status item button only holds a weak action target, so this
    /// controller is the single owner.
    let popover: NSPopover

    /// SwiftUI host. Retained transitively via `popover.contentViewController`,
    /// but tracked here for clarity. The hosting controller is
    /// parameterized on `AnyView` so the popover can apply environment
    /// modifiers (e.g. `\.recordingController`) without leaking the
    /// modifier's chained generic types into this type.
    private let hostingController: NSHostingController<AnyView>

    private let logger: Logger

    /// Constructs the popover and wires its `contentViewController` to
    /// an `NSHostingController<AnyView>`. Behavior defaults to
    /// `.transient` (per investigation Topic 1 gotcha — switch to
    /// `.semitransient` only while a folder picker is up).
    ///
    /// The controller is injected here (not via `RootView` properties)
    /// so the SwiftUI environment is applied at the top of the view
    /// tree — every descendant view in Phase E can read
    /// `@Environment(\.recordingController)` directly.
    ///
    /// - Parameters:
    ///   - rootView: The SwiftUI top-level view to host.
    ///   - recordingController: Shared view-model injected into the
    ///     SwiftUI environment under `\.recordingController`.
    ///   - logger: Component-scoped logger (label `macrec.ui.popover`).
    init(
        rootView: RootView,
        recordingController: RecordingController,
        logger: Logger
    ) {
        self.logger = logger

        // Phase E: build the popover before composing the SwiftUI host
        // so the `setBehaviorForPanel(_:)` closure (used by the
        // `FolderPicker` to swap to `.semitransient` while the
        // `NSOpenPanel` is up — R-27) can be captured into the
        // environment. The closure references `popover.behavior` via
        // a method call on `self`, so the popover is constructed first
        // and then the host is built second.
        let popover = NSPopover()
        // `.transient`: closes when the user clicks anywhere outside the
        // popover. This is the standard "menu-like" feel and matches
        // the OQ-UI-9 spec ("sit quietly in menu bar; user clicks to
        // open"). Phase E's `FolderPicker` flips this to `.semitransient`
        // for the duration of `NSOpenPanel` (R-27).
        popover.behavior = .transient
        popover.animates = true
        self.popover = popover

        // Capture a `@MainActor`-isolated closure that swaps the popover
        // behavior. Injected into the SwiftUI environment under
        // `\.popoverBehavior` so the FolderPicker can call it without
        // a hard reference to this controller (Phase E / R-27).
        let behaviorSetter: PopoverBehaviorSetter = { [weak popover] newBehavior in
            popover?.behavior = newBehavior
        }

        let composed = AnyView(
            rootView
                .environment(\.recordingController, recordingController)
                .environment(\.popoverBehavior, behaviorSetter)
        )
        let hosting = NSHostingController(rootView: composed)
        self.hostingController = hosting
        popover.contentViewController = hosting

        logger.debug("PopoverController initialized (behavior=.transient)")
    }

    /// Open or close the popover, anchored to the supplied status-bar
    /// button. Wired into the `NSStatusItem.button.action` selector by
    /// `AppDelegate`.
    ///
    /// - Parameter button: The status-item's button to anchor to. The
    ///   popover's arrow will point up at this button.
    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            logger.debug("toggle: closing popover")
            popover.performClose(nil)
        } else {
            logger.debug("toggle: showing popover relative to status item button")
            // `.minY` places the popover below the status item with the
            // arrow pointing up — the standard menu-bar app placement.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Programmatically dismiss the popover. Used by Phase F's quit
    /// flow and by Phase E's "close after Stop" affordance.
    func close() {
        guard popover.isShown else { return }
        logger.debug("close: dismissing popover")
        popover.performClose(nil)
    }

    /// Swap the popover behavior. Used by Phase E's `FolderPicker` to
    /// switch to `.semitransient` while an `NSOpenPanel` is up (so the
    /// open panel does not dismiss the popover) and back to `.transient`
    /// after the panel is dismissed. R-27.
    ///
    /// - Parameter behavior: The new behavior to apply.
    func setBehaviorForPanel(_ behavior: NSPopover.Behavior) {
        logger.debug("setBehaviorForPanel: \(behavior.rawValue)")
        popover.behavior = behavior
    }
}
