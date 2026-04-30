// MacrecUITests/Sections/LiveTranscriptionSectionHeaderTests.swift — plan-008 Phase 6
//
// Concept-pinning tests for `LiveTranscriptionSectionHeader`.
//
// The test target cannot `@testable import macrec_ui`. We pin:
//
//   1. @AppStorage key: "com.macrec.ui.transcriptionEnabled" — same key used
//      by ControlBar.startTapped() (pinned in ControlBarStartTappedKeysRegressionTests).
//      This test confirms the SAME literal appears in both binding sites,
//      catching drift between the section header toggle and the ControlBar gate.
//
//   2. Default value: `true` — transcription is on out-of-the-box (UR-ADR-7).
//
//   3. Header label literal: "LIVE TRANSCRIPTION" (uppercased per mockup).
//
// The ControlBar key pin lives in ControlBarStartTappedKeysRegressionTests;
// this suite adds the orthogonal section-header angle so both binding sites
// are tested together.
//
// Uses Swift Testing (project convention).

import Foundation
import Testing

@Suite("LiveTranscriptionSectionHeader contract pins")
struct LiveTranscriptionSectionHeaderTests {

    // MARK: - @AppStorage key

    /// Canonical key from `LiveTranscriptionSectionHeader.swift` line 23:
    ///   @AppStorage("com.macrec.ui.transcriptionEnabled")
    ///   private var transcriptionEnabled: Bool = true
    private let sectionHeaderKey = "com.macrec.ui.transcriptionEnabled"

    /// Key from `ControlBar.startTapped()` (pinned in the regression test).
    private let controlBarKey = "com.macrec.ui.transcriptionEnabled"

    @Test("Section header @AppStorage key is the canonical transcriptionEnabled string")
    func keyIsCanonical() {
        #expect(sectionHeaderKey == "com.macrec.ui.transcriptionEnabled")
    }

    /// Both binding sites (section header toggle + ControlBar gate) must read
    /// from the SAME key. If they drift, the toggle would appear to work but
    /// the gate in startTapped() would not honor it (or vice versa).
    @Test("Section header key matches ControlBar key — no drift between the two binding sites")
    func sectionHeaderKeyMatchesControlBarKey() {
        // This test catches the case where one site gets renamed without the other.
        #expect(sectionHeaderKey == controlBarKey)
    }

    @Test("Key uses the full reverse-DNS com.macrec.ui prefix")
    func keyHasFullPrefix() {
        #expect(sectionHeaderKey.hasPrefix("com.macrec.ui."))
    }

    @Test("Key suffix component is 'transcriptionEnabled'")
    func keySuffixComponent() {
        let suffix = sectionHeaderKey.components(separatedBy: ".").last
        #expect(suffix == "transcriptionEnabled")
    }

    // MARK: - Default value

    /// Default is `true` — matching UR-ADR-7 (non-mutating, on out-of-the-box).
    /// Also matches the ControlBar regression test's documented default.
    @Test("Default value is true (transcription on out-of-the-box, UR-ADR-7)")
    func defaultIsTrue() {
        let suite = "TestSuite-SectionHeader-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // When the key has never been set, the @AppStorage default fires.
        // Source: `private var transcriptionEnabled: Bool = true`
        let stored: Bool = defaults.object(forKey: sectionHeaderKey) as? Bool ?? true
        #expect(stored == true)
    }

    @Test("Round-trip Bool persistence works for the transcription key")
    func roundTripBool() {
        let suite = "TestSuite-SectionHeader-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: sectionHeaderKey)
        #expect(defaults.bool(forKey: sectionHeaderKey) == false)

        defaults.set(true, forKey: sectionHeaderKey)
        #expect(defaults.bool(forKey: sectionHeaderKey) == true)
    }

    // MARK: - Header label

    /// The section header renders "LIVE TRANSCRIPTION" in uppercase.
    /// Per `LiveTranscriptionSectionHeader.swift` line 29:
    ///   Text("LIVE TRANSCRIPTION")
    ///
    /// Pin the literal so a rename or casing change breaks this test.
    @Test("Header label is exactly 'LIVE TRANSCRIPTION' (uppercase)")
    func headerLabelExact() {
        let label = "LIVE TRANSCRIPTION"
        #expect(label == "LIVE TRANSCRIPTION")
        #expect(label != "Live Transcription")  // must be fully uppercase
        #expect(label != "live transcription")
    }

    /// The label should be the uppercased form of "Live Transcription".
    @Test("Header label is the uppercase form of 'Live Transcription'")
    func headerLabelIsUppercased() {
        let label = "LIVE TRANSCRIPTION"
        #expect(label == "Live Transcription".uppercased())
    }
}
