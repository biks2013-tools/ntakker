// NtakkerCore/Logging/LoggerFactory.swift — see project-design.md §2.5, §6,
// §15.13 (UI dual-backend logging).
//
// `swift-log` bootstrap and per-subsystem logger vendor.
//
// Two bootstrap entry points:
//
// 1. `bootstrap(level:)` — CLI surface (Phase C, plan-001). Installs a
//    `StreamLogHandler.standardError` handler. The CLI's
//    `Daemonizer` is responsible for swapping the underlying file
//    descriptor when running detached (FR-29) — this factory does NOT
//    open files for the CLI.
//
// 2. `bootstrap(subsystem:fileURL:levelString:)` — UI surface (Phase H,
//    plan-002 §3 / project-design §15.13). Installs a multiplexed
//    handler that simultaneously routes every log line to:
//      - macOS unified logging (`os_log`/`OSLog`) under the supplied
//        subsystem (e.g. `com.local.ntakker`), so logs appear in
//        Console.app and via `log stream --subsystem …`.
//      - A plain-text append-only file at `fileURL` (mode `0600`),
//        formatted as
//          `2026-04-26T19:30:00.123 [info] [ntakker-cli.ui.app] message`.
//
// Both entry points share the SAME one-shot bootstrap guard
// (swift-log's `LoggingSystem.bootstrap` traps on second invocation).
// The UI overload also retains a mutable `LogLevelBox` so the hidden
// debug menu (`UILoggingMenu`) can change the level at runtime without
// re-bootstrapping `LoggingSystem` (which would trap).

import Foundation
import Logging
// `os.log` brings the legacy `os_log(_:log:type:_:)` C-API and `OSLog`
// type — both of which we use for the OSLog backend. It also re-exports
// the new `os.Logger` struct, which clashes with `Logging.Logger` in
// unqualified type-position. To dodge the clash without losing the
// `os_log`/`OSLog` symbols, every reference to the swift-log logger
// type in this file is fully-qualified as `Logging.Logger`.
import os.log

// MARK: - LogLevel (CLI-facing)
//
// The CLI's `LogLevel` type itself is declared in `RecordingOptions.swift`
// (Phase B) so that `RecordingOptions` does not need to import `Logging`.
// This file owns the bridge to `Logging.Logger.Level` and the design-§2.5
// level mapping (`.quiet → .warning`, `.info → .info`, `.debug → .debug`).
//
// Authoritative mapping; Phase B references this from RecordingOptions.

extension LogLevel {
    /// Mapping into `swift-log`'s level enum. Per design §2.5:
    /// `.quiet → .warning`, `.info → .info`, `.debug → .debug`.
    public var loggingLevel: Logging.Logger.Level {
        switch self {
        case .quiet: return .warning
        case .info:  return .info
        case .debug: return .debug
        }
    }
}

// MARK: - LoggerFactory

/// Errors raised by `LoggerFactory`. Only the UI overload throws — the
/// CLI overload is infallible.
public enum LoggerFactoryError: Error, CustomStringConvertible, Sendable {
    /// `NTAKKER_UI_LOG_LEVEL` (or any string-typed level argument) was
    /// not one of `info | debug | trace`.
    case invalidLogLevel(String)

    /// File-backed log sink could not be opened (file create / chmod /
    /// open failure). The UI bootstrap surfaces this on stderr but
    /// does NOT throw — the OSLog backend stays installed so the app
    /// keeps running with reduced visibility. Exposed for tests.
    case fileSinkOpenFailed(path: String, underlying: String)

    public var description: String {
        switch self {
        case .invalidLogLevel(let raw):
            return "invalid log level '\(raw)' (allowed: info | debug | trace)"
        case .fileSinkOpenFailed(let path, let underlying):
            return "failed to open log file at \(path): \(underlying)"
        }
    }
}

public enum LoggerFactory {

    // MARK: - CLI bootstrap (plan-001 Phase C)

