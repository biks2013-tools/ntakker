// Tests/MacrecCoreTests/Transcription/Soniox/SonioxErrorMapperTests.swift
//
// Plan-006 Phase D / Unit D1: tests for `SonioxErrorMapper`.

import XCTest
@testable import MacrecCore

final class SonioxErrorMapperTests: XCTestCase {

    func testMap401IsInvalidApiKey() {
        XCTAssertEqual(
            SonioxErrorMapper.map(httpCode: 401, message: nil),
            .invalidApiKey
        )
    }

    func testMap402IsQuotaExceeded() {
        XCTAssertEqual(
            SonioxErrorMapper.map(httpCode: 402, message: "no credits"),
            .quotaExceeded
        )
    }

    func testMap503IsTerminatedReconnect() {
        XCTAssertEqual(
            SonioxErrorMapper.map(httpCode: 503, message: nil),
            .terminatedReconnect
        )
    }

    func testCloseCodeNormalIsNilOtherwiseConnectionError() {
        XCTAssertNil(SonioxErrorMapper.map(closeCode: .normal))
        XCTAssertEqual(
            SonioxErrorMapper.map(closeCode: .internalServerError),
            .connectionError(code: 1011, reason: nil)
        )
    }
}
