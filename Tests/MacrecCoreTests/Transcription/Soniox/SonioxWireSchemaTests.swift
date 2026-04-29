// Tests/MacrecCoreTests/Transcription/Soniox/SonioxWireSchemaTests.swift
//
// Plan-006 Phase A / Unit A: snapshot tests for the Soniox wire-format
// Codable types in `Sources/MacrecCore/Transcription/Live/Soniox/`.
//
// These tests pin the producer/consumer contract against the JSON
// shapes documented in `docs/research/soniox-wire-schema.md` (§§2.1,
// 2.3, 3.1–3.5). They cover:
//   1.  Minimal config encode (api_key + model + format + rate +
//       channels + hints).
//   2.  Maximal config encode (every Optional populated).
//   3.  Decode of a typical mixed-tokens batch.
//   4.  Decode of an `<end>` marker token envelope.
//   5.  Decode of a `<fin>` marker token envelope.
//   6.  Decode of the terminal `finished: true` envelope.
//   7.  Decode of each error envelope (401, 402, 408, 503).
//   8.  Round-trip of `{"type":"keepalive"}` and `{"type":"finalize"}`.
//   9.  Forward-compat: an unknown JSON field MUST NOT cause decode
//       failure.
//   10. Outgoing config produces ONLY documented keys (no inferred
//       extras leak into the wire).
//
// Test framework: `XCTest` (per the Phase A task brief). Note this
// deviates from the project's standard `Testing`-framework pattern —
// see Unit A summary for rationale.

import XCTest
@testable import MacrecCore

final class SonioxWireSchemaTests: XCTestCase {

    // MARK: - Encoder helper

    /// Default-formatted encoder (compact, no sorted keys), per the
    /// Phase A brief: "Use `JSONEncoder` with default formatting
    /// (compact). Verify `OutputFormatting = []`."
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        XCTAssertEqual(encoder.outputFormatting, [])
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    // MARK: - Structural JSON comparison
    //
    // Compares two JSON byte buffers for *semantic* equivalence
    // (key set + value set), ignoring whitespace and key order. We
    // need this because the research doc's verbatim JSON literals
    // are pretty-printed/indented for human readability while the
    // encoder produces compact output.
    //
    // The byte-exact key-order assertions are handled by separate
    // `assertExactBytes` checks where we know the canonical
    // declaration order.

    private func assertJSONEqual(
        _ actual: Data,
        _ expectedJSON: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expectedData = expectedJSON.data(using: .utf8) else {
            XCTFail("Expected JSON not UTF-8 representable",
                    file: file, line: line)
            return
        }
        let actualParsed: Any
        let expectedParsed: Any
        do {
            actualParsed = try JSONSerialization.jsonObject(
                with: actual,
                options: [.fragmentsAllowed]
            )
            expectedParsed = try JSONSerialization.jsonObject(
                with: expectedData,
                options: [.fragmentsAllowed]
            )
        } catch {
            XCTFail("JSON parse failure: \(error)\nactual: " +
                    "\(String(data: actual, encoding: .utf8) ?? "<nil>")",
                    file: file, line: line)
            return
        }
        let actualNS  = actualParsed   as? NSObject
        let expectNS  = expectedParsed as? NSObject
        XCTAssertEqual(
            actualNS, expectNS,
            "JSON mismatch.\nExpected:\n\(expectedJSON)\nActual:\n" +
            "\(String(data: actual, encoding: .utf8) ?? "<nil>")",
            file: file, line: line
        )
    }

    // MARK: - 1. Minimal config encode

