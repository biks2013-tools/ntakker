// MacrecCore/Config/RecordingOptions.swift — see project-design.md §3.1 / §2.4
// Phase B — Bootstrap + Config (FR-12, FR-13, FR-14, FR-15, FR-25, FR-27, FR-29)

import Foundation

// MARK: - Public enum aliases

/// Output container format (FR-1, FR-2, FR-3).
public enum OutputFormat: String, CaseIterable, Sendable {
    case m4a
    case wav
    case caf
}

/// Track layout of the recording (FR-4, FR-5, FR-6).
public enum TrackLayout: String, CaseIterable, Sendable {
    case mixed
    case split
    case stereoSplit = "stereo-split"
}

/// Microphone channel pinning when `layout == .stereoSplit` (FR-6).
public enum StereoChannel: String, CaseIterable, Sendable {
    case left
    case right
}

/// Microphone channel name accepted by the CLI / config layer.
/// This is an alias retained for backward-compatibility with documentation
/// that uses the spelling `MicChannel` (the design calls it
/// `StereoChannel`).
public typealias MicChannel = StereoChannel

/// Logger verbosity (FR-11).
public enum LogLevel: String, CaseIterable, Sendable {
    case quiet
    case info
    case debug
}

/// Run mode (FR-25).
///
/// `.foreground` — runs in the invoking shell; logs to stderr; no PID file.
/// `.detached`   — double-forks; logs to log file; writes PID file.
public enum RunMode: String, CaseIterable, Sendable {
    case foreground
    case detached
}

// MARK: - Live transcription configuration enums (plan-003 Phase C)
//
// These enums describe the live-transcription configuration surface
// (project-design.md §LT-3, §LT-5). The `RecordingOptions` storage uses a
// `String?` for `transcriptionProviderId` (per D-LT-5) so dynamic / future
// providers can flow through without re-deploying; this enum is the canonical
// set of resolver / parser values at v1.

/// Live-transcription provider identifier resolved from the
/// `MACREC_TRANSCRIBE` env-var or `--transcribe` CLI flag.
///
/// `.none` means transcription is disabled (the no-op short-circuit; AC-LT-16).
/// `.apple` selects Apple's on-device `SpeechAnalyzer` streaming provider
/// (plan-005). It is the **default** as of plan-005 Phase G — the user no
/// longer needs to configure anything to get live transcription.
/// `.gemini` selects the Gemini REST batch provider (plan-004 Phase D).
/// `.geminiLive` is the deprecated alias for `.gemini` retained for one
/// release for back-compat with the plan-003 Gemini Live wire id; the
/// resolver lowers it to `"gemini"` and logs a deprecation notice.
/// `.soniox` selects the Soniox cloud-streaming provider (plan-006 Phase B —
/// SX-9.1). The resolver keeps the wire form as `"soniox"`.
/// `.whisperkit` selects the on-device WhisperKit / argmax-oss-swift provider
/// (originally added in plan-005 Phase H but the enum case landed late;
/// plan-007 Task 0.1 closes the drift so `MACREC_TRANSCRIBE=whisperkit`
/// resolves cleanly through `parseEnum(...)` instead of throwing
/// `invalidConfigValue`).
/// `.azure` selects the Azure OpenAI `gpt-4o-mini-transcribe` REST batch
/// provider (plan-007 Phase A1). `.azureOpenAIRealtime` selects the
/// matching `intent=transcription` realtime WebSocket provider
/// (plan-007 Phase A2). `.elevenlabs` selects the ElevenLabs
/// `scribe_v2` REST batch provider (plan-007 Phase B).
///
/// Design §LT-3.1 / D-LT-5. `RecordingOptions.transcriptionProviderId` stores
/// the lowered `String` form (per D-LT-5) so future external providers don't
/// require an enum-update redeploy; this enum is the canonical set parsed
/// by the resolver.
public enum TranscriptionProviderId: String, CaseIterable, Sendable, Codable, Equatable {
    case none
    case apple = "apple"
    case gemini
    case geminiLive = "gemini-live"
    /// Plan-005 Phase H + plan-007 Task 0.1 — on-device WhisperKit provider.
    case whisperkit
    /// Plan-006 SX-9.1 — Soniox cloud streaming (WebSocket).
    case soniox
    /// Plan-007 Phase A1 — Azure OpenAI `gpt-4o-mini-transcribe` REST batch.
    case azure
    /// Plan-007 Phase A2 — Azure OpenAI realtime transcription WebSocket
    /// (`intent=transcription`).
    case azureOpenAIRealtime = "azure-openai-realtime"
    /// Plan-007 Phase B — ElevenLabs `scribe_v2` REST batch.
    case elevenlabs
}

