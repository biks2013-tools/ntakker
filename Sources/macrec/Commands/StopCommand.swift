// macrec/Commands/StopCommand.swift — see project-design.md §9.2a, §14.3
// Phase K finalization (FR-26, AC-17/AC-18/AC-19).
//
// Stops a detached recording started with `macrec start --detach`. The
// decision tree (project-design.md §14.3) has four cases:
//
//   * No PID file (ENOENT) → `MacrecError.noActiveRecording`, exit 78.
//   * PID file with stale PID (kill(0) → ESRCH) → remove the file,
//     throw `MacrecError.staleRecording`, exit 75.
//   * PID file with live PID → SIGTERM, poll kill(0) every 100 ms up
//     to `--stop-timeout`. On clean exit, remove the file (best-
//     effort — the daemon should remove its own file) and exit 0.
//     On timeout, throw `MacrecError.stopTimeout`, exit 70.
//   * PID file with malformed content → treated identically to
//     stale: remove and throw `MacrecError.staleRecording(0, ...)`.
//
// `stop` does NOT call `PermissionGate` — TCC is not relevant when we
// are only reading a PID file and sending a signal (design §8.4).
//
// Configuration resolution: we reuse `ConfigResolver` so the four-
// source precedence chain (CLI > local .env > user .env > shell env)
// applies uniformly. Because `ConfigResolver.resolve` requires
// `OUTPUT_PATH`, we inject a placeholder ("/dev/null") into the CLI
// overrides; we then discard everything except `pidFile` and
// `stopTimeout`. This preserves the precedence semantics without
// duplicating the resolver logic.

import ArgumentParser
import Darwin
import Foundation
import Logging
import MacrecCore

