// Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeConfig.swift —
// plan-007 Phase A2 §A2.4.

import Foundation

public struct AzureOpenAIRealtimeConfig: Sendable, Equatable {

    public let endpoint: URL          // https://{resource}.openai.azure.com
    public let deployment: String     // user-chosen deployment
    public let apiVersion: String     // e.g. "2025-04-01-preview"
    public let apiKey: String
    public let apiKeyExpiresAt: Date?

    // -- VAD knobs (research §7.1, defaults from §A2.4) --
    public let vadThreshold: Float            // 0.0..1.0 (default 0.5)
    public let vadPrefixPaddingMS: Int        // ≥ 0 (default 300)
    public let vadSilenceMS: Int              // ≥ 0 (default 200)
    public let noiseReduction: String         // "near_field" | "far_field" | "none"
    public let includeLogprobs: Bool          // default false
    public let deploymentInUrl: Bool          // default true — Azure realtime
                                              // transcription rejects the
                                              // deployment-less URL on most
                                              // tenants (close=1000 with
                                              // "Socket is not connected"
                                              // before any frame is exchanged).
                                              // Reverted from OQ-A2-2's
                                              // speculative `false` after
                                              // 2026-05-01 field repro.

    public static let defaultVADThreshold: Float = 0.5
    public static let defaultVADPrefixPaddingMS: Int = 300
    public static let defaultVADSilenceMS: Int = 200
    public static let defaultNoiseReduction: String = "near_field"

    public init(
        endpoint: URL,
        deployment: String,
        apiVersion: String,
        apiKey: String,
        apiKeyExpiresAt: Date? = nil,
        vadThreshold: Float? = nil,
        vadPrefixPaddingMS: Int? = nil,
        vadSilenceMS: Int? = nil,
        noiseReduction: String? = nil,
        includeLogprobs: Bool? = nil,
        deploymentInUrl: Bool? = nil
    ) throws {
        // Validate the same way the batch config does.
        guard endpoint.scheme?.lowercased() == "https" else {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "Azure realtime requires AZURE_OPENAI_ENDPOINT to be https:// (got: \(endpoint.absoluteString))"
            )
        }
        let trimmedDeployment = deployment.trimmingCharacters(in: .whitespaces)
        guard !trimmedDeployment.isEmpty else {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "Azure realtime requires AZURE_OPENAI_DEPLOYMENT (got empty)"
            )
        }
        let trimmedVersion = apiVersion.trimmingCharacters(in: .whitespaces)
        guard !trimmedVersion.isEmpty else {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "Azure realtime requires AZURE_OPENAI_API_VERSION; recommended starter '\(AzureOpenAIConfig.defaultApiVersion)'"
            )
        }
        guard !apiKey.isEmpty else {
            throw NtakkerError.transcriptionApiKeyMissing(provider: "azure-openai-realtime")
        }

        // VAD field validation (range guards mirror ConfigResolver but
        // double-check at the construction boundary so direct callers
        // still get a clear failure).
        if let t = vadThreshold, !(0.0...1.0).contains(t) {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "AZURE_OPENAI_REALTIME_VAD_THRESHOLD must be in 0.0..1.0 (got \(t))"
            )
        }
        if let p = vadPrefixPaddingMS, p < 0 {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS must be >= 0 (got \(p))"
            )
        }
        if let s = vadSilenceMS, s < 0 {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "AZURE_OPENAI_REALTIME_VAD_SILENCE_MS must be >= 0 (got \(s))"
            )
        }
        if let nr = noiseReduction {
            let lower = nr.lowercased()
            guard ["near_field", "far_field", "none"].contains(lower) else {
                throw NtakkerError.transcriptionConfigConflict(
                    reason: "AZURE_OPENAI_REALTIME_NOISE_REDUCTION must be one of: near_field, far_field, none (got '\(nr)')"
                )
            }
        }

        self.endpoint = endpoint
        self.deployment = trimmedDeployment
        self.apiVersion = trimmedVersion
        self.apiKey = apiKey
        self.apiKeyExpiresAt = apiKeyExpiresAt
        self.vadThreshold = vadThreshold ?? Self.defaultVADThreshold
        self.vadPrefixPaddingMS = vadPrefixPaddingMS ?? Self.defaultVADPrefixPaddingMS
        self.vadSilenceMS = vadSilenceMS ?? Self.defaultVADSilenceMS
        self.noiseReduction = (noiseReduction?.lowercased() ?? Self.defaultNoiseReduction)
        self.includeLogprobs = includeLogprobs ?? false
        self.deploymentInUrl = deploymentInUrl ?? true
    }

    /// Compose the WebSocket URL from the config. Always wss://, with
    /// `intent=transcription` and the resolved api-version. Optionally
    /// appends `&deployment={name}` when `deploymentInUrl == true`.
    public func websocketURL() -> URL? {
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.scheme = "wss"
        components.path = "/openai/realtime"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api-version", value: apiVersion),
            URLQueryItem(name: "intent", value: "transcription"),
        ]
        if deploymentInUrl {
            items.append(URLQueryItem(name: "deployment", value: deployment))
        }
        components.queryItems = items
        return components.url
    }
}