// `TranscriptionSource` is defined in
// `Sources/MacrecCore/Transcription/TranscriptionSource.swift` (Phase B).
// `RecordingOptions` consumes that single source-of-truth enum.

/// Sidecar transcript format. `jsonl` is the canonical lossless format (one
/// JSON event per line; Phase D writer). `txt`/`srt`/`vtt` are convenience
/// outputs.
public enum TranscriptFormat: String, CaseIterable, Sendable, Codable, Equatable {
    case jsonl
    case srt
    case vtt
    case txt
}

// MARK: - RecordingOptions

/// The fully resolved, validated configuration consumed by
/// `RecordingSession`. Built by `ConfigResolver.buildRecordingOptions()`
/// after merging the four configuration sources (FR-12).
public struct RecordingOptions: Sendable, Equatable {

    /// Output file path. Required (FR-12 / OQ-10) — there is no default.
    public let output: URL

    /// Output container format. Default `.m4a` (FR-1).
    public let format: OutputFormat

    /// Track layout. Default `.mixed` (FR-4).
    public let layout: TrackLayout

    /// Mic-channel pin used only when `layout == .stereoSplit`. Default
    /// `.left` (FR-6).
    public let micChannel: StereoChannel

    /// Sample rate in Hz. One of {44100, 48000}. Default `48000`.
    public let sampleRate: Int

    /// PCM bit depth. One of {16, 24}. Ignored for AAC. Default `16`.
    public let bitDepth: Int

    /// AAC bitrate in bits-per-second. In the range [64_000, 320_000].
    /// Default `192_000`.
    public let bitrate: Int

    /// Microphone device UID/name. `nil` selects the system default input
    /// (FR-7).
    public let micDevice: String?

    /// Logger verbosity. Default `.info`.
    public let logLevel: LogLevel

    /// Maximum recording duration in seconds. `nil` runs until SIGINT
    /// (FR-10).
    public let maxDuration: TimeInterval?

    /// If `true`, replace `output` if it already exists (FR-15).
    public let overwrite: Bool

    /// Run mode (FR-25). Default `.foreground`.
    public let runMode: RunMode

    /// PID file path (FR-26 / FR-27). Default
    /// `~/.tool-agents/macrec/macrec.pid`.
    public let pidFile: URL

    /// Log file path used in detach mode (FR-29). Default
    /// `~/.tool-agents/macrec/macrec.log`.
    public let logFile: URL

    /// Stop-subcommand timeout in seconds (FR-26). Default `35`.
    public let stopTimeout: TimeInterval

    // MARK: - Live transcription (plan-003 Phase C; design §LT-5.4)

    /// Live-transcription provider identifier (e.g. `"gemini-live"`). `nil`
    /// means transcription is disabled — the no-op short-circuit per AC-LT-16.
    /// Stored as `String?` (not `TranscriptionProviderId`) per D-LT-5: the
    /// typed enum is used at parse time; the wire form is a string so future
    /// provider plug-ins don't require an enum-update redeploy.
    public let transcriptionProviderId: String?

    /// Audio source fed into the transcription provider. Default `.mixed`.
    /// Independent of `layout` (design §LT-5.2).
    public let transcriptionSource: TranscriptionSource

    /// Sidecar transcript format. Default `.jsonl`.
    public let transcriptionFormat: TranscriptFormat

