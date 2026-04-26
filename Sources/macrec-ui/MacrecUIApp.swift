// macrec-ui/MacrecUIApp.swift — see project-design.md §15.1, §15.2 and
// plan-002-toolbar-ui.md §3 Phase C.
//
// SwiftUI `@main` App entrypoint for the menu-bar accessory app.
//
// Per investigation Topic 1 Option 1B (the locked design), the SwiftUI
// `App`'s only declared scene is `Settings { EmptyView() }`. This is the
// documented idiom for a "no-window, status-bar-only" SwiftUI app —
// `Settings` is the only `Scene` that does not produce a visible window
// at launch on macOS, so declaring it (with an empty body) keeps the
// SwiftUI App lifecycle alive (so `@AppStorage`, `@Environment`, etc.
// continue to work) while producing zero standalone windows.
//
// All real UI lives inside an `NSPopover` hosted by `PopoverController`,
// anchored to the `NSStatusItem` owned by `StatusItemController`, both
// constructed by `AppDelegate` in `applicationDidFinishLaunching(_:)`.
//
// `@NSApplicationDelegateAdaptor` is the SwiftUI-blessed bridge to an
// AppKit `NSApplicationDelegate`; it instantiates and retains the
// delegate for the lifetime of the app, and SwiftUI installs it as
// `NSApp.delegate` automatically (per investigation Topic 1 Option 1B
// and the nilcoalescing.com / Sarunw idiom).
//
// Activation policy: `LSUIElement=true` is set in
// `Resources/MacrecUI-Info.plist` (Phase B) so the app launches without
// a Dock icon. `AppDelegate.applicationDidFinishLaunching(_:)` ALSO
// calls `NSApp.setActivationPolicy(.accessory)` defensively — this is
// the investigator's recommended belt-and-braces pattern.

import SwiftUI

@main
struct MacrecUIApp: App {
    /// AppKit shell. SwiftUI instantiates this once at launch and
    /// retains it for the lifetime of the process; it owns the status
    /// item, the popover, and the `RecordingController` (Phase D).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Per investigation Topic 1 Option 1B: `Settings` is the only
        // `Scene` that does not produce a visible window at launch on
        // macOS. We declare it with an `EmptyView()` body so the SwiftUI
        // App lifecycle is fully formed but no window appears. All real
        // UI is hosted inside an `NSPopover` from `AppDelegate`.
        Settings {
            EmptyView()
        }
    }
}
