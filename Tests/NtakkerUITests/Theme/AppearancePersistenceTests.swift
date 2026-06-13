// NtakkerUITests/Theme/AppearancePersistenceTests.swift — see plan-008
// Phase 1 Unit F (project-design §UR-10).
//
// Concept-pinning tests for `AppearanceHostingRoot`'s persistence
// contract. The wrapper itself lives in `ntakker` (an executable
// target) and cannot be reached from the test target without
// `@testable import ntakker_ui`, which is not part of this project's
// test setup. Instead we pin the contract `AppearanceHostingRoot`
// relies on — the canonical `UserDefaults` key, the round-trip of the
// raw value, the documented fallback for unknown values, the default,
// and the per-case `ColorScheme` mapping.
//
// If any of these change, the wrapper will silently behave differently;
// these tests fail loudly first.
//
// Uses Swift Testing (project convention; see AppearanceModeTests).
// Reaches `AppearanceMode` via the public `NtakkerUIKit` import
// (the symbol lives there precisely so the test target can read it
// without `@testable` of an executable — project-design §UR-ADR-4).

import Foundation
import SwiftUI
import Testing
import NtakkerUIKit

@Suite("Appearance persistence contract pins")
struct AppearancePersistenceTests {

    // MARK: - Canonical key

    /// `AppearanceHostingRoot` reads `@AppStorage(AppearanceMode.userDefaultsKey)`.
    /// If this constant ever changes, every persisted user preference
    /// is orphaned. Pin it.
    @Test("UserDefaults key is the canonical AppearanceMode key")
    func canonicalKey() {
        #expect(AppearanceMode.userDefaultsKey == "com.ntakker-cli.ui.appearance")
    }

    // MARK: - Round-trip

    /// Use a private suite (NOT `UserDefaults.standard`) so we don't
    /// pollute other tests or the real app's preferences.
    @Test("Round-trip: setting and reading the persisted raw value preserves the case")
    func roundTrip() {
        let suite = "TestSuite-AppearancePersistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AppearanceMode.dark.rawValue, forKey: AppearanceMode.userDefaultsKey)
        let raw = defaults.string(forKey: AppearanceMode.userDefaultsKey)
        let mode = raw.flatMap(AppearanceMode.init(rawValue:))
        #expect(mode == .dark)
    }

    // MARK: - Unknown fallback

    /// Documented behavior of `AppearanceHostingRoot`:
    /// `AppearanceMode(rawValue:)` returns `nil` for an unknown raw
    /// value, and the wrapper collapses that to `.system`.
    @Test("Unknown raw value collapses to nil; consumers should fall back to .system")
    func unknownValueFallback() {
        let result = AppearanceMode(rawValue: "totally-bogus-value")
        #expect(result == nil)
        // Documented behavior: AppearanceHostingRoot falls back to .system.
    }

    // MARK: - Default

    @Test("Default raw value is the system case rawValue")
    func defaultMatchesSystem() {
        #expect(AppearanceMode.defaultRawValue == AppearanceMode.system.rawValue)
        #expect(AppearanceMode.defaultRawValue == "system")
    }

    // MARK: - ColorScheme mapping

    /// `AppearanceHostingRoot` feeds `mode.colorScheme` into
    /// `.preferredColorScheme(_:)`; the `nil` case is critical because
    /// it's how "follow system" defers to `\.colorScheme`.
    @Test("Each AppearanceMode maps to the documented ColorScheme")
    func colorSchemeMapping() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }
}