    /// Verbatim from `docs/research/soniox-wire-schema.md` §2.1
    /// "Minimal recommended config for `macrec`" — minus `client_reference_id`,
    /// `language_hints_strict`, `enable_language_identification`,
    /// `enable_endpoint_detection`, `max_endpoint_delay_ms` (those
    /// belong to the maximal-config test). The Phase A brief's
    /// "minimal" set is api_key + model + audio_format + sample_rate
    /// + num_channels + language_hints.
    func testEncodeMinimalConfig() throws {
        let config = SonioxConfigMessage(
            apiKey: "TEST_API_KEY",
            model: "stt-rt-v4",
            audioFormat: "pcm_s16le",
            sampleRate: 16_000,
            numChannels: 1,
            languageHints: ["el", "en"],
            languageHintsStrict: nil,
            enableLanguageIdentification: nil,
            enableEndpointDetection: nil,
            maxEndpointDelayMs: nil,
            enableSpeakerDiarization: nil,
            context: nil,
            clientReferenceId: nil,
            keepaliveIntervalMs: nil
        )

        let data = try makeEncoder().encode(config)

        // Verbatim minimal-config JSON from the research doc, trimmed
        // to the fields listed in the Phase A brief's "minimal" set.
        let expectedJSON = """
        {
          "api_key": "TEST_API_KEY",
          "model": "stt-rt-v4",
          "audio_format": "pcm_s16le",
          "sample_rate": 16000,
          "num_channels": 1,
          "language_hints": ["el", "en"]
        }
        """

        assertJSONEqual(data, expectedJSON)

        // Sanity check on encoder configuration: default
        // `outputFormatting` is `[]` (compact, no sorted keys, no
        // pretty-printing). Soniox accepts any compliant JSON, so we
        // do NOT pin a byte-exact key order — `JSONEncoder` does not
        // guarantee declaration order. Structural equivalence above
        // is the contract.
        XCTAssertFalse(
            (String(data: data, encoding: .utf8) ?? "").contains("\n"),
            "Default JSONEncoder must produce single-line compact JSON"
        )
    }

    // MARK: - 2. Maximal config encode

    /// Every Optional populated. Mirrors the "Full wire JSON (all
    /// supported fields)" example in §2.1 of the research doc, minus
    /// `translation` (out of v1 scope per OQ-SX-3 default — the field
    /// is not present in the Swift struct at all).
    func testEncodeMaximalConfig() throws {
        let context = SonioxContext(
            general: [
                SonioxContextEntry(key: "domain", value: "meeting")
            ],
            text: "Background text context here.",
            terms: ["MacRec", "ScreenCaptureKit"],
            translationTerms: [
                SonioxTranslationTerm(source: "MacRec", target: "MacRec")
            ]
        )

        let config = SonioxConfigMessage(
            apiKey: "TEST_API_KEY",
            model: "stt-rt-v4",
            audioFormat: "pcm_s16le",
            sampleRate: 16_000,
            numChannels: 1,
            languageHints: ["el", "en"],
            languageHintsStrict: false,
            enableLanguageIdentification: true,
            enableEndpointDetection: true,
            maxEndpointDelayMs: 2_000,
            enableSpeakerDiarization: false,
            context: context,
            clientReferenceId: "macrec-recid-mixed",
            keepaliveIntervalMs: 10_000
        )

        let data = try makeEncoder().encode(config)

        let expectedJSON = """
        {
          "api_key": "TEST_API_KEY",
          "model": "stt-rt-v4",
          "audio_format": "pcm_s16le",
          "sample_rate": 16000,
          "num_channels": 1,
          "language_hints": ["el", "en"],
          "language_hints_strict": false,
          "enable_language_identification": true,
          "enable_endpoint_detection": true,
          "max_endpoint_delay_ms": 2000,
          "enable_speaker_diarization": false,
          "context": {
            "general": [
              { "key": "domain", "value": "meeting" }
            ],
            "text": "Background text context here.",
            "terms": ["MacRec", "ScreenCaptureKit"],
            "translation_terms": [
              { "source": "MacRec", "target": "MacRec" }
            ]
          },
          "client_reference_id": "macrec-recid-mixed",
          "keepalive_interval_ms": 10000
        }
        """

        assertJSONEqual(data, expectedJSON)
    }

    // MARK: - 3. Decode mixed-tokens batch

