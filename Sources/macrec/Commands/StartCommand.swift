// macrec/Commands/StartCommand.swift — see project-design.md §9.2, §11.11, §14
// Phase K finalization (FR-1..FR-15, FR-25, FR-29; AC-16, AC-17, AC-20).
//
// `start` is the primary recording entrypoint. Its responsibilities,
// in order:
//
//   1. Bootstrap `~/.tool-agents/macrec/` (FR-13). Required before any
//      `.env` lookup.
//   2. Build the `cliOverrides` dictionary from the parsed flags. CLI
//      values take the highest precedence in `ConfigResolver`.
//   3. Resolve `RecordingOptions` via `ConfigResolver.resolve(...)`.
//      A `ConfigResolver` `MacrecError` here is surfaced verbatim and
//      the process exits with the locked exit code.
//   4. Bootstrap `LoggerFactory` at the resolved log level.
//   5. If `runMode == .detached`: run `Daemonizer.detach(_:)`. The
//      original parent and the intermediate parent both `_exit(0)`
//      from inside that call; only the grandchild returns. Crucially,
//      we daemonize BEFORE constructing `RecordingSession` so no
//      framework thread has been spun up yet (see Daemonizer header
//      for why this matters).
//   6. Construct and `run()` `RecordingSession`. The session itself
//      handles permissions (FR-10), the already-recording PID guard
//      (FR-28), the PID-file write/remove lifecycle (FR-25 / FR-27),
//      and the recording pipeline.
//
// Error mapping: any `MacrecError` thrown along this path is printed
// via `MacrecError.printToStderr()` and surfaces its locked exit code
// (design §9.5). Any other `Error` is printed with its localized
// description and exits 1.

import ArgumentParser
import Foundation
import Logging
import MacrecCore

