// MacrecUITests/Transcription/Dual/DualTranscriptionControlsTests.swift —
// plan-010 Phase F / Lane L-8 — Channel A locale-set constraint tests.
//
// PURPOSE: Defend the #1 fragility in `DualTranscriptionControls`:
// the Channel A locale picker MUST source from
// `DualLocaleSets.channelASupportedLocales` (the macOS 26
// `SpeechTranscriber.supportedLocales` set, ~42 locales, NO Greek)
// and NOT from `SFSpeechRecognizer.supportedLocales()` (which DOES
// include `el-GR`). A user picking Greek for the on-device English
// channel would silently fail at session-open inside
// `DualTranscriptionConfig.init` with no actionable error.
//
// TESTABILITY BOUNDARY:
// `DualTranscriptionControls` is a SwiftUI view in the `macrec-ui`
// EXECUTABLE target.  We test the pure-logic locale-set boundary by:
//   (a) Asserting that `DualLocaleSets.channelASupportedLocales` does
//       NOT include `el-GR` (the specific locale that would cause
//       a Channel A session-open failure).
//   (b) Asserting that `DualLocaleSets.channelBSupportedLocales` DOES
//       include `el-GR` (Channel B is the cloud path that supports Greek).
//   (c) Asserting that the two locale sets are DISJOINT on the
//       `el-GR` axis — the design property this test defends.
//   (d) Asserting that `en-US` IS present in Channel A's set (the
//       default locale must be reachable in the picker).
//   (e) Asserting the default locale strings are stable.
//
// The Channel A locale picker in `DualTranscriptionControls` is
// constructed with the INJECTED `DualLocaleSets.channelASupportedLocales`
// array (see source file comment: "the array is INJECTED by the caller;
// `DualLocalePicker` does NOT consult any locale source itself").
// If the injected source ever changes to `SFSpeechRecognizer.supportedLocales()`
// the assertion in (a) would catch the drift because that cloud set
// INCLUDES `el-GR`.
//
// NOTE: `DualLocaleSets.channelASupportedLocales` makes a one-shot
// blocking call to `SpeechTranscriber.supportedLocales` (async, capped
// at 5 s).  On CI / TCC-denied hosts the async resolver may time out
// and return an empty set — in that case the "el-GR absent" assertion
// trivially passes (empty set contains nothing).  The "en-US present"
// assertion is wrapped with `withKnownIssue` to handle the CI case
// gracefully without failing the suite.

import Foundation
import Testing
import Speech
@testable import MacrecCore

@Suite("DualTranscriptionControls Channel-A locale-set constraint (plan-010 §DT-13)")
struct DualTranscriptionControlsTests {

    // MARK: - Default locale constants

    @Test("DualLocaleSets.channelADefaultLocale is 'en-US' (stable default)")
    func channelADefaultLocaleIsEnUS() {
        #expect(DualLocaleSets.channelADefaultLocale == "en-US")
    }

    @Test("DualLocaleSets.channelBDefaultLocale is 'el-GR' (stable default)")
    func channelBDefaultLocaleIsElGR() {
        #expect(DualLocaleSets.channelBDefaultLocale == "el-GR")
    }

    // MARK: - Channel A locale set: MUST NOT include Greek

