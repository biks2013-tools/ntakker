// MacrecCore/Transcription/TranscriptionOptions.swift — see project-design.md §LT-3.2
//
// Phase A (plan-003) — runtime options the `TranscriptionDriver` passes
// into `provider.run(audio:options:)`. The fields are deliberately the
// minimum any provider needs to configure a session; provider-specific
// extensions (Gemini system instruction, OpenAI Realtime modality flags)
// fit on top via `customSystemInstruction` (passthrough hint) and
// `modelId` (vendor-specific model selection).
//
// Project rule: NO defaults / fallback values for required configuration.
// All fields are explicit at the call site. The only non-required field is
// `apiKey`, which is `nil` for providers that need none (NoOp, Fake) and
// non-nil for provider implementations that authenticate (Gemini, etc.).

import Foundation

/// The resolved per-session configuration handed to a
/// `TranscriptionProvider`. Built by Phase C's configuration plumbing
/// from CLI flags / `.env` / `UserDefaults`; for Phase A test fixtures
/// it is constructed directly.
public struct TranscriptionOptions: Sendable, Equatable {

    /// Wire-protocol id of the provider that will be run with these
    /// options (e.g. `"noop"`, `"fake"`, `"gemini-live"`). Kept as a
    /// `String` for the same reason the protocol uses one — see D-LT-5.
    /// Phase C / Phase F resolve a typed `TranscriptionProviderId` enum
    /// from CLI input and lower it to this `String`.
    public let providerId: String

    /// Resolved API key (already looked up through the four-tier env
    /// chain). `nil` for providers whose `requiredApiKey == nil`. The
    /// resolver fails fast (with `MacrecError.transcriptionApiKeyMissing`)
    /// before this struct is constructed, so a non-nil-required provider
    /// will never see `apiKey == nil` here.
    public let apiKey: String?

    /// Vendor-specific model identifier override. `nil` means "use the
    /// provider's pinned default model" (e.g. Gemini 3.1 Flash Live).
    public let modelId: String?

    /// BCP-47 language hints passed to the provider when supported (e.g.
    /// `["en"]`, `["el-GR", "en-US"]`). Empty lets the provider auto-detect.
    /// Plan-005 widens this from a single string to an ordered list so dual-locale
    /// streaming providers (Apple Speech) can be configured with two active locales
    /// (`["en-US", "el-GR"]`); batch providers (Gemini REST) consume only the first.
    public let languageHints: [String]

    /// Provider-specific system / context instruction passed verbatim
    /// (e.g. Gemini Live's `setup.systemInstruction`). `nil` means no
    /// custom prompt; the provider may still apply its own internal
    /// defaults, but no fallback is computed in this struct.
    public let customSystemInstruction: String?

    /// Optional ISO-8601 expiration timestamp captured for the API key
    /// (per CLAUDE.md's "expiring config parameter" guidance). The
    /// resolver may surface a "key expires in N days" warning at
    /// startup based on this value. `nil` means no expiry is known.
    public let keyExpiresAt: Date?

    public init(
        providerId: String,
        apiKey: String?,
        modelId: String?,
        languageHints: [String] = [],
        customSystemInstruction: String?,
        keyExpiresAt: Date?
    ) {
        self.providerId = providerId
        self.apiKey = apiKey
        self.modelId = modelId
        self.languageHints = languageHints
        self.customSystemInstruction = customSystemInstruction
        self.keyExpiresAt = keyExpiresAt
    }
}
