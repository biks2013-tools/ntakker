// MacrecUIKit/UIErrorPresenter.swift — see project-design.md §15.10
// and plan-002-toolbar-ui.md §3 Phase G.
//
// Pure-logic mapping from `MacrecError` (engine-thrown) to a value-typed
// `UIErrorMessage` consumed by the SwiftUI `ErrorBanner` in the
// executable target. Living in `MacrecUIKit` keeps the mapping testable
// without dragging SwiftUI/AppKit into the test target.
//
// Per project-design §15.10:
//   * Every engine-thrown error is `MacrecError` (existing 26 cases).
//   * The UI MUST NOT introduce a parallel error type.
//   * Every case is mapped to a presentable triple: title, detail,
//     recovery action.
//
// Per project rules:
//   * No fallback configuration — every case is enumerated explicitly
//     so a future case-addition surfaces as a Swift compiler exhaustive-
//     -switch warning rather than degrading silently to a generic
//     "Unknown error" string.
//   * All user-facing strings wrapped in `String(localized:)`.
//
// NFR-7 (no PII / serial numbers / home-dir leakage): the only user-
// derived strings interpolated into details are filenames
// (`url.lastPathComponent`) and `Error.localizedDescription` of system
// errors, both of which the user already saw in the failing operation.
// Full paths and process IDs from PID-file errors are surfaced because
// they are the user's own input via flags.

import Foundation
import MacrecCore

/// Value-typed presentation of a `MacrecError` for the UI banner.
///
/// `Sendable` so it can cross actor boundaries (e.g. from the
/// `@MainActor` controller into a SwiftUI body which is implicitly
/// main-actor-isolated).
public struct UIErrorMessage: Equatable, Sendable {
    /// Short banner heading (bold).
    public let title: String

    /// One- or two-line explanation under the title.
    public let detail: String

    /// Optional recovery action attached to the right-hand button.
    /// `nil` means "show no action button — only the close X".
    public let recovery: RecoveryAction?

    /// Recovery action variants. Banner buttons map onto these.
    public enum RecoveryAction: Equatable, Sendable {
        /// Open the supplied System Settings deep-link URL. Used for
        /// permission-denied cases (Privacy_Microphone, Privacy_ScreenCapture).
        case openSystemSettings(URL)
        /// Re-issue a Start request (`recordingController.start()`).
        case retry
        /// Close the banner with no further action.
        case dismiss
    }

    public init(
        title: String,
        detail: String,
        recovery: RecoveryAction?
    ) {
        self.title = title
        self.detail = detail
        self.recovery = recovery
    }
}

/// Stateless presenter — converts a `MacrecError` to a
/// `UIErrorMessage` suitable for the SwiftUI banner.
public struct UIErrorPresenter: Sendable {

    // MARK: - System Settings deep links (project-design §8 / §15.10)

    /// Deep-link URL string for the macOS Privacy & Security pane,
    /// scoped to Microphone. Force-unwrapping is safe — these are
    /// compile-time constant strings under Apple's documented
    /// `x-apple.systempreferences:` scheme.
    private static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!

    /// Deep-link URL string for the macOS Privacy & Security pane,
    /// scoped to Screen Recording.
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    // MARK: - Mapping

    /// Convert a `MacrecError` to a `UIErrorMessage` per the
    /// project-design §15.10 mapping table.
    ///
    /// EVERY case in `MacrecError` is mapped explicitly so the Swift
    /// compiler's exhaustive-switch checking guarantees future case
    /// additions cannot silently regress to a generic message.
    public static func present(_ error: MacrecError) -> UIErrorMessage {
        switch error {

        // MARK: Permissions ---------------------------------------------------

        case .microphonePermissionDenied:
            return UIErrorMessage(
                title: String(localized: "Microphone access required"),
                detail: String(
                    localized: "macrec needs Microphone permission to record. Open System Settings > Privacy & Security > Microphone and enable macrec."
                ),
                recovery: .openSystemSettings(microphoneSettingsURL)
            )

        case .microphonePermissionNotDetermined:
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Microphone permission pending"),
                detail: String(
                    localized: "Approve the system prompt that just appeared, then try again."
                ),
                recovery: .retry
            )

        case .microphonePermissionRestricted:
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Microphone access restricted"),
                detail: String(
                    localized: "Microphone access is restricted by an MDM profile or parental control. Contact your administrator."
                ),
                recovery: .dismiss
            )

