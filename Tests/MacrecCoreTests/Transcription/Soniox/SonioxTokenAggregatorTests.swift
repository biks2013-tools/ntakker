// Tests/MacrecCoreTests/Transcription/Soniox/SonioxTokenAggregatorTests.swift
//
// Plan-006 Phase D / Unit D1: tests for `SonioxTokenAggregator`'s
// state machine.

import XCTest
@testable import MacrecCore

final class SonioxTokenAggregatorTests: XCTestCase {

    func testSingleNonFinalTokenEmitsOnePartial() async {
        let agg = SonioxTokenAggregator()
        let tok = SonioxToken(
            text: "hello",
            isFinal: false,
            startMs: 0,
            endMs: 100,
            confidence: 0.9,
            language: "en"
        )
        let events = await agg.ingest([tok])
        XCTAssertEqual(events.count, 1)
        guard case let .partial(_, text, confidence) = events[0] else {
            return XCTFail("Expected .partial; got \(events[0])")
        }
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(confidence, 0.9)
    }

    func testTwoNonFinalsThenFinalEmitsTwoPartialsAndOneFinal() async {
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "hello ", isFinal: false, confidence: 0.8, language: "en")
        let t2 = SonioxToken(text: "world", isFinal: false, confidence: 0.9, language: "en")
        let t3 = SonioxToken(text: "!", isFinal: true, confidence: 1.0, language: "en")
        let events = await agg.ingest([t1, t2, t3])
        XCTAssertEqual(events.count, 3)
        guard case .partial = events[0] else {
            return XCTFail("Expected .partial at [0]; got \(events[0])")
        }
        guard case .partial = events[1] else {
            return XCTFail("Expected .partial at [1]; got \(events[1])")
        }
        guard case let .final(_, text, _, _, language) = events[2] else {
            return XCTFail("Expected .final at [2]; got \(events[2])")
        }
        XCTAssertEqual(text, "hello world!")
        XCTAssertEqual(language, "en")
    }

    func testEndMarkerAfterPartialFlushesAsFinalWithoutMarkerText() async {
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "hello", isFinal: false, confidence: 0.9, language: "en")
        let endMarker = SonioxToken(text: "<end>", isFinal: true, confidence: 1.0)
        let events = await agg.ingest([t1, endMarker])
        XCTAssertEqual(events.count, 2)
        guard case .partial = events[0] else {
            return XCTFail("Expected .partial first; got \(events[0])")
        }
        guard case let .final(_, text, _, _, _) = events[1] else {
            return XCTFail("Expected .final second; got \(events[1])")
        }
        XCTAssertEqual(text, "hello")
        XCTAssertFalse(text.contains("<end>"))
    }

    func testFinMarkerBehavesSameAsEndMarker() async {
        let agg = SonioxTokenAggregator()
        let t1 = SonioxToken(text: "yes", isFinal: false, confidence: 0.9, language: "en")
        let finMarker = SonioxToken(text: "<fin>", isFinal: true, confidence: 1.0)
        let events = await agg.ingest([t1, finMarker])
        XCTAssertEqual(events.count, 2)
        guard case .partial = events[0] else {
            return XCTFail("Expected .partial first; got \(events[0])")
        }
        guard case let .final(_, text, _, _, _) = events[1] else {
            return XCTFail("Expected .final second; got \(events[1])")
        }
        XCTAssertEqual(text, "yes")
        XCTAssertFalse(text.contains("<fin>"))
    }

    func testDrainWithEmptyBufferReturnsEmpty() async {
        let agg = SonioxTokenAggregator()
        let events = await agg.drain()
        XCTAssertEqual(events.count, 0)
    }
}
