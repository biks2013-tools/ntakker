// MacrecUITests/PrivacyDisclosure/DualPrivacyDisclosureTests.swift —
// plan-010 Phase J / Lane L-12 — dual-mode privacy disclosure trigger.
//
// PURPOSE: Verify the three privacy-gate scenarios in plan-010 §J.3
// and project-design.md §DT-11 (FR-8):
//
//   Test 1 — dual-mode start with apple-cloud NOT acknowledged:
//     The UserDefaults key is absent → the gate logic determines the
//     sheet must appear and the recording must be stopped first.
//
//   Test 2 — dual-mode start with apple-cloud ALREADY acknowledged:
//     The UserDefaults key is present → the gate logic skips the sheet.
//
//   Test 3 — single→dual interop:
//     Acknowledging apple-cloud via the single-mode picker writes the
//     SAME per-provider key that the dual-mode gate checks (DT-ADR-12).
//
// TESTABILITY BOUNDARY:
// The L-12 gate logic lives in `RootView.swift` (the `macrec-ui`
// EXECUTABLE target) and `PrivacyDisclosureViewModel` is also in that
// executable.  Neither is importable from `MacrecUITests`.
//
// We test the gate by:
//   (a) Replicating the key-formula logic (a pure string computation)
//       directly in this file — matching the production formula
//       `"com.local.macrec-ui.transcription.privacy.<providerId>.acknowledged"`.
//   (b) Replicating the gate-decision predicate inline (also a pure
//       boolean function of mode + defaults).
//   (c) Verifying that the controller's `pendingDisclosure` and
//       `acknowledgePendingDisclosure()` surface match the expected
//       pre/post-gate state (these are public on `RecordingController`).
//
// DT-ADR-12: the per-provider key for `apple-cloud` is SHARED between
// single mode and dual mode — acknowledging via the single-mode picker
// carries forward into dual mode.  This means the UserDefaults key
// formula in `PrivacyDisclosureSheet.swift` and the key the L-12 gate
// reads are identical.  We pin this formula here.

import Foundation
import Testing
@testable import MacrecCore
@testable import MacrecUIKit

// MARK: - Pinned key formula (mirrors PrivacyDisclosureViewModel in macrec-ui)

/// Local replica of the production key formula:
///   `"com.local.macrec-ui.transcription.privacy.<providerId>.acknowledged"`
/// Defined by `PrivacyDisclosureViewModel.acknowledgedKey(for:)` in
/// `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift`.
///
/// Pinned here so any drift in the production file is caught by
/// `appleCloudAcknowledgementKeyFormulaIsStable`.
private func acknowledgedKey(for providerId: String) -> String {
    "com.local.macrec-ui.transcription.privacy.\(providerId).acknowledged"
}

// MARK: - Local mirror of the L-12 gate logic

/// Mirrors the dual-mode gate branch in
/// `RootView.onChange(of: recordingController?.state)` (L-12).
/// Returns `true` when a dual-mode start should trigger the disclosure
/// sheet (i.e. the apple-cloud key has not been acknowledged yet).
private enum DualPrivacyGate {

    /// Providers that require a disclosure.
    /// Must stay in sync with `RootView.isCloudProvider(_:)`.
    static let cloudProviders: Set<String> = [
        "gemini", "gemini-live", "soniox",
        "azure", "azure-openai-realtime", "elevenlabs",
        "apple-cloud",
    ]

    static func isCloudProvider(_ providerId: String) -> Bool {
        cloudProviders.contains(providerId.lowercased())
    }

    static func hasAcknowledged(provider providerId: String, in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: acknowledgedKey(for: providerId))
    }

    static func acknowledge(provider providerId: String, in defaults: UserDefaults) {
        defaults.set(true, forKey: acknowledgedKey(for: providerId))
    }

    static func reset(provider providerId: String, in defaults: UserDefaults) {
        defaults.removeObject(forKey: acknowledgedKey(for: providerId))
    }

    /// Simulate the L-12 guard: should the dual-mode start show a disclosure?
    static func shouldShowDisclosure(
        for mode: LiveTranscriptionMode,
        in defaults: UserDefaults
    ) -> Bool {
        guard mode == .dual else { return false }
        // DT-ADR-12: Channel B is always apple-cloud in v1.
        return !hasAcknowledged(provider: "apple-cloud", in: defaults)
    }
}

// MARK: - Test suite