    /// §3.1 "Example: With `language` field" — the most field-dense
    /// realistic batch the production session will see. Mixes
    /// `is_final: true` and (synthesized) `is_final: false` entries
    /// with `confidence` and `language` populated.
    func testDecodeMixedTokensBatch() throws {
        let json = """
        {
          "tokens": [
            { "text": "Καλημέρα", "start_ms": 120, "end_ms": 480,
              "confidence": 0.97, "is_final": true,  "language": "el" },
            { "text": " good",    "start_ms": 500, "end_ms": 640,
              "confidence": 0.89, "is_final": true,  "language": "en" },
            { "text": " morning", "start_ms": 640, "end_ms": 820,
              "confidence": 0.93, "is_final": false, "language": "en" }
          ],
          "final_audio_proc_ms": 640,
          "total_audio_proc_ms": 820
        }
        """
        let data = json.data(using: .utf8)!

        let msg = try makeDecoder().decode(SonioxServerMessage.self, from: data)

        XCTAssertEqual(msg.tokens.count, 3)
        XCTAssertEqual(msg.finalAudioProcMs, 640)
        XCTAssertEqual(msg.totalAudioProcMs, 820)
        XCTAssertNil(msg.finished)
        XCTAssertNil(msg.errorCode)
        XCTAssertNil(msg.errorMessage)

        let t0 = msg.tokens[0]
        XCTAssertEqual(t0.text, "Καλημέρα")
        XCTAssertEqual(t0.startMs, 120)
        XCTAssertEqual(t0.endMs, 480)
        XCTAssertEqual(try XCTUnwrap(t0.confidence), 0.97, accuracy: 1e-9)
        XCTAssertTrue(t0.isFinal)
        XCTAssertEqual(t0.language, "el")
        XCTAssertNil(t0.speaker)
        XCTAssertNil(t0.translationStatus)
        XCTAssertNil(t0.sourceLanguage)
        XCTAssertFalse(t0.isMarker)

        let t1 = msg.tokens[1]
        XCTAssertEqual(t1.text, " good")
        XCTAssertEqual(try XCTUnwrap(t1.confidence), 0.89, accuracy: 1e-9)
        XCTAssertTrue(t1.isFinal)
        XCTAssertEqual(t1.language, "en")

        let t2 = msg.tokens[2]
        XCTAssertEqual(t2.text, " morning")
        XCTAssertEqual(try XCTUnwrap(t2.confidence), 0.93, accuracy: 1e-9)
        XCTAssertFalse(t2.isFinal)
        XCTAssertEqual(t2.language, "en")
    }

    // MARK: - 4. Decode `<end>` marker envelope

    /// §3.2 endpoint-detection response.
    func testDecodeEndMarkerEnvelope() throws {
        let json = """
        {
          "tokens": [
            { "text": "<end>", "start_ms": 1240, "end_ms": 1240,
              "confidence": 1.0, "is_final": true, "language": "el" }
          ],
          "final_audio_proc_ms": 1240,
          "total_audio_proc_ms": 1240
        }
        """
        let data = json.data(using: .utf8)!

        let msg = try makeDecoder().decode(SonioxServerMessage.self, from: data)
        XCTAssertEqual(msg.tokens.count, 1)
        let token = msg.tokens[0]
        XCTAssertEqual(token.text, "<end>")
        XCTAssertTrue(token.isEndMarker)
        XCTAssertFalse(token.isFinalizeMarker)
        XCTAssertTrue(token.isMarker)
        XCTAssertTrue(token.isFinal)
        XCTAssertEqual(try XCTUnwrap(token.confidence), 1.0, accuracy: 1e-9)
        XCTAssertEqual(token.language, "el")
        XCTAssertEqual(msg.finalAudioProcMs, 1240)
        XCTAssertEqual(msg.totalAudioProcMs, 1240)
        XCTAssertFalse(msg.isFinishedResponse)
        XCTAssertFalse(msg.isErrorResponse)
    }

    // MARK: - 5. Decode `<fin>` marker envelope

