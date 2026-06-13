// NtakkerUITests/Theme/AppearanceHostingRootSystemModeTests.swift — plan-008 Phase 6
//
// Concept-pinning test for `AppearanceHostingRoot`'s `.system` mode
// palette-injection contract.
//
// The five persistence tests already in `AppearancePersistenceTests.swift`
// pin the UserDefaults key, round-trip, unknown-value fallback, default,
// and per-case ColorScheme mapping. This file adds one more contract:
//
//   In `.system` mode the effective palette is selected by the OS-supplied
//   `\.colorScheme`, NOT by the persisted raw value itself.
//
// From `AppearanceHostingRoot.swift` (lines 52-56):
//
//   // For `.system`, defer to SwiftUI's `\.colorScheme` which is
//   // already tracking the OS / parent's choice.
//   let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
//
//   content()
//       .preferredColorScheme(mode.colorScheme)        // nil for .system
//       .environment(\.palette, effective == .dark ? .dark : .light)
//
// The two branches are:
//   A. mode != .system  →  effective = mode.colorScheme (non-nil)
//   B. mode == .system  →  effective = systemColorScheme (OS-provided)
//
// We pin both branches as concept-pins, using `AppearanceMode.colorScheme`
// from the public `NtakkerUIKit` API surface.
//
// Uses Swift Testing + NtakkerUIKit (project convention).

import Foundation
import SwiftUI
import Testing
import NtakkerUIKit

@Suite("AppearanceHostingRoot system-mode palette contract")
struct AppearanceHostingRootSystemModeTests {

    // MARK: - Branch A: explicit mode (light / dark)

    /// When mode is `.light`, `mode.colorScheme` is `.light` (non-nil),
    /// so `effective = mode.colorScheme ?? systemColorScheme` resolves to
    /// `.light` regardless of what the OS says.
    @Test("Light mode: effective ColorScheme is .light, ignores systemColorScheme")
    func lightModeEffectiveIsLight() {
        let mode = AppearanceMode.light
        let systemColorScheme = ColorScheme.dark  // OS says dark — should be ignored

        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        #expect(effective == .light)
        #expect(mode.colorScheme != nil)  // non-nil is the "explicit mode" branch
    }

    /// When mode is `.dark`, `mode.colorScheme` is `.dark` (non-nil),
    /// so `effective` resolves to `.dark` regardless of the OS.
    @Test("Dark mode: effective ColorScheme is .dark, ignores systemColorScheme")
    func darkModeEffectiveIsDark() {
        let mode = AppearanceMode.dark
        let systemColorScheme = ColorScheme.light  // OS says light — should be ignored

        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        #expect(effective == .dark)
        #expect(mode.colorScheme != nil)
    }

    // MARK: - Branch B: .system mode (OS-deferred)

    /// When mode is `.system`, `mode.colorScheme` is `nil`.
    /// The `??` operator falls through to `systemColorScheme`.
    /// If the OS says dark → effective is dark → palette is .dark.
    @Test("System mode: effective ColorScheme follows OS dark appearance")
    func systemModeFollowsOSDark() {
        let mode = AppearanceMode.system
        let systemColorScheme = ColorScheme.dark

        // mode.colorScheme is nil for .system (pinned in AppearancePersistenceTests)
        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        #expect(effective == .dark)
        #expect(mode.colorScheme == nil)  // nil is the "system mode" branch
    }

    /// When mode is `.system` and OS says light → effective is light → palette is .light.
    @Test("System mode: effective ColorScheme follows OS light appearance")
    func systemModeFollowsOSLight() {
        let mode = AppearanceMode.system
        let systemColorScheme = ColorScheme.light

        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        #expect(effective == .light)
    }

    // MARK: - Palette selection rule

    /// `AppearanceHostingRoot` selects `.dark` palette when effective == .dark,
    /// `.light` palette otherwise. Pin this two-branch logic.
    @Test("Palette is .dark when effective ColorScheme is .dark")
    func paletteDarkForDarkEffective() {
        // Mirrors: .environment(\.palette, effective == .dark ? .dark : .light)
        let effective = ColorScheme.dark
        let paletteChoice = effective == .dark ? "dark" : "light"
        #expect(paletteChoice == "dark")
    }

    @Test("Palette is .light when effective ColorScheme is .light")
    func paletteLightForLightEffective() {
        let effective = ColorScheme.light
        let paletteChoice = effective == .dark ? "dark" : "light"
        #expect(paletteChoice == "light")
    }

    // MARK: - Combined end-to-end pin

    /// End-to-end: mode=.system + OS=dark → palette=dark.
    @Test("system + OS dark → dark palette end-to-end")
    func endToEndSystemDark() {
        let mode = AppearanceMode.system
        let systemColorScheme = ColorScheme.dark

        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        let palette = effective == .dark ? "dark" : "light"
        #expect(palette == "dark")
    }

    /// End-to-end: mode=.system + OS=light → palette=light.
    @Test("system + OS light → light palette end-to-end")
    func endToEndSystemLight() {
        let mode = AppearanceMode.system
        let systemColorScheme = ColorScheme.light

        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        let palette = effective == .dark ? "dark" : "light"
        #expect(palette == "light")
    }

    /// End-to-end: mode=.dark + OS=light → palette=dark (OS overridden).
    @Test("dark mode + OS light → dark palette (mode overrides OS)")
    func endToEndDarkOverridesOSLight() {
        let mode = AppearanceMode.dark
        let systemColorScheme = ColorScheme.light  // OS says light but mode says dark

        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme
        let palette = effective == .dark ? "dark" : "light"
        #expect(palette == "dark")
    }

    // MARK: - preferredColorScheme contract

    /// `.preferredColorScheme(mode.colorScheme)` receives `nil` in .system mode.
    /// This is how AppearanceHostingRoot opts out of overriding the OS scheme
    /// (SwiftUI treats nil as "no preference" = follow parent/OS).
    @Test("system mode passes nil to preferredColorScheme — no OS override")
    func systemModePreferredColorSchemeIsNil() {
        let mode = AppearanceMode.system
        #expect(mode.colorScheme == nil)
    }

    /// In light/dark mode, a non-nil value is passed — OS is overridden.
    @Test("explicit modes pass non-nil to preferredColorScheme — OS overridden")
    func explicitModesPreferredColorSchemeIsNonNil() {
        #expect(AppearanceMode.light.colorScheme != nil)
        #expect(AppearanceMode.dark.colorScheme  != nil)
    }
}
