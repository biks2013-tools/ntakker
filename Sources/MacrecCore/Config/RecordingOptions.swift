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
        stopTimeout: TimeInterval = RecordingOptions.defaultStopTimeout
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
            stopTimeout: stopTimeout
        )
    }
}
