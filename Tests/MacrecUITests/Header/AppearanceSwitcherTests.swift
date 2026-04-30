// MacrecUITests/Header/AppearanceSwitcherTests.swift — see plan-008
// Unit G (project-design §UR-10).
//
// Concept-pin tests for `AppearanceSwitcher`. The test target cannot
// `@testable import macrec_ui` (it's an executable), so we exercise
// the contract surface that the view depends on:
//
//   * The `@AppStorage` key spelling
//     (`AppearanceMode.userDefaultsKey`) — a typo here would silently
//     desync the in-popover switcher from the Settings picker and the
//     host's `.preferredColorScheme(_:)` plumbing.
//   * The 3-option case set is stable and each option has a non-empty
//     SF Symbol + display name (the trigger icon and menu rows would
//     render blank otherwise).
//   * Default-value semantics: when the key is absent the consumer
//     should resolve to `.system` (mirrors `@AppStorage`'s behavior
//     when the default is `AppearanceMode.defaultRawValue`).
//   * Round-trip persistence: writing each mode's raw value to
//     `UserDefaults` and reading it back yields the same string —
//     sanity check that `@AppStorage` will see what we wrote.
//
// Uses an isolated `UserDefaults(suiteName:)` per test so we don't
// leak state into `UserDefaults.standard` (which would affect the dev
// host's actual app on the next run).
//
// Imports `MacrecUIKit` (not `macrec-ui`) — `AppearanceMode` lives in
// the framework target precisely so tests can reach it without
// `@testable import` of the executable. See `AppearanceMode.swift`
// header for the rationale.

import Testing
import Foundation
import MacrecUIKit

@Suite("AppearanceSwitcher contract pins")
struct AppearanceSwitcherTests {

    // MARK: - Key spelling

    @Test("Switcher binds to AppearanceMode.userDefaultsKey")
    func bindingKey() {
        // The literal must match every other consumer's @AppStorage
        // key. If this assertion fires you've drifted from the frozen
        // contract documented in project-design §UR-4.1.
        #expect(AppearanceMode.userDefaultsKey == "com.macrec.ui.appearance")
    }

    // MARK: - Option set stability

    @Test("All three options are exposed in stable order with non-empty SF Symbols")
    func threeOptionsWithIcons() {
        let cases = AppearanceMode.allCases
        #expect(cases.count == 3)
        for mode in cases {
            #expect(!mode.systemImageName.isEmpty)
            #expect(!mode.displayName.isEmpty)
        }
    }

    // MARK: - Default-value semantics

    @Test("Default raw value falls back to .system when key is absent")
    func defaultsToSystem() {
        let suite = "TestSuite-AppearanceSwitcher-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Mirror `@AppStorage`'s read path: if the key is absent, it
        // serves the declared default. Then we decode the typed mode
        // exactly as `AppearanceSwitcher.current` does.
        let raw = defaults.string(forKey: AppearanceMode.userDefaultsKey)
            ?? AppearanceMode.defaultRawValue
        let mode = AppearanceMode(rawValue: raw) ?? .system
        #expect(mode == .system)
    }

    // MARK: - Round-trip persistence

    @Test("Setting any AppearanceMode rawValue persists round-trip")
    func roundTripPersistence() {
        let suite = "TestSuite-AppearanceSwitcher-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for mode in AppearanceMode.allCases {
            defaults.set(mode.rawValue, forKey: AppearanceMode.userDefaultsKey)
            let read = defaults.string(forKey: AppearanceMode.userDefaultsKey)
            #expect(read == mode.rawValue)
        }
    }
}