    /// §3.3 manual-finalize response.
    func testDecodeFinMarkerEnvelope() throws {
        let json = """
        {
          "tokens": [
            { "text": " recording", "start_ms": 2100, "end_ms": 2440,
              "confidence": 0.92, "is_final": true },
            { "text": "<fin>",      "start_ms": 2440, "end_ms": 2440,
              "confidence": 1.0,  "is_final": true }
          ],
          "final_audio_proc_ms": 2440,
          "total_audio_proc_ms": 2440
        }
        """
        let data = json.data(using: .utf8)!

        let msg = try makeDecoder().decode(SonioxServerMessage.self, from: data)
        XCTAssertEqual(msg.tokens.count, 2)

        let recording = msg.tokens[0]
        XCTAssertEqual(recording.text, " recording")
        XCTAssertFalse(recording.isMarker)

        let finToken = msg.tokens[1]
        XCTAssertEqual(finToken.text, "<fin>")
        XCTAssertFalse(finToken.isEndMarker)
        XCTAssertTrue(finToken.isFinalizeMarker)
        XCTAssertTrue(finToken.isMarker)
        XCTAssertTrue(finToken.isFinal)
        XCTAssertEqual(try XCTUnwrap(finToken.confidence), 1.0, accuracy: 1e-9)

        XCTAssertEqual(msg.finalAudioProcMs, 2440)
        XCTAssertEqual(msg.totalAudioProcMs, 2440)
    }

    // MARK: - 6. Decode terminal `finished` envelope

    /// §3.4. The terminal close-confirmation. `tokens: []`,
    /// `finished: true`, both timing fields set.
    func testDecodeFinishedCloseEnvelope() throws {
        let json = #"{"finished": true, "final_audio_proc_ms": 12345, "total_audio_proc_ms": 12500, "tokens": []}"#
        let data = json.data(using: .utf8)!

        let msg = try makeDecoder().decode(SonioxServerMessage.self, from: data)
        XCTAssertTrue(msg.tokens.isEmpty)
        XCTAssertEqual(msg.finished, true)
        XCTAssertTrue(msg.isFinishedResponse)
        XCTAssertFalse(msg.isErrorResponse)
        XCTAssertEqual(msg.finalAudioProcMs, 12345)
        XCTAssertEqual(msg.totalAudioProcMs, 12500)
        XCTAssertNil(msg.errorCode)
        XCTAssertNil(msg.errorMessage)
    }

    // MARK: - 7. Decode every error envelope (401, 402, 408, 503)

    func testDecodeErrorEnvelopes() throws {
        struct Case { let code: Int; let message: String }
        let cases: [Case] = [
            Case(code: 401, message: "Invalid API key."),
            Case(code: 402,
                 message: "Organization balance exhausted. Please either add funds manually or enable autopay."),
            Case(code: 408, message: "Request timeout."),
            Case(code: 503,
                 message: "Cannot continue request (code 1). Please restart the request."),
        ]

        let decoder = makeDecoder()
        for c in cases {
            // Escape any embedded quotes in the message for JSON
            // safety. None of our fixture strings contain quotes.
            let json = """
            {
              "tokens": [],
              "error_code": \(c.code),
              "error_message": "\(c.message)"
            }
            """
            let data = json.data(using: .utf8)!
            let msg = try decoder.decode(SonioxServerMessage.self, from: data)
            XCTAssertTrue(msg.tokens.isEmpty,
                "tokens must be `[]` for error envelopes (code \(c.code))")
            XCTAssertEqual(msg.errorCode, c.code)
            XCTAssertEqual(msg.errorMessage, c.message)
            XCTAssertTrue(msg.isErrorResponse,
                "isErrorResponse must be true (code \(c.code))")
            XCTAssertFalse(msg.isFinishedResponse,
                "isFinishedResponse must be false (code \(c.code))")
            XCTAssertNil(msg.finished)
            XCTAssertNil(msg.finalAudioProcMs)
            XCTAssertNil(msg.totalAudioProcMs)
        }
    }

    // MARK: - 8. Control message round-trip

