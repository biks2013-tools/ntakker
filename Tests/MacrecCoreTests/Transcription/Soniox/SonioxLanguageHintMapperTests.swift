// Tests/MacrecCoreTests/Transcription/Soniox/SonioxLanguageHintMapperTests.swift
//
// Plan-006 Phase D / Unit D1: tests for `SonioxLanguageHintMapper`.
// Test framework: XCTest (matches the Phase A SonioxWireSchemaTests
// convention rather than the project-wide `Testing` framework).

import XCTest
@testable import MacrecCore

final class SonioxLanguageHintMapperTests: XCTestCase {

    func testStripsRegionTagFromSingleHint() {
        XCTAssertEqual(SonioxLanguageHintMapper.map(["el-GR"]), ["el"])
    }

    func testStripsRegionTagsAndDedupesPreservingOrder() {
        XCTAssertEqual(
            SonioxLanguageHintMapper.map(["el-GR", "en-US", "en-GB"]),
            ["el", "en"]
        )
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(SonioxLanguageHintMapper.map([]), [])
    }

    func testWhitespaceAndEmptyStringsAreFilteredOut() {
        XCTAssertEqual(SonioxLanguageHintMapper.map(["", "  "]), [])
    }

    func testDefaultHintsIsGreekThenEnglish() {
        XCTAssertEqual(SonioxLanguageHintMapper.defaultHints, ["el", "en"])
    }
}
