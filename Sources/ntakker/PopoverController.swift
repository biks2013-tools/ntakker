// ntakker/PopoverController.swift — see project-design.md §15.1, §15.2,
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
import NtakkerCore
import NtakkerUIKit
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

    /// KVO observer on the persisted popover-size keys (height + width).
    /// The user drags `ResizeHandle` (in `RootView`) → SwiftUI
    /// `@AppStorage` writes the new value(s) to UserDefaults → this
    /// observer fires → we push `NSPopover.contentSize` so the AppKit
    /// frame updates. A single observer covers both axes because
    /// `UserDefaults.didChangeNotification` does not carry a key —
    /// we re-read both keys and re-clamp on every fire.
    private var sizeObserver: NSObjectProtocol?

    /// Default size + clamp range when no user choice has been
    /// persisted yet. Matches `ResizeHandle.{min,max}{Height,Width}`
    /// so the SwiftUI clamp and the AppKit clamp agree.
    /// `nonisolated` so the `@Sendable` closure passed to
    /// `NotificationCenter.addObserver(forName:object:queue:using:)`
    /// can read them without an actor hop.
    // plan-015 (FR-IRQ-59..61): default width 480, with min/max
    // 440-760 x 440-820. Kept in sync with `ResizeHandle.{min,max}{Width,Height}`.
    nonisolated static let defaultHeight: CGFloat = 600
    nonisolated static let minHeight: CGFloat = 440
    nonisolated static let maxHeight: CGFloat = 820
    nonisolated static let defaultWidth: CGFloat = 480
    nonisolated static let minWidth: CGFloat = 440
    nonisolated static let maxWidth: CGFloat = 760

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
    ///   - logger: Component-scoped logger (label `ntakker-cli.ui.popover`).
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
                    .environmentObject(PredefinedQuestionsStore.shared)
            }
        )
        let hosting = NSHostingController(rootView: composed)
        self.hostingController = hosting
        popover.contentViewController = hosting

        // Apply the persisted popover size (both axes resizable —
        // plan-008-followup-1). Reading from `UserDefaults.standard`
        // matches what SwiftUI's `@AppStorage(RootView.popoverHeightKey)`
        // and `@AppStorage(RootView.popoverWidthKey)` write to. If the
        // user has not set a value yet for either axis, fall back to
        // the matching default constant.
        let persistedH = UserDefaults.standard.object(forKey: RootView.popoverHeightKey) as? Double
        let persistedW = UserDefaults.standard.object(forKey: RootView.popoverWidthKey)  as? Double
        let initialHeight = Self.clampHeight(CGFloat(persistedH ?? Double(Self.defaultHeight)))
        let initialWidth  = Self.clampWidth (CGFloat(persistedW ?? Double(Self.defaultWidth)))
        popover.contentSize = NSSize(width: initialWidth, height: initialHeight)

        // Subscribe to subsequent size changes so a drag on the
        // resize handle propagates to the AppKit popover frame in
        // real time. We use `UserDefaults.didChangeNotification`
        // (rather than KVO via key-path) to avoid having to expose a
        // `@objc dynamic` property on a `UserDefaults` extension —
        // SwiftUI's `@AppStorage` only writes through a plain string
        // key, which the notification observes uniformly.
        //
        // A single observer covers both axes: on every fire we re-read
        // both keys, re-clamp, and only push to `contentSize` if either
        // dimension materially differs from the current frame. This
        // avoids the "two writes → two pushes" jitter that would otherwise
        // happen on a diagonal drag (the gesture writes both keys on
        // the same SwiftUI tick, but the notification fires twice).
        sizeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak popover, weak hosting] _ in
            guard let popover, let hosting else { return }
            let rawH = UserDefaults.standard.double(forKey: RootView.popoverHeightKey)
            let rawW = UserDefaults.standard.double(forKey: RootView.popoverWidthKey)
            let h: CGFloat = rawH > 0 ? Self.clampHeight(CGFloat(rawH)) : popover.contentSize.height
            let w: CGFloat = rawW > 0 ? Self.clampWidth (CGFloat(rawW)) : popover.contentSize.width
            // Avoid spurious churn when neither dimension actually
            // changed for THIS key (the notification fires for every
            // defaults write across the whole process).
            let dh = abs(popover.contentSize.height - h)
            let dw = abs(popover.contentSize.width  - w)
            if dh < 0.5 && dw < 0.5 { return }

            // Drag-time resize requires the same three-layer push that
            // `fitToCurrentScreen` performs at open time. Setting only
            // `popover.contentSize` lets `NSHostingController`'s
            // intrinsic-size publication race with the AppKit frame —
            // the visible symptom was a popover window that grew or
            // shrunk only after a hide/show cycle (the cycle re-ran
            // `fitToCurrentScreen` and re-synced the three layers).
            //
            // Also suppress the popover's implicit resize animation: at
            // 60 Hz drag-tick rate the queued animations stack and the
            // window lags behind the cursor. We restore `animates` to
            // its prior value once the push lands.
            let newSize = NSSize(width: w, height: h)
            let previousAnimates = popover.animates
            popover.animates = false
            hosting.preferredContentSize = newSize
            hosting.view.setFrameSize(newSize)
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentSize = newSize
            popover.animates = previousAnimates
        }

        logger.debug("PopoverController initialized (behavior=.transient, contentSize=\(popover.contentSize))")
    }

    deinit {
        // KVO observation token is released automatically.
        _ = sizeObserver
    }

    /// Clamp helpers — centralised so the init path and the observer
    /// path agree on the bounds. `nonisolated` for the same reason
    /// as the static size bounds.
    nonisolated private static func clampHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, minHeight), maxHeight)
    }

    nonisolated private static func clampWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, minWidth), maxWidth)
    }

    /// Open or close the popover, anchored to the supplied status-bar
    /// button. Wired into the `NSStatusItem.button.action` selector by
    /// `AppDelegate`.
    ///
    /// On every open we re-clamp `contentSize` to the current screen's
    /// `visibleFrame` (menu bar + Dock already excluded). The persisted
    /// `@AppStorage` value may have been set on a larger external
    /// display; without this clamp, opening on a smaller built-in
    /// screen would let the popover overflow.
    ///
    /// - Parameter button: The status-item's button to anchor to. The
    ///   popover's arrow will point up at this button.
    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            logger.debug("toggle: closing popover")
            popover.performClose(nil)
        } else {
            fitToCurrentScreen(anchor: button)
            logger.debug("toggle: showing popover relative to status item button (contentSize=\(popover.contentSize))")
            // `.minY` places the popover below the status item with the
            // arrow pointing up — the standard menu-bar app placement.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Shrink the popover so it fits the current screen's
    /// `visibleFrame`. Runs through three coordinated layers so that
    /// SwiftUI's intrinsic content size (read from `RootView.frame(...)`)
    /// cannot push back against the AppKit-side clamp:
    ///
    ///   1. **Persisted `@AppStorage`** — write the fitted height/width
    ///      so `RootView.body` re-evaluates with the smaller value the
    ///      next render. `RootView.fittedHeight(_:) / .fittedWidth(_:)`
    ///      additionally re-clamp against `NSScreen.main` at every
    ///      render as a defence-in-depth so the popover stays bounded
    ///      even if this code path is bypassed.
    ///   2. **`hostingController.preferredContentSize`** — force the
    ///      NSHostingController's published size so `NSPopover` reads
    ///      our clamp on its next `show(...)`. NSHostingController
    ///      normally derives `preferredContentSize` from SwiftUI's
    ///      intrinsic size; setting it explicitly here wins until the
    ///      next SwiftUI layout pass (and SwiftUI's pass will agree
    ///      because step 1 fixed `@AppStorage`).
    ///   3. **`popover.contentSize`** — final belt-and-braces write.
    ///
    /// Status-item's screen wins; fallback to `NSScreen.main` then to
    /// the first `NSScreen.screens` entry.
    private func fitToCurrentScreen(anchor button: NSStatusBarButton) {
        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        // Reserve a margin: ~24pt below the status bar for the popover
        // callout arrow + a small breathing gap so the resize handle
        // stays hit-testable when the Dock is pinned to "always show".
        let arrowMargin: CGFloat = 40
        let edgeMargin: CGFloat = 16
        let maxFittingHeight = max(Self.minHeight, frame.height - arrowMargin)
        let maxFittingWidth  = max(Self.minWidth,  frame.width  - edgeMargin)
        // Source of truth for the requested size is the persisted
        // AppStorage value (not the current `popover.contentSize`),
        // because the SwiftUI body reads `popoverHeight`/`popoverWidth`
        // and applies `RootView.fittedHeight/Width`, which is what
        // ultimately drives `preferredContentSize`.
        let requestedH = CGFloat(UserDefaults.standard.object(forKey: RootView.popoverHeightKey) as? Double
            ?? Double(popover.contentSize.height))
        let requestedW = CGFloat(UserDefaults.standard.object(forKey: RootView.popoverWidthKey) as? Double
            ?? Double(popover.contentSize.width))
        let fittedH = min(requestedH, maxFittingHeight)
        let fittedW = min(requestedW, maxFittingWidth)
        logger.info("fitToCurrentScreen: requested=(\(requestedW), \(requestedH)) → fitted=(\(fittedW), \(fittedH)) for visibleFrame \(frame.size)")
        // 1. Persisted AppStorage — drives RootView's intrinsic size on
        //    the next layout pass. Writing the same value is a no-op
        //    for SwiftUI's @AppStorage publisher.
        if abs(requestedH - fittedH) >= 0.5 {
            UserDefaults.standard.set(Double(fittedH), forKey: RootView.popoverHeightKey)
        }
        if abs(requestedW - fittedW) >= 0.5 {
            UserDefaults.standard.set(Double(fittedW), forKey: RootView.popoverWidthKey)
        }
        let fittedSize = NSSize(width: fittedW, height: fittedH)
        // 2. Hosting controller preferred size — read by NSPopover at
        //    show time. Without this, AppKit may queue the older
        //    intrinsic size from SwiftUI's last layout.
        hostingController.preferredContentSize = fittedSize
        // 3. Popover content size — belt-and-braces.
        popover.contentSize = fittedSize
        // Force SwiftUI to run a layout pass NOW so the hosting
        // controller's view bounds match the new clamp before
        // `popover.show(...)` queries the size. `layoutSubtreeIfNeeded`
        // is synchronous and idempotent.
        hostingController.view.setFrameSize(fittedSize)
        hostingController.view.layoutSubtreeIfNeeded()
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
