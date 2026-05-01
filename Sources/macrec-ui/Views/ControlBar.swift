// macrec-ui/Views/ControlBar.swift — see project-design.md §15.4,
// §15.8 (start-button gating) and plan-002-toolbar-ui.md §3 Phase E
// (FR-31, FR-32, FR-36 default folder, R-32 fix, button-enable matrix).
//
// Lifecycle button bar: Start, Pause, Resume, Stop, Split. Visibility
// and enablement derive from `recordingController.state` per the
// matrix in plan-002 §3 Phase E:
//
//   | State                          | Buttons visible            |
//   |--------------------------------|----------------------------|
//   | idle / stopped / failed        | Start                      |
//   | starting                       | (none — transient)         |
//   | recording                      | Pause, Stop, Split         |
//   | pausing                        | (none — transient)         |
//   | paused                         | Resume, Stop               |
//   | resuming                       | (none — transient)         |
//   | splitting                      | (none — transient)         |
//   | stopping                       | (none — transient)         |
//
// The Start button is **not** gated on the persisted folder path —
// FR-36 specifies that an empty `folderPath` resolves to `~/Recordings/`
// (created on first use). `startTapped()` calls
// `DefaultRecordingFolder.resolve()` and writes the resolved path back
// into `@AppStorage` before composing `RecordingOptions`, so first-run
// UX is friction-free (R-32).
//
// Each button forwards to the matching `RecordingController` method
// after composing a fresh `RecordingOptions` from the persisted UI
// state. The composition lives here because the controller's API takes
// a complete `RecordingOptions` (per the actual Phase D
// implementation) — see project-design §15.4 controller surface and
// `RecordingController.setOptions(_:)`.

import Foundation
import Logging
import MacrecCore
import MacrecUIKit
import SwiftUI

/// Lifecycle controls for the active recording.
struct ControlBar: View {
    @Environment(\.recordingController) private var recordingController

    // Persisted UI state read here so we can compose `RecordingOptions`
    // when the user clicks Start. Each control owns the writes; the
    // ControlBar only reads at action time.
    @AppStorage("com.macrec.ui.outputFolder") private var folderPath: String = ""
    @AppStorage("com.macrec.ui.basename") private var basename: String = ""
    @AppStorage("com.macrec.ui.format") private var formatRaw: String = OutputFormat.m4a.rawValue
    @AppStorage("com.macrec.ui.layout") private var layoutRaw: String = TrackLayout.mixed.rawValue
    @AppStorage("com.macrec.ui.micUID") private var micUID: String = ""

    // Transcription persisted state (plan-003 Phase G; read here so the
    // composed `RecordingOptions` carries the user's picker selection
    // into `RecordingSession.setUpTranscriptionPipelineIfNeeded`).
    // Default `"apple"` per plan-005 Phase H — Apple Speech is the
    // on-device default; the user can opt back to "none" or to the
    // Gemini cloud provider via `TranscriptionPicker`.
    @AppStorage("com.macrec.ui.transcribeProvider")
    private var transcribeProviderRaw: String = "apple"
    // plan-008 Unit I: master enable/disable switch for transcription.
    // Defaults `true` so existing users do not lose transcription on
    // upgrade. The gate in `startTapped()` is **non-mutating** — when
    // `false`, the effective provider passed to the engine is forced to
    // `"none"` while the persisted `transcribeProviderRaw` is preserved
    // so re-toggling ON restores the user's last engine choice
    // (UR-ADR-7).
    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true
    @AppStorage("com.macrec.ui.transcribeSource")
    private var transcribeSourceRaw: String = TranscriptionSource.mixed.rawValue
    @AppStorage("com.macrec.ui.transcriptFormat")
    private var transcriptFormatRaw: String = TranscriptFormat.jsonl.rawValue
    // Language hints for the Apple Speech provider (and the
    // first-hint-only prompt for Gemini). Persisted by
    // `TranscriptionLanguagePicker`. Empty = engine falls back to
    // `Locale.current` per `AppleSpeechTranscriptionProvider`.
    @AppStorage("com.macrec.ui.transcribeLanguage")
    private var transcribeLanguagePrimaryRaw: String = ""
    @AppStorage("com.macrec.ui.transcribeLanguage2")
    private var transcribeLanguageSecondaryRaw: String = ""
    /// 2026-05-01 — third language slot. Used by the ElevenLabs path
    /// (the user explicitly asked for up to 3 selectable languages
    /// when transcribing bilingual / trilingual content). The Apple
    /// `SpeechAnalyzer` path still consumes only the first two
    /// (its dual-locale API is hard-capped); a third value is dropped
    /// silently inside its provider.
    @AppStorage("com.macrec.ui.transcribeLanguage3")
    private var transcribeLanguageTertiaryRaw: String = ""

