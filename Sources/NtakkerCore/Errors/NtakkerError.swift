// NtakkerCore/Errors/NtakkerError.swift — see project-design.md §2.1, §9.5
//
// Phase C (plan-001) — typed error enum returned by every other module.
//
// The stderr `description` strings and one-liner `remediation` strings are
// LOCKED by design §2.1. Phase 9 will regression-test these strings
// verbatim, so do not edit punctuation, casing, or wording without first
// updating the design doc.
//
// Exit codes are LOCKED by design §9.5.
//
// NFR-7: messages MUST NOT contain raw audio samples, device serial
// numbers, MAC addresses, or absolute home-directory paths beyond what
// the user passed in via --output / --pid-file.

import Foundation

public enum NtakkerError: Error, LocalizedError, CustomStringConvertible {
    // Configuration
    case missingRequiredConfig(key: String, sourcesChecked: [String])
    case invalidConfigValue(key: String, value: String, expected: String)
    case dotEnvParseError(path: String, line: Int, reason: String)

    // Output path
    case outputParentMissing(URL)
    case outputAlreadyExists(URL)

    // Permissions
    case screenRecordingPermissionDenied
    case screenRecordingPermissionNotDetermined
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case microphonePermissionRestricted

    // Devices
    case noInputDevicesAvailable
    case micDeviceNotFound(String)

    // Capture
    case scStreamFailedToStart(underlying: Error)
    case scStreamSilentStopExceeded(restartCount: Int)
    case avCaptureFailedToStart(underlying: Error)
    /// plan-013 — Apple voice-processing AEC could not be enabled on the
    /// resolved input device (`AVAudioEngine.inputNode.setVoiceProcessingEnabled`
    /// or `AVAudioEngine.start` threw). Maps to EX_SOFTWARE (70) like the
    /// other capture-startup errors. The user can re-run with `--mic-aec off`
    /// (or toggle off in the UI) to fall back to the raw `AVMicrophoneSource`.
    case micAECUnavailable(underlying: Error)

    // Encoding
    case writerFailedToStart(underlying: Error)
    case writerFinalizationTimeout(URL)
    case finishWritingFailed(underlying: Error)

    // Detach mode and `stop` subcommand (added 2026-04-26 per FR-25..FR-29)
    case noActiveRecording(pidFilePath: String)
    case staleRecording(pid: Int32, pidFilePath: String)
    case stopTimeout(pid: Int32, seconds: Int)
    case alreadyRecording(pid: Int32, pidFilePath: String)
    case pidFileWriteFailed(path: String, reason: String)

    // Live transcription (plan-003 Phase C; design §LT-4)
    //
    // No new exit codes are introduced — these cases map to the existing
    // EX_CONFIG (78) / EX_USAGE (64) / EX_SOFTWARE (70) buckets. See the
    // `exitCode` switch below.
    case transcriptionApiKeyMissing(provider: String)
    case transcriptionPermissionDenied(provider: String)
    case transcriptionProviderUnavailable(reason: String)
    case transcriptionConfigConflict(reason: String)
    case transcriptionKeyExpired(provider: String, expiredAt: Date)

    // Generic
    case ioError(String)
    case unknown(String)

    // MARK: - Exit codes (locked by design §9.5)

