// NtakkerUIKit/Theme/AppearanceMode.swift — see project-design.md §UR-4.1
// and plan-008-ui-redesign-and-theming.md Phase 1 (foundation).
//
// User-facing appearance preference for the ntakker menu-bar app.
// Persisted as a `String` raw value in `UserDefaults.standard` under
// `AppearanceMode.userDefaultsKey` (`"com.ntakker-cli.ui.appearance"`),
// consumed by `@AppStorage` in:
//   * `NtakkerUIApp` — applies `.preferredColorScheme(_:)` to the
//     `Settings { }` scene (P1).
//   * `AppearanceHostingRoot` — wraps `RootView` inside the popover
//     hosting controller and applies `.preferredColorScheme(_:)` so
//     the popover honors the same choice (P8).
//   * `GeneralSettingsView` — the picker UI in the new General tab
//     (P2).
//   * `AppearanceSwitcher` — the segmented picker in the popover
//     header strip (P3).
//
// Lives in `NtakkerUIKit` (not `ntakker`) so the test target can
// reach it without `@testable import` of an executable. Mirrors the
// architectural decision documented for `PrivacyDisclosureViewModel`
// (project-design §UR-ADR-4).
//
// **Frozen contract** for plan-008 parallel units C, F, G — see
// project-design §UR-10. Do NOT rename the cases, the raw values,
// `userDefaultsKey`, or `defaultRawValue` without coordinating via
// the dependency-validator.

import SwiftUI

/// User-facing appearance preference. Persisted as a `String` raw
/// value in `UserDefaults.standard` under `Self.userDefaultsKey`.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    // MARK: - Identifiable

    public var id: String { rawValue }

    // MARK: - Display

    /// Display name for the picker UI. Stable, English-only (no
    /// localization in v1.6 — see project-design §UR-4.1 docstring).
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// SF Symbol name suitable for `Image(systemName:)` in picker rows.
    /// `.system` → `"circle.lefthalf.filled"`, `.light` → `"sun.max"`,
    /// `.dark` → `"moon"`.
    public var systemImageName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    // MARK: - SwiftUI integration

    /// SwiftUI color scheme to feed into `.preferredColorScheme(_:)`.
    /// `nil` for `.system` so the OS / parent scope's choice applies.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    // MARK: - Persistence keys

    /// `@AppStorage` key. The single string spelling for this
    /// preference; every consumer must reference this constant rather
    /// than re-typing the literal so the magic string lives in one
    /// place.
    public static let userDefaultsKey: String = "com.ntakker-cli.ui.appearance"

    /// Documented user-facing default (NOT a missing-config fallback —
    /// `@AppStorage` uses this when the key is absent or unparseable;
    /// no consumer should silently substitute another value).
    public static let defaultRawValue: String = AppearanceMode.system.rawValue
}