    /// Bootstraps `swift-log` with a stderr handler at the requested
    /// level. Used by the CLI. Call exactly once at process start
    /// (`main.swift`); subsequent calls are no-ops so tests can safely
    /// re-invoke.
    ///
    /// This signature is preserved unchanged for backward compatibility
    /// with every existing CLI call-site (e.g. `StartCommand`,
    /// `StopCommand`, `CheckPermissionsCommand`, `ListDevicesCommand`).
    public static func bootstrap(level: LogLevel) {
        BootstrapState.shared.bootstrapStderrIfNeeded(level: level.loggingLevel)
    }

    // MARK: - UI bootstrap (plan-002 Phase H, project-design §15.13)

    /// Bootstraps `swift-log` for the UI app with a dual backend:
    /// macOS unified logging (`OSLog`) + an append-only file at
    /// `fileURL`. Both sinks receive every emitted log line.
    ///
    /// The first call to this overload installs the multiplexed handler
    /// via `LoggingSystem.bootstrap`. Subsequent calls do NOT re-install
    /// the handler (swift-log traps on second `LoggingSystem.bootstrap`)
    /// — they only update the shared level. This is exactly the
    /// behaviour the hidden debug menu (`UILoggingMenu`) needs: pick
    /// a new level → call `bootstrap(subsystem:fileURL:levelString:)`
    /// again with the same `subsystem`/`fileURL` and the new
    /// `levelString` → all existing `Logger` instances start respecting
    /// the new level on their next call.
    ///
    /// - Parameters:
    ///   - subsystem: macOS unified-logging subsystem string. For the
    ///     menu-bar app this is `"com.local.ntakker"` (the UI's
    ///     CFBundleIdentifier; mirrors the convention in §15.13).
    ///   - fileURL: Optional path to a plain-text log file. When
    ///     non-nil, the file is opened in append mode and `chmod`ed
    ///     to `0600` (NFR-16). When nil, only the OSLog backend is
    ///     installed.
    ///   - levelString: Optional level name. Allowed values:
    ///     `"info"`, `"debug"`, `"trace"`. Case-insensitive. When
    ///     `nil` defaults to `.info` — this is an explicit, documented
    ///     exception to the project's "no-fallback" rule and applies
    ///     ONLY to diagnostic verbosity (see
    ///     `~/.tool-agents/ntakker/.env`). When the string is
    ///     present but unrecognized, throws
    ///     `LoggerFactoryError.invalidLogLevel`.
    /// - Throws: `LoggerFactoryError.invalidLogLevel` if `levelString`
    ///   is non-nil and not one of `info | debug | trace`.
    public static func bootstrap(
        subsystem: String,
        fileURL: URL?,
        levelString: String?
    ) throws {
        let level = try Self.parseLevel(levelString)
        BootstrapState.shared.bootstrapDualIfNeeded(
            subsystem: subsystem,
            fileURL: fileURL,
            level: level
        )
    }

    /// Parses a level string into a `Logging.Logger.Level`. Public so callers
    /// (tests, the `UILoggingMenu`) can validate without bootstrapping.
    public static func parseLevel(_ raw: String?) throws -> Logging.Logger.Level {
        guard let raw, !raw.isEmpty else { return .info }
        switch raw.lowercased() {
        case "info":  return .info
        case "debug": return .debug
        case "trace": return .trace
        default:      throw LoggerFactoryError.invalidLogLevel(raw)
        }
    }

    // MARK: - Logger vending