public struct StartCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Begin a recording. Stop with Ctrl-C (SIGINT) or SIGTERM (foreground), or with 'macrec stop' (when started with --detach)."
    )

    // MARK: - Recording knobs

    @Option(name: [.short, .long], help: "Output file path (required).")
    public var output: String?

    @Option(name: .long, help: "Output format (m4a | wav | caf). Default: m4a.")
    public var format: String?

    @Option(name: .long, help: "Track layout (mixed | split | stereo-split). Default: mixed.")
    public var layout: String?

    @Option(name: .long, help: "Stereo-split mic channel (left | right). Default: left.")
    public var micChannel: String?

    @Option(name: .long, help: "Sample rate in Hz (44100 | 48000). Default: 48000.")
    public var sampleRate: Int?

    @Option(name: .long, help: "Bit depth (16 | 24, PCM only). Default: 16.")
    public var bitDepth: Int?

    @Option(name: .long, help: "AAC bitrate in kbps (64-320) or bps (64000-320000). Default: 192.")
    public var bitrate: Int?

    @Option(name: .long, help: "Microphone device name or UID. Default: system default.")
    public var micDevice: String?

    @Option(name: .long, help: "Log verbosity (quiet | info | debug). Default: info.")
    public var logLevel: String?

    @Option(name: .long, help: "Auto-stop after N seconds. Default: run until SIGINT.")
    public var maxDuration: Double?

    @Flag(name: .long, help: "Overwrite an existing output file.")
    public var overwrite: Bool = false

    // MARK: - Microphone AEC (plan-013 / plan-014)

    @Option(name: .long, help: "Microphone echo cancellation (on | off | true | false). Default: off (opt-in as of plan-014). When on, routes the mic through a software NLMS adaptive filter that subtracts speaker-to-mic acoustic bleed using the captured system audio as the reference. The processor preserves the mic's native frequency response (no AGC, no NS, no band narrowing). Env: MACREC_MIC_AEC.")
    public var micAec: String?

    // MARK: - Run-mode knobs (FR-25, FR-29)

    @Flag(name: .long, help: "Run the recording in the background (double-fork daemon). The shell prompt returns immediately; PID is written to --pid-file. Stop with 'macrec stop'. (FR-25)")
    public var detach: Bool = false

    @Option(name: .long, help: "PID file path for --detach mode. Default: ~/.tool-agents/macrec/macrec.pid. Env: MACREC_PID_FILE. (FR-25/FR-27/FR-28)")
    public var pidFile: String?

    @Option(name: .long, help: "Log file path for --detach mode (mode 0600, append). Default: ~/.tool-agents/macrec/macrec.log. Env: MACREC_LOG_FILE. (FR-29)")
    public var logFile: String?

    // MARK: - Live transcription knobs (plan-003 Phase C; design §LT-5.3)
    //
    // SECURITY: there is intentionally NO `--transcribe-key` flag. Provider
    // API keys live ONLY in the env-var resolution chain
    // (shell → ~/.tool-agents/macrec/.env → ./.env). Putting a key on a
    // command line would leak it into shell history and `ps` output.

    @Option(name: .long, help: "Live transcription provider (none | apple | apple-cloud | gemini | whisperkit | parakeet | soniox | azure | azure-openai-realtime | elevenlabs). Default: apple (per plan-005 Phase H). Env: MACREC_TRANSCRIBE.")
    public var transcribe: String?

    @Option(name: .long, help: "Audio source for transcription (system | mic | mixed | both). Default: mixed. Ignored when --transcribe none. Env: MACREC_TRANSCRIBE_SOURCE.")
    public var transcribeSource: String?

    @Option(name: .long, help: "Sidecar transcript format (jsonl | srt | vtt | txt). Default: jsonl. Env: MACREC_TRANSCRIBE_FORMAT.")
    public var transcribeFormat: String?

    @Option(name: .long, help: "Provider model id override (e.g. gemini-3.1-flash-live-preview). Default: provider's pinned default. Env: MACREC_TRANSCRIBE_MODEL.")
    public var transcribeModel: String?

    @Option(name: .long, help: "ISO-639-1 language hint for transcription (e.g. en, el). Default: provider auto-detect. Env: MACREC_TRANSCRIBE_LANGUAGE.")
    public var transcribeLanguage: String?

    @Option(name: .long, help: "ISO-8601 expiry date for the transcription API key (warns N days before expiry). Env: MACREC_TRANSCRIBE_KEY_EXPIRES_AT. Note: API keys themselves are NOT accepted as flags; set GOOGLE_API_KEY (Gemini) or SONIOX_API_KEY (Soniox) in your shell or ~/.tool-agents/macrec/.env.")
    public var transcribeKeyExpiresAt: String?

    @Option(name: .long, help: "Soniox WebSocket endpoint override (default: wss://stt-rt.soniox.com/transcribe-websocket; for regional endpoints see https://soniox.com/docs/stt/data-residency). Env: MACREC_SONIOX_ENDPOINT.")
    public var sonioxEndpoint: String?

    @Option(name: .long, help: "Override Soniox speaker diarization (true | false). Default: true. Env: MACREC_SONIOX_DIARIZE.")
    public var sonioxDiarize: Bool?

    @Option(name: .long, help: "Parakeet-specific model id (defaults to parakeet-tdt-0.6b-v3). Wins over --transcribe-model. Env: MACREC_PARAKEET_MODEL.")
    public var parakeetModel: String?

    @Option(name: .long, help: "Parakeet language hint (bare ISO-639-1, e.g. 'el'). Informational only — FluidAudio v0.8.x has no per-call language API; the multilingual model auto-detects. Env: MACREC_PARAKEET_LANGUAGE.")
    public var parakeetLanguage: String?

    public init() {}

    // MARK: - Execution

    public func run() async throws {
        // ---- Step 1: bootstrap ~/.tool-agents/macrec/. (FR-13) -------
        do {
            _ = try ToolAgentsBootstrap.ensure(toolName: "macrec")
        } catch let err as MacrecError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        // ---- Step 2: build CLI overrides. ----------------------------
        let overrides = buildCLIOverrides()

        // ---- Step 3: resolve options. --------------------------------
        let options: RecordingOptions
        do {
            options = try ConfigResolver(toolName: "macrec").resolve(cliOverrides: overrides)
        } catch let err as MacrecError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        // ---- Step 4: bootstrap logger at the resolved level. ---------
        LoggerFactory.bootstrap(level: options.logLevel)

        // ---- Step 5: daemonize if --detach was set. ------------------
        // CRITICAL: must happen BEFORE constructing `RecordingSession`
        // so no framework thread has been spun up yet (see Daemonizer
        // header for the fork-after-thread-creation hazard).
        if options.runMode == .detached {
            do {
                try Daemonizer.detach(
                    Daemonizer.Options(
                        pidFile: options.pidFile,
                        logFile: options.logFile
                    )
                )
            } catch let err as MacrecError {
                err.printToStderr()
                throw ExitCode(err.exitCode)
            } catch {
                FileHandle.standardError.write(
                    Data("macrec: error: \(error.localizedDescription)\n".utf8)
                )
                throw ExitCode(1)
            }
            // After successful detach we are the grandchild process.
            // stderr is now redirected to options.logFile, so any
            // further log output flows to the log file.
        }

        // ---- Step 6: run the session. --------------------------------
        let logger = LoggerFactory.make("macrec.cli")
        let session = RecordingSession(options: options, logger: logger)
        do {
            try await session.run()
        } catch let err as MacrecError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }
    }

    // MARK: - Helpers

    /// Translates the parsed CLI flags into the env-var-keyed overrides
    /// dictionary expected by `ConfigResolver.resolve(cliOverrides:)`.
    /// Only present (non-nil / true) flags are forwarded; absent flags
    /// fall through to the lower-precedence sources.
    func buildCLIOverrides() -> [String: String] {
        var o: [String: String] = [:]
        if let v = output       { o[ConfigResolver.Keys.output] = v }
        if let v = format       { o[ConfigResolver.Keys.format] = v }
        if let v = layout       { o[ConfigResolver.Keys.layout] = v }
        if let v = micChannel   { o[ConfigResolver.Keys.micChannel] = v }
        if let v = sampleRate   { o[ConfigResolver.Keys.sampleRate] = String(v) }
        if let v = bitDepth     { o[ConfigResolver.Keys.bitDepth] = String(v) }
        if let v = bitrate      { o[ConfigResolver.Keys.bitrate] = String(v) }
        if let v = micDevice    { o[ConfigResolver.Keys.micDevice] = v }
        if let v = logLevel     { o[ConfigResolver.Keys.logLevel] = v }
        if let v = maxDuration  { o[ConfigResolver.Keys.maxDuration] = String(v) }
        if overwrite            { o[ConfigResolver.Keys.overwrite] = "true" }
        if detach               { o[ConfigResolver.Keys.detach] = "true" }
        // plan-013 — `--mic-aec` is forwarded as the raw user-provided
        // string; `ConfigResolver.parseBool` accepts the same set of
        // spellings (`on`/`off`/`true`/`false`/`yes`/`no`/`1`/`0`).
        if let v = micAec       { o[ConfigResolver.Keys.micAEC] = v }
        if let v = pidFile      { o[ConfigResolver.Keys.pidFile] = v }
        if let v = logFile      { o[ConfigResolver.Keys.logFile] = v }
        // -- Live transcription (plan-003 Phase C) --
        if let v = transcribe              { o[ConfigResolver.Keys.transcribe] = v }
        if let v = transcribeSource        { o[ConfigResolver.Keys.transcribeSource] = v }
        if let v = transcribeFormat        { o[ConfigResolver.Keys.transcribeFormat] = v }
        if let v = transcribeModel         { o[ConfigResolver.Keys.transcribeModel] = v }
        if let v = transcribeLanguage      { o[ConfigResolver.Keys.transcribeLanguage] = v }
        if let v = transcribeKeyExpiresAt  { o[ConfigResolver.Keys.transcribeKeyExpiresAt] = v }
        if let v = sonioxEndpoint          { o[ConfigResolver.Keys.sonioxEndpoint] = v }
        if let v = sonioxDiarize           { o[ConfigResolver.Keys.sonioxDiarize] = v ? "true" : "false" }
        if let v = parakeetModel           { o[ConfigResolver.Keys.parakeetModel] = v }
        if let v = parakeetLanguage        { o[ConfigResolver.Keys.parakeetLanguage] = v }
        // Soft validation (plan-006 Phase H): warn if --soniox-endpoint
        // was provided without selecting the Soniox provider. Don't
        // fail — the override is harmless and may be future-config.
        if sonioxEndpoint != nil && (transcribe?.lowercased() != "soniox") {
            FileHandle.standardError.write(
                Data("macrec: warning: --soniox-endpoint was provided but --transcribe is not 'soniox'; the endpoint override will only take effect when the Soniox provider is selected.\n".utf8)
            )
        }
        return o
    }
}
