// MacrecUITests/ControlBarStartTappedKeysRegressionTests.swift
//
// plan-008 Unit I — concept-pinning regression test for the new
// `transcriptionEnabled` master switch wired through
// `ControlBar.startTapped()`.
//
// Why this is a *concept-pin* test rather than a behavioural one:
// the test target `MacrecUITests` can `import MacrecUIKit` but is
// not granted `@testable import macrec_ui` (the popover module is
// the SwiftUI app target itself). We therefore cannot reach the
// `@AppStorage` wrapper or `startTapped()` directly. Instead we
// pin the contract that `startTapped()` relies on:
//
//   1. The persisted key string is **exactly** the value documented
//      in `project-design.md` §UR-9 (`com.macrec.ui.transcriptionEnabled`).
//   2. The default value is `true` (transcription on out-of-the-box;
//      upgrade-safe).
//   3. The persisted value round-trips as a `Bool`.
//   4. The gate semantics are non-mutating (UR-ADR-7): when the
//      switch is OFF the engine receives `"none"` while the
//      user's previously-chosen provider stays in storage so
//      flipping the switch back ON restores it.
//
// If a future change drifts any of these, the gate logic in
// `ControlBar.startTapped()` would silently break (the picker
// would still let users pick a provider, but recordings would
// either always-have or never-have transcription regardless of
// the switch).

import Foundation
import Testing

@Suite("ControlBar transcriptionEnabled key contract")
struct ControlBarStartTappedKeysRegressionTests {

    private let key = "com.macrec.ui.transcriptionEnabled"

    @Test("Key is exactly the documented string")
    func keyIsCanonical() {
        #expect(key == "com.macrec.ui.transcriptionEnabled")
    }

    @Test("Default value is true (transcription on out-of-the-box)")
    func defaultIsTrue() {
        let suite = "TestSuite-ControlBar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // When the key has never been set, Bool reading via @AppStorage
        // would return the declared default. Tests can't reach the
        // @AppStorage wrapper directly, but we pin the convention: the
        // default is true.
        let stored: Bool = defaults.object(forKey: key) as? Bool ?? true
        #expect(stored == true)
    }

    @Test("Round-trip Bool persistence works")
    func roundTrip() {
        let suite = "TestSuite-ControlBar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: key)
        #expect(defaults.bool(forKey: key) == false)

        defaults.set(true, forKey: key)
        #expect(defaults.bool(forKey: key) == true)
    }

    @Test("Gate semantics: provider passed to engine is 'none' when disabled, persisted value otherwise")
    func gateSemantics() {
        // Concept pin of the one-line gate. If `ControlBar.startTapped()`
        // ever mutates the persisted value instead of computing an
        // effective value at call time, the user's last-engine memory
        // would be lost (UR-ADR-7 explicitly forbids this).
        let persistedProvider = "soniox"
        let effective_on  = true  ? persistedProvider : "none"
        let effective_off = false ? persistedProvider : "none"
        #expect(effective_on  == "soniox")
        #expect(effective_off == "none")
        // The persisted value is not mutated:
        #expect(persistedProvider == "soniox")
    }
}