    /// POSIX-style exit code for this error. See design §9.5 for the locked
    /// table. All values below 64 follow generic Unix conventions; values at
    /// or above 64 follow `sysexits.h`.
    public var exitCode: Int32 {
        switch self {
        case .missingRequiredConfig,
             .micDeviceNotFound,
             .alreadyRecording,
             .noActiveRecording,
             .transcriptionApiKeyMissing,
             .transcriptionKeyExpired:
            return 78  // EX_CONFIG

        case .invalidConfigValue,
             .dotEnvParseError,
             .transcriptionConfigConflict:
            return 64  // EX_USAGE

        case .outputParentMissing,
             .outputAlreadyExists,
             .pidFileWriteFailed:
            return 66  // EX_NOINPUT

        case .screenRecordingPermissionNotDetermined,
             .microphonePermissionNotDetermined,
             .staleRecording:
            return 75  // EX_TEMPFAIL

        case .screenRecordingPermissionDenied,
             .microphonePermissionDenied,
             .microphonePermissionRestricted,
             .transcriptionPermissionDenied:
            return 77  // EX_NOPERM

        case .noInputDevicesAvailable,
             .scStreamFailedToStart,
             .scStreamSilentStopExceeded,
             .avCaptureFailedToStart,
             .micAECUnavailable,
             .writerFailedToStart,
             .stopTimeout,
             .transcriptionProviderUnavailable:
            return 70  // EX_SOFTWARE

        case .writerFinalizationTimeout:
            return 2

        case .finishWritingFailed,
             .ioError,
             .unknown:
            return 1
        }
    }

    // MARK: - User-facing summary (locked by design §2.1)

    /// One-line summary printed to stderr after the `ntakker-cli: error:` prefix.
    /// MUST NOT contain raw audio samples or any user PII (NFR-7).
    public var description: String {
        switch self {
        case let .missingRequiredConfig(key, sourcesChecked):
            let joined = sourcesChecked.joined(separator: ", ")
            return "missing required config: \(key) (checked: \(joined))"

        case let .invalidConfigValue(key, value, expected):
            return "invalid value for \(key): '\(value)' (expected: \(expected))"

        case let .dotEnvParseError(path, line, reason):
            return "failed to parse .env at \(path):\(line): \(reason)"

        case let .outputParentMissing(url):
            return "output parent directory does not exist: \(url.deletingLastPathComponent().path)"

        case let .outputAlreadyExists(url):
            return "output file already exists: \(url.path)"

        case .screenRecordingPermissionDenied:
            return "Screen Recording permission denied"

        case .screenRecordingPermissionNotDetermined:
            return "Screen Recording permission not yet granted; system prompt has been triggered"

        case .microphonePermissionDenied:
            return "Microphone permission denied"

        case .microphonePermissionNotDetermined:
            return "Microphone permission not yet granted; system prompt has been triggered"

        case .microphonePermissionRestricted:
            return "Microphone access is restricted by an MDM profile or parental control"

        case .noInputDevicesAvailable:
            return "no input audio devices found on this system"

        case let .micDeviceNotFound(identifier):
            return "microphone device not found: '\(identifier)'"

        case let .scStreamFailedToStart(underlying):
            return "system audio capture failed to start: \(underlying.localizedDescription)"

        case let .scStreamSilentStopExceeded(restartCount):
            return "system audio capture silently stopped \(restartCount) times in 60s; aborting"

        case let .avCaptureFailedToStart(underlying):
            return "microphone capture failed to start: \(underlying.localizedDescription)"

        case let .micAECUnavailable(underlying):
            return "microphone echo cancellation (AEC) could not be enabled: \(underlying.localizedDescription)"

        case let .writerFailedToStart(underlying):
            return "output writer failed to initialize: \(underlying.localizedDescription)"

        case let .writerFinalizationTimeout(url):
            return "finishWriting timed out after 30s; partial output at \(url.path)"

        case let .finishWritingFailed(underlying):
            return "writer finalization failed: \(underlying.localizedDescription)"

        case let .ioError(msg):
            return "I/O error: \(msg)"

        case let .unknown(msg):
            return "unexpected error: \(msg)"

        case let .noActiveRecording(pidFilePath):
            return "No active ntakker-cli recording found (PID file at \(pidFilePath) does not exist)."

        case let .staleRecording(pid, pidFilePath):
            return "Stale PID file at \(pidFilePath) referenced PID \(pid) which is no longer running. The file has been removed."

        case let .stopTimeout(pid, seconds):
            return "ntakker-cli process \(pid) did not exit within \(seconds)s of SIGTERM. The process may still be finalizing or hung."

        case let .alreadyRecording(pid, pidFilePath):
            return "Another ntakker-cli recording is already running (PID \(pid), PID file \(pidFilePath))."

        case let .pidFileWriteFailed(path, reason):
            return "Failed to write PID file at \(path): \(reason)."

        case let .transcriptionApiKeyMissing(provider):
            return "transcription API key missing for provider '\(provider)'"

        case let .transcriptionPermissionDenied(provider):
            return "transcription permission denied for provider '\(provider)'. Enable in System Settings → Privacy & Security → Speech Recognition, then re-run."

        case let .transcriptionProviderUnavailable(reason):
            return "transcription provider unavailable: \(reason)"

        case let .transcriptionConfigConflict(reason):
            return "transcription configuration conflict: \(reason)"

        case let .transcriptionKeyExpired(provider, expiredAt):
            let formatter = ISO8601DateFormatter()
            return "transcription API key for provider '\(provider)' expired at \(formatter.string(from: expiredAt))"
        }
    }