    /// Returns a `Logger` labelled with the given subsystem string.
    ///
    /// Subsystem string convention (design §6.2 — used as a prefix so that
    /// `grep ntakker-cli.capture` matches every capture-related log line):
    ///
    ///   ntakker-cli.cli, ntakker-cli.config, ntakker-cli.bootstrap,
    ///   ntakker-cli.permissions, ntakker-cli.permissions.screen,
    ///   ntakker-cli.permissions.microphone, ntakker-cli.devices,
    ///   ntakker-cli.capture.system, ntakker-cli.capture.system.watchdog,
    ///   ntakker-cli.capture.mic, ntakker-cli.capture.fake,
    ///   ntakker-cli.aligner, ntakker-cli.mixer,
    ///   ntakker-cli.recorder.m4a, ntakker-cli.recorder.wav, ntakker-cli.recorder.caf,
    ///   ntakker-cli.session, ntakker-cli.signal, ntakker-cli.daemon, ntakker-cli.pidfile.
    ///
    /// UI labels (project-design §15.13): `ntakker-cli.ui.app`,
    /// `ntakker-cli.ui.statusItem`, `ntakker-cli.ui.popover`, `ntakker-cli.ui.controller`,
    /// `ntakker-cli.ui.session`, `ntakker-cli.ui.permissions`, `ntakker-cli.ui.devices`.
    ///
    /// These are not exported as constants on purpose — owners pick their
    /// own subsystem strings to keep this file from becoming a coupling
    /// hub.
    public static func make(_ subsystem: String) -> Logging.Logger {
        Logging.Logger(label: subsystem)
    }
}

// MARK: - Bootstrap-once guard

/// Encapsulates the "bootstrap exactly once" invariant. `swift-log`'s
/// `LoggingSystem.bootstrap` traps when called more than once per
/// process, so we gate it behind a lock.
///
/// Also owns the shared, mutable `LogLevelBox` consulted by every
/// installed handler on every emit — that allows the UI's hidden debug
/// menu to change the level at runtime without re-calling
/// `LoggingSystem.bootstrap`.
private final class BootstrapState: @unchecked Sendable {
    static let shared = BootstrapState()

    private let lock = NSLock()
    private var didBootstrap = false

    /// Shared, mutable level cell read on every log emit. Stored so the
    /// UI's hidden debug menu can flip the verbosity at runtime.
    fileprivate let levelBox = LogLevelBox(level: .info)

    private init() {}

    /// CLI variant — stderr only. Installs a `StreamLogHandler.standardError`
    /// at the supplied level. Idempotent.
    func bootstrapStderrIfNeeded(level: Logging.Logger.Level) {
        lock.lock()
        defer { lock.unlock() }

        if didBootstrap {
            // Subsequent CLI bootstraps just nudge the level. (The CLI
            // doesn't really need this — every CLI command bootstraps
            // exactly once at the start of `run()` — but it keeps the
            // tests' "second call is safe" contract intact.)
            levelBox.level = level
            return
        }

        levelBox.level = level
        let box = levelBox
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = box.level
            return DynamicLevelHandler(wrapped: handler, levelBox: box)
        }
        didBootstrap = true
    }

    /// UI variant — OSLog + optional file. Installs a multiplexed
    /// handler at the supplied level. Idempotent: subsequent calls only
    /// update the shared level (so `UILoggingMenu` can change verbosity
    /// at runtime).
    func bootstrapDualIfNeeded(
        subsystem: String,
        fileURL: URL?,
        level: Logging.Logger.Level
    ) {
        lock.lock()
        defer { lock.unlock() }

        if didBootstrap {
            levelBox.level = level
            return
        }

        levelBox.level = level

        // Open the file sink up-front so handler creation is cheap.
        let fileSink: FileLogSink? = fileURL.flatMap { url in
            do {
                return try FileLogSink.open(at: url)
            } catch {
                // We can't use a Logger yet (LoggingSystem isn't
                // bootstrapped). Surface the error on stderr so the
                // operator sees it, then fall through with no file
                // sink — the OSLog backend is still wired so we don't
                // lose visibility.
                FileHandle.standardError.write(Data(
                    "ntakker: failed to open log file at \(url.path): \(error)\n".utf8
                ))
                return nil
            }
        }

        let box = levelBox
        let capturedSubsystem = subsystem

        LoggingSystem.bootstrap { label in
            let osHandler = OSLogHandler(
                subsystem: capturedSubsystem,
                category: label,
                levelBox: box
            )
            if let fileSink {
                let fileHandler = FileLogHandler(
                    label: label,
                    sink: fileSink,
                    levelBox: box
                )
                return MultiplexLogHandler([osHandler, fileHandler])
            } else {
                return osHandler
            }
        }
        didBootstrap = true
    }
}