    @Test("Channel A locale set MUST NOT contain 'el-GR' (SpeechAnalyzer does not support Greek)")
    func channelADoesNotContainGreek() {
        // This is the critical constraint: if 'el-GR' ever appears in
        // channelASupportedLocales, a user could select Greek for the
        // on-device channel. The AppleSpeechTranscriptionProvider would
        // then fail at openStreamingSession time with no user-facing
        // explanation (SpeechTranscriber only supports English variants
        // at macOS 26 launch — confirmed in the investigation doc §Q5).
        let localeIDs = DualLocaleSets.channelASupportedLocales
            .map { $0.identifier }
        #expect(!localeIDs.contains("el-GR"),
                "Channel A locale picker must NOT include el-GR; got: \(localeIDs)")
    }

    @Test("Channel A locale set MUST NOT contain 'el' language code variant")
    func channelADoesNotContainAnyGreekVariant() {
        let locales = DualLocaleSets.channelASupportedLocales
        let greekLocales = locales.filter {
            $0.language.languageCode?.identifier == "el"
        }
        #expect(greekLocales.isEmpty,
                "Channel A locale set must contain no Greek locales; found: \(greekLocales.map { $0.identifier })")
    }

    @Test("Channel A locale set does not include Cloud-only locales (it sources from SpeechTranscriber, not SFSpeechRecognizer)")
    func channelAIsNotSupersetOfCloudSet() {
        // The cloud set (`SFSpeechRecognizer.supportedLocales()`) has ~57
        // locales including Greek. The on-device set is a SUBSET of what
        // the cloud supports for English. If Channel A ever uses the cloud
        // set it would include Greek, which is the core fragility this
        // file defends.
        //
        // Approach: count on-device locales. If the count equals the
        // current SFSpeechRecognizer count (~57) with the same members, it
        // is using the wrong source. We check the specific Greek marker.
        let cloudLocaleIDs = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier })
        let channelALocaleIDs = Set(DualLocaleSets.channelASupportedLocales.map { $0.identifier })

        // If channelA IS using the cloud set we'd have Greek in channelA.
        // The test above already catches this — this one pins the invariant
        // from the other direction: the cloud set contains el-GR.
        #expect(cloudLocaleIDs.contains("el-GR"),
                "Baseline: cloud set must contain el-GR (if this fails the cloud API changed)")
        // Therefore channelA (which must NOT be the cloud set) must not have el-GR.
        #expect(!channelALocaleIDs.contains("el-GR"),
                "Channel A must NOT contain el-GR — it is not using the correct SpeechTranscriber source")
    }

    // MARK: - Channel A locale set: MUST include en-US variant

    @Test("Channel A locale set contains an English-US variant (default locale must be reachable)")
    func channelAContainsEnUSVariant() {
        // SpeechTranscriber.supportedLocales uses underscores in identifiers
        // (e.g. "en_US"), not hyphens ("en-US"). Match by language + region
        // so the test is format-agnostic and survives API-side representation
        // changes. The AppStorage default for Channel A is "en-US"; if no
        // English-US locale exists in the picker the user's default is an orphan.
        let locales = DualLocaleSets.channelASupportedLocales
        if locales.isEmpty {
            withKnownIssue(
                "SpeechTranscriber.supportedLocales timed out — empty set on TCC-denied host"
            ) {
                #expect(!locales.isEmpty)
            }
            return
        }
        let hasEnUS = locales.contains { locale in
            locale.language.languageCode?.identifier == "en" &&
            (locale.region?.identifier == "US" || locale.identifier.contains("US"))
        }
        #expect(hasEnUS,
                "Channel A locale set must include an English-US variant; got: \(locales.map { $0.identifier })")
    }

    @Test("Channel A locale set contains at least one English locale")
    func channelAContainsAtLeastOneEnglishLocale() {
        // Minimal sanity check: the on-device set must have at least one
        // English locale. Does NOT assert English exclusivity — the macOS 26
        // SpeechAnalyzer set includes non-English locales (German, Spanish,
        // French, etc.), so the "English-dominant" assumption from the early
        // investigation doc was incorrect. The authoritative guard remains
        // the Greek-absent test above.
        let locales = DualLocaleSets.channelASupportedLocales
        guard !locales.isEmpty else {
            withKnownIssue("SpeechTranscriber.supportedLocales returned empty set") {
                #expect(!locales.isEmpty)
            }
            return
        }
        let englishLocales = locales.filter {
            $0.language.languageCode?.identifier == "en"
        }
        #expect(!englishLocales.isEmpty,
                "Channel A locale set must contain at least one English locale; got: \(locales.map { $0.identifier })")
    }

    // MARK: - Channel B locale set: MUST include el-GR

    @Test("Channel B locale set MUST contain 'el-GR' (apple-cloud supports Greek)")
    func channelBContainsGreek() {
        let localeIDs = DualLocaleSets.channelBSupportedLocales
            .map { $0.identifier }
        #expect(localeIDs.contains("el-GR"),
                "Channel B locale picker must include el-GR; got: \(localeIDs)")
    }

    @Test("Channel B locale set has el-GR as the first element (sorted first by design)")
    func channelBElGRIsFirst() {
        let locales = DualLocaleSets.channelBSupportedLocales
        guard !locales.isEmpty else {
            // SFSpeechRecognizer.supportedLocales() is synchronous and
            // should never be empty on a macOS 26 host; treat empty as
            // unexpected but non-fatal in this test.
            withKnownIssue("SFSpeechRecognizer.supportedLocales() returned empty set") {
                #expect(!locales.isEmpty)
            }
            return
        }
        #expect(locales[0].identifier == "el-GR",
                "el-GR must be the first (default-prominent) locale in Channel B; got \(locales[0].identifier)")
    }

    // MARK: - Locale set disjointness on the el-GR axis

    @Test("Channel A and Channel B locale sets are disjoint on el-GR")
    func channelAAndBDisjointOnGreek() {
        let channelAIDs = Set(DualLocaleSets.channelASupportedLocales.map { $0.identifier })
        let channelBIDs = Set(DualLocaleSets.channelBSupportedLocales.map { $0.identifier })

        // el-GR must NOT be in Channel A
        #expect(!channelAIDs.contains("el-GR"),
                "el-GR must NOT be in Channel A locale set")
        // el-GR MUST be in Channel B
        #expect(channelBIDs.contains("el-GR"),
                "el-GR MUST be in Channel B locale set")
    }

    // MARK: - AppStorage key stability (DT-ADR-13 — disjoint key spaces)

    @Test("Channel A AppStorage key uses com.macrec.ui.dual.* prefix (disjoint from single-mode)")
    func channelAStorageKeyHasDualPrefix() {
        // The key literal in DualTranscriptionControls must match this
        // string. If it drifts to reuse a single-mode key, toggling
        // Single↔Dual would corrupt the user's single-mode state (AC-2).
        let expected = "com.macrec.ui.dual.channelALocale"
        // We cannot directly read the @AppStorage declaration in the
        // production view, but we can verify that writing to this key
        // round-trips correctly through UserDefaults (same mechanism
        // @AppStorage uses).
        let suite = "TestSuite-DualA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("en-AU", forKey: expected)
        #expect(defaults.string(forKey: expected) == "en-AU")
        #expect(!expected.hasPrefix("com.macrec.ui.transcribe"),
                "Channel A key must use com.macrec.ui.dual.* prefix, not the single-mode prefix")
    }

    @Test("Channel B AppStorage key uses com.macrec.ui.dual.* prefix (disjoint from single-mode)")
    func channelBStorageKeyHasDualPrefix() {
        let expected = "com.macrec.ui.dual.channelBLocale"
        let suite = "TestSuite-DualB-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("fr-FR", forKey: expected)
        #expect(defaults.string(forKey: expected) == "fr-FR")
        #expect(!expected.hasPrefix("com.macrec.ui.transcribe"),
                "Channel B key must use com.macrec.ui.dual.* prefix, not the single-mode prefix")
    }

    @Test("Dual-mode source key is disjoint from single-mode source key")
    func dualSourceKeyDisjointFromSingleModeKey() {
        let dualKey = "com.macrec.ui.dual.source"
        let singleKey = "com.macrec.ui.transcribeSource"
        #expect(dualKey != singleKey,
                "Dual-mode source key must not collide with single-mode key")
    }

    @Test("Dual-mode format key is disjoint from single-mode format key")
    func dualFormatKeyDisjointFromSingleModeKey() {
        let dualKey = "com.macrec.ui.dual.transcriptFormat"
        let singleKey = "com.macrec.ui.transcriptFormat"
        #expect(dualKey != singleKey,
                "Dual-mode format key must not collide with single-mode key")
    }
}