    /// API key resolved through the four-tier env-var chain (e.g.
    /// `GOOGLE_API_KEY` for the Gemini providers). `nil` when no provider
    /// is selected or when the resolver hasn't found a key yet — by
    /// project rule (NO fallback) the missing-key state is checked at
    /// provider-build time and raises
    /// `MacrecError.transcriptionApiKeyMissing`.
    ///
    /// Exception note (CLAUDE.md "no fallback for missing config"): the
    /// resolver intentionally tolerates a missing key at config-load
    /// time because the entire transcription pipeline short-circuits to
    /// no-op when `transcriptionProviderId == nil`. The hard validation
    /// (raise `MacrecError.transcriptionApiKeyMissing`) happens at the
    /// plan-004 Phase G `TranscriptionProviderFactory.build` boundary,
    /// invoked from `RecordingSession.setUpTranscriptionPipelineIfNeeded`.
    public let transcriptionApiKey: String?

    /// Optional ISO-8601 expiry date for the transcription API key. Drives
    /// the "key expires in N days" warning at start (CLAUDE.md
    /// configuration-guide rule for expiring credentials).
    public let transcriptionKeyExpiresAt: Date?

    /// Provider-specific model id override (e.g.
    /// `"gemini-3.1-flash-live-preview"`). `nil` means "use the provider's
    /// pinned default model" (D-LT-? / R-Phase C.3 — the model id default
    /// is owned in code by the provider, NOT looked up through `value(_:)`).
    public let transcriptionModelId: String?

    /// Optional list of BCP-47 language tags passed to the provider (e.g.
    /// `["en-US"]`, `["en-US", "el-GR"]`). Empty list lets the provider
    /// auto-detect (Gemini REST), or — for the Apple Speech provider —
    /// fall back to `Locale.current`.
    ///
    /// Plan-005 Phase G widens the field from `String?` to `[String]` so the
    /// dual-locale Apple Speech path can pass two locales without overloading
    /// a single string. The resolver parses the comma-separated wire form
    /// `MACREC_TRANSCRIBE_LANGUAGE=en-US,el-GR`.
    public let transcriptionLanguageHints: [String]

    // MARK: - Soniox-specific overrides (plan-006 Phase B; design SX-5)

    /// Optional Soniox WebSocket endpoint override (plan-006 SX-5.1). `nil`
    /// means the provider should fall back to its hard-coded vendor default
    /// (`wss://stt-rt.soniox.com/transcribe-websocket`). Regional variants
    /// the user may set: `wss://stt-rt.eu.soniox.com/transcribe-websocket`,
    /// `wss://stt-rt.jp.soniox.com/transcribe-websocket`. Resolved from
    /// `MACREC_SONIOX_ENDPOINT` through the standard 4-tier chain.
    ///
    /// Storing the default at the **provider** layer (not here) keeps this
    /// `RecordingOptions` value pure-data — the project's "no fallback for
    /// missing config" rule (CLAUDE.md) treats vendor endpoints as a
    /// stable code constant rather than a config default. Sanctioned by
    /// design SX-5.3.
    public let sonioxEndpoint: URL?

    /// Optional ISO-8601 expiry date for the Soniox API key (plan-006
    /// SX-5.1 / SX-5.4). Provider-scoped; takes precedence over the
    /// shared `transcriptionKeyExpiresAt` per D-SX-3 / OQ-SX-12. The
    /// resolver applies the precedence and stores the winning value here
    /// (so consumers see a single field). When both are unset this is
    /// `nil` — no expiry warning is emitted at recording start (AC-SX-16).
    public let sonioxKeyExpiresAt: Date?

    // MARK: - Azure OpenAI overrides (plan-007 Phase A1 + A2; §5.1 / §A2.4)
    //
    // Per the no-fallback rule the resolver throws when these values are
    // required but missing. The `apiVersion` field carries a documented
    // starter `2025-04-01-preview` (plan-007 §A2.4) — the resolver
    // forwards `nil` if the user did not set it, and the Azure providers
    // apply the documented constant.

    /// Azure OpenAI resource endpoint (e.g.
    /// `https://my-resource.openai.azure.com`). Required when
    /// `transcriptionProviderId == "azure" || == "azure-openai-realtime"`.
    public let azureOpenAIEndpoint: URL?

    /// Azure OpenAI deployment name (NOT the model name). Required for
    /// both Azure surfaces.
    public let azureOpenAIDeployment: String?

    /// Azure OpenAI api-version. `nil` lets the providers apply the
    /// documented starter (`2025-04-01-preview`).
    public let azureOpenAIApiVersion: String?

