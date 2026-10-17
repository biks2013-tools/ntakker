import Foundation
import Testing
@testable import NtakkerCore

/// `parakeet` and `apple-cloud` were built by the provider factory but
/// rejected by the CLI resolver ("invalid value for NTAKKER_TRANSCRIBE"),
/// because `TranscriptionProviderId` lacked both cases. Found 2026-10-17
/// during plan-022 T5.
@Suite("ConfigResolver — on-device and Apple Cloud provider ids")
struct ConfigResolverProviderIdTests {

    private func resolve(_ provider: String) throws -> RecordingOptions {
        try ConfigResolver(
            toolName: "ntakker-cli",
            shellEnv: [
                "OUTPUT_PATH": "/tmp/ntakker-cli-resolver-provider-id.m4a",
                "NTAKKER_TRANSCRIBE": provider,
            ],
            userEnv: [:],
            localEnv: [:]
        ).resolve(cliOverrides: [:])
    }

    @Test("NTAKKER_TRANSCRIBE=parakeet resolves without an API key")
    func parakeet() throws {
        let opts = try resolve("parakeet")
        #expect(opts.transcriptionProviderId == "parakeet")
        #expect(opts.transcriptionApiKey == nil)
    }

    @Test("NTAKKER_TRANSCRIBE=apple-cloud resolves without an API key")
    func appleCloud() throws {
        let opts = try resolve("apple-cloud")
        #expect(opts.transcriptionProviderId == "apple-cloud")
        #expect(opts.transcriptionApiKey == nil)
    }

    @Test("every resolver id is one the factory accepts")
    func resolverIdsMatchFactory() {
        let ids = Set(TranscriptionProviderId.allCases.map(\.rawValue))
        #expect(ids.isSuperset(of: ["apple", "apple-cloud", "gemini", "whisperkit", "parakeet", "soniox", "azure", "azure-openai-realtime", "elevenlabs"]))
    }
}
