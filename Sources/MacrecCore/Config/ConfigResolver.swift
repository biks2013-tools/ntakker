// MacrecCore/Config/ConfigResolver.swift — see project-design.md §2.4 / §5
// Phase B — Bootstrap + Config (FR-12, FR-14, FR-15, FR-25, FR-26, FR-29)

import Foundation

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
    /// - Throws: `MacrecError.missingRequiredConfig` if `output` cannot
    ///   be resolved from any source. `MacrecError.invalidConfigValue`
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
            throw MacrecError.missingRequiredConfig(
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
            throw MacrecError.invalidConfigValue(
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
            stopTimeout: stopTimeout
        )
    }

    // MARK: - Env-var key constants (mapping table)

    /// Canonical env-var names per the Phase B coder briefing.
    public enum Keys {
        public static let output       = "OUTPUT_PATH"
        public static let format       = "MACREC_FORMAT"
        public static let layout       = "MACREC_LAYOUT"
        public static let micChannel   = "MACREC_MIC_CHANNEL"
        public static let sampleRate   = "MACREC_SAMPLE_RATE"
        public static let bitDepth     = "MACREC_BIT_DEPTH"
        public static let bitrate      = "MACREC_BITRATE"
        public static let micDevice    = "MACREC_MIC_DEVICE"
        public static let logLevel     = "MACREC_LOG_LEVEL"
        public static let maxDuration  = "MACREC_MAX_DURATION"
        public static let overwrite    = "MACREC_OVERWRITE"
        public static let detach       = "MACREC_DETACH"
        public static let pidFile      = "MACREC_PID_FILE"
        public static let logFile      = "MACREC_LOG_FILE"
        public static let stopTimeout  = "MACREC_STOP_TIMEOUT"
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
        throw MacrecError.invalidConfigValue(
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
            throw MacrecError.invalidConfigValue(
                key: key, value: raw, expected: "integer in {\(allowed.map(String.init).joined(separator: ", "))}"
            )
        }
        guard allowed.contains(v) else {
            throw MacrecError.invalidConfigValue(
                key: key, value: raw, expected: "one of: \(allowed.map(String.init).joined(separator: ", "))"
            )
        }
        return v
    }

    private func parseBitrate(raw: String?) throws -> Int {
        guard let raw = raw else { return 192_000 }
        guard let v = Int(raw) else {
            throw MacrecError.invalidConfigValue(
                key: Keys.bitrate, value: raw,
                expected: "integer (kbps in [64, 320] or bits-per-second in [64000, 320000])"
            )
        }
        // Accept both kbps (e.g. 192) and bps (e.g. 192000) per FR-17.
        let bps: Int = (v >= 1_000) ? v : v * 1_000
        guard (64_000...320_000).contains(bps) else {
            throw MacrecError.invalidConfigValue(
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
            throw MacrecError.invalidConfigValue(
                key: key, value: raw, expected: "positive number of seconds"
            )
        }
        guard v > 0 else {
            throw MacrecError.invalidConfigValue(
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
            throw MacrecError.invalidConfigValue(
                key: key, value: raw,
                expected: "positive number of seconds (<= \(Int(upperBound)))"
            )
        }
        guard v > 0, v <= upperBound else {
            throw MacrecError.invalidConfigValue(
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
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            throw MacrecError.invalidConfigValue(
                key: key, value: raw,
                expected: "boolean (true/false, 1/0, yes/no)"
            )
        }
    }
}