    /// Optional ISO-8601 expiry for `AZURE_OPENAI_API_KEY`. Falls back
    /// to the shared `transcriptionKeyExpiresAt` when unset.
    public let azureOpenAIApiKeyExpiresAt: Date?

    /// Plan-007 §A2.4 — VAD detection threshold (0.0..1.0). `nil`
    /// makes the realtime provider apply 0.5.
    public let azureOpenAIRealtimeVADThreshold: Float?

    /// Plan-007 §A2.4 — VAD prefix-padding ms. `nil` → 300.
    public let azureOpenAIRealtimeVADPrefixPaddingMS: Int?

    /// Plan-007 §A2.4 — VAD silence ms. `nil` → 200.
    public let azureOpenAIRealtimeVADSilenceMS: Int?

    /// Plan-007 §A2.4 — `near_field` (default), `far_field`, or `none`.
    public let azureOpenAIRealtimeNoiseReduction: String?

    /// Plan-007 §A2.4 — when true, request logprobs on transcription
    /// events.
    public let azureOpenAIRealtimeIncludeLogprobs: Bool?

    /// Plan-007 §A2.4 — when true, append `&deployment={name}` to the
    /// realtime WebSocket URL (per OQ-A2-2).
    public let azureOpenAIRealtimeDeploymentInUrl: Bool?

    // MARK: - ElevenLabs overrides (plan-007 Phase B; §5.1)

    /// Plan-007 §B.7 — model id (`scribe_v2` default).
    public let elevenLabsModelId: String?

    /// Plan-007 §B.7 — optional ISO-639-1/-3 language code.
    public let elevenLabsLanguageCode: String?

    /// Plan-007 §B.7 — diarisation toggle (default false).
    public let elevenLabsDiarize: Bool?

    /// Plan-007 §B.7 — tag non-speech audio events (default true).
    public let elevenLabsTagAudioEvents: Bool?

    /// Plan-007 §B.7 — optional 1..32 speaker count hint.
    public let elevenLabsNumSpeakers: Int?

    /// Plan-007 §B.7 — file-format hint. Default `pcm_s16le_16` (low-
    /// latency fast-path; matches `AudioWAVEncoder` output per §13 EL-3).
    public let elevenLabsFileFormat: String?

    /// Plan-007 §B.7 — entity-detection mode (`pii` | `phi` | `pci` |
    /// `all`). Unset = off (default per §13 EL-2).
    public let elevenLabsEntityDetection: String?

    /// 2026-05-01 — `keyterms[]` form-field added by ElevenLabs on
    /// 2026-01-12. Comma-separated entries in `ELEVENLABS_KEYTERMS`
    /// are parsed and forwarded as repeated `keyterms` form-fields to
    /// bias the model toward target vocabulary (mitigates
    /// Italian/French phonetic confusion when transcribing bilingual
    /// Greek+English content). Empty / `nil` means no bias.
    public let elevenLabsKeyterms: [String]?

    /// Plan-007 §B.7 — optional ISO-8601 expiry for `ELEVENLABS_API_KEY`.
    public let elevenLabsApiKeyExpiresAt: Date?

