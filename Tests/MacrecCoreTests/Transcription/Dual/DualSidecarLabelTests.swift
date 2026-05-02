// MacrecCoreTests/Transcription/Dual/DualSidecarLabelTests.swift —
// see project-design.md §DT-2 (OQ-3 resolution) / §DT-7,
// plan-010-dual-transcription.md §Wave-4 Lane L-6
//
// Phase 7 reviewer requested tests for `DualSidecarLabel`:
//   1. `channelLabel(for: .channelA) == "EN"`
//   2. `channelLabel(for: .channelB) == "EL"`
//   3. `channelTag(forModel: "apple") == .channelA`
//   4. `channelTag(forModel: "apple-cloud") == .channelB`
//   5. `channelTag(forModel: anything_else) == nil`
//
// Note: `SidecarChannelTaggingTests.swift` (Lane L-6) already tests
// `channelTag(forModel:)` for the `"apple"`, `"apple-cloud"`,
// `"gemini-live"`, and `nil` cases. This suite AUGMENTS that coverage
// with the channel-label mapping (which is NOT in L-6's suite) and
// adds the edge cases `""` and `nil` to the model-tag helper.
//
// These tests are pure unit tests of stateless static functions —
// no async context, no framework mocking required.

import Foundation
import Testing
@testable import MacrecCore

@Suite("DualSidecarLabel — channel label and model-tag mapping")
struct DualSidecarLabelTests {

    // MARK: - channelLabel(for:) — DualChannelTag → String

    @Test("channelLabel(for: .channelA) returns 'EN' (v1 English channel)")
    func channelLabelForChannelAIsEN() {
        let label = DualSidecarLabel.channelLabel(for: .channelA)
        #expect(label == "EN",
                "Expected 'EN' for .channelA; got: '\(label)'")
    }

    @Test("channelLabel(for: .channelB) returns 'EL' (v1 Greek channel)")
    func channelLabelForChannelBIsEL() {
        let label = DualSidecarLabel.channelLabel(for: .channelB)
        #expect(label == "EL",
                "Expected 'EL' for .channelB; got: '\(label)'")
    }

    @Test("channelLabel(for:) covers all DualChannelTag cases — no missing arm")
    func channelLabelCoversAllCases() {
        // CaseIterable conformance on DualChannelTag lets us verify
        // that every case returns a non-empty label without listing
        // cases manually. Protects against future wave adding a third
        // channel and forgetting to update the switch.
        for tag in DualChannelTag.allCases {
            let label = DualSidecarLabel.channelLabel(for: tag)
            #expect(!label.isEmpty,
                    "channelLabel(for: .\(tag)) must not be empty; got: '\(label)'")
        }
    }

    // MARK: - channelLabel(forLocale:) — BCP-47 → uppercase primary subtag

    @Test("channelLabel(forLocale: 'en-US') returns 'EN'")
    func localeEnUSReturnsEN() {
        let label = DualSidecarLabel.channelLabel(forLocale: "en-US")
        #expect(label == "EN")
    }

    @Test("channelLabel(forLocale: 'el-GR') returns 'EL'")
    func localeElGRReturnsEL() {
        let label = DualSidecarLabel.channelLabel(forLocale: "el-GR")
        #expect(label == "EL")
    }

    @Test("channelLabel(forLocale: 'de-DE') returns 'DE'")
    func localeDeDeReturnsDe() {
        let label = DualSidecarLabel.channelLabel(forLocale: "de-DE")
        #expect(label == "DE")
    }

    @Test("channelLabel(forLocale: 'fr-CA') returns 'FR'")
    func localeFrCaReturnsFr() {
        let label = DualSidecarLabel.channelLabel(forLocale: "fr-CA")
        #expect(label == "FR")
    }

    @Test("channelLabel(forLocale: 'zh-Hant-TW') returns 'ZH' (three-part BCP-47 tag)")
    func localeZhHantTwReturnsZh() {
        let label = DualSidecarLabel.channelLabel(forLocale: "zh-Hant-TW")
        #expect(label == "ZH")
    }

    @Test("channelLabel(forLocale: '') returns '' (defensive empty-string case)")
    func localeEmptyStringReturnsEmpty() {
        let label = DualSidecarLabel.channelLabel(forLocale: "")
        #expect(label == "",
                "Empty locale must return empty string (defensive — no crash); got: '\(label)'")
    }

    // MARK: - channelTag(forModel:) — model String → DualChannelTag?

    @Test("channelTag(forModel: 'apple') returns .channelA")
    func modelAppleReturnsChannelA() {
        let tag = DualSidecarLabel.channelTag(forModel: "apple")
        #expect(tag == .channelA,
                "Model 'apple' must map to .channelA; got: \(String(describing: tag))")
    }

    @Test("channelTag(forModel: 'apple-cloud') returns .channelB")
    func modelAppleCloudReturnsChannelB() {
        let tag = DualSidecarLabel.channelTag(forModel: "apple-cloud")
        #expect(tag == .channelB,
                "Model 'apple-cloud' must map to .channelB; got: \(String(describing: tag))")
    }

    @Test("channelTag(forModel: nil) returns nil (nil model → no channel)")
    func modelNilReturnsNil() {
        let tag = DualSidecarLabel.channelTag(forModel: nil)
        #expect(tag == nil,
                "nil model must return nil tag; got: \(String(describing: tag))")
    }

    @Test("channelTag(forModel: '') returns nil (empty string is not a known provider id)")
    func modelEmptyStringReturnsNil() {
        let tag = DualSidecarLabel.channelTag(forModel: "")
        #expect(tag == nil,
                "Empty model string must return nil tag; got: \(String(describing: tag))")
    }

    @Test("channelTag(forModel: 'gemini-live') returns nil")
    func modelGeminiLiveReturnsNil() {
        let tag = DualSidecarLabel.channelTag(forModel: "gemini-live")
        #expect(tag == nil)
    }

    @Test("channelTag(forModel: 'soniox') returns nil")
    func modelSonioxReturnsNil() {
        let tag = DualSidecarLabel.channelTag(forModel: "soniox")
        #expect(tag == nil)
    }

    @Test("channelTag(forModel: 'whisperkit') returns nil")
    func modelWhisperKitReturnsNil() {
        let tag = DualSidecarLabel.channelTag(forModel: "whisperkit")
        #expect(tag == nil)
    }

    @Test("channelTag(forModel: 'Apple') returns nil — model match is case-sensitive")
    func modelAppleUppercaseReturnsNil() {
        // The switch in channelTag(forModel:) uses exact string comparison.
        // 'Apple' (capital A) is NOT the model id — 'apple' (lower) is.
        let tag = DualSidecarLabel.channelTag(forModel: "Apple")
        #expect(tag == nil,
                "channelTag(forModel:) is case-sensitive; 'Apple' ≠ 'apple'. Got: \(String(describing: tag))")
    }
}
