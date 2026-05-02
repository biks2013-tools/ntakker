// MacrecCoreTests/Transcription/Dual/DualLocaleSetsTests.swift —
// see project-design.md §DT-3 / §DT-9, plan-010-dual-transcription.md §Phase A
//
// Phase 7 reviewer requested tests — correctness checks for
// `DualLocaleSets`: count > 0, key locale memberships (en-US present
// in Channel A; el-GR absent from Channel A; el-GR + en-US present
// in Channel B), and the superset relationship between the two sets.
//
// NOTE on `channelASupportedLocales`: the first access triggers a
// blocking 5-second wait for `SpeechTranscriber.supportedLocales`
// (see `DualLocaleSets.resolveChannelALocalesBlocking`). On hosts
// without the Speech framework entitlement the query may time out
// and return an empty array. Tests that depend on a non-empty Channel
// A set are labelled with a guard so they emit a clear Issue record
// rather than a confusing assertion failure.
//
// `channelBSupportedLocales` queries `SFSpeechRecognizer.supportedLocales()`
// which is always available (no entitlement needed for the metadata
// call itself); the only risk is a very old Speech binary with a
// reduced locale set.

import Foundation
import Testing
@testable import MacrecCore

@Suite("DualLocaleSets — locale set correctness")
struct DualLocaleSetsTests {

    // MARK: - Channel B (SFSpeechRecognizer) — always available

