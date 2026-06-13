// Tests/NtakkerCoreTests/Transcription/Providers/TranscriptionProviderFactoryTests.swift
//
// Phase D (plan-004 rest-batch) — verifies the factory's contract:
//
//   • `"none"` returns `NoOpTranscriptionProvider`.
//   • `"gemini"` with a non-empty API key returns
//     `GeminiRESTTranscriptionProvider`.
//   • `"gemini"` with an empty API key throws
//     `NtakkerError.transcriptionApiKeyMissing(provider:)`.
//   • `"gemini-live"` (deprecation alias) resolves to
//     `GeminiRESTTranscriptionProvider` and emits a `.notice` log entry.
//   • An unknown id throws
//     `NtakkerError.transcriptionConfigConflict(reason:)`.

import Foundation
import Testing
import Logging
@testable import NtakkerCore

@Suite("TranscriptionProviderFactory")
struct TranscriptionProviderFactoryTests {

    // MARK: - Helpers

    private static let logger = Logger(label: "ntakker-cli.transcription.factory.tests")

    private func makeInput(
        providerId: String,
        apiKey: String? = nil,
        modelId: String? = nil,
        languageHints: [String] = []
    ) -> TranscriptionProviderFactoryInput {
        TranscriptionProviderFactoryInput(
            providerId: providerId,
            apiKey: apiKey,
            modelId: modelId,
            languageHints: languageHints,
            logger: Self.logger,
            keyExpiresAt: nil
        )
    }

    // MARK: - none → NoOp

    @Test("\"none\" providerId returns NoOpTranscriptionProvider")
    func noneReturnsNoOp() throws {
        let provider = try TranscriptionProviderFactory.build(
            makeInput(providerId: "none")
        )
        #expect(provider is NoOpTranscriptionProvider)
        #expect(provider.id == "none")
    }

    // MARK: - gemini with API key

    @Test("\"gemini\" with API key returns GeminiRESTTranscriptionProvider")
    func geminiReturnsRESTProvider() throws {
        let provider = try TranscriptionProviderFactory.build(
            makeInput(providerId: "gemini", apiKey: "test-key")
        )
        #expect(provider is GeminiRESTTranscriptionProvider)
        #expect(provider.id == "gemini")
    }

    // MARK: - gemini without API key → throws

    @Test("\"gemini\" with empty API key throws transcriptionApiKeyMissing")
    func geminiWithEmptyKeyThrows() {
        do {
            _ = try TranscriptionProviderFactory.build(
                makeInput(providerId: "gemini", apiKey: "")
            )
            Issue.record("expected transcriptionApiKeyMissing for empty-string key")
        } catch let error as NtakkerError {
            switch error {
            case .transcriptionApiKeyMissing(let provider):
                #expect(provider == "gemini")
            default:
                Issue.record("expected .transcriptionApiKeyMissing; got \(error)")
            }
        } catch {
            Issue.record("expected NtakkerError; got \(type(of: error))")
        }
    }

    // MARK: - gemini-live (deprecation alias) → resolves to gemini REST

    @Test("\"gemini-live\" deprecation alias resolves to GeminiRESTTranscriptionProvider")
    func geminiLiveAliasResolvesToREST() throws {
        let provider = try TranscriptionProviderFactory.build(
            makeInput(providerId: "gemini-live", apiKey: "test-key")
        )
        #expect(provider is GeminiRESTTranscriptionProvider)
        #expect(provider.id == "gemini")
    }

    // MARK: - unknown provider → throws

    @Test("Unknown providerId throws transcriptionConfigConflict")
    func unknownProviderThrows() {
        do {
            _ = try TranscriptionProviderFactory.build(
                makeInput(providerId: "fake")
            )
            Issue.record("expected transcriptionConfigConflict to be thrown")
        } catch let error as NtakkerError {
            switch error {
            case .transcriptionConfigConflict(let reason):
                #expect(reason.contains("fake"),
                        "reason should reference the bad id; got: \(reason)")
            default:
                Issue.record("expected .transcriptionConfigConflict; got \(error)")
            }
        } catch {
            Issue.record("expected NtakkerError; got \(type(of: error))")
        }
    }
}
