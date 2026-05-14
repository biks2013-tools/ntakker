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

import AppKit
import SwiftUI

@main
struct MacrecUIApp: App {
    /// AppKit shell. SwiftUI instantiates this once at launch and
    /// retains it for the lifetime of the process; it owns the status
    /// item, the popover, the `RecordingController` (Phase D), and
    /// (plan-016) the modal `SettingsWindowController`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Per investigation Topic 1 Option 1B: `Settings` is the only
        // `Scene` that does not produce a visible window at launch on
        // macOS, so declaring it (with an empty body) keeps the
        // SwiftUI App lifecycle alive while producing zero standalone
        // windows.
        //
        // **plan-016 (2026-05-14)** — Settings is no longer hosted in
        // this scene. The old `Settings { AppearanceHostingRoot { … } }`
        // declaration opened a non-modal `NSWindow` that left the
        // popover fully interactable. Settings now lives in
        // `SettingsWindowController` (an AppKit `NSWindow` run via
        // `NSApp.runModal(for:)`), and this scene is intentionally
        // empty. We override the auto-installed "Settings…" menu
        // item / Cmd-, shortcut via `CommandGroup(replacing:
        // .appSettings)` below so both paths route into the modal
        // controller instead of opening the empty SwiftUI window.
        Settings {
            EmptyView()
        }
        .commands {
            // Replace the SwiftUI-installed Preferences menu item
            // (which would otherwise open the empty Settings scene
            // above) with a custom Button bound to the modal
            // SettingsWindowController held by the AppDelegate.
            // Keeps Cmd-, working from any key window — for the
            // popover, the gear Button additionally re-declares the
            // shortcut so it also fires when the popover (not a
            // standard NSWindow) is the active surface.
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…")) {
                    (NSApp.delegate as? AppDelegate)?
                        .settingsWindowController
                        .show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