    public init(
        output: URL,
        format: OutputFormat = .m4a,
        layout: TrackLayout = .mixed,
        micChannel: StereoChannel = .left,
        sampleRate: Int = 48_000,
        bitDepth: Int = 16,
        bitrate: Int = 192_000,
        micDevice: String? = nil,
        logLevel: LogLevel = .info,
        maxDuration: TimeInterval? = nil,
        overwrite: Bool = false,
        runMode: RunMode = .foreground,
        pidFile: URL = RecordingOptions.defaultPidFile,
        logFile: URL = RecordingOptions.defaultLogFile,
        stopTimeout: TimeInterval = RecordingOptions.defaultStopTimeout,
        transcriptionProviderId: String? = nil,
        transcriptionSource: TranscriptionSource = .mixed,
        transcriptionFormat: TranscriptFormat = .jsonl,
        transcriptionApiKey: String? = nil,
        transcriptionKeyExpiresAt: Date? = nil,
        transcriptionModelId: String? = nil,
        transcriptionLanguageHints: [String] = [],
        sonioxEndpoint: URL? = nil,
        sonioxKeyExpiresAt: Date? = nil,
        azureOpenAIEndpoint: URL? = nil,
        azureOpenAIDeployment: String? = nil,
        azureOpenAIApiVersion: String? = nil,
        azureOpenAIApiKeyExpiresAt: Date? = nil,
        azureOpenAIRealtimeVADThreshold: Float? = nil,
        azureOpenAIRealtimeVADPrefixPaddingMS: Int? = nil,
        azureOpenAIRealtimeVADSilenceMS: Int? = nil,
        azureOpenAIRealtimeNoiseReduction: String? = nil,
        azureOpenAIRealtimeIncludeLogprobs: Bool? = nil,
        azureOpenAIRealtimeDeploymentInUrl: Bool? = nil,
        elevenLabsModelId: String? = nil,
        elevenLabsLanguageCode: String? = nil,
        elevenLabsDiarize: Bool? = nil,
        elevenLabsTagAudioEvents: Bool? = nil,
        elevenLabsNumSpeakers: Int? = nil,
        elevenLabsFileFormat: String? = nil,
        elevenLabsEntityDetection: String? = nil,
        elevenLabsKeyterms: [String]? = nil,
        elevenLabsApiKeyExpiresAt: Date? = nil
    ) {
        self.output = output
        self.format = format
        self.layout = layout
        self.micChannel = micChannel
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.micDevice = micDevice
        self.logLevel = logLevel
        self.maxDuration = maxDuration
        self.overwrite = overwrite
        self.runMode = runMode
        self.pidFile = pidFile
        self.logFile = logFile
        self.stopTimeout = stopTimeout
        self.transcriptionProviderId = transcriptionProviderId
        self.transcriptionSource = transcriptionSource
        self.transcriptionFormat = transcriptionFormat
        self.transcriptionApiKey = transcriptionApiKey
        self.transcriptionKeyExpiresAt = transcriptionKeyExpiresAt
        self.transcriptionModelId = transcriptionModelId
        self.transcriptionLanguageHints = transcriptionLanguageHints
        self.sonioxEndpoint = sonioxEndpoint
        self.sonioxKeyExpiresAt = sonioxKeyExpiresAt
        self.azureOpenAIEndpoint = azureOpenAIEndpoint
        self.azureOpenAIDeployment = azureOpenAIDeployment
        self.azureOpenAIApiVersion = azureOpenAIApiVersion
        self.azureOpenAIApiKeyExpiresAt = azureOpenAIApiKeyExpiresAt
        self.azureOpenAIRealtimeVADThreshold = azureOpenAIRealtimeVADThreshold
        self.azureOpenAIRealtimeVADPrefixPaddingMS = azureOpenAIRealtimeVADPrefixPaddingMS
        self.azureOpenAIRealtimeVADSilenceMS = azureOpenAIRealtimeVADSilenceMS
        self.azureOpenAIRealtimeNoiseReduction = azureOpenAIRealtimeNoiseReduction
        self.azureOpenAIRealtimeIncludeLogprobs = azureOpenAIRealtimeIncludeLogprobs
        self.azureOpenAIRealtimeDeploymentInUrl = azureOpenAIRealtimeDeploymentInUrl
        self.elevenLabsModelId = elevenLabsModelId
        self.elevenLabsLanguageCode = elevenLabsLanguageCode
        self.elevenLabsDiarize = elevenLabsDiarize
        self.elevenLabsTagAudioEvents = elevenLabsTagAudioEvents
        self.elevenLabsNumSpeakers = elevenLabsNumSpeakers
        self.elevenLabsFileFormat = elevenLabsFileFormat
        self.elevenLabsEntityDetection = elevenLabsEntityDetection
        self.elevenLabsKeyterms = elevenLabsKeyterms
        self.elevenLabsApiKeyExpiresAt = elevenLabsApiKeyExpiresAt
    }

    // MARK: - Defaults

    /// Default stop-timeout in seconds (FR-26).
    public static let defaultStopTimeout: TimeInterval = 35

    /// Default PID file location: `~/.tool-agents/macrec/macrec.pid`
    /// (FR-26 / FR-27).
    public static var defaultPidFile: URL {
        toolAgentsHome().appendingPathComponent("macrec.pid")
    }

