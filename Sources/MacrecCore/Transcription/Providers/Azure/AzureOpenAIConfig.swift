// Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAIConfig.swift —
// plan-007 Phase A1 §A.2.
//
// Resolved configuration for the Azure OpenAI batch (REST) provider.
// Captured at provider construction so per-call `TranscriptionOptions`
// stays stable. The struct validates URL shape and required-field
// non-emptiness; missing required values throw
// `MacrecError.transcriptionConfigConflict` (factory level — this
// init is `init(...) throws`).

import Foundation

public struct AzureOpenAIConfig: Sendable, Equatable {

    /// Resource endpoint, e.g.
    /// `https://my-resource.openai.azure.com` (no trailing slash).
    public let endpoint: URL

    /// User-chosen deployment name backing
    /// `gpt-4o-mini-transcribe` (NOT the model name).
    public let deployment: String

    /// API version. Plan-007 Phase A2 standardises on
    /// `2025-04-01-preview` (covers both batch and realtime); the
    /// provider applies that constant when the resolver forwards `nil`.
    public let apiVersion: String

    /// Resolved API key (`AZURE_OPENAI_API_KEY`). Non-empty.
    public let apiKey: String

    /// Optional ISO-8601 expiry; surfaces a warning ~7 days before
    /// expiry through the standard `transcriptionKeyExpired` warning
    /// path (consumed by `TranscriptionManager`).
    public let apiKeyExpiresAt: Date?

    /// Plan-007 §A.2 — recommended starter for the api-version when
    /// the user does not pin one (Open Decision Az-1, raised to
    /// `2025-04-01-preview` in Phase A2 §A.4.update so the same
    /// constant covers both batch and realtime).
    public static let defaultApiVersion = "2025-04-01-preview"

    public init(
        endpoint: URL,
        deployment: String,
        apiVersion: String,
        apiKey: String,
        apiKeyExpiresAt: Date? = nil
    ) throws {
        // 1. Endpoint scheme + host shape — warn-don't-throw on host
        //    mismatch per §A.2 (some users may use a custom domain).
        guard endpoint.scheme?.lowercased() == "https" else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "Azure provider requires AZURE_OPENAI_ENDPOINT to be https:// (got: \(endpoint.absoluteString))"
            )
        }
        // 2. Deployment non-empty.
        let trimmedDeployment = deployment.trimmingCharacters(in: .whitespaces)
        guard !trimmedDeployment.isEmpty else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "Azure provider requires AZURE_OPENAI_DEPLOYMENT (got empty value)"
            )
        }
        // 3. API version shape — warn-don't-throw on mismatch.
        let trimmedVersion = apiVersion.trimmingCharacters(in: .whitespaces)
        guard !trimmedVersion.isEmpty else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "Azure provider requires AZURE_OPENAI_API_VERSION (got empty); recommended starter '\(Self.defaultApiVersion)'"
            )
        }
        // 4. API key non-empty (caller already enforced; defensive).
        guard !apiKey.isEmpty else {
            throw MacrecError.transcriptionApiKeyMissing(provider: "azure")
        }

        self.endpoint = endpoint
        self.deployment = trimmedDeployment
        self.apiVersion = trimmedVersion
        self.apiKey = apiKey
        self.apiKeyExpiresAt = apiKeyExpiresAt
    }
}
