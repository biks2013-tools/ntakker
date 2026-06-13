// NtakkerUITests/Settings/GeneralSettingsViewTests.swift —
// see plan-008 Phase 2 (Unit C in project-design §UR-10) and
// project-design §UR-4.5.
//
// Concept-pinning tests for `GeneralSettingsView`. The test target
// cannot `@testable import ntakker_ui` (the executable target is not
// declared as a test dependency in Package.swift), so these tests
// re-state the design contract that the view depends on as constants
// and assert the invariants on the public `NtakkerUIKit` types it
// consumes. If the view drifts from this contract — wrong AppStorage
// key, wrong default, missing case, empty label/icon — the picker
// silently breaks at runtime; pinning here surfaces the drift loudly
// at build/test time.
//
// Uses Swift Testing (project convention — every existing test file
// in NtakkerUITests imports `Testing`, not `XCTest`).

import Foundation
import Testing
import NtakkerUIKit

@Suite("GeneralSettingsView contract pins")
struct GeneralSettingsViewTests {

    // MARK: - AppStorage key

    /// The view declares
    /// `@AppStorage(AppearanceMode.userDefaultsKey)`. If this string
    /// drifts, the picker stops persisting (and the popover header
    /// switcher + the `.preferredColorScheme(_:)` modifiers stop
    /// observing the same key, so the UI desyncs).
    @Test("Appearance picker binds to the canonical AppStorage key")
    func appearanceKeyIsCanonical() {
        #expect(AppearanceMode.userDefaultsKey == "com.ntakker-cli.ui.appearance")
    }

    // MARK: - Default value

    /// `@AppStorage` uses `defaultRawValue` when the key is absent or
    /// unparseable. Per the documented user-facing default (and the
    /// project's no-fallback rule for *config* settings — note: this
    /// is a UI preference, not a config setting), the initial value
    /// must be `system` so first-run UX honors the OS appearance.
    @Test("Default appearance value matches AppearanceMode.system")
    func defaultIsSystem() {
        #expect(AppearanceMode.defaultRawValue == "system")
        #expect(AppearanceMode(rawValue: AppearanceMode.defaultRawValue) == .system)
    }

    // MARK: - Picker option set

    /// The picker uses `ForEach(AppearanceMode.allCases)`. The locked
    /// declaration order (system, light, dark) must hold so the
    /// segmented / inline picker presents the same option order as
    /// the popover header switcher (Unit G).
    @Test("Picker has exactly three options in stable order")
    func threeOptions() {
        let cases = AppearanceMode.allCases
        #expect(cases.count == 3)
        #expect(cases[0] == .system)
        #expect(cases[1] == .light)
        #expect(cases[2] == .dark)
    }

    // MARK: - Display content

    /// Each `Label` row in the picker requires a non-empty title
    /// string and a resolvable SF Symbol. Empty values would render
    /// blank rows that the user could neither read nor tap reliably.
    @Test("Each picker option has a non-empty display name and SF Symbol")
    func displayContent() {
        for mode in AppearanceMode.allCases {
            #expect(!mode.displayName.isEmpty,
                    "displayName for \(mode) must not be empty")
            #expect(!mode.systemImageName.isEmpty,
                    "systemImageName for \(mode) must not be empty")
        }
    }

    // MARK: - Tag stability

    /// The picker tags each row with `mode.rawValue` and binds to a
    /// `String` `@AppStorage`. Round-tripping the tag back through
    /// `AppearanceMode(rawValue:)` must always succeed for every
    /// `allCases` entry, otherwise the picker selection cannot be
    /// restored from the persisted string.
    @Test("Every allCases raw value round-trips through init(rawValue:)")
    func tagsRoundTripCleanly() {
        for mode in AppearanceMode.allCases {
            #expect(AppearanceMode(rawValue: mode.rawValue) == mode)
        }
    }
}
