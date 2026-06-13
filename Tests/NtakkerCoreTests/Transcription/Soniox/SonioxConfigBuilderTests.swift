// Tests/NtakkerCoreTests/Transcription/Soniox/SonioxConfigBuilderTests.swift
//
// Plan-006 Phase D / Unit D1: tests for `SonioxConfigBuilder`.

import XCTest
@testable import NtakkerCore

final class SonioxConfigBuilderTests: XCTestCase {

    func testDefaultsMatchNtakkerV1Policy() {
        let cfg = SonioxConfigBuilder.build(
            apiKey: "key-123",
            languageHints: ["el", "en"]
        )
        XCTAssertEqual(cfg.apiKey, "key-123")
        XCTAssertEqual(cfg.model, "stt-rt-v4")
        XCTAssertEqual(cfg.audioFormat, "pcm_s16le")
        XCTAssertEqual(cfg.sampleRate, 16_000)
        XCTAssertEqual(cfg.numChannels, 1)
        XCTAssertEqual(cfg.languageHints, ["el", "en"])
        XCTAssertEqual(cfg.languageHintsStrict, false)
        XCTAssertEqual(cfg.enableLanguageIdentification, true)
        XCTAssertEqual(cfg.enableEndpointDetection, true)
        XCTAssertEqual(cfg.maxEndpointDelayMs, 2_000)
        XCTAssertEqual(cfg.enableSpeakerDiarization, false)
        XCTAssertNil(cfg.context)
        XCTAssertNil(cfg.clientReferenceId)
        XCTAssertNil(cfg.keepaliveIntervalMs)
    }

    func testCustomModelOverridesDefault() {
        let cfg = SonioxConfigBuilder.build(
            apiKey: "key-xyz",
            model: "stt-rt-future",
            languageHints: ["en"]
        )
        XCTAssertEqual(cfg.model, "stt-rt-future")
    }

    func testClientReferenceIdPassesThrough() {
        let cfg = SonioxConfigBuilder.build(
            apiKey: "key",
            languageHints: ["en"],
            clientReferenceId: "ntakker-cli-rec-1-mic"
        )
        XCTAssertEqual(cfg.clientReferenceId, "ntakker-cli-rec-1-mic")
    }
}
