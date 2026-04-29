// Tests/MacrecCoreTests/Transcription/Soniox/SonioxLanguageHintMapperEdgeTests.swift
//
// Plan-006 Phase D / Test-Build (soniox-error-paths): edge-case coverage
// for `SonioxLanguageHintMapper` beyond what `SonioxLanguageHintMapperTests`
// already covers (el-GR→el, mixed list, empty input, whitespace filtering,
// defaultHints).
//
// New cases exercised here:
//   1. Already-ISO-639-1 inputs — preserve order, no mutation
//   2. Mixed-case BCP-47 tags   — EL-gr, En-Us → ["el", "en"]
//   3. Triple region tag         — zh-Hant-CN → "zh" (collapse to primary)
//   4. Whitespace within input   — "  el-GR  " → ["el"] (trim before split)

import XCTest
@testable import MacrecCore

final class SonioxLanguageHintMapperEdgeTests: XCTestCase {

    // MARK: - 1. Already-ISO-639-1 inputs

    func testAlreadyIso6391InputsPreserveOrder() {
        // Inputs that are already the plain ISO 639-1 two-letter codes
        // (no region subtag) must pass through without mutation, and their
        // original order must be preserved exactly.
        let result = SonioxLanguageHintMapper.map(["el", "en"])
        XCTAssertEqual(result, ["el", "en"],
                       "Pure ISO 639-1 inputs must come out unchanged in the same order")
    }

    // MARK: - 2. Mixed-case BCP-47 normalisation

    func testMixedCaseBcp47NormalisedToLowercase() {
        // Language tags are case-insensitive per RFC 5646. The mapper must
        // lowercase the primary subtag so consumers never see "EL" or "EN".
        // "EL-gr" → primary "EL" → lowercased to "el"
        // "En-Us" → primary "En" → lowercased to "en"
        let result = SonioxLanguageHintMapper.map(["EL-gr", "En-Us"])
        XCTAssertEqual(result, ["el", "en"],
                       "Mixed-case BCP-47 tags must be normalised to lowercase ISO 639-1")
    }

    // MARK: - 3. Triple region tag (script + region)

    func testTripleRegionTagCollapsesToPrimaryLanguageCode() {
        // BCP-47 can contain script subtags between the language and
        // region: "zh-Hant-CN" (Traditional Chinese, China),
        // "zh-Hans-CN" (Simplified Chinese, China). Split on "-" with
        // maxSplits: 1 yields "zh" as the primary, so both collapse to
        // "zh" and deduplication retains only the first occurrence.
        let result = SonioxLanguageHintMapper.map(["zh-Hant-CN", "zh-Hans-CN"])
        XCTAssertEqual(result, ["zh"],
                       "Both 'zh-Hant-CN' and 'zh-Hans-CN' must collapse to 'zh' (deduped)")
    }

    // MARK: - 4. Whitespace within input (trim before split)

    func testLeadingAndTrailingWhitespaceIsTrimmedBeforeRegionStrip() {
        // "  el-GR  " — the whitespace is on the OUTSIDE of the BCP-47
        // tag. The mapper must trim before splitting on "-", otherwise
        // the trimmed string " el" (with leading space) would not match
        // "el" and the dedup/normalise chain would produce " el" instead.
        let result = SonioxLanguageHintMapper.map(["  el-GR  "])
        XCTAssertEqual(result, ["el"],
                       "'  el-GR  ' must be trimmed then region-stripped to produce ['el']")
    }
}