    /// Default log file location: `~/.tool-agents/macrec/macrec.log`
    /// (FR-29).
    public static var defaultLogFile: URL {
        toolAgentsHome().appendingPathComponent("macrec.log")
    }

    /// `~/.tool-agents/macrec/`. Pure path computation — no I/O. The
    /// folder itself is materialized by `ToolAgentsBootstrap.ensure`.
    private static func toolAgentsHome() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".tool-agents", isDirectory: true)
            .appendingPathComponent("macrec", isDirectory: true)
    }
}

// MARK: - Derivation helpers

extension RecordingOptions {

    /// Returns a copy of this `RecordingOptions` with `output` replaced
    /// and every other field preserved verbatim. Pure value-type
    /// derivation; performs no I/O and no validation (the caller is
    /// responsible for any pre-flight checks).
    ///
    /// Used by:
    ///   * `RecordingSession.split(nextOutput:)` (FR-32) — derives the
    ///     next-segment options when the encoder rotates.
    ///   * The UI's `SessionCoordinator` (plan-002 Phase D) — derives
    ///     per-segment options for stop-and-stitch pause/resume.
    ///
    /// project-design.md §15.3.5.
    ///
    /// **plan-003 Phase C / R-Top2**: this method MUST forward every
    /// transcription field. The codebase scan flagged the original
    /// implementation as latently buggy because adding new stored properties
    /// without updating this method would silently lose them at every
    /// pause/resume / segment rotation. The
    /// `RecordingOptionsTranscriptionTests.testWithOutputPreservesTranscriptionFields`
    /// regression test asserts every transcription field is preserved.
    public func withOutput(_ url: URL) -> RecordingOptions {
        RecordingOptions(
            output: url,
            format: format,
            layout: layout,
            micChannel: micChannel,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            bitrate: bitrate,
            micDevice: micDevice,
            logLevel: logLevel,
            maxDuration: maxDuration,
            overwrite: overwrite,
            runMode: runMode,
            pidFile: pidFile,
            logFile: logFile,
            stopTimeout: stopTimeout,
            transcriptionProviderId: transcriptionProviderId,
            transcriptionSource: transcriptionSource,
            transcriptionFormat: transcriptionFormat,
            transcriptionApiKey: transcriptionApiKey,
            transcriptionKeyExpiresAt: transcriptionKeyExpiresAt,
            transcriptionModelId: transcriptionModelId,
            transcriptionLanguageHints: transcriptionLanguageHints,
            sonioxEndpoint: sonioxEndpoint,
            sonioxKeyExpiresAt: sonioxKeyExpiresAt,
            azureOpenAIEndpoint: azureOpenAIEndpoint,
            azureOpenAIDeployment: azureOpenAIDeployment,
            azureOpenAIApiVersion: azureOpenAIApiVersion,
            azureOpenAIApiKeyExpiresAt: azureOpenAIApiKeyExpiresAt,
            azureOpenAIRealtimeVADThreshold: azureOpenAIRealtimeVADThreshold,
            azureOpenAIRealtimeVADPrefixPaddingMS: azureOpenAIRealtimeVADPrefixPaddingMS,
            azureOpenAIRealtimeVADSilenceMS: azureOpenAIRealtimeVADSilenceMS,
            azureOpenAIRealtimeNoiseReduction: azureOpenAIRealtimeNoiseReduction,
            azureOpenAIRealtimeIncludeLogprobs: azureOpenAIRealtimeIncludeLogprobs,
            azureOpenAIRealtimeDeploymentInUrl: azureOpenAIRealtimeDeploymentInUrl,
            elevenLabsModelId: elevenLabsModelId,
            elevenLabsLanguageCode: elevenLabsLanguageCode,
            elevenLabsDiarize: elevenLabsDiarize,
            elevenLabsTagAudioEvents: elevenLabsTagAudioEvents,
            elevenLabsNumSpeakers: elevenLabsNumSpeakers,
            elevenLabsFileFormat: elevenLabsFileFormat,
            elevenLabsEntityDetection: elevenLabsEntityDetection,
            elevenLabsKeyterms: elevenLabsKeyterms,
            elevenLabsApiKeyExpiresAt: elevenLabsApiKeyExpiresAt
        )
    }
}