        case .screenRecordingPermissionDenied:
            return UIErrorMessage(
                title: String(localized: "Screen Recording access required"),
                detail: String(
                    localized: "macrec needs Screen Recording permission to capture system audio. Open System Settings > Privacy & Security > Screen Recording and enable macrec."
                ),
                recovery: .openSystemSettings(screenRecordingSettingsURL)
            )

        case .screenRecordingPermissionNotDetermined:
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Screen Recording permission pending"),
                detail: String(
                    localized: "Approve the system prompt that just appeared, then try again."
                ),
                recovery: .retry
            )

        // MARK: Output path ---------------------------------------------------

        case let .outputAlreadyExists(url):
            return UIErrorMessage(
                title: String(localized: "Output file already exists"),
                detail: String(
                    localized: "A file named \(url.lastPathComponent) is already at the chosen location. Choose a different name or delete the existing file."
                ),
                recovery: .dismiss
            )

        case let .outputParentMissing(url):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Output folder is missing"),
                detail: String(
                    localized: "The folder \(url.deletingLastPathComponent().lastPathComponent) does not exist. Choose a different folder."
                ),
                recovery: .dismiss
            )

        // MARK: Configuration -------------------------------------------------

        case let .missingRequiredConfig(key, _):
            return UIErrorMessage(
                title: String(localized: "Required configuration missing"),
                detail: String(
                    localized: "Setting \(key) is required but was not provided."
                ),
                recovery: .dismiss
            )

        case let .invalidConfigValue(key, value, expected):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Invalid configuration value"),
                detail: String(
                    localized: "\(key)='\(value)' is not valid. Expected: \(expected)."
                ),
                recovery: .dismiss
            )

        case let .dotEnvParseError(path, line, reason):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Configuration file is invalid"),
                detail: String(
                    localized: "Could not parse \(path) at line \(line): \(reason)."
                ),
                recovery: .dismiss
            )

        // MARK: Devices -------------------------------------------------------

        case .noInputDevicesAvailable:
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "No microphone available"),
                detail: String(
                    localized: "Connect a microphone or enable the built-in microphone in System Settings > Sound."
                ),
                recovery: .dismiss
            )

        case let .micDeviceNotFound(identifier):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Microphone not found"),
                detail: String(
                    localized: "The selected microphone '\(identifier)' is no longer available. Choose a different one."
                ),
                recovery: .dismiss
            )

        // MARK: Capture -------------------------------------------------------

        case let .scStreamFailedToStart(underlying):
            return UIErrorMessage(
                title: String(localized: "Failed to start system-audio capture"),
                detail: String(
                    localized: "System audio capture could not start: \(underlying.localizedDescription)"
                ),
                recovery: .retry
            )

        case let .scStreamSilentStopExceeded(restartCount):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "System-audio capture is unstable"),
                detail: String(
                    localized: "System audio capture stopped silently \(restartCount) times in a minute. Try restarting the Mac."
                ),
                recovery: .retry
            )

        case let .avCaptureFailedToStart(underlying):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Failed to start microphone capture"),
                detail: String(
                    localized: "Microphone capture could not start: \(underlying.localizedDescription)"
                ),
                recovery: .retry
            )

        // MARK: Encoding ------------------------------------------------------

        case let .writerFailedToStart(underlying):
            // Maps to the design's `.encoderFailure` slot — recovery: retry.
            return UIErrorMessage(
                title: String(localized: "Recording failed"),
                detail: String(
                    localized: "The output writer could not initialize: \(underlying.localizedDescription)"
                ),
                recovery: .retry
            )

        case let .writerFinalizationTimeout(url):
            return UIErrorMessage(
                title: String(localized: "File finalize took too long"),
                detail: String(
                    localized: "Finalizing took longer than expected. A partial file was saved as \(url.lastPathComponent)."
                ),
                recovery: .dismiss
            )

        case let .finishWritingFailed(underlying):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Recording failed"),
                detail: String(
                    localized: "The output file could not be finalized: \(underlying.localizedDescription)"
                ),
                recovery: .retry
            )

        // MARK: Detach / stop subcommand --------------------------------------

        case let .noActiveRecording(pidFilePath):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "No active recording"),
                detail: String(
                    localized: "No PID file at \(pidFilePath). There is nothing to stop."
                ),
                recovery: .dismiss
            )

        case let .staleRecording(pid, _):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Stale recording cleared"),
                detail: String(
                    localized: "The previous PID file referenced process \(pid), which is no longer running. Try starting a new recording."
                ),
                recovery: .retry
            )

        case let .stopTimeout(pid, seconds):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Stopping is taking longer than expected"),
                detail: String(
                    localized: "Process \(pid) did not exit within \(seconds) seconds. It may still be finalizing."
                ),
                recovery: .dismiss
            )

        case let .alreadyRecording(pid, _):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Another recording is in progress"),
                detail: String(
                    localized: "A macrec recording is already running (PID \(pid). Stop it first."
                ),
                recovery: .dismiss
            )

        case let .pidFileWriteFailed(path, reason):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Could not start recording"),
                detail: String(
                    localized: "Failed to write PID file at \(path): \(reason)."
                ),
                recovery: .dismiss
            )

        // MARK: Live transcription (plan-003 Phase C) ------------------------
        //
        // Minimal mapping added to keep the exhaustive switch compiling
        // after `MacrecError`'s plan-003 Phase C cases were introduced.
        // Phase G owns the final UI presentation contract for these cases
        // (see plan-003 §0.3); this stub is the no-fallback placeholder.

        case let .transcriptionApiKeyMissing(provider):
            return UIErrorMessage(
                title: String(localized: "Transcription API key missing"),
                detail: String(
                    localized: "Set the API key for provider '\(provider)' in your shell or ~/.tool-agents/macrec/.env, then try again."
                ),
                recovery: .dismiss
            )

        case let .transcriptionPermissionDenied(provider):
            // plan-005 Phase C — Apple on-device Speech requires Speech
            // Recognition TCC permission. The Phase H UI integration may
            // upgrade this to an `openSystemSettings(...)` deep link
            // (Privacy_SpeechRecognition); for now keep it consistent
            // with the other plan-003 transcription stubs.
            return UIErrorMessage(
                title: String(localized: "Speech Recognition permission required"),
                detail: String(
                    localized: "Transcription provider '\(provider)' needs Speech Recognition permission. Open System Settings > Privacy & Security > Speech Recognition and enable macrec, then try again."
                ),
                recovery: .dismiss
            )

        case let .transcriptionProviderUnavailable(reason):
            return UIErrorMessage(
                title: String(localized: "Transcription provider unavailable"),
                detail: String(
                    localized: "The transcription provider could not start: \(reason)"
                ),
                recovery: .retry
            )

        case let .transcriptionConfigConflict(reason):
            return UIErrorMessage(
                title: String(localized: "Conflicting transcription settings"),
                detail: String(
                    localized: "The transcription configuration is inconsistent: \(reason)"
                ),
                recovery: .dismiss
            )

        case let .transcriptionKeyExpired(provider, expiredAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let when = formatter.string(from: expiredAt)
            return UIErrorMessage(
                title: String(localized: "Transcription API key expired"),
                detail: String(
                    localized: "The API key for provider '\(provider)' expired on \(when). Renew the key and update your env files."
                ),
                recovery: .dismiss
            )

        // MARK: Generic -------------------------------------------------------

        case let .ioError(message):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Disk I/O error"),
                detail: String(
                    localized: "An I/O error occurred: \(message)"
                ),
                recovery: .retry
            )

        case let .unknown(message):
            // Phase G addition; consider documenting in §15.10.
            return UIErrorMessage(
                title: String(localized: "Unexpected error"),
                detail: String(
                    localized: "An unexpected error occurred: \(message)"
                ),
                recovery: .dismiss
            )
        }
    }
}
