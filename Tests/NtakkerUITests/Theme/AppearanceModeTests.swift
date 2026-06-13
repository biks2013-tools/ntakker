// NtakkerUITests/Theme/AppearanceModeTests.swift — see plan-008
// Phase 1 + Phase 10 (Unit A in project-design §UR-10).
//
// Pins the frozen API contract for `AppearanceMode` so downstream
// units (C / F / G) can rely on stable raw values, the
// `userDefaultsKey` spelling, and the `defaultRawValue`. Any rename
// or reorder breaks these tests loudly.
//
// Uses Swift Testing (project convention — every existing test file
// in NtakkerUITests imports `Testing`, not `XCTest`; the test target's
// linker settings only wire the Swift Testing framework search path).
//
// R-22: the dev host's `swift test` exits 0 silently. These tests are
// authored for compile-only verification of the API surface (matching
// the convention established by FilenameGeneratorTests etc.).

import Foundation
import SwiftUI
import Testing
@testable import NtakkerUIKit

@Suite("AppearanceMode")
struct AppearanceModeTests {

    // MARK: - Raw-value stability

    /// Critical — these strings persist to disk via `@AppStorage`.
    /// A rename would silently revert every user's preference.
    @Test("raw values are stable: system / light / dark")
    func testRawValuesAreStable() {
        #expect(AppearanceMode.system.rawValue == "system")
        #expect(AppearanceMode.light.rawValue == "light")
        #expect(AppearanceMode.dark.rawValue == "dark")
    }

    // MARK: - CaseIterable

    @Test("allCases enumerates exactly three cases in declaration order")
    func testAllCasesEnumerated() {
        let all = AppearanceMode.allCases
        #expect(all.count == 3)
        #expect(all.contains(.system))
        #expect(all.contains(.light))
        #expect(all.contains(.dark))
    }

    // MARK: - SwiftUI bridging

    @Test(".system maps to nil ColorScheme; .light/.dark map to their named scheme")
    func testColorSchemeMapping() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }

    // MARK: - Identifiable

    @Test("id matches rawValue for ForEach use")
    func testIdentifierMatchesRawValue() {
        #expect(AppearanceMode.system.id == "system")
        #expect(AppearanceMode.light.id == "light")
        #expect(AppearanceMode.dark.id == "dark")
    }

    // MARK: - RawRepresentable

    @Test("init(rawValue:) round-trips known values and rejects unknowns")
    func testInitFromRawValue() {
        #expect(AppearanceMode(rawValue: "system") == .system)
        #expect(AppearanceMode(rawValue: "light") == .light)
        #expect(AppearanceMode(rawValue: "dark") == .dark)
        #expect(AppearanceMode(rawValue: "garbage") == nil)
        #expect(AppearanceMode(rawValue: "") == nil)
    }

    // MARK: - Persistence keys

    /// Will break loudly if the `@AppStorage` key is renamed — every
    /// consumer (popover wrapper, Settings scene, picker) reads this
    /// constant; users' on-disk preference would be orphaned by a
    /// rename.
    @Test("userDefaultsKey is the documented com.ntakker-cli.ui.appearance string")
    func testUserDefaultsKeyIsStable() {
        #expect(AppearanceMode.userDefaultsKey == "com.ntakker-cli.ui.appearance")
    }

    @Test("defaultRawValue is system, matching the documented user-facing default")
    func testDefaultRawValueIsSystem() {
        #expect(AppearanceMode.defaultRawValue == "system")
        #expect(AppearanceMode(rawValue: AppearanceMode.defaultRawValue) == .system)
    }

    // MARK: - Display

    @Test("every case has a non-empty displayName")
    func testDisplayNamesNonEmpty() {
        for mode in AppearanceMode.allCases {
            #expect(!mode.displayName.isEmpty,
                    "displayName for \(mode) must not be empty")
        }
    }

    @Test("every case has a non-empty systemImageName")
    func testSystemImageNamesNonEmpty() {
        for mode in AppearanceMode.allCases {
            #expect(!mode.systemImageName.isEmpty,
                    "systemImageName for \(mode) must not be empty")
        }
    }
}