// MARK: - Shared mutable level cell
//
// `Logging.Logger.Level` is `Sendable`. `LogLevelBox` exposes thread-safe get/set
// so every installed handler can read the current level on every emit
// (handlers are constructed once per label by swift-log; we cannot mutate
// the wrapped handler's `logLevel` field from outside, so the handler
// reads through the box instead).

private final class LogLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Logging.Logger.Level

    init(level: Logging.Logger.Level) {
        self._level = level
    }

    var level: Logging.Logger.Level {
        get {
            lock.lock(); defer { lock.unlock() }
            return _level
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _level = newValue
        }
    }
}

// MARK: - DynamicLevelHandler (CLI stderr)
//
// Wraps a stock `StreamLogHandler` so the CLI can also benefit from
// runtime-mutable level (mainly for parity with the UI; the CLI itself
// never mutates the box after `bootstrap(level:)`).

private struct DynamicLevelHandler: LogHandler {
    var wrapped: StreamLogHandler
    let levelBox: LogLevelBox

    var metadata: Logging.Logger.Metadata {
        get { wrapped.metadata }
        set { wrapped.metadata = newValue }
    }

    var logLevel: Logging.Logger.Level {
        get { levelBox.level }
        // Per LogHandler contract this setter must exist. We honour
        // per-handler overrides by writing through to the box — but in
        // practice swift-log only writes via `Logger.logLevel`, which
        // we treat as a global override here.
        set { levelBox.level = newValue }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { wrapped[metadataKey: key] }
        set { wrapped[metadataKey: key] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= levelBox.level else { return }
        wrapped.log(event: event)
    }
}

// MARK: - OSLogHandler (UI Console.app backend)

/// `swift-log` `LogHandler` that forwards to macOS unified logging.
///
/// Each `Logging.Logger.Level` maps to an `OSLogType`:
///   .trace, .debug → .debug
///   .info, .notice → .info
///   .warning       → .default
///   .error         → .error
///   .critical      → .fault
///
/// One `OSLog` instance is created per (subsystem, category) pair.
private struct OSLogHandler: LogHandler {
    let osLog: OSLog
    let levelBox: LogLevelBox
    var metadata: Logging.Logger.Metadata = [:]

    init(subsystem: String, category: String, levelBox: LogLevelBox) {
        self.osLog = OSLog(subsystem: subsystem, category: category)
        self.levelBox = levelBox
    }

    var logLevel: Logging.Logger.Level {
        get { levelBox.level }
        set { levelBox.level = newValue }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= levelBox.level else { return }
        let osLogType: OSLogType
        switch event.level {
        case .trace, .debug: osLogType = .debug
        case .info, .notice: osLogType = .info
        case .warning:       osLogType = .default
        case .error:         osLogType = .error
        case .critical:      osLogType = .fault
        }
        // Combine the message with any per-call metadata so it is
        // visible in Console.app.
        let merged = Self.merge(self.metadata, event.metadata)
        let rendered: String
        if merged.isEmpty {
            rendered = event.message.description
        } else {
            let pairs = merged.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            rendered = "\(event.message.description) [\(pairs)]"
        }
        // %{public}@ — we are explicit about not redacting, since these
        // are application logs not PII.
        os_log("%{public}@", log: osLog, type: osLogType, rendered)
    }

