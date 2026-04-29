// Tests/MacrecCoreTests/Transcription/Soniox/SonioxStreamingTranscriptionProviderTests.swift
//
// Plan-006 Phase D / Unit D2: black-box tests for the public
// `SonioxStreamingTranscriptionProvider` adapter.

import XCTest
@testable import MacrecCore

final class SonioxStreamingTranscriptionProviderTests: XCTestCase {

    // MARK: - Test 1: identity / supportedModes

    func testProviderIdentityAndSupportedModes() {
        let provider = SonioxStreamingTranscriptionProvider(apiKey: "test-key")

        XCTAssertEqual(provider.id, "soniox")
        XCTAssertEqual(provider.displayName, "Soniox (cloud, multilingual)")
        XCTAssertEqual(provider.supportedModes, [.streaming])
    }

    // MARK: - Test 2: transcribe(...) is unsupported

    func testTranscribeThrowsBecauseStreamingOnly() async {
        let provider = SonioxStreamingTranscriptionProvider(apiKey: "test-key")
        let options = TranscriptionOptions(
            providerId: "soniox",
            apiKey: "test-key",
            modelId: nil,
            languageHints: [],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
        do {
            _ = try await provider.transcribe(
                samples: [0.0, 0.1, 0.2],
                source: .system,
                options: options
            )
            XCTFail("transcribe(...) should throw on a streaming-only provider")
        } catch let error as MacrecError {
            // Soniox surfaces this as a config-conflict so the failure
            // mode is symmetric with Apple Speech's same-shape error.
            switch error {
            case .transcriptionConfigConflict:
                break
            default:
                XCTFail("expected .transcriptionConfigConflict — got \(error)")
            }
        } catch {
            XCTFail("expected MacrecError — got \(error)")
        }
    }

    // MARK: - Test 3: openStreamingSession(...) wires config + hints correctly

    func testOpenStreamingSessionSendsConfigWithApiKeyAndMappedHints() async throws {
        let mock = MockWebSocketTransport()

        let provider = SonioxStreamingTranscriptionProvider(
            apiKey: "abc-123",
            transportFactory: { mock }
        )
        // BCP-47 hints should be lowered to ISO 639-1 in the outgoing
        // config (`el-GR` → `el`, `en-US` → `en`).
        let options = TranscriptionOptions(
            providerId: "soniox",
            apiKey: "abc-123",
            modelId: nil,
            languageHints: ["el-GR", "en-US"],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )

        let session = try await provider.openStreamingSession(
            source: .microphone,
            options: options
        )
        // The session is live; tear it down so the receive task cleans up.
        await session.finish()

        let sentText = await mock.sentTextFrames
        XCTAssertGreaterThanOrEqual(sentText.count, 1, "config text frame must have been sent")

        let configJSON = sentText[0]
        // Spot-check the wire-level fields. We don't full-parse here
        // because the wire schema is locked-in by SonioxWireSchemaTests
        // — these checks just confirm the provider plumbed the values
        // through.
        XCTAssertTrue(configJSON.contains("\"api_key\":\"abc-123\""),
                      "config must carry the provider's apiKey — got \(configJSON)")
        XCTAssertTrue(configJSON.contains("\"language_hints\":[\"el\",\"en\"]"),
                      "BCP-47 hints must lower to ISO 639-1 in the wire config — got \(configJSON)")
        XCTAssertTrue(configJSON.contains("\"client_reference_id\":\"macrec-microphone\""),
                      "clientReferenceId must include the source tag — got \(configJSON)")
        XCTAssertTrue(configJSON.contains("\"model\":\"stt-rt-v4\""),
                      "default model id must be stt-rt-v4 — got \(configJSON)")

        // And the connect URL was the default endpoint.
        let connectURL = await mock.lastConnectURL
        XCTAssertEqual(connectURL, SonioxStreamingTranscriptionProvider.defaultEndpoint)
    }
}
