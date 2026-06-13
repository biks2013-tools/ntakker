// ntakker/Views/ControlBar.swift — see project-design.md §15.4,
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
import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Lifecycle controls for the active recording.
struct ControlBar: View {
    @Environment(\.recordingController) private var recordingController

    // Persisted UI state read here so we can compose `RecordingOptions`
    // when the user clicks Start. Each control owns the writes; the
    // ControlBar only reads at action time.
    @AppStorage("com.ntakker-cli.ui.outputFolder") private var folderPath: String = ""
    @AppStorage("com.ntakker-cli.ui.basename") private var basename: String = ""
    @AppStorage("com.ntakker-cli.ui.format") private var formatRaw: String = OutputFormat.m4a.rawValue
    @AppStorage("com.ntakker-cli.ui.layout") private var layoutRaw: String = TrackLayout.mixed.rawValue
    @AppStorage("com.ntakker-cli.ui.micUID") private var micUID: String = ""

    // plan-013 / plan-014 — Microphone AEC toggle. Default `false`
    // (opt-in): when enabled, `RecordingSession` routes mic buffers
    // through `SoftwareAECProcessor`. Read at `start()` and forwarded
    // into `RecordingOptions(micAEC:)`. The user-facing control lives
    // in `MicEchoCancellationToggle` (in the popover's General section).
    @AppStorage(kMicAECStorageKey) private var micAEC: Bool = false

    // Transcription persisted state (plan-003 Phase G; read here so the
    // composed `RecordingOptions` carries the user's picker selection
    // into `RecordingSession.setUpTranscriptionPipelineIfNeeded`).
    // Default `"apple"` per plan-005 Phase H — Apple Speech is the
    // on-device default; the user can opt back to "none" or to the
    // Gemini cloud provider via `TranscriptionPicker`.
    @AppStorage("com.ntakker-cli.ui.transcribeProvider")
    private var transcribeProviderRaw: String = "apple"
    // plan-008 Unit I: master enable/disable switch for transcription.
    // Defaults `true` so existing users do not lose transcription on
    // upgrade. The gate in `startTapped()` is **non-mutating** — when
    // `false`, the effective provider passed to the engine is forced to
    // `"none"` while the persisted `transcribeProviderRaw` is preserved
    // so re-toggling ON restores the user's last engine choice
    // (UR-ADR-7).
    @AppStorage("com.ntakker-cli.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true
    @AppStorage("com.ntakker-cli.ui.transcribeSource")
    private var transcribeSourceRaw: String = TranscriptionSource.mixed.rawValue
    @AppStorage("com.ntakker-cli.ui.transcriptFormat")
    private var transcriptFormatRaw: String = TranscriptFormat.jsonl.rawValue
    // Language hints for the Apple Speech provider (and the
    // first-hint-only prompt for Gemini). Persisted by
    // `TranscriptionLanguagePicker`. Empty = engine falls back to
    // `Locale.current` per `AppleSpeechTranscriptionProvider`.
    @AppStorage("com.ntakker-cli.ui.transcribeLanguage")
    private var transcribeLanguagePrimaryRaw: String = ""
    @AppStorage("com.ntakker-cli.ui.transcribeLanguage2")
    private var transcribeLanguageSecondaryRaw: String = ""
    /// 2026-05-01 — third language slot. Used by the ElevenLabs path
    /// (the user explicitly asked for up to 3 selectable languages
    /// when transcribing bilingual / trilingual content). The Apple
    /// `SpeechAnalyzer` path still consumes only the first two
    /// (its dual-locale API is hard-capped); a third value is dropped
    /// silently inside its provider.
    @AppStorage("com.ntakker-cli.ui.transcribeLanguage3")
    private var transcribeLanguageTertiaryRaw: String = ""

    private let logger = Logger(label: "ntakker-cli.ui.controlBar")

    /// Resolve an env-var name to its current effective value, preferring
    /// `~/.tool-agents/ntakker/.env` over `ProcessInfo.environment`.
    /// This matches the documented four-tier precedence chain
    /// (`localEnv > userEnv > shellEnv` — see `ConfigResolver`) so the
    /// popover's view of the environment agrees with the Settings panel
    /// even when a shell-exported value would otherwise override the
    /// user's stored configuration. Returns `nil` for empty / missing.
    static func resolvedEnvValue(_ envVar: String) -> String? {
        if let fromEnvFile = EnvFileStore.read(toolName: "ntakker", key: envVar),
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
    /// to the controller. The composition logic moved to
    /// `RecordingStarter.start(controller:)` (plan-015 Phase 1.8) so
    /// the New-Session → restart path can reuse it. ControlBar's own
    /// Start button is the original caller.
    private func startTapped() {
        guard let controller = recordingController else { return }
        RecordingStarter.start(controller: controller)
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