    private let logger = Logger(label: "macrec.ui.controlBar")

    /// Resolve an env-var name to its current effective value, preferring
    /// `~/.tool-agents/macrec-ui/.env` over `ProcessInfo.environment`.
    /// This matches the documented four-tier precedence chain
    /// (`localEnv > userEnv > shellEnv` — see `ConfigResolver`) so the
    /// popover's view of the environment agrees with the Settings panel
    /// even when a shell-exported value would otherwise override the
    /// user's stored configuration. Returns `nil` for empty / missing.
    static func resolvedEnvValue(_ envVar: String) -> String? {
        if let fromEnvFile = EnvFileStore.read(toolName: "macrec-ui", key: envVar),
           !fromEnvFile.isEmpty
        {
            return fromEnvFile
        }
        return ProcessInfo.processInfo.environment[envVar]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        HStack(spacing: 8) {
            startButton
            pauseButton
            resumeButton
            stopButton
            splitButton
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var startButton: some View {
        if showsStart {
            Button(action: startTapped) {
                Label(String(localized: "Start"), systemImage: "record.circle")
            }
            .help(String(localized: "Start recording."))
        }
    }

    @ViewBuilder
    private var pauseButton: some View {
        if showsPause {
            Button(action: { recordingController?.pause() }) {
                Label(String(localized: "Pause"), systemImage: "pause.circle")
            }
            .help(String(localized: "Pause the active recording."))
        }
    }

    @ViewBuilder
    private var resumeButton: some View {
        if showsResume {
            Button(action: { recordingController?.resume() }) {
                Label(String(localized: "Resume"), systemImage: "play.circle")
            }
            .help(String(localized: "Resume from pause."))
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if showsStop {
            Button(action: { recordingController?.stop() }) {
                Label(String(localized: "Stop"), systemImage: "stop.circle")
            }
            .help(String(localized: "Stop and finalize the recording."))
        }
    }

    @ViewBuilder
    private var splitButton: some View {
        if showsSplit {
            Button(action: { recordingController?.split() }) {
                Label(String(localized: "Split"), systemImage: "scissors")
            }
            .help(String(localized: "Split the recording into a new file."))
        }
    }

    // MARK: - Visibility

    private var showsStart: Bool {
        guard let state = recordingController?.state else { return true }
        switch state {
        case .idle, .stopped, .failed:
            return true
        default:
            return false
        }
    }

    private var showsPause: Bool {
        guard case .recording = recordingController?.state else { return false }
        return true
    }

    private var showsResume: Bool {
        guard case .paused = recordingController?.state else { return false }
        return true
    }

    private var showsStop: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .recording, .paused:
            return true
        default:
            return false
        }
    }

    /// Per FR-32: split is only available during active recording.
    private var showsSplit: Bool {
        guard case .recording = recordingController?.state else { return false }
        return true
    }

    // MARK: - Start composition

    /// Compose a `RecordingOptions` from persisted UI state and forward
    /// to the controller. When `folderPath` is empty (first-run UX,
    /// R-32) the default `~/Recordings/` is resolved via
    /// `DefaultRecordingFolder.resolve()` (created if missing) and the
    /// path is persisted so subsequent invocations short-circuit. The
    /// basename falls back to `FilenameGenerator.default(now:)` when
    /// the user has not typed one.
    private func startTapped() {
        guard let controller = recordingController else { return }

        // FR-36 default-folder fallback (R-32). Resolve and persist on
        // first launch — `FolderPicker.onAppear` does the same, but
        // ControlBar may be Start-tapped before the folder picker has
        // rendered (e.g. via keyboard shortcut), so we belt-and-braces
        // here.
        let resolvedFolderPath: String
        if folderPath.isEmpty {
            resolvedFolderPath = DefaultRecordingFolder.resolve()
            folderPath = resolvedFolderPath
            logger.debug("resolved default folder on Start: \(resolvedFolderPath)")
        } else {
            resolvedFolderPath = folderPath
        }

        let folder = URL(fileURLWithPath: resolvedFolderPath, isDirectory: true)
        let format = OutputFormat(rawValue: formatRaw) ?? .m4a
        let layout = TrackLayout(rawValue: layoutRaw) ?? .mixed

        let resolvedBasename: String
        let trimmed = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resolvedBasename = FilenameGenerator.default(now: Date())
        } else {
            resolvedBasename = trimmed
        }

        let outputURL = folder
            .appendingPathComponent(resolvedBasename)
            .appendingPathExtension(format.rawValue)

        // The mic UID is `nil` (system default) when the user has not
        // chosen, or when they explicitly picked the sentinel default.
        let micDevice: String? = {
            if micUID.isEmpty { return nil }
            if micUID == "__default__" { return nil }
            return micUID
        }()

        // Transcription wiring (plan-003 Phase G — bug-fix R-LT-6).
        // The `TranscriptionPicker` writes to @AppStorage but did not
        // propagate to `RecordingOptions`; without this the recording
        // ran with `transcriptionProviderId == nil` and the
        // transcription pipeline was silently skipped.
        //
        // plan-008 Unit I: the persisted `transcribeProviderRaw` is
        // gated by the master `transcriptionEnabled` switch BEFORE we
        // normalize it. When the master switch is OFF the effective
        // provider is forced to `"none"`, which then collapses through
        // the existing `transcriptionActive` check below to a nil
        // `resolvedProviderId`. The persisted value is **not** mutated
        // (UR-ADR-7) so re-toggling ON restores the prior engine.
        let effectiveProvider: String = transcriptionEnabled
            ? transcribeProviderRaw
            : "none"
        let normalizedProvider = effectiveProvider.lowercased()
        let transcriptionActive = !normalizedProvider.isEmpty
            && normalizedProvider != "none"
            && normalizedProvider != "noop"
        let resolvedProviderId: String? = transcriptionActive
            ? normalizedProvider
            : nil
        let resolvedTranscriptionSource = TranscriptionSource(
            rawValue: transcribeSourceRaw
        ) ?? .mixed
        let resolvedTranscriptionFormat = TranscriptFormat(
            rawValue: transcriptFormatRaw
        ) ?? .jsonl
        // Resolve API key from the merged process environment. The
        // AppDelegate startup already merges `~/.tool-agents/macrec-ui/.env`
        // into ProcessInfo, so reading from there honours the
        // documented env-var resolution chain. A nil here flips
        // `RecordingController.transcriptionMissingKey` true and
        // `RecordingSession` will throw `transcriptionApiKeyMissing`
        // BEFORE the recorder starts (per project no-fallback rule).
        //
        // The env-var name is provider-specific (vendor-canonical):
        // GOOGLE_API_KEY for Gemini (also gemini-live alias),
        // SONIOX_API_KEY for Soniox (plan-006 SX-5 / SX-9),
        // AZURE_OPENAI_API_KEY for the Azure batch + realtime providers
        // (plan-007 Phase A1 + A2),
        // ELEVENLABS_API_KEY for ElevenLabs (plan-007 Phase B).
        // Apple Speech and WhisperKit are on-device and need no key.
        let resolvedTranscriptionApiKey: String? = {
            guard transcriptionActive else { return nil }
            let envVar: String?
            switch (resolvedProviderId ?? "").lowercased() {
            case "gemini", "gemini-live":           envVar = "GOOGLE_API_KEY"
            case "soniox":                          envVar = "SONIOX_API_KEY"
            case "azure", "azure-openai-realtime":  envVar = "AZURE_OPENAI_API_KEY"
            case "elevenlabs":                      envVar = "ELEVENLABS_API_KEY"
            default:                                envVar = nil
            }
            guard let envVar else { return nil }
            return Self.resolvedEnvValue(envVar)
        }()

        // Plan-007 Phase A1 / A2: forward Azure-specific fields when
        // either Azure provider is active. The factory needs all three
        // (endpoint, deployment, api-version) at build time; missing
        // endpoint or deployment surfaces as
        // `MacrecError.transcriptionConfigConflict` BEFORE the recorder
        // starts. The api-version is optional with a documented starter.
        let azureProviderActive = transcriptionActive
            && ((resolvedProviderId ?? "").lowercased() == "azure"
                || (resolvedProviderId ?? "").lowercased() == "azure-openai-realtime")
        let azureOpenAIEndpoint: URL? = {
            guard azureProviderActive else { return nil }
            guard let raw = Self.resolvedEnvValue("AZURE_OPENAI_ENDPOINT") else { return nil }
            return URL(string: raw)
        }()
        let azureOpenAIDeployment: String? = {
            guard azureProviderActive else { return nil }
            return Self.resolvedEnvValue("AZURE_OPENAI_DEPLOYMENT")
        }()
        let azureOpenAIApiVersion: String? = {
            guard azureProviderActive else { return nil }
            return Self.resolvedEnvValue("AZURE_OPENAI_API_VERSION")
        }()

        // Build the language-hints array from the two persisted slots
        // (`TranscriptionLanguagePicker` writes to them). Empty primary
        // OR transcription-disabled produces an empty array, which the
        // engine treats as "use Locale.current" (per
        // `AppleSpeechTranscriptionProvider.openStreamingSession`). The
        // dedup is defensive — the picker already prevents the user
        // from selecting the same locale twice, but persisted state
        // from a previous build / external override could still smuggle
        // a duplicate in.
        let resolvedLanguageHints: [String] = {
            guard transcriptionActive else { return [] }
            var seen: Set<String> = []
            var out: [String] = []
            for raw in [
                transcribeLanguagePrimaryRaw,
                transcribeLanguageSecondaryRaw,
                transcribeLanguageTertiaryRaw,
            ] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }
            return out
        }()