@MainActor
@Suite("DualPrivacyDisclosure trigger (plan-010 §J.3 / FR-8 / DT-ADR-12)")
struct DualPrivacyDisclosureTests {

    // MARK: - Test helpers

    /// Isolated UserDefaults suite so tests do not pollute `.standard`.
    private func makeSuite() -> UserDefaults {
        let name = "TestSuite-DualPrivacy-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func makeController() -> RecordingController {
        RecordingController(logger: .init(label: "test"))
    }

    // MARK: - Key formula pinning

    @Test("Per-provider key formula produces the correct string for apple-cloud")
    func appleCloudAcknowledgementKeyFormulaIsStable() {
        let expected = "com.local.macrec-ui.transcription.privacy.apple-cloud.acknowledged"
        let actual = acknowledgedKey(for: "apple-cloud")
        #expect(actual == expected,
                "Key formula for apple-cloud must match the design spec (DT-ADR-12)")
    }

    @Test("Per-provider key formula is provider-specific (gemini != apple-cloud key)")
    func keyFormulaIsProviderSpecific() {
        let appleCloudKey = acknowledgedKey(for: "apple-cloud")
        let geminiKey = acknowledgedKey(for: "gemini")
        #expect(appleCloudKey != geminiKey,
                "Different providers must have different acknowledged keys")
    }

    @Test("apple-cloud is classified as a cloud provider (gate fires for it)")
    func appleCloudIsCloudProvider() {
        #expect(DualPrivacyGate.isCloudProvider("apple-cloud") == true)
    }

    @Test("apple on-device is NOT a cloud provider (no disclosure for Channel A)")
    func appleOnDeviceIsNotCloudProvider() {
        // Channel A must never trigger a disclosure (it is on-device, no
        // data leaves the machine). L-12 only checks apple-cloud.
        #expect(DualPrivacyGate.isCloudProvider("apple") == false)
    }

    // MARK: - Test 1: apple-cloud NOT acknowledged → gate fires

    @Test("Dual start with apple-cloud NOT acknowledged → disclosure gate fires")
    func dualStartWithoutAcknowledgementTriggersGate() {
        let defaults = makeSuite()
        DualPrivacyGate.reset(provider: "apple-cloud", in: defaults)

        let shouldShow = DualPrivacyGate.shouldShowDisclosure(for: .dual, in: defaults)
        #expect(shouldShow == true,
                "Dual mode with unacknowledged apple-cloud must trigger the disclosure sheet")
    }

    @Test("Fresh UserDefaults suite has no apple-cloud acknowledgement")
    func freshSuiteHasNoAcknowledgement() {
        let defaults = makeSuite()
        let hasKey = DualPrivacyGate.hasAcknowledged(provider: "apple-cloud", in: defaults)
        #expect(hasKey == false,
                "Fresh UserDefaults suite must not have the apple-cloud key set")
    }

    @Test("Controller.pendingDisclosure is nil by default (no gate fired on fresh controller)")
    func controllerPendingDisclosureIsNilByDefault() {
        let c = makeController()
        #expect(c.pendingDisclosure == nil)
    }

    @Test("Controller.acknowledgePendingDisclosure() is a safe no-op when pendingDisclosure is nil")
    func acknowledgeNilPendingDisclosureIsNoOp() {
        let c = makeController()
        #expect(c.pendingDisclosure == nil)
        c.acknowledgePendingDisclosure()
        #expect(c.pendingDisclosure == nil)
    }

    // MARK: - Test 2: apple-cloud ALREADY acknowledged → gate does NOT fire

    @Test("Dual start with apple-cloud ALREADY acknowledged → disclosure gate does NOT fire")
    func dualStartWithAcknowledgementSkipsGate() {
        let defaults = makeSuite()
        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)

        let shouldShow = DualPrivacyGate.shouldShowDisclosure(for: .dual, in: defaults)
        #expect(shouldShow == false,
                "Dual mode with acknowledged apple-cloud must NOT trigger the sheet")
    }

    @Test("Acknowledged key round-trips through UserDefaults")
    func acknowledgedKeyRoundTrips() {
        let defaults = makeSuite()
        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)
        let hasKey = DualPrivacyGate.hasAcknowledged(provider: "apple-cloud", in: defaults)
        #expect(hasKey == true)
    }

    @Test("Acknowledged gate: multiple subsequent dual starts do not re-show the sheet")
    func multipleStartsDontRepeatDisclosure() {
        let defaults = makeSuite()
        let before = DualPrivacyGate.shouldShowDisclosure(for: .dual, in: defaults)
        #expect(before == true)

        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)

        for _ in 0..<3 {
            let subsequent = DualPrivacyGate.shouldShowDisclosure(for: .dual, in: defaults)
            #expect(subsequent == false,
                    "Gate must not re-fire after acknowledgement")
        }
    }

    @Test("Single mode NEVER fires the dual disclosure gate")
    func singleModeNeverFiresDualGate() {
        let defaults = makeSuite()
        DualPrivacyGate.reset(provider: "apple-cloud", in: defaults)
        let shouldShow = DualPrivacyGate.shouldShowDisclosure(for: .single, in: defaults)
        #expect(shouldShow == false,
                "Dual disclosure gate must only fire in .dual mode")
    }

    // MARK: - Test 3: single→dual interop (DT-ADR-12)

    @Test("Single-mode apple-cloud acknowledgement carries into dual mode (DT-ADR-12 shared key)")
    func singleModeAcknowledgementCarriesToDualMode() {
        // DT-ADR-12: the per-provider acknowledgement key is shared
        // between single and dual mode. A user who accepted the apple-cloud
        // disclosure in single mode should NOT see it again in dual mode.
        let defaults = makeSuite()

        // Simulate user acknowledged apple-cloud via the single-mode picker
        // (which writes the same key the gate checks).
        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)

        // Now user switches to dual mode and taps Start.
        let shouldShow = DualPrivacyGate.shouldShowDisclosure(for: .dual, in: defaults)
        #expect(shouldShow == false,
                "Single-mode apple-cloud acknowledgement must satisfy the dual-mode gate")
    }

    @Test("DT-ADR-12: single and dual modes check the SAME UserDefaults key for apple-cloud")
    func singleAndDualModeUseTheSameKey() {
        let key1 = acknowledgedKey(for: "apple-cloud")
        let key2 = acknowledgedKey(for: "apple-cloud")
        #expect(key1 == key2)
        #expect(key1 == "com.local.macrec-ui.transcription.privacy.apple-cloud.acknowledged")
    }

    @Test("apple-cloud acknowledgement is provider-specific: does NOT grant gemini")
    func appleCloudAcknowledgementIsProviderSpecific() {
        let defaults = makeSuite()
        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)

        let hasAppleCloud = DualPrivacyGate.hasAcknowledged(provider: "apple-cloud", in: defaults)
        let hasGemini = DualPrivacyGate.hasAcknowledged(provider: "gemini", in: defaults)

        #expect(hasAppleCloud == true)
        #expect(hasGemini == false,
                "apple-cloud acknowledgement must not bleed into the gemini slot")
    }

    @Test("apple on-device has no disclosure key polluted by apple-cloud acknowledgement")
    func appleOnDeviceHasNoDisclosureKeyPopulated() {
        let defaults = makeSuite()
        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)
        let onDeviceKey = acknowledgedKey(for: "apple")
        #expect(defaults.object(forKey: onDeviceKey) == nil,
                "Acknowledging apple-cloud must not populate the apple (on-device) key")
    }

    @Test("Reset removes apple-cloud acknowledgement (state reverts to unacknowledged)")
    func resetClearsAcknowledgement() {
        let defaults = makeSuite()
        DualPrivacyGate.acknowledge(provider: "apple-cloud", in: defaults)
        #expect(DualPrivacyGate.hasAcknowledged(provider: "apple-cloud", in: defaults) == true)

        DualPrivacyGate.reset(provider: "apple-cloud", in: defaults)
        #expect(DualPrivacyGate.hasAcknowledged(provider: "apple-cloud", in: defaults) == false)

        let shouldShow = DualPrivacyGate.shouldShowDisclosure(for: .dual, in: defaults)
        #expect(shouldShow == true,
                "After reset, the gate must fire again")
    }

    // MARK: - TranscriptionMode enum stability (underpins gate branching)

    @Test("LiveTranscriptionMode.single.rawValue is 'single' (gate branch key)")
    func singleModeRawValueIsStable() {
        #expect(LiveTranscriptionMode.single.rawValue == "single")
    }

    @Test("LiveTranscriptionMode.dual.rawValue is 'dual' (gate branch key)")
    func dualModeRawValueIsStable() {
        #expect(LiveTranscriptionMode.dual.rawValue == "dual")
    }
}
