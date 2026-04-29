// Tests/MacrecCoreTests/Transcription/Soniox/SonioxConfigBuilderEdgeTests.swift
//
// Plan-006 Phase D / Test-Build (soniox-error-paths): boundary and
// edge-case coverage for `SonioxConfigBuilder` beyond what
// `SonioxConfigBuilderTests` already covers (defaults, custom model,
// clientReferenceId round-trip).
//
// New cases exercised here:
//   1. Empty languageHints array  — no crash; config valid and encodable
//   2. Very long clientReferenceId (200 chars) — passes through unchanged
//   3. nil clientReferenceId      — field omitted from JSON output entirely

import XCTest
@testable import MacrecCore

final class SonioxConfigBuilderEdgeTests: XCTestCase {

    // MARK: - 1. Empty languageHints

    func testEmptyLanguageHintsProducesValidConfig() {
        // Callers that pass an empty slice (e.g. when no language hints
        // are configured by the user) must not cause a crash or produce
        // an uncodable struct. The resulting config must be encodable.
        let config = SonioxConfigBuilder.build(apiKey: "test-key", languageHints: [])
        XCTAssertEqual(config.languageHints, [],
                       "Empty languageHints must be stored as an empty array (not nil)")

        // Verify the config is encodable without throwing.
        let encoder = JSONEncoder()
        XCTAssertNoThrow(
            try encoder.encode(config),
            "Config with empty languageHints must be JSON-encodable without throwing"
        )
    }

    // MARK: - 2. Very long clientReferenceId

    func testVeryLongClientReferenceIdPassesThroughUnchanged() {
        // `clientReferenceId` has a Soniox-documented max of 256 chars.
        // The builder must not truncate or modify the value — that guard
        // belongs in the caller, not the builder. A 200-char id must be
        // stored verbatim so the operator's tracing scheme is honoured.
        let longId = String(repeating: "x", count: 200)
        let config = SonioxConfigBuilder.build(
            apiKey: "key",
            languageHints: ["el", "en"],
            clientReferenceId: longId
        )
        XCTAssertEqual(config.clientReferenceId, longId,
                       "A 200-character clientReferenceId must be stored verbatim without truncation")
    }

    // MARK: - 3. nil clientReferenceId → field omitted from JSON

    func testNilClientReferenceIdIsOmittedFromEncodedJSON() {
        // When clientReferenceId is nil (the default), the encoder must
        // NOT include a "client_reference_id" key in the outgoing JSON
        // (Swift's JSONEncoder behaviour for Optional properties with
        // synthesized Encodable conformance — nil == omit). This matters
        // because sending a null-valued key to Soniox would be an
        // unexpected field in the config message.
        let config = SonioxConfigBuilder.build(
            apiKey: "key",
            languageHints: ["el"]
        )
        XCTAssertNil(config.clientReferenceId,
                     "clientReferenceId must be nil when not provided")

        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(config) else {
            XCTFail("Config must be JSON-encodable"); return
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            XCTFail("Encoded JSON must be a dictionary"); return
        }
        XCTAssertFalse(
            jsonObject.keys.contains("client_reference_id"),
            "JSON must NOT contain 'client_reference_id' key when clientReferenceId is nil; keys found: \(jsonObject.keys.sorted())"
        )
    }
}