    private static func merge(_ a: Logging.Logger.Metadata,
                              _ b: Logging.Logger.Metadata?) -> Logging.Logger.Metadata {
        guard let b, !b.isEmpty else { return a }
        var out = a
        for (k, v) in b { out[k] = v }
        return out
    }
}

// MARK: - FileLogHandler (UI per-app log file)

/// `swift-log` `LogHandler` that appends formatted lines to a shared
/// `FileLogSink`. Format (project-design §15.13 / Phase H spec):
///
///     2026-04-26T19:30:00.123 [info] [ntakker-cli.ui.app] message text
private struct FileLogHandler: LogHandler {
    let label: String
    let sink: FileLogSink
    let levelBox: LogLevelBox
    var metadata: Logging.Logger.Metadata = [:]

    var logLevel: Logging.Logger.Level {
        get { levelBox.level }
        set { levelBox.level = newValue }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= levelBox.level else { return }
        let timestamp = Self.timestampFormatter.string(from: Date())
        let merged = Self.merge(self.metadata, event.metadata)
        let suffix: String
        if merged.isEmpty {
            suffix = ""
        } else {
            let pairs = merged.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            suffix = " [\(pairs)]"
        }
        let renderedLine = "\(timestamp) [\(event.level)] [\(label)] \(event.message)\(suffix)\n"
        sink.append(renderedLine)
    }

    /// ISO-8601 with millisecond precision, fixed UTC offset, fixed
    /// locale. Constructed once and stored statically because
    /// `ISO8601DateFormatter` allocations are non-trivial under
    /// log-heavy workloads.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        return f
    }()

    private static func merge(_ a: Logging.Logger.Metadata,
                              _ b: Logging.Logger.Metadata?) -> Logging.Logger.Metadata {
        guard let b, !b.isEmpty else { return a }
        var out = a
        for (k, v) in b { out[k] = v }
        return out
    }
}

// MARK: - FileLogSink (shared append-only writer)

/// Thread-safe, append-only writer backed by a single `FileHandle`.
/// Created once at bootstrap and shared by every `FileLogHandler` so
/// they serialize writes through one lock and one fd.
///
/// Permission discipline (NFR-16):
///   - Parent directory is owned/created by `ToolAgentsBootstrap.ensure`
///     at mode `0700` (NOT touched here — we do not want to downgrade
///     it).
///   - The log file itself is created at mode `0600` if missing, and
///     defensively `chmod 0600`'d on every open even if it pre-exists.
private final class FileLogSink: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    private init(handle: FileHandle) {
        self.handle = handle
    }

    static func open(at url: URL) throws -> FileLogSink {
        let fm = FileManager.default
        let path = url.path

        if !fm.fileExists(atPath: path) {
            // Create empty file first so we can chmod it before writing.
            let created = fm.createFile(
                atPath: path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                throw LoggerFactoryError.fileSinkOpenFailed(
                    path: path,
                    underlying: "FileManager.createFile returned false"
                )
            }
        }

        // Defensive re-chmod regardless of whether we just created the
        // file or it already existed (NFR-16 requires 0600).
        do {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            throw LoggerFactoryError.fileSinkOpenFailed(
                path: path,
                underlying: "chmod 0600 failed: \(error.localizedDescription)"
            )
        }

        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw LoggerFactoryError.fileSinkOpenFailed(
                path: path,
                underlying: "FileHandle(forWritingAtPath:) returned nil"
            )
        }
        // Append mode: seek to end on every open.
        handle.seekToEndOfFile()
        return FileLogSink(handle: handle)
    }

    func append(_ line: String) {
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        // FileHandle.write is documented to throw on macOS 11+ but
        // legacy callers still see the non-throwing variant. Use the
        // typed throwing variant where available; if it raises, swallow
        // the error to keep logging best-effort (a logging path that
        // crashes the app is worse than a silent loss).
        do {
            if #available(macOS 10.15.4, *) {
                try handle.write(contentsOf: data)
            } else {
                handle.write(data)
            }
        } catch {
            // Best-effort: log loss is preferable to log-induced crash.
        }
    }
}
