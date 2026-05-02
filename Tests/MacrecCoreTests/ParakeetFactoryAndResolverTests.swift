import Testing
import Foundation
import Logging
@testable import MacrecCore

@Suite("Parakeet factory + resolver wiring (Phase B3)")
struct ParakeetFactoryAndResolverTests {

    @Test("factory returns ParakeetTranscriptionProvider for id 'parakeet'")
    func factoryBuildsParakeet() throws {
        let input = TranscriptionProviderFactoryInput(
            providerId: "parakeet",
            apiKey: nil,
            modelId: nil,
            logger: Logger(label: "t"),
            keyExpiresAt: nil
        )
        let p = try TranscriptionProviderFactory.build(input)
        #expect(p.id == "parakeet")
    }

    @Test("factory honours parakeetModel-specific override over shared modelId")
    func parakeetModelOverridesSharedModelId() throws {
        let input = TranscriptionProviderFactoryInput(
            providerId: "parakeet",
            apiKey: nil,
            modelId: "shared-default",
            logger: Logger(label: "t"),
            keyExpiresAt: nil,
            parakeetModel: "parakeet-specific"
        )
        let p = try TranscriptionProviderFactory.build(input)
        // displayName surfaces the resolved model name
        #expect(p.displayName.contains("parakeet-specific"))
    }

    @Test("factory falls back to provider default when both overrides are nil")
    func providerDefaultWhenNoOverride() throws {
        let input = TranscriptionProviderFactoryInput(
            providerId: "parakeet",
            apiKey: nil,
            modelId: nil,
            logger: Logger(label: "t"),
            keyExpiresAt: nil
        )
        let p = try TranscriptionProviderFactory.build(input)
        #expect(p.displayName.contains(ParakeetTranscriptionProvider.defaultModelName))
    }
}