        // ElevenLabs forwarding (2026-05-01). When the active provider
        // is `elevenlabs`, read the optional knobs from the merged
        // env file so the keyterms / num_speakers / diarize toggle
        // edits in Settings actually affect the recording. For every
        // other provider these stay nil and the factory's documented
        // defaults apply.
        let elevenLabsActive = transcriptionActive
            && (resolvedProviderId ?? "").lowercased() == "elevenlabs"
        let elevenLabsKeyterms: [String]? = {
            guard elevenLabsActive,
                  let raw = Self.resolvedEnvValue("ELEVENLABS_KEYTERMS"),
                  !raw.isEmpty
            else { return nil }
            var seen: Set<String> = []
            var out: [String] = []
            for piece in raw.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }
            return out.isEmpty ? nil : out
        }()
        let elevenLabsNumSpeakers: Int? = {
            guard elevenLabsActive,
                  let raw = Self.resolvedEnvValue("ELEVENLABS_NUM_SPEAKERS"),
                  let n = Int(raw), (1...32).contains(n)
            else { return nil }
            return n
        }()
        let elevenLabsDiarize: Bool? = {
            guard elevenLabsActive,
                  let raw = Self.resolvedEnvValue("ELEVENLABS_DIARIZE")?.lowercased()
            else { return nil }
            switch raw {
            case "1", "true", "yes", "on":  return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }()

        let options = RecordingOptions(
            output: outputURL,
            format: format,
            layout: layout,
            micDevice: micDevice,
            transcriptionProviderId: resolvedProviderId,
            transcriptionSource: resolvedTranscriptionSource,
            transcriptionFormat: resolvedTranscriptionFormat,
            transcriptionApiKey: resolvedTranscriptionApiKey,
            transcriptionLanguageHints: resolvedLanguageHints,
            azureOpenAIEndpoint: azureOpenAIEndpoint,
            azureOpenAIDeployment: azureOpenAIDeployment,
            azureOpenAIApiVersion: azureOpenAIApiVersion,
            elevenLabsDiarize: elevenLabsDiarize,
            elevenLabsNumSpeakers: elevenLabsNumSpeakers,
            elevenLabsKeyterms: elevenLabsKeyterms
        )

        let languageHintsForLog = resolvedLanguageHints.isEmpty
            ? "[]"
            : resolvedLanguageHints.joined(separator: ",")
        logger.debug(
            "starting recording: output=\(outputURL.path) format=\(format.rawValue) layout=\(layout.rawValue) transcribe=\(resolvedProviderId ?? "none") source=\(resolvedTranscriptionSource.rawValue) sidecarFormat=\(resolvedTranscriptionFormat.rawValue) apiKeyPresent=\(resolvedTranscriptionApiKey != nil) languageHints=\(languageHintsForLog)"
        )
        controller.setOptions(options)
        controller.start()
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