public struct StopCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a detached recording started with 'macrec start --detach'."
    )

    @Option(name: .long, help: "PID file path of the detached recording. Default: ~/.tool-agents/macrec/macrec.pid. Env: MACREC_PID_FILE.")
    public var pidFile: String?

    @Option(name: .long, help: "Seconds to wait for the recording process to exit cleanly after SIGTERM. Default: 35. Env: MACREC_STOP_TIMEOUT.")
    public var stopTimeout: Double?

    public init() {}

    // MARK: - Execution

    public func run() async throws {
        // ---- Step 1: bootstrap ~/.tool-agents/macrec/ (FR-13). -------
        // Same as every other subcommand: every invocation must be
        // safe to run from a fresh user account.
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

        // ---- Step 2: resolve pidFile + stopTimeout. ------------------
        // We reuse `ConfigResolver` but pass a placeholder OUTPUT_PATH
        // (the resolver requires it; `stop` doesn't actually need a
        // real output). We then discard everything except the two
        // values we care about.
        let resolved: RecordingOptions
        do {
            var overrides = buildCLIOverrides()
            // Only inject the placeholder if the user has not already
            // supplied OUTPUT_PATH via env / .env. (We never want to
            // hide a misconfigured environment from a misuse error in
            // start; for stop the placeholder is harmless either way
            // since we ignore the resolved `output`.)
            if overrides[ConfigResolver.Keys.output] == nil,
               ProcessInfo.processInfo.environment[ConfigResolver.Keys.output] == nil
            {
                overrides[ConfigResolver.Keys.output] = "/dev/null"
            }
            resolved = try ConfigResolver(toolName: "macrec").resolve(cliOverrides: overrides)
        } catch let err as MacrecError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        // Bootstrap the logger AFTER resolution so we honor the
        // resolved log level (e.g. `MACREC_LOG_LEVEL=debug` in the
        // user's `.env` flips on debug logging for stop, which is
        // useful when diagnosing PID-file races).
        LoggerFactory.bootstrap(level: resolved.logLevel)
        let logger = LoggerFactory.make("macrec.cli.stop")

        let pidFileURL = resolved.pidFile
        let timeoutSeconds = resolved.stopTimeout

        // ---- Step 3: read the PID file. ------------------------------
        let storedPid: Int32?
        do {
            storedPid = try PidFile.read(at: pidFileURL)
        } catch let err as MacrecError {
            // Malformed file → treated identically to stale per §14.3.
            // Remove and throw `staleRecording(0, ...)`.
            logger.warning("PID file at \(pidFileURL.path) is malformed: \(err.description); treating as stale")
            PidFile.remove(at: pidFileURL, logger: logger)
            let stale = MacrecError.staleRecording(pid: 0, pidFilePath: pidFileURL.path)
            stale.printToStderr()
            throw ExitCode(stale.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        guard let pid = storedPid else {
            // ENOENT → no active recording.
            let err = MacrecError.noActiveRecording(pidFilePath: pidFileURL.path)
            err.printToStderr()
            throw ExitCode(err.exitCode)
        }

        // ---- Step 4: probe liveness. ---------------------------------
        let alive: Bool
        do {
            alive = try PidFile.isAlive(pid: pid)
        } catch let err as MacrecError {
            // Conservative: surface the underlying ioError, exit 1.
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        if !alive {
            // Stale PID → remove the file, surface staleRecording.
            logger.warning("PID \(pid) at \(pidFileURL.path) is no longer running; removing stale PID file")
            PidFile.remove(at: pidFileURL, logger: logger)
            let stale = MacrecError.staleRecording(pid: pid, pidFilePath: pidFileURL.path)
            stale.printToStderr()
            throw ExitCode(stale.exitCode)
        }

        // ---- Step 5: SIGTERM. ----------------------------------------
        let killRC = kill(pid, SIGTERM)
        if killRC != 0 {
            let reason = String(cString: strerror(errno))
            let err = MacrecError.unknown("kill(\(pid), SIGTERM) failed: \(reason)")
            err.printToStderr()
            throw ExitCode(err.exitCode)
        }
        logger.info("sent SIGTERM to PID \(pid); polling for clean exit (timeout=\(timeoutSeconds)s)")

        // ---- Step 6: poll kill(pid, 0) every 100 ms. -----------------
        let pollIntervalNs: UInt64 = 100_000_000  // 100 ms
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var exited = false
        while Date() < deadline {
            try await Task.sleep(nanoseconds: pollIntervalNs)
            let probe = kill(pid, 0)
            if probe == 0 {
                continue  // still alive
            }
            // probe == -1 — inspect errno.
            let err = errno
            if err == ESRCH {
                exited = true
                break
            }
            // EPERM means the process exists but we don't own it —
            // SIGTERM definitely went somewhere (or we wouldn't have
            // gotten this far), but the kernel still considers the
            // process alive. Treat as "still alive" for the purpose
            // of the poll loop.
            if err == EPERM {
                continue
            }
            // Any other errno is unexpected; bail.
            let reason = String(cString: strerror(err))
            let macErr = MacrecError.unknown("kill(\(pid), 0) probe failed: \(reason)")
            macErr.printToStderr()
            throw ExitCode(macErr.exitCode)
        }

        if !exited {
            // Timeout fired before the process exited.
            let err = MacrecError.stopTimeout(pid: pid, seconds: Int(timeoutSeconds))
            err.printToStderr()
            throw ExitCode(err.exitCode)
        }

        // ---- Step 7: verify PID file removed. ------------------------
        // The daemon's `RecordingSession` removes its own PID file on
        // every clean exit path. If it is still there, log a warning
        // and remove it ourselves so the user can immediately re-run
        // `start --detach`.
        do {
            if try PidFile.read(at: pidFileURL) != nil {
                logger.warning("daemon did not clean up its own PID file at \(pidFileURL.path); removing it")
                PidFile.remove(at: pidFileURL, logger: logger)
            }
        } catch {
            // Read failed (probably malformed/empty after the daemon
            // partially cleaned up). Remove unconditionally.
            logger.debug("PidFile.read after stop returned: \(error.localizedDescription); removing best-effort")
            PidFile.remove(at: pidFileURL, logger: logger)
        }

        logger.info("stop complete; PID \(pid) exited cleanly")
    }

    // MARK: - Helpers

    private func buildCLIOverrides() -> [String: String] {
        var o: [String: String] = [:]
        if let v = pidFile     { o[ConfigResolver.Keys.pidFile] = v }
        if let v = stopTimeout { o[ConfigResolver.Keys.stopTimeout] = String(v) }
        return o
    }
}