    // MARK: - Remediation (locked by design §2.1)

    /// User-facing actionable remediation guidance, printed on the line
    /// after the summary, indented two spaces (see `printToStderr()`).
    public var remediation: String {
        switch self {
        case let .missingRequiredConfig(key, _):
            return "Set --\(flagName(forConfigKey: key)) on the command line, or define \(key) in ./.env, ~/.tool-agents/ntakker-cli/.env, or your shell environment."

        case .invalidConfigValue:
            return "See 'ntakker-cli start --help' for the accepted values."

        case let .dotEnvParseError(path, _, _):
            return "Fix the syntax in \(path) (KEY=VALUE per line; # for comments; quoted values supported)."

        case .outputParentMissing:
            return "Create the parent directory (e.g. mkdir -p) before running ntakker-cli start."

        case .outputAlreadyExists:
            return "Pass --overwrite to replace it, or choose a different --output path."

        case .screenRecordingPermissionDenied:
            return "Open System Settings > Privacy & Security > Screen Recording and enable ntakker-cli, then re-run."

        case .screenRecordingPermissionNotDetermined:
            return "Approve the prompt that just appeared, then re-run ntakker-cli start. (Same-process state cannot be re-read; relaunch is required.)"

        case .microphonePermissionDenied:
            return "Open System Settings > Privacy & Security > Microphone and enable ntakker-cli, then re-run."

        case .microphonePermissionNotDetermined:
            return "Approve the prompt that just appeared, then re-run ntakker-cli start."

        case .microphonePermissionRestricted:
            return "Contact your administrator; the tool cannot record audio under this restriction."

        case .noInputDevicesAvailable:
            return "Connect a microphone or enable the built-in microphone in System Settings > Sound."

        case .micDeviceNotFound:
            return "Run 'ntakker-cli list-devices' to see the available UIDs and names."

        case .scStreamFailedToStart:
            return "Confirm Screen Recording permission is granted; try 'tccutil reset ScreenCapture' and re-grant."

        case .scStreamSilentStopExceeded:
            return "Restart the Mac, or rerun the recording. If the problem persists, please file an issue with the debug log."

        case .avCaptureFailedToStart:
            return "Confirm Microphone permission and that the selected device is available (see 'ntakker-cli list-devices')."

        case .micAECUnavailable:
            return "Re-run with --mic-aec off to use the raw mic source (no echo cancellation), or pick a different microphone with --mic-device."

        case .writerFailedToStart:
            return "Verify the output path is writable and the parent directory exists."

        case .writerFinalizationTimeout:
            return "The file may still be playable in VLC/ffmpeg thanks to fragmentation; re-run with shorter recordings if this recurs."

        case .finishWritingFailed:
            return "The output file is likely incomplete. Re-run the recording."

        case .ioError:
            return "Check disk space and write permissions on the output directory."

        case .unknown:
            return "Re-run with --log-level debug and report the log to the project maintainer."

        case .noActiveRecording:
            return "Start a recording with 'ntakker-cli start --detach' first."

        case .staleRecording:
            return "You can start a new recording with 'ntakker-cli start --detach'."

        case let .stopTimeout(pid, _):
            return "Inspect 'ps -p \(pid)'. If it is still finalizing, wait. If it is hung, escalate to 'kill -KILL \(pid)' (will lose the recording)."

        case .alreadyRecording:
            return "Run 'ntakker-cli stop' first or pass '--pid-file <path>' to use a different file."

        case .pidFileWriteFailed:
            return "Check that the parent directory exists and is writable; try passing '--pid-file <path>' to a writable location."

        case .transcriptionApiKeyMissing:
            return "Set the provider's API key (e.g. GOOGLE_API_KEY for gemini-live) in your shell, ~/.tool-agents/ntakker-cli/.env, or ./.env, then re-run."

        case .transcriptionPermissionDenied:
            return "Open System Settings > Privacy & Security > Speech Recognition and enable ntakker-cli, then re-run."

        case .transcriptionProviderUnavailable:
            return "Verify the provider configuration (model id, endpoint) and try again, or pass '--transcribe none' to disable live transcription."

        case .transcriptionConfigConflict:
            return "Adjust the conflicting flags (e.g. set --transcribe-source mixed when --mic none, or pass --transcribe none to disable transcription)."

        case .transcriptionKeyExpired:
            return "Renew the API key with the provider, update the value in your shell, ~/.tool-agents/ntakker-cli/.env, or ./.env, then re-run. Update NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT to the new expiry date."
        }
    }

