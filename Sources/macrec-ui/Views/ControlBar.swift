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

    private let logger = Logger(label: "macrec.ui.controlBar")

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

        let options = RecordingOptions(
            output: outputURL,
            format: format,
            layout: layout,
            micDevice: micDevice
        )

        logger.debug(
            "starting recording: output=\(outputURL.path) format=\(format.rawValue) layout=\(layout.rawValue)"
        )
        controller.setOptions(options)
        controller.start()
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