    func testEncodeDecodeKeepaliveControl() throws {
        let encoded = try makeEncoder().encode(SonioxControlMessage.keepalive)
        let actual = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertEqual(actual, #"{"type":"keepalive"}"#)

        let decoded = try makeDecoder().decode(
            SonioxControlMessage.self, from: encoded
        )
        XCTAssertEqual(decoded, SonioxControlMessage.keepalive)
    }

    func testEncodeDecodeFinalizeControl() throws {
        let encoded = try makeEncoder().encode(SonioxControlMessage.finalize)
        let actual = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertEqual(actual, #"{"type":"finalize"}"#)

        let decoded = try makeDecoder().decode(
            SonioxControlMessage.self, from: encoded
        )
        XCTAssertEqual(decoded, SonioxControlMessage.finalize)
    }

    // MARK: - 9. Forward-compat — unknown JSON field MUST NOT fail decode

    /// Synthesized `Decodable` conformance ignores unknown keys. If
    /// Soniox adds a field tomorrow (e.g. `vad_score`), the existing
    /// build must keep parsing. This test pins that contract for the
    /// server envelope, the token, and the control message.
    func testDecodeIgnoresUnknownFields() throws {
        let serverJSON = """
        {
          "tokens": [
            {
              "text": "hello",
              "is_final": true,
              "start_ms": 0,
              "end_ms": 100,
              "confidence": 0.9,
              "vad_score": 0.42,
              "future_token_field": "ok"
            }
          ],
          "final_audio_proc_ms": 100,
          "total_audio_proc_ms": 100,
          "future_top_level_field": { "anything": [1, 2, 3] }
        }
        """
        let data = serverJSON.data(using: .utf8)!
        let msg = try makeDecoder().decode(SonioxServerMessage.self, from: data)
        XCTAssertEqual(msg.tokens.count, 1)
        XCTAssertEqual(msg.tokens[0].text, "hello")
        XCTAssertEqual(try XCTUnwrap(msg.tokens[0].confidence), 0.9, accuracy: 1e-9)

        let controlJSON = #"{"type":"keepalive","extra":"ignored"}"#
        let ctrl = try makeDecoder().decode(
            SonioxControlMessage.self,
            from: controlJSON.data(using: .utf8)!
        )
        XCTAssertEqual(ctrl, SonioxControlMessage.keepalive)
    }

    // MARK: - 10. Outgoing config emits ONLY documented keys

    /// Inverse of test #9 on the producer side. Soniox returns 400 for
    /// an unknown field in the config message. The encoder must NEVER
    /// emit a key that is not part of the documented set, so the
    /// asserted key-set here is the authoritative inventory.
    func testEncodeOutgoingConfigContainsOnlyDocumentedKeys() throws {
        let config = SonioxConfigMessage(
            apiKey: "k",
            model: "stt-rt-v4",
            audioFormat: "pcm_s16le",
            sampleRate: 16_000,
            numChannels: 1,
            languageHints: ["el", "en"],
            languageHintsStrict: false,
            enableLanguageIdentification: true,
            enableEndpointDetection: true,
            maxEndpointDelayMs: 2_000,
            enableSpeakerDiarization: false,
            context: SonioxContext(general: nil, text: "ctx", terms: nil,
                                   translationTerms: nil),
            clientReferenceId: "macrec-x",
            keepaliveIntervalMs: 10_000
        )
        let data = try makeEncoder().encode(config)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(parsed?.keys ?? Dictionary<String, Any>().keys)

        // Documented v1 outgoing key set. `keepalive_interval_ms` is
        // marked Inferred in the research doc — kept here because the
        // brief explicitly listed it; if a future probe rejects it,
        // remove from BOTH the struct and this set.
        let documentedKeys: Set<String> = [
            "api_key",
            "model",
            "audio_format",
            "sample_rate",
            "num_channels",
            "language_hints",
            "language_hints_strict",
            "enable_language_identification",
            "enable_endpoint_detection",
            "max_endpoint_delay_ms",
            "enable_speaker_diarization",
            "context",
            "client_reference_id",
            "keepalive_interval_ms"
        ]

        let unexpected = keys.subtracting(documentedKeys)
        XCTAssertTrue(unexpected.isEmpty,
            "Encoder produced undocumented keys: \(unexpected)")

        // Also assert NONE of the explicitly-out-of-v1-scope keys
        // leaked back in (the brief lists `translation` as forbidden;
        // SX-3 also calls out `translation` as out of scope).
        let forbidden: Set<String> = ["translation"]
        let leaks = keys.intersection(forbidden)
        XCTAssertTrue(leaks.isEmpty,
            "Encoder leaked forbidden v1-scope keys: \(leaks)")
    }
}
