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

    /// KVO observer on the persisted popover-height key. The user
    /// drags `ResizeHandle` (in `RootView`) → SwiftUI `@AppStorage`
    /// writes the new value to UserDefaults → this observer fires →
    /// we push `NSPopover.contentSize` so the AppKit frame updates.
    private var heightObserver: NSObjectProtocol?

    /// Default height when no user choice has been persisted yet.
    /// Matches the previous fixed cap so first-run users see no
    /// behavioural change.
    /// `nonisolated` so the `@Sendable` closure passed to
    /// `NotificationCenter.addObserver(forName:object:queue:using:)`
    /// can read them without an actor hop.
    nonisolated static let defaultHeight: CGFloat = 600
    nonisolated static let minHeight: CGFloat = 360
    nonisolated static let maxHeight: CGFloat = 1100
    nonisolated static let popoverWidth: CGFloat = 360

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

        // Wrap in `AppearanceHostingRoot` so the persisted
        // `AppearanceMode` choice flows into `.preferredColorScheme(_:)`
        // AND the `\.palette` environment value for every descendant
        // view — see `Theme/AppearanceHostingRoot.swift` and
        // project-design §UR-4.4 / §UR-6. The wrapper subscribes to
        // `@AppStorage` and `\.colorScheme` itself; no
        // `NotificationCenter` observer or `popover.appearance`
        // override is required (research-nshostingcontroller-appearance.md).
        let composed = AnyView(
            AppearanceHostingRoot {
                rootView
                    .environment(\.recordingController, recordingController)
                    .environment(\.popoverBehavior, behaviorSetter)
            }
        )
        let hosting = NSHostingController(rootView: composed)
        self.hostingController = hosting
        popover.contentViewController = hosting

        // Apply the persisted popover height (vertical-resize feature).
        // Reading from `UserDefaults.standard` matches what SwiftUI's
        // `@AppStorage(RootView.popoverHeightKey)` writes to. If the
        // user has not set a value yet, fall back to `defaultHeight`.
        let persisted = UserDefaults.standard.object(forKey: RootView.popoverHeightKey) as? Double
        let initialHeight = Self.clamp(CGFloat(persisted ?? Double(Self.defaultHeight)))
        popover.contentSize = NSSize(width: Self.popoverWidth, height: initialHeight)

        // Subscribe to subsequent height changes so a drag on the
        // resize handle propagates to the AppKit popover frame in
        // real time. We use `UserDefaults.didChangeNotification`
        // (rather than KVO via key-path) to avoid having to expose a
        // `@objc dynamic` property on a `UserDefaults` extension —
        // SwiftUI's `@AppStorage` only writes through a plain string
        // key, which the notification observes uniformly.
        heightObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak popover] _ in
            let newValue = UserDefaults.standard.double(forKey: RootView.popoverHeightKey)
            guard newValue > 0 else { return }
            let clamped = Self.clamp(CGFloat(newValue))
            guard let popover else { return }
            // Avoid spurious churn when the value did not actually
            // change for THIS key (the notification fires for every
            // defaults write).
            if abs(popover.contentSize.height - clamped) < 0.5 { return }
            popover.contentSize = NSSize(width: Self.popoverWidth, height: clamped)
        }

        logger.debug("PopoverController initialized (behavior=.transient, contentSize=\(popover.contentSize))")
    }

    deinit {
        // KVO observation token is released automatically.
        _ = heightObserver
    }

    /// Clamp helper — centralised so the init path and the observer
    /// path agree on the bounds. `nonisolated` for the same reason
    /// as the static height bounds.
    nonisolated private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minHeight), maxHeight)
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