    @Test("Channel B supported locales count is > 0")
    func channelBLocaleCountPositive() {
        let locales = DualLocaleSets.channelBSupportedLocales
        #expect(!locales.isEmpty,
                "channelBSupportedLocales must be non-empty; SFSpeechRecognizer returned 0 locales")
    }

    @Test("Channel B supported locales contains el-GR")
    func channelBContainsGreek() {
        let locales = DualLocaleSets.channelBSupportedLocales
        // `Locale.identifier` on macOS uses underscore separators (e.g.
        // `el_GR`), while BCP-47 uses hyphens (`el-GR`). Accept both.
        let identifiers = Set(locales.map(\.identifier))
        let containsGreek = identifiers.contains("el-GR") || identifiers.contains("el_GR")
        #expect(containsGreek,
                "channelBSupportedLocales must contain el-GR (hyphen or underscore); got: \(identifiers.sorted())")
    }

    @Test("Channel B supported locales contains en-US")
    func channelBContainsEnglishUS() {
        let locales = DualLocaleSets.channelBSupportedLocales
        // Accept both `en-US` (BCP-47) and `en_US` (macOS Locale.identifier).
        let identifiers = Set(locales.map(\.identifier))
        let containsEnUS = identifiers.contains("en-US") || identifiers.contains("en_US")
        #expect(containsEnUS,
                "channelBSupportedLocales must contain en-US (hyphen or underscore); got: \(identifiers.sorted())")
    }

    @Test("Channel B default locale (el-GR) is first in sorted order")
    func channelBGreekIsFirst() {
        let locales = DualLocaleSets.channelBSupportedLocales
        guard !locales.isEmpty else { return }  // guarded by channelBLocaleCountPositive
        let firstId = locales[0].identifier
        // Accept both "el-GR" (BCP-47) and "el_GR" (macOS Locale.identifier).
        let isGreekFirst = firstId == "el-GR" || firstId == "el_GR"
        #expect(isGreekFirst,
                "First Channel B locale must be el-GR (sort spec: Greek first); got: '\(firstId)'")
    }

    // MARK: - Channel A (SpeechTranscriber) — may be empty on CI

    @Test("Channel A default locale (en-US) is in DualLocaleSets.channelADefaultLocale constant")
    func channelADefaultLocaleConstant() {
        #expect(DualLocaleSets.channelADefaultLocale == "en-US",
                "channelADefaultLocale constant must be 'en-US'")
    }

    @Test("Channel B default locale (el-GR) is in DualLocaleSets.channelBDefaultLocale constant")
    func channelBDefaultLocaleConstant() {
        #expect(DualLocaleSets.channelBDefaultLocale == "el-GR",
                "channelBDefaultLocale constant must be 'el-GR'")
    }

    @Test("Channel A supported locales does NOT contain el-GR (on-device set excludes Greek at macOS 26 launch)")
    func channelAExcludesGreek() {
        let locales = DualLocaleSets.channelASupportedLocales
        guard !locales.isEmpty else {
            // The on-device locale query timed out or returned empty due
            // to missing Speech entitlement on this host. Skip rather
            // than fabricate a result.
            Issue.record("channelASupportedLocales is empty — Speech framework may not be entitled on this host. Skipping el-GR exclusion check.")
            return
        }
        let identifiers = Set(locales.map(\.identifier))
        #expect(!identifiers.contains("el-GR"),
                "channelASupportedLocales must NOT contain 'el-GR' at macOS 26 launch (Apple on-device does not support Greek); got: \(identifiers.sorted())")
    }

    @Test("Channel A supported locales count is > 0 when Speech entitlement is available")
    func channelALocaleCountPositiveWhenAvailable() {
        let locales = DualLocaleSets.channelASupportedLocales
        if locales.isEmpty {
            // Not a failure — may be running on a CI host without Speech.
            // Record as informational.
            Issue.record("channelASupportedLocales is empty — Speech framework may not be entitled on this host. If running locally with Speech permission, this should not be empty.")
            return
        }
        // If we have locales, assert a plausible lower bound.
        // The documented count at macOS 26 launch is ~42; 5 is a
        // conservative floor that would only fail if the API breaks.
        #expect(locales.count >= 5,
                "channelASupportedLocales.count should be >= 5; got: \(locales.count)")
    }

    @Test("Channel A supported locales contains en-US when Speech entitlement is available")
    func channelAContainsEnglishUS() {
        let locales = DualLocaleSets.channelASupportedLocales
        guard !locales.isEmpty else {
            Issue.record("channelASupportedLocales is empty — en-US membership check skipped.")
            return
        }
        let identifiers = Set(locales.map(\.identifier))
        // Accept both `en-US` (BCP-47) and `en_US` (macOS Locale.identifier).
        // macOS uses underscore in Locale.identifier; BCP-47 uses hyphens.
        let containsEnUS = identifiers.contains("en-US") || identifiers.contains("en_US")
        #expect(containsEnUS,
                "channelASupportedLocales must contain en-US (hyphen or underscore); got: \(identifiers.sorted().prefix(20))")
    }

    // MARK: - Superset relationship

    @Test("Both sets share en-US — the intersection of english-language locales is non-empty")
    func bothSetsShareEnglishUS() {
        // This is the sanity check requested by the Phase 7 reviewer:
        // "Assert that channelBSupportedLocales is a strict superset of
        // channelASupportedLocales's English variants (sanity check —
        // both should have at least en-US)."
        //
        // We narrow to the single anchor `en-US` (the v1 Channel A default)
        // because the full superset assertion requires the Channel A set to
        // be non-empty, which cannot be guaranteed on CI.
        //
        // NOTE: macOS `Locale.identifier` uses underscores (e.g. `en_US`)
        // while BCP-47 uses hyphens (`en-US`). We normalise to underscore
        // for comparison because that is what `Locale.identifier` returns.
        func normalise(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "_") }

        let channelBIds = Set(DualLocaleSets.channelBSupportedLocales.map { normalise($0.identifier) })
        // Channel B (SFSpeechRecognizer) always has en_US / en-US.
        #expect(channelBIds.contains("en_US"),
                "channelBSupportedLocales must contain en-US/en_US — shared anchor for both channels; got: \(channelBIds.sorted().prefix(10))")

        // If Channel A set is available, additionally verify en_US
        // appears there too, confirming the "both have en-US" invariant.
        let channelALocales = DualLocaleSets.channelASupportedLocales
        if !channelALocales.isEmpty {
            let channelAIds = Set(channelALocales.map { normalise($0.identifier) })
            #expect(channelAIds.contains("en_US"),
                    "channelASupportedLocales must contain en-US/en_US; got: \(channelAIds.sorted().prefix(20))")
            // Verify that every Channel A English locale ALSO appears in
            // Channel B (the "strict superset on English" invariant).
            let channelAEnglish = channelAIds.filter { $0.hasPrefix("en_") }
            let missingFromB = channelAEnglish.subtracting(channelBIds)
            #expect(missingFromB.isEmpty,
                    "Channel B must be a superset of Channel A's English locales; missing: \(missingFromB.sorted())")
        }
    }
}
