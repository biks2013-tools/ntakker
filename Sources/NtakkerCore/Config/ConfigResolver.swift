// NtakkerCore/Config/ConfigResolver.swift — see project-design.md §2.4 / §5
// Phase B — Bootstrap + Config (FR-12, FR-14, FR-15, FR-25, FR-26, FR-29)

import Foundation
import Speech

/// The four-source configuration resolver mandated by FR-12.
///
/// Precedence (lowest → highest):
///   1. Shell environment   (`ProcessInfo.processInfo.environment`)
///   2. User defaults `.env` at `~/.tool-agents/<toolName>/.env`
///   3. Local `.env` in the current working directory
///   4. CLI flag overrides supplied by the calling subcommand
public struct ConfigResolver {

    /// Names of the four sources, in the order used in error messages
    /// when a required value is missing.
    public static let sourceLabels: [String] = [
        "--<flag>",
        "./.env",
        "~/.tool-agents/<toolName>/.env",
        "shell",
    ]

    private let toolName: String
    private let fileManager: FileManager
    private let processInfo: ProcessInfo
    private let cwdProvider: () -> URL
    private let injectedShellEnv: [String: String]?
    private let injectedUserEnv: [String: String]?
    private let injectedLocalEnv: [String: String]?

    /// Production initializer.
    public init(
        toolName: String,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        cwdProvider: @escaping () -> URL = {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
    ) {
        self.toolName = toolName
        self.fileManager = fileManager
        self.processInfo = processInfo
        self.cwdProvider = cwdProvider
        self.injectedShellEnv = nil
        self.injectedUserEnv = nil
        self.injectedLocalEnv = nil
    }

    /// Test-only initializer — allows the three env-variable sources to
    /// be injected verbatim, sidestepping the filesystem and the live
    /// `ProcessInfo`. The CLI overrides remain a `resolve(...)`
    /// argument so tests still exercise the full precedence merge.
    public init(
        toolName: String,
        shellEnv: [String: String],
        userEnv: [String: String],
        localEnv: [String: String]
    ) {
        self.toolName = toolName
        self.fileManager = .default
        self.processInfo = .processInfo
        self.cwdProvider = {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        self.injectedShellEnv = shellEnv
        self.injectedUserEnv = userEnv
        self.injectedLocalEnv = localEnv
    }

    // MARK: - Public API

    /// Resolves all configuration sources and returns a fully-validated
    /// `RecordingOptions`. CLI overrides (highest priority) are expressed
    /// as a `[String: String]` keyed by env-var name (per the mapping
    /// table) — the calling command translates its flags into this
    /// dictionary.
    ///
    /// - Throws: `NtakkerError.missingRequiredConfig` if `output` cannot
    ///   be resolved from any source. `NtakkerError.invalidConfigValue`
    ///   on type-coercion or range-validation failure.
    public func resolve(cliOverrides: [String: String]) throws -> RecordingOptions {
        let shellEnv = injectedShellEnv ?? processInfo.environment
        let userEnv = try injectedUserEnv ?? DotEnvParser.parseFile(at: userEnvURL())
        let localEnv = try injectedLocalEnv ?? DotEnvParser.parseFile(at: localEnvURL())

        // Merge per FR-12: cliOverrides > localEnv > userEnv > shellEnv.
        func value(_ key: String) -> String? {
            if let v = cliOverrides[key], !v.isEmpty { return v }
            if let v = localEnv[key], !v.isEmpty { return v }
            if let v = userEnv[key], !v.isEmpty { return v }
            if let v = shellEnv[key], !v.isEmpty { return v }
            return nil
        }

        // --- output (required) -------------------------------------------------
        guard let outputRaw = value(Keys.output) else {
            throw NtakkerError.missingRequiredConfig(
                key: Keys.output,
                sourcesChecked: [
                    "--output",
                    "./.env",
                    "~/.tool-agents/\(toolName)/.env",
                    "shell",
                ]
            )
        }
        if outputRaw == "-" {
            throw NtakkerError.invalidConfigValue(
                key: Keys.output,
                value: "-",
                expected: "a writable file path (stdout streaming is not supported in v1)"
            )
        }
        let output = expandTilde(outputRaw)

        // --- format ------------------------------------------------------------
        let format: OutputFormat = try parseEnum(
            key: Keys.format,
            raw: value(Keys.format),
            default: .m4a
        )

        // --- layout ------------------------------------------------------------
        let layout: TrackLayout = try parseEnum(
            key: Keys.layout,
            raw: value(Keys.layout),
            default: .mixed
        )

        // --- micChannel --------------------------------------------------------
        let micChannel: StereoChannel = try parseEnum(
            key: Keys.micChannel,
            raw: value(Keys.micChannel),
            default: .left
        )

        // --- sampleRate --------------------------------------------------------
        let sampleRate = try parseInt(
            key: Keys.sampleRate,
            raw: value(Keys.sampleRate),
            default: 48_000,
            allowed: [44_100, 48_000]
        )

        // --- bitDepth ----------------------------------------------------------
        let bitDepth = try parseInt(
            key: Keys.bitDepth,
            raw: value(Keys.bitDepth),
            default: 16,
            allowed: [16, 24]
        )

        // --- bitrate -----------------------------------------------------------
        let bitrate = try parseBitrate(raw: value(Keys.bitrate))

        // --- micDevice ---------------------------------------------------------
        let micDeviceRaw = value(Keys.micDevice)
        let micDevice: String? = (micDeviceRaw?.isEmpty == false) ? micDeviceRaw : nil

        // --- logLevel ----------------------------------------------------------
        let logLevel: LogLevel = try parseEnum(
            key: Keys.logLevel,
            raw: value(Keys.logLevel),
            default: .info
        )

        // --- maxDuration -------------------------------------------------------
        let maxDuration = try parseOptionalPositiveDouble(
            key: Keys.maxDuration,
            raw: value(Keys.maxDuration)
        )

        // --- overwrite ---------------------------------------------------------
        let overwrite = try parseBool(
            key: Keys.overwrite,
            raw: value(Keys.overwrite),
            default: false
        )

        // --- detach / runMode --------------------------------------------------
        let detach = try parseBool(
            key: Keys.detach,
            raw: value(Keys.detach),
            default: false
        )
        let runMode: RunMode = detach ? .detached : .foreground

        // --- pidFile -----------------------------------------------------------
        let pidFile: URL = {
            if let raw = value(Keys.pidFile) {
                return expandTilde(raw)
            }
            return RecordingOptions.defaultPidFile
        }()

        // --- logFile -----------------------------------------------------------
        let logFile: URL = {
            if let raw = value(Keys.logFile) {
                return expandTilde(raw)
            }
            return RecordingOptions.defaultLogFile
        }()

        // --- stopTimeout -------------------------------------------------------
        let stopTimeout = try parsePositiveDouble(
            key: Keys.stopTimeout,
            raw: value(Keys.stopTimeout),
            default: RecordingOptions.defaultStopTimeout,
            upperBound: 600
        )

        // --- micAEC (plan-013 / plan-014) ----------------------------------
        //
        // Microphone acoustic-echo-cancellation toggle. **Default: `false`
        // (plan-014).** AEC is opt-in — set to `true` to route the mic
        // through `SoftwareAECProcessor` (NLMS adaptive filter, v5) which
        // subtracts speaker-to-mic acoustic bleed using the captured
        // system audio as the reference signal. The processor is safe
        // to leave on even when there is no bleed (it self-guards via
        // reference-activity gating, a double-talk detector, and a 50 ms
        // windowed divergence reset), but it costs ~5–8 % CPU doing
        // nothing on no-bleed setups, so the default is off. See plan-013
        // §3, plan-014, and the field comment on `RecordingOptions.micAEC`.
        let micAEC = try parseBool(
            key: Keys.micAEC,
            raw: value(Keys.micAEC),
            default: false
        )

        // --- Live transcription (plan-003 Phase C; design §LT-5.5) -----------
        //
        // Step 1: resolve the provider id. `none` (or absent) ⇒ no
        //         transcription; the rest of the chain short-circuits to
        //         defaults so the recording pipeline is byte-identical to the
        //         pre-plan-003 build (AC-LT-16).
        //
        // plan-004 Phase G.2: `gemini-live` is a deprecated alias for
        // `gemini`. The resolver lowers both to the canonical wire id
        // `"gemini"` (matching `TranscriptionProviderFactory.build` /
        // Phase D's REST batch provider) and emits a deprecation notice
        // on stderr the first time it is seen so the user has a migration
        // path with one release of overlap.
        //
        // **plan-005 Phase G default flip**: when `NTAKKER_TRANSCRIBE` is
        // unset across the entire four-tier chain, the resolver defaults
        // to `.apple` — Apple's on-device `SpeechAnalyzer` is the
        // out-of-the-box experience now. Set `NTAKKER_TRANSCRIBE=none`
        // explicitly to disable transcription. Set `NTAKKER_TRANSCRIBE=gemini`
        // to opt into the cloud REST provider.
        //
        // **plan-006 Phase B (SX-9.1)**: `soniox` joins the enum as a new
        // wire id; the resolver lowers it through unchanged.
        let transcribeRaw = value(Keys.transcribe)

        let transcribeProviderEnum: TranscriptionProviderId = try parseEnum(
            key: Keys.transcribe,
            raw: transcribeRaw,
            default: .apple
        )
        let transcribeIsActive = transcribeProviderEnum != .none
        let transcriptionProviderId: String? = {
            guard transcribeIsActive else { return nil }
            switch transcribeProviderEnum {
            case .none:
                return nil
            case .apple:
                return "apple"
            case .gemini:
                return "gemini"
            case .geminiLive:
                // Deprecation warning to stderr (no Logger plumbed into
                // ConfigResolver; the `TranscriptionProviderFactory.build`
                // path also logs via its own logger, so users see one
                // notice on each side of the boundary).
                let msg = "ntakker-cli: notice: NTAKKER_TRANSCRIBE=gemini-live is deprecated; use 'gemini'. Resolving to 'gemini'.\n"
                if let data = msg.data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                return "gemini"
            case .whisperkit:
                // plan-007 Task 0.1: enum case finally added so
                // `parseEnum` resolves cleanly. The factory already
                // dispatched on `"whisperkit"` since plan-005 Phase H.
                return "whisperkit"
            case .soniox:
                // plan-006 SX-9.1: Soniox cloud-streaming provider id.
                return "soniox"
            case .azure:
                // plan-007 Phase A1: Azure OpenAI batch (REST) provider.
                return "azure"
            case .azureOpenAIRealtime:
                // plan-007 Phase A2: Azure OpenAI realtime (WebSocket)
                // provider with `intent=transcription`.
                return "azure-openai-realtime"
            case .elevenlabs:
                // plan-007 Phase B: ElevenLabs Scribe v2 batch (REST).
                return "elevenlabs"
            case .parakeet:
                return "parakeet"
            case .appleCloud:
                return "apple-cloud"
            }
        }()

        // Step 2: resolve the audio source. Default `.mixed` per OQ-LT-2.
        let transcribeSourceEnum: TranscriptionSource = try parseEnum(
            key: Keys.transcribeSource,
            raw: value(Keys.transcribeSource),
            default: .mixed
        )

        // Step 3: resolve the sidecar format. Default `.jsonl`. Validated
        //         even when the provider is `.none` so a typo in
        //         `NTAKKER_TRANSCRIBE_FORMAT` always raises a clear error
        //         (the project's no-fallback rule).
        let transcribeFormatEnum: TranscriptFormat = try parseEnum(
            key: Keys.transcribeFormat,
            raw: value(Keys.transcribeFormat),
            default: .jsonl
        )

        // Step 4: resolve optional model id (no default; nil = provider's
        //         pinned default — see R-Phase C.3).
        let transcribeModelRaw = value(Keys.transcribeModel)
        let transcriptionModelId: String? =
            (transcribeModelRaw?.isEmpty == false) ? transcribeModelRaw : nil

        // Step 5: resolve the optional language-hint list.
        //
        // **plan-005 Phase G widening**: the wire form is now a comma-
        // separated list (e.g. `NTAKKER_TRANSCRIBE_LANGUAGE=en-US,el-GR`)
        // so the dual-locale Apple Speech path can pass two locales
        // without overloading a single string. A single value
        // (e.g. `en-US`) parses to a one-element list; an empty / unset
        // value parses to `[]`.
        let transcribeLanguageRaw = value(Keys.transcribeLanguage)
        let transcriptionLanguageHints: [String] = {
            guard let raw = transcribeLanguageRaw?
                .trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return [] }
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }()

        // Step 5b: when the active provider is Apple Speech, pre-validate
        //          every locale against the Speech-framework supported set
        //          so the user gets a deterministic config-load failure
        //          instead of a runtime `noModel` error from the analyzer.
        //
        //          We use `SFSpeechRecognizer.supportedLocales()` here —
        //          well-documented, available on macOS 13+, and returns
        //          the on-device-installed locale set. (`SpeechAnalyzer`
        //          on macOS 26 does not currently expose its own
        //          `supportedLocales()` static, and even when it does the
        //          underlying installed-asset list is the same.)
        if transcribeProviderEnum == .apple, !transcriptionLanguageHints.isEmpty {
            if #available(macOS 26.0, *) {
                let supported = Set(
                    SFSpeechRecognizer.supportedLocales().map { $0.identifier }
                )
                for hint in transcriptionLanguageHints {
                    guard supported.contains(hint) else {
                        let preview = supported.sorted().prefix(20)
                            .joined(separator: ", ")
                        throw NtakkerError.transcriptionConfigConflict(
                            reason: "language '\(hint)' not supported by Apple Speech on this Mac. Add it via System Settings > General > Language & Region > Add Language. First few supported: \(preview)…"
                        )
                    }
                }
            }
        }

        // Step 6: resolve provider-specific API key. Vendor-canonical name
        //         per CLAUDE.md tool-conventions: `GOOGLE_API_KEY` for
        //         Gemini, `SONIOX_API_KEY` for Soniox.
        //
        //         **Project rule (NO fallback)**: a missing key is a hard
        //         error.
        //
        //         For **Gemini**, the resolver returns `nil` for a missing
        //         key here and `TranscriptionProviderFactory.build` hard-throws
        //         `NtakkerError.transcriptionApiKeyMissing` before any audio
        //         capture begins. The no-fallback rule is enforced — the
        //         deferral is a layering choice (factory build time vs.
        //         config-resolve time), not a relaxation of the rule. The
        //         absent value is carried on `RecordingOptions.transcriptionApiKey`.
        //
        //         For **Soniox** (plan-006 SX-5.2 / SX-8.1), the resolver
        //         raises `NtakkerError.transcriptionApiKeyMissing(provider:
        //         "soniox")` immediately when the key is unresolvable
        //         across the four tiers — exit 78 (EX_CONFIG) BEFORE any
        //         audio file is created (AC-SX-5). No fallback value, no
        //         demo key, no anonymous mode (CLAUDE.md "no fallback for
        //         missing config" + FR-SX-4).
        //
        //         Apple Speech is on-device — no API key is required.
        let transcriptionApiKey: String? = try {
            guard transcribeIsActive else { return nil }
            switch transcribeProviderEnum {
            case .gemini, .geminiLive:
                let raw = value(Keys.googleApiKey)
                return (raw?.isEmpty == false) ? raw : nil
            case .soniox:
                let raw = value(Keys.sonioxApiKey)
                guard let key = raw, !key.isEmpty else {
                    // plan-006 SX-5.2 / SX-8.1: hard fail at config-load.
                    throw NtakkerError.transcriptionApiKeyMissing(
                        provider: "soniox"
                    )
                }
                return key
            case .azure, .azureOpenAIRealtime:
                // plan-007 Phase A1 / A2 §A.7 — `AZURE_OPENAI_API_KEY` is
                // shared between the batch REST provider and the realtime
                // WebSocket provider. Per the project no-fallback rule,
                // missing → hard fail at config-load (exit 78).
                let raw = value(Keys.azureOpenAIApiKey)
                guard let key = raw, !key.isEmpty else {
                    throw NtakkerError.transcriptionApiKeyMissing(
                        provider: transcribeProviderEnum == .azureOpenAIRealtime
                            ? "azure-openai-realtime"
                            : "azure"
                    )
                }
                return key
            case .elevenlabs:
                // plan-007 Phase B §B.7 — `ELEVENLABS_API_KEY`. Same
                // hard-fail-at-load posture as Soniox / Azure.
                let raw = value(Keys.elevenLabsApiKey)
                guard let key = raw, !key.isEmpty else {
                    throw NtakkerError.transcriptionApiKeyMissing(
                        provider: "elevenlabs"
                    )
                }
                return key
            case .apple, .appleCloud, .whisperkit, .parakeet, .none:
                // On-device, Apple-account, or no-op providers — no API
                // key required.
                return nil
            }
        }()

        // Step 7: resolve optional ISO-8601 expiry timestamp (shared key).
        let transcriptionKeyExpiresAt = try parseOptionalISO8601Date(
            key: Keys.transcribeKeyExpiresAt,
            raw: value(Keys.transcribeKeyExpiresAt)
        )

        // Step 7b (plan-006 SX-5.1 / SX-5.4): resolve optional Soniox WebSocket
        //         endpoint override. The vendor's stable production URL
        //         (`wss://stt-rt.soniox.com/transcribe-websocket`) is treated
        //         as a constant in the **provider** code (Unit D) — not as a
        //         fallback default in this resolver — so the project's
        //         "no fallback for missing config" rule (CLAUDE.md) is
        //         honoured. Sanctioned by design SX-5.3 (vendor endpoint is
        //         a stable code constant, not a sensitive credential).
        //
        //         When set, the value MUST parse as a URL; otherwise the
        //         resolver raises `invalidConfigValue` (exit 64).
        let sonioxEndpoint: URL? = try {
            guard let raw = value(Keys.sonioxEndpoint),
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "ws" || scheme == "wss"
            else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.sonioxEndpoint,
                    value: raw,
                    expected: "valid wss:// or ws:// URL (e.g. wss://stt-rt.soniox.com/transcribe-websocket)"
                )
            }
            return url
        }()

        // Step 7c (plan-006 SX-5.4 / D-SX-3 / OQ-SX-12): resolve the Soniox
        //         expiry timestamp with **provider-scoped > shared**
        //         precedence. `NTAKKER_SONIOX_KEY_EXPIRES_AT` wins when set;
        //         otherwise we fall back to the shared
        //         `NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT` (already parsed above
        //         into `transcriptionKeyExpiresAt`). Both unset ⇒ nil
        //         (no expiry warning is emitted at recording start —
        //         AC-SX-16).
        let sonioxKeyExpiresAt: Date? = try {
            if let perProvider = try parseOptionalISO8601Date(
                key: Keys.sonioxKeyExpiresAt,
                raw: value(Keys.sonioxKeyExpiresAt)
            ) {
                return perProvider
            }
            return transcriptionKeyExpiresAt
        }()

        // Step 7c.1 (plan-012 Phase A5): resolve the optional Soniox
        //         diarization toggle. `nil` here means "use the provider
        //         default" — the factory falls back to
        //         `SonioxConfigBuilder.defaultDiarize` (true). Set to
        //         `false` (via `NTAKKER_SONIOX_DIARIZE=false` or
        //         `--soniox-diarize false`) to revert to the
        //         pre-plan-012 single-speaker transcript form. Any
        //         non-boolean value raises `invalidConfigValue`
        //         (exit 64) per the project no-fallback rule.
        let sonioxDiarize: Bool? = try parseOptionalBool(
            key: Keys.sonioxDiarize,
            raw: value(Keys.sonioxDiarize)
        )

        // Step 7c.2 (plan-012 Phase B3): Parakeet on-device provider
        //          knobs. Both are optional strings; the factory layers
        //          NTAKKER_PARAKEET_MODEL > NTAKKER_TRANSCRIBE_MODEL >
        //          provider default. Language is informational only in
        //          v1 (FluidAudio v0.8.x has no per-call language hint
        //          API; the multilingual model auto-detects).
        let parakeetModelRaw = value(Keys.parakeetModel)
        let parakeetModel: String? =
            (parakeetModelRaw?.isEmpty == false) ? parakeetModelRaw : nil
        let parakeetLanguageRaw = value(Keys.parakeetLanguage)
        let parakeetLanguage: String? = {
            guard let raw = parakeetLanguageRaw?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            return raw
        }()

        // Step 7d (plan-007 Phase A1 + A2 §A.7): resolve the Azure OpenAI
        //         endpoint, deployment name, and api-version. The api-version
        //         is OPTIONAL with a documented starter (`2025-04-01-preview`,
        //         per Phase A2 §A.4.update); the resolver forwards `nil`
        //         when unset and the providers apply that constant locally.
        //         Endpoint and deployment are REQUIRED only when the active
        //         provider is `.azure` or `.azureOpenAIRealtime`; the
        //         factory raises `transcriptionConfigConflict` if either is
        //         missing at provider-build time so non-Azure runs are
        //         unaffected.
        let azureOpenAIEndpoint: URL? = try {
            guard let raw = value(Keys.azureOpenAIEndpoint),
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https"
            else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.azureOpenAIEndpoint,
                    value: raw,
                    expected: "valid https:// URL (e.g. https://my-resource.openai.azure.com)"
                )
            }
            return url
        }()
        let azureOpenAIDeploymentRaw = value(Keys.azureOpenAIDeployment)
        let azureOpenAIDeployment: String? =
            (azureOpenAIDeploymentRaw?.isEmpty == false) ? azureOpenAIDeploymentRaw : nil
        let azureOpenAIApiVersionRaw = value(Keys.azureOpenAIApiVersion)
        let azureOpenAIApiVersion: String? =
            (azureOpenAIApiVersionRaw?.isEmpty == false) ? azureOpenAIApiVersionRaw : nil

        // Step 7e (plan-007 Phase A1 §A.7): per-provider expiry override
        //         for `AZURE_OPENAI_API_KEY` with shared-key fallback,
        //         mirroring the Soniox precedence in step 7c.
        let azureOpenAIApiKeyExpiresAt: Date? = try {
            if let perProvider = try parseOptionalISO8601Date(
                key: Keys.azureOpenAIApiKeyExpiresAt,
                raw: value(Keys.azureOpenAIApiKeyExpiresAt)
            ) {
                return perProvider
            }
            return transcriptionKeyExpiresAt
        }()

        // Step 7f (plan-007 Phase A2 §A2.4): realtime-only VAD + noise-
        //         reduction + include-logprobs + deployment-in-URL knobs.
        //         All optional — the realtime provider applies documented
        //         defaults when unset.
        let azureOpenAIRealtimeVADThreshold: Float? = try parseOptionalFloat(
            key: Keys.azureOpenAIRealtimeVADThreshold,
            raw: value(Keys.azureOpenAIRealtimeVADThreshold),
            range: 0.0...1.0
        )
        let azureOpenAIRealtimeVADPrefixPaddingMS: Int? = try parseOptionalNonNegativeInt(
            key: Keys.azureOpenAIRealtimeVADPrefixPaddingMS,
            raw: value(Keys.azureOpenAIRealtimeVADPrefixPaddingMS)
        )
        let azureOpenAIRealtimeVADSilenceMS: Int? = try parseOptionalNonNegativeInt(
            key: Keys.azureOpenAIRealtimeVADSilenceMS,
            raw: value(Keys.azureOpenAIRealtimeVADSilenceMS)
        )
        let azureOpenAIRealtimeNoiseReduction: String? = try {
            guard let raw = value(Keys.azureOpenAIRealtimeNoiseReduction),
                  !raw.isEmpty else { return nil }
            let lower = raw.lowercased()
            guard ["near_field", "far_field", "none"].contains(lower) else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.azureOpenAIRealtimeNoiseReduction,
                    value: raw,
                    expected: "one of: near_field, far_field, none"
                )
            }
            return lower
        }()
        let azureOpenAIRealtimeIncludeLogprobs: Bool? = try parseOptionalBool(
            key: Keys.azureOpenAIRealtimeIncludeLogprobs,
            raw: value(Keys.azureOpenAIRealtimeIncludeLogprobs)
        )
        let azureOpenAIRealtimeDeploymentInUrl: Bool? = try parseOptionalBool(
            key: Keys.azureOpenAIRealtimeDeploymentInUrl,
            raw: value(Keys.azureOpenAIRealtimeDeploymentInUrl)
        )

        // Step 7g (plan-007 Phase B §B.7): ElevenLabs optional config.
        //         All fields are optional; the factory applies documented
        //         defaults when unset.
        let elevenLabsModelIdRaw = value(Keys.elevenLabsModelId)
        let elevenLabsModelId: String? =
            (elevenLabsModelIdRaw?.isEmpty == false) ? elevenLabsModelIdRaw : nil
        let elevenLabsLanguageCodeRaw = value(Keys.elevenLabsLanguageCode)
        let elevenLabsLanguageCode: String? =
            (elevenLabsLanguageCodeRaw?.isEmpty == false) ? elevenLabsLanguageCodeRaw : nil
        let elevenLabsDiarize: Bool? = try parseOptionalBool(
            key: Keys.elevenLabsDiarize,
            raw: value(Keys.elevenLabsDiarize)
        )
        let elevenLabsTagAudioEvents: Bool? = try parseOptionalBool(
            key: Keys.elevenLabsTagAudioEvents,
            raw: value(Keys.elevenLabsTagAudioEvents)
        )
        let elevenLabsNumSpeakers: Int? = try {
            guard let raw = value(Keys.elevenLabsNumSpeakers),
                  !raw.isEmpty else { return nil }
            guard let n = Int(raw), (1...32).contains(n) else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.elevenLabsNumSpeakers,
                    value: raw,
                    expected: "integer in 1..32"
                )
            }
            return n
        }()
        let elevenLabsFileFormat: String? = try {
            guard let raw = value(Keys.elevenLabsFileFormat),
                  !raw.isEmpty else { return nil }
            let lower = raw.lowercased()
            guard ["pcm_s16le_16", "other"].contains(lower) else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.elevenLabsFileFormat,
                    value: raw,
                    expected: "one of: pcm_s16le_16, other"
                )
            }
            return lower
        }()
        let elevenLabsEntityDetection: String? = try {
            guard let raw = value(Keys.elevenLabsEntityDetection),
                  !raw.isEmpty else { return nil }
            let lower = raw.lowercased()
            guard ["pii", "phi", "pci", "all"].contains(lower) else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.elevenLabsEntityDetection,
                    value: raw,
                    expected: "one of: pii, phi, pci, all"
                )
            }
            return lower
        }()
        // 2026-05-01 — `ELEVENLABS_KEYTERMS` parser. Comma-separated
        // form. Each entry trimmed; empties + duplicates dropped.
        // Hard limits (≤50 entries, ≤20 chars each) are enforced both
        // here AND inside `ElevenLabsConfig.init` so the CLI can fail
        // fast with a clear message before the recorder opens.
        let elevenLabsKeyterms: [String]? = try {
            guard let raw = value(Keys.elevenLabsKeyterms),
                  !raw.isEmpty else { return nil }
            var seen: Set<String> = []
            var out: [String] = []
            for piece in raw.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.count > ElevenLabsConfig.maxKeytermLength {
                    throw NtakkerError.invalidConfigValue(
                        key: Keys.elevenLabsKeyterms,
                        value: trimmed,
                        expected: "each entry ≤ \(ElevenLabsConfig.maxKeytermLength) chars"
                    )
                }
                if seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }
            guard out.count <= ElevenLabsConfig.maxKeyterms else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.elevenLabsKeyterms,
                    value: raw,
                    expected: "at most \(ElevenLabsConfig.maxKeyterms) comma-separated entries"
                )
            }
            return out.isEmpty ? nil : out
        }()
        let elevenLabsApiKeyExpiresAt: Date? = try {
            if let perProvider = try parseOptionalISO8601Date(
                key: Keys.elevenLabsApiKeyExpiresAt,
                raw: value(Keys.elevenLabsApiKeyExpiresAt)
            ) {
                return perProvider
            }
            return transcriptionKeyExpiresAt
        }()

        // -- WhisperKit (on-device) tunables (added 2026-05-02) --
        //
        // All five values are OPTIONAL. The resolver forwards `nil`
        // when the env-var is missing / empty (R-Phase C.3 — provider
        // owns the default). Out-of-range / unknown values raise
        // `NtakkerError.invalidConfigValue(...)` per the project's
        // no-fallback rule.
        let whisperKitModelRaw = value(Keys.whisperKitModel)
        let whisperKitModel: String? =
            (whisperKitModelRaw?.isEmpty == false) ? whisperKitModelRaw : nil

        let whisperKitLanguageRaw = value(Keys.whisperKitLanguage)
        let whisperKitLanguage: String? = {
            guard let raw = whisperKitLanguageRaw?
                .trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            return raw.lowercased()
        }()

        let whisperKitTask: String? = try {
            guard let raw = value(Keys.whisperKitTask)?
                .trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            let lower = raw.lowercased()
            guard ["transcribe", "translate"].contains(lower) else {
                throw NtakkerError.invalidConfigValue(
                    key: Keys.whisperKitTask,
                    value: raw,
                    expected: "one of: transcribe, translate"
                )
            }
            return lower
        }()

        let whisperKitTemperature: Float? = try parseOptionalFloat(
            key: Keys.whisperKitTemperature,
            raw: value(Keys.whisperKitTemperature),
            range: 0.0...1.0
        )

        let whisperKitWordTimestamps: Bool? = try parseOptionalBool(
            key: Keys.whisperKitWordTimestamps,
            raw: value(Keys.whisperKitWordTimestamps)
        )

        // Step 8 (cross-check): `--transcribe gemini-live` with
        //         `--transcribe-source mic` AND `--mic <empty/none>` is a
        //         configuration conflict (asks to transcribe a microphone
        //         that's been disabled). Per design §LT-5.5 step 9.
        if transcribeIsActive
            && transcribeSourceEnum == .mic
            && (micDevice == nil || micDevice?.lowercased() == "none")
        {
            throw NtakkerError.transcriptionConfigConflict(
                reason: "--transcribe-source mic requires a microphone (current --mic is disabled)"
            )
        }

        return RecordingOptions(
            output: output,
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
            micAEC: micAEC,
            transcriptionProviderId: transcriptionProviderId,
            transcriptionSource: transcribeSourceEnum,
            transcriptionFormat: transcribeFormatEnum,
            transcriptionApiKey: transcriptionApiKey,
            transcriptionKeyExpiresAt: transcriptionKeyExpiresAt,
            transcriptionModelId: transcriptionModelId,
            transcriptionLanguageHints: transcriptionLanguageHints,
            sonioxEndpoint: sonioxEndpoint,
            sonioxKeyExpiresAt: sonioxKeyExpiresAt,
            sonioxDiarize: sonioxDiarize,
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
            elevenLabsApiKeyExpiresAt: elevenLabsApiKeyExpiresAt,
            whisperKitModel: whisperKitModel,
            whisperKitLanguage: whisperKitLanguage,
            whisperKitTask: whisperKitTask,
            whisperKitTemperature: whisperKitTemperature,
            whisperKitWordTimestamps: whisperKitWordTimestamps,
            parakeetModel: parakeetModel,
            parakeetLanguage: parakeetLanguage
        )
    }

    // MARK: - Env-var key constants (mapping table)

    /// Canonical env-var names per the Phase B coder briefing.
    public enum Keys {
        public static let output       = "OUTPUT_PATH"
        public static let format       = "NTAKKER_FORMAT"
        public static let layout       = "NTAKKER_LAYOUT"
        public static let micChannel   = "NTAKKER_MIC_CHANNEL"
        public static let sampleRate   = "NTAKKER_SAMPLE_RATE"
        public static let bitDepth     = "NTAKKER_BIT_DEPTH"
        public static let bitrate      = "NTAKKER_BITRATE"
        public static let micDevice    = "NTAKKER_MIC_DEVICE"
        public static let logLevel     = "NTAKKER_LOG_LEVEL"
        public static let maxDuration  = "NTAKKER_MAX_DURATION"
        public static let overwrite    = "NTAKKER_OVERWRITE"
        public static let detach       = "NTAKKER_DETACH"
        public static let pidFile      = "NTAKKER_PID_FILE"
        public static let logFile      = "NTAKKER_LOG_FILE"
        public static let stopTimeout  = "NTAKKER_STOP_TIMEOUT"

        /// plan-013 — Microphone acoustic-echo-cancellation toggle.
        /// Accepts the standard boolean spellings (`true`/`false`,
        /// `1`/`0`, `yes`/`no`, `on`/`off`). Default is `true` — the
        /// recording captures the mic through `VPMicrophoneSource`
        /// (`AVAudioEngine` + voice-processing AEC) so Apple's
        /// echo-cancellation subtracts system-output bleed from the
        /// mic signal. Set to `false` to fall back to the raw
        /// `AVCaptureSession`-based `AVMicrophoneSource` (no AEC, no
        /// AGC, no NS, native frequency response).
        public static let micAEC       = "NTAKKER_MIC_AEC"

        // -- Live transcription (plan-003 Phase C; design §LT-5.2) --
        // Naming follows the user-prompt-suggested `NTAKKER_TRANSCRIBE*`
        // family (design §LT-5.2 records the rename from plan-003 §4
        // Phase C's earlier `NTAKKER_TRANSCRIBE_PROVIDER` /
        // `NTAKKER_TRANSCRIPT_*` spellings).
        public static let transcribe                = "NTAKKER_TRANSCRIBE"
        public static let transcribeSource          = "NTAKKER_TRANSCRIBE_SOURCE"
        public static let transcribeFormat          = "NTAKKER_TRANSCRIBE_FORMAT"
        public static let transcribeModel           = "NTAKKER_TRANSCRIBE_MODEL"
        public static let transcribeLanguage        = "NTAKKER_TRANSCRIBE_LANGUAGE"
        public static let transcribeKeyExpiresAt    = "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT"
        /// Vendor-canonical name per CLAUDE.md tool-conventions. Used by the
        /// Gemini Live provider (no `NTAKKER_*` prefix because the value is
        /// shared with other Google SDK consumers in the user's shell).
        public static let googleApiKey              = "GOOGLE_API_KEY"

        // -- Soniox provider (plan-006 Phase B; design SX-5.1) --
        //
        // Vendor-canonical key name (no `NTAKKER_*` prefix) follows the
        // same convention as `GOOGLE_API_KEY` so the value can be shared
        // with other Soniox SDK consumers in the user's shell.

        /// Soniox API key (vendor-canonical). Resolved through the standard
        /// 4-tier chain. Required when `NTAKKER_TRANSCRIBE=soniox`.
        public static let sonioxApiKey              = "SONIOX_API_KEY"

        /// Optional Soniox WebSocket endpoint override. Defaults to the
        /// vendor production URL `wss://stt-rt.soniox.com/transcribe-websocket`
        /// (constant lives in the provider, not here — design SX-5.3).
        /// Regional variants:
        ///   * `wss://stt-rt.eu.soniox.com/transcribe-websocket`
        ///   * `wss://stt-rt.jp.soniox.com/transcribe-websocket`
        public static let sonioxEndpoint            = "NTAKKER_SONIOX_ENDPOINT"

        /// Optional per-provider expiry override. Provider-scoped value
        /// takes precedence over the shared `NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT`
        /// (D-SX-3 / OQ-SX-12). Backwards-compatible with the existing
        /// Gemini-only configuration.
        public static let sonioxKeyExpiresAt        = "NTAKKER_SONIOX_KEY_EXPIRES_AT"

        /// Optional Soniox speaker-diarization toggle (plan-012 Phase A5).
        /// When unset, the resolver forwards `nil` and the factory falls
        /// back to `SonioxConfigBuilder.defaultDiarize` (true). Accepts the
        /// usual boolean spellings (`true`/`false`, `1`/`0`, `yes`/`no`).
        /// Set to `false` to revert to the pre-plan-012 single-speaker
        /// transcript form.
        public static let sonioxDiarize             = "NTAKKER_SONIOX_DIARIZE"

        // -- Parakeet (on-device, multilingual; plan-012 Phase B) --

        /// Optional Parakeet model id override. Mirrors WhisperKit's
        /// model-resolution chain: this Parakeet-specific key wins over
        /// the shared `NTAKKER_TRANSCRIBE_MODEL` which wins over the
        /// provider default (`parakeet-tdt-0.6b-v3`, multilingual).
        public static let parakeetModel             = "NTAKKER_PARAKEET_MODEL"

        /// Optional Parakeet language hint (bare ISO-639-1, e.g. `el`).
        /// Informational only — FluidAudio v0.8.x has no per-call
        /// language hint API; the multilingual TDT V3 model auto-
        /// detects per chunk. Kept so the env-var convention stays
        /// consistent with WhisperKit.
        public static let parakeetLanguage          = "NTAKKER_PARAKEET_LANGUAGE"

        // -- Azure OpenAI provider (plan-007 Phase A1 + A2; §5.2) --
        //
        // Vendor-canonical names per CLAUDE.md `<configuration-guide>` and
        // the eight-standard-providers list. All Azure surfaces share
        // `AZURE_OPENAI_*` so a single env / `.env` entry covers both the
        // batch REST and the realtime WebSocket providers.

        /// Azure OpenAI API key (vendor-canonical, no `NTAKKER_*` prefix
        /// per CLAUDE.md tool-conventions). Required when
        /// `NTAKKER_TRANSCRIBE=azure` or `=azure-openai-realtime`.
        public static let azureOpenAIApiKey            = "AZURE_OPENAI_API_KEY"

        /// Azure OpenAI resource endpoint. Required for both Azure
        /// providers. Format: `https://{resource-name}.openai.azure.com`
        /// (no trailing slash; the provider rewrites the scheme to
        /// `wss://` and replaces the path for the realtime variant).
        public static let azureOpenAIEndpoint          = "AZURE_OPENAI_ENDPOINT"

        /// Azure OpenAI deployment name (NOT the model name). The
        /// deployment must be backed by `gpt-4o-mini-transcribe` (or a
        /// compatible STT model) in the Azure portal. Required for both
        /// Azure providers.
        public static let azureOpenAIDeployment        = "AZURE_OPENAI_DEPLOYMENT"

        /// Azure OpenAI API version. Optional with documented starter
        /// `2025-04-01-preview` (covers both batch and realtime — see
        /// plan-007 §A2.4). Per Open Decision Az-1 the starter is a
        /// config-guide-documented default rather than a silent fallback.
        public static let azureOpenAIApiVersion        = "AZURE_OPENAI_API_VERSION"

        /// Optional ISO-8601 expiry timestamp for `AZURE_OPENAI_API_KEY`.
        /// Drives the "key expires in N days" warning at start.
        public static let azureOpenAIApiKeyExpiresAt   = "AZURE_OPENAI_API_KEY_EXPIRES_AT"

        // -- Azure OpenAI Realtime tuning (plan-007 Phase A2 §A2.4) --

        /// Server-side VAD detection threshold (0.0..1.0). Default 0.5.
        public static let azureOpenAIRealtimeVADThreshold       = "AZURE_OPENAI_REALTIME_VAD_THRESHOLD"

        /// Server-side VAD prefix-padding in milliseconds. Default 300.
        public static let azureOpenAIRealtimeVADPrefixPaddingMS = "AZURE_OPENAI_REALTIME_VAD_PREFIX_PADDING_MS"

        /// Server-side VAD silence-duration in milliseconds. Default 200.
        public static let azureOpenAIRealtimeVADSilenceMS       = "AZURE_OPENAI_REALTIME_VAD_SILENCE_MS"

        /// Server-side noise-reduction profile: `near_field` (default),
        /// `far_field`, or `none` (omit the field entirely).
        public static let azureOpenAIRealtimeNoiseReduction     = "AZURE_OPENAI_REALTIME_NOISE_REDUCTION"

        /// When true, the session adds
        /// `["item.input_audio_transcription.logprobs"]` to the `include`
        /// list so logprobs ride on delta / completed events.
        public static let azureOpenAIRealtimeIncludeLogprobs    = "AZURE_OPENAI_REALTIME_INCLUDE_LOGPROBS"

        /// When true, the WebSocket URL appends `&deployment={name}`.
        /// Default flipped to ON 2026-05-01 after field repro: most
        /// Azure tenants reject the parameter-less URL with an
        /// immediate close=1000 + "Socket is not connected". OQ-A2-2's
        /// original `false` default matched the early TechCommunity
        /// sample but turned out not to generalise.
        public static let azureOpenAIRealtimeDeploymentInUrl    = "AZURE_OPENAI_REALTIME_DEPLOYMENT_IN_URL"

        // -- ElevenLabs provider (plan-007 Phase B; §5.2) --

        /// ElevenLabs API key (vendor-canonical). Required when
        /// `NTAKKER_TRANSCRIBE=elevenlabs`.
        public static let elevenLabsApiKey             = "ELEVENLABS_API_KEY"

        /// ElevenLabs model id. Defaults to `scribe_v2`; `scribe_v1` is
        /// accepted for older accounts.
        public static let elevenLabsModelId            = "ELEVENLABS_MODEL_ID"

        /// Optional ISO-639-1 (`en`, `el`) or ISO-639-3 (`eng`, `ell`)
        /// language code. Unset → ElevenLabs auto-detects.
        public static let elevenLabsLanguageCode       = "ELEVENLABS_LANGUAGE_CODE"

        /// When true, response carries `speaker_id` per word (up to 32
        /// speakers). Default false.
        public static let elevenLabsDiarize            = "ELEVENLABS_DIARIZE"

        /// Whether to tag non-speech audio events (`(laughter)`,
        /// `(music)`, etc.). Default true.
        public static let elevenLabsTagAudioEvents     = "ELEVENLABS_TAG_AUDIO_EVENTS"

        /// Optional integer 1..32 — speaker count hint when known.
        public static let elevenLabsNumSpeakers        = "ELEVENLABS_NUM_SPEAKERS"

        /// File-format hint. `pcm_s16le_16` enables ElevenLabs's
        /// low-latency fast-path; `other` for anything else (e.g. m4a).
        /// Default `pcm_s16le_16` (matches `AudioWAVEncoder` output —
        /// per plan-007 §13 EL-3 always-on contract).
        public static let elevenLabsFileFormat         = "ELEVENLABS_FILE_FORMAT"

        /// Entity-detection mode (`pii`, `phi`, `pci`, `all`). Unset =
        /// off (plan-007 §13 EL-2 default; +30% surcharge when enabled).
        public static let elevenLabsEntityDetection    = "ELEVENLABS_ENTITY_DETECTION"

        /// 2026-05-01 — comma-separated list of bias terms forwarded as
        /// repeated `keyterms` form-fields. Helps disambiguate
        /// bilingual content (Greek+English) by biasing the model
        /// toward target-language vocabulary. Hard limits: ≤50 entries,
        /// each ≤20 characters. Empty / unset disables the bias.
        public static let elevenLabsKeyterms           = "ELEVENLABS_KEYTERMS"

        /// Optional ISO-8601 expiry timestamp for `ELEVENLABS_API_KEY`.
        public static let elevenLabsApiKeyExpiresAt    = "ELEVENLABS_API_KEY_EXPIRES_AT"

        // -- WhisperKit (on-device) provider tunables --
        //
        // Added 2026-05-02 alongside the WhisperKit Settings panel so the
        // user can override the WhisperKit-only knobs WITHOUT touching
        // the shared `NTAKKER_TRANSCRIBE_MODEL` (which other providers
        // also read). All five values are OPTIONAL — missing → the
        // provider's pinned defaults apply at construction time
        // (R-Phase C.3 — model-id default lives at the provider layer,
        // not as a config-resolver fallback substitution; the resolver
        // forwards `nil` and the provider applies the documented
        // default). Per CLAUDE.md no-fallback rule, *invalid* values
        // (out-of-range temperature, unknown task name, etc.) raise
        // `NtakkerError.invalidConfigValue(...)` at config-load time.

        /// WhisperKit model id override (e.g. `openai_whisper-base`,
        /// `openai_whisper-large-v3-v20240930_626MB`). Unset → provider
        /// default (`large-v3-v20240930_626MB`). When set, takes
        /// precedence over the shared `NTAKKER_TRANSCRIBE_MODEL` for the
        /// WhisperKit provider only.
        public static let whisperKitModel           = "NTAKKER_WHISPERKIT_MODEL"

        /// Whisper language code override — bare ISO-639-1 (e.g. `en`,
        /// `el`, `tr`, `de`). Empty / unset → Whisper auto-detects per
        /// chunk. NOT a BCP-47 tag (Whisper's tokenizer wants the bare
        /// 2-letter form).
        public static let whisperKitLanguage        = "NTAKKER_WHISPERKIT_LANGUAGE"

        /// Decoding task: `transcribe` (default — text in source
        /// language) or `translate` (translate to English).
        public static let whisperKitTask            = "NTAKKER_WHISPERKIT_TASK"

        /// Decoding temperature 0.0..1.0. Default 0 (verbatim, lowest
        /// hallucination). Higher values diversify decoding but reduce
        /// stability — only useful when the model returns repeated /
        /// degenerate text on a tricky chunk.
        public static let whisperKitTemperature     = "NTAKKER_WHISPERKIT_TEMPERATURE"

        /// When true, request per-word timestamps. Adds compute cost
        /// (~10–20 % per chunk) but is required for accurate SRT / VTT
        /// sidecars. Default false.
        public static let whisperKitWordTimestamps  = "NTAKKER_WHISPERKIT_WORD_TIMESTAMPS"

    }

    // MARK: - Helpers

    private func userEnvURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".tool-agents", isDirectory: true)
            .appendingPathComponent(toolName, isDirectory: true)
            .appendingPathComponent(".env")
    }

    private func localEnvURL() -> URL {
        cwdProvider().appendingPathComponent(".env")
    }

    private func expandTilde(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~/") {
            let home = fileManager.homeDirectoryForCurrentUser.path
            let suffix = String(trimmed.dropFirst(2))
            return URL(fileURLWithPath: "\(home)/\(suffix)")
        }
        if trimmed == "~" {
            return fileManager.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: trimmed)
    }

    private func parseEnum<E: RawRepresentable & CaseIterable>(
        key: String,
        raw: String?,
        default defaultValue: E
    ) throws -> E where E.RawValue == String {
        guard let raw = raw else { return defaultValue }
        if let parsed = E(rawValue: raw) { return parsed }
        let allowed = E.allCases.map { $0.rawValue }.joined(separator: ", ")
        throw NtakkerError.invalidConfigValue(
            key: key, value: raw, expected: "one of: \(allowed)"
        )
    }

    private func parseInt(
        key: String,
        raw: String?,
        default defaultValue: Int,
        allowed: [Int]
    ) throws -> Int {
        guard let raw = raw else { return defaultValue }
        guard let v = Int(raw) else {
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw, expected: "integer in {\(allowed.map(String.init).joined(separator: ", "))}"
            )
        }
        guard allowed.contains(v) else {
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw, expected: "one of: \(allowed.map(String.init).joined(separator: ", "))"
            )
        }
        return v
    }

    private func parseBitrate(raw: String?) throws -> Int {
        guard let raw = raw else { return 192_000 }
        guard let v = Int(raw) else {
            throw NtakkerError.invalidConfigValue(
                key: Keys.bitrate, value: raw,
                expected: "integer (kbps in [64, 320] or bits-per-second in [64000, 320000])"
            )
        }
        // Accept both kbps (e.g. 192) and bps (e.g. 192000) per FR-17.
        let bps: Int = (v >= 1_000) ? v : v * 1_000
        guard (64_000...320_000).contains(bps) else {
            throw NtakkerError.invalidConfigValue(
                key: Keys.bitrate, value: raw,
                expected: "kbps in [64, 320] or bps in [64000, 320000]"
            )
        }
        return bps
    }

    private func parseOptionalPositiveDouble(
        key: String,
        raw: String?
    ) throws -> TimeInterval? {
        guard let raw = raw else { return nil }
        guard let v = Double(raw) else {
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw, expected: "positive number of seconds"
            )
        }
        guard v > 0 else {
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw, expected: "positive number of seconds (> 0)"
            )
        }
        return v
    }

    private func parsePositiveDouble(
        key: String,
        raw: String?,
        default defaultValue: TimeInterval,
        upperBound: TimeInterval
    ) throws -> TimeInterval {
        guard let raw = raw else { return defaultValue }
        guard let v = Double(raw) else {
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw,
                expected: "positive number of seconds (<= \(Int(upperBound)))"
            )
        }
        guard v > 0, v <= upperBound else {
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw,
                expected: "positive number of seconds (> 0 and <= \(Int(upperBound)))"
            )
        }
        return v
    }

    private func parseBool(
        key: String,
        raw: String?,
        default defaultValue: Bool
    ) throws -> Bool {
        guard let raw = raw else { return defaultValue }
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            throw NtakkerError.invalidConfigValue(
                key: key, value: raw,
                expected: "boolean (true/false, 1/0, yes/no, on/off)"
            )
        }
    }

    /// Plan-007 §A2.4: parse an optional float in `range`. Returns
    /// `nil` when the env var is unset; throws `invalidConfigValue`
    /// when set but malformed or out of range.
    private func parseOptionalFloat(
        key: String,
        raw: String?,
        range: ClosedRange<Float>
    ) throws -> Float? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        guard let v = Float(raw), range.contains(v) else {
            throw NtakkerError.invalidConfigValue(
                key: key,
                value: raw,
                expected: "decimal in [\(range.lowerBound), \(range.upperBound)]"
            )
        }
        return v
    }

    /// Plan-007 §A2.4: parse an optional non-negative integer.
    private func parseOptionalNonNegativeInt(key: String, raw: String?) throws -> Int? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        guard let v = Int(raw), v >= 0 else {
            throw NtakkerError.invalidConfigValue(
                key: key,
                value: raw,
                expected: "non-negative integer"
            )
        }
        return v
    }

    /// Plan-007 §A2.4 / §B.7: parse an optional boolean (same vocabulary
    /// as `parseBool` but returns nil instead of a default when unset).
    private func parseOptionalBool(key: String, raw: String?) throws -> Bool? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default:
            throw NtakkerError.invalidConfigValue(
                key: key,
                value: raw,
                expected: "boolean (true/false, 1/0, yes/no, on/off)"
            )
        }
    }

    /// Parses an optional ISO-8601 timestamp. Accepts both date-only
    /// (`YYYY-MM-DD`) and full date-time (`YYYY-MM-DDTHH:MM:SS[Z|±HH:MM]`).
    /// Plan-003 Phase C: used to surface "key expires in N days" warnings.
    private func parseOptionalISO8601Date(key: String, raw: String?) throws -> Date? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        // Try full ISO-8601 first (with time + zone).
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFull.date(from: raw) { return date }
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]
        if let date = isoNoFraction.date(from: raw) { return date }
        // Fall back to date-only YYYY-MM-DD parsed as UTC midnight.
        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .iso8601)
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let date = dateOnly.date(from: raw) { return date }
        throw NtakkerError.invalidConfigValue(
            key: key,
            value: raw,
            expected: "ISO-8601 timestamp (e.g. 2026-12-31 or 2026-12-31T23:59:59Z)"
        )
    }
}