    // MARK: - LocalizedError conformance

    public var errorDescription: String? { description }

    public var failureReason: String? {
        // The single-line summary is also our underlying-reason explanation.
        // Splitting it would force translation of duplicate strings without
        // adding information.
        description
    }

    public var recoverySuggestion: String? { remediation }

    // MARK: - stderr emission

    /// Writes the formatted error to stderr in the locked format:
    ///
    ///     ntakker-cli: error: <description>\n
    ///       <remediation>\n
    ///
    /// The remediation line is indented two spaces. Used by the CLI's
    /// top-level error handler before exiting with `exitCode`.
    public func printToStderr() {
        let line = "ntakker-cli: error: \(description)\n  \(remediation)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    // MARK: - Helpers

    /// Best-effort mapping from an env-var-style config key (e.g.
    /// `NTAKKER_OUTPUT`) to the corresponding CLI flag name (e.g. `output`)
    /// used in remediation messages. Strips a leading `NTAKKER_` prefix and
    /// lowercases-with-dashes the remainder.
    ///
    /// Special-cased keys whose CLI flag does not derive trivially from the
    /// env-var name are handled explicitly:
    ///
    ///   * `OUTPUT_PATH` (the only env-var key that pre-dates the
    ///     `NTAKKER_*` prefix convention; see R-19) → `output`.
    private func flagName(forConfigKey key: String) -> String {
        // Explicit overrides for env-var names that do not match the
        // generic `NTAKKER_<NAME>` → `--<name>` rule.
        switch key {
        case "OUTPUT_PATH":
            return "output"
        default:
            break
        }
        var stripped = key
        let prefix = "NTAKKER_"
        if stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
        }
        return stripped.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}

/// EVAL-2026-06-12 C7: `RecordingSession.split(nextOutput:)` completed —
/// the new segment is recording and the transcript follows it — but the
/// previous segment's file failed to finalize and may be incomplete.
/// Callers should treat the split as done and report the error.
public struct SplitPreviousSegmentError: Error, LocalizedError, CustomStringConvertible {
    public let underlying: Error

    public init(underlying: Error) {
        self.underlying = underlying
    }

    public var errorDescription: String? { description }

    public var description: String {
        "split: the new segment is recording, but the previous segment failed to finalize and may be incomplete: \(underlying.localizedDescription)"
    }
}
