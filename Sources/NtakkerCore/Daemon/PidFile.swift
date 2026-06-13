// NtakkerCore/Daemon/PidFile.swift — see plan-001 §J/§K (FR-25/FR-27/FR-28)
// and project-design.md §14 (PID file lifecycle).
//
// Phase J finalization (2026-04-26 scope expansion).
//
// `PidFile` owns the on-disk PID-file primitives used by both
// `RecordingSession` (write at recorder-open, remove on every clean
// exit path — FR-27) and the eventual `StopCommand` (read + isAlive +
// remove on stale — FR-26). Phase K's `Daemonizer` does NOT call into
// this file; the grandchild process still runs `RecordingSession`,
// which decides whether to materialize the PID file based on
// `options.runMode`.
//
// Concurrency: stateless `enum` namespace. All filesystem operations
// are atomic for the operations we need. Callers may invoke from any
// thread; multi-writer races on the same path are not a documented
// scenario (the PID file is owned by exactly one running daemon at
// any time).

import Darwin
import Foundation
import Logging

/// PID-file primitives for the detach-mode lifecycle.
///
/// All filesystem operations are best-effort logged at debug level.
/// `read` and `write` throw `NtakkerError` variants; `remove` swallows
/// and logs.
public enum PidFile {

    // MARK: - Read

    /// Reads the PID stored at `url`. Returns `nil` if the file does
    /// not exist (`ENOENT`). Trims surrounding whitespace before
    /// parsing. Empty / whitespace-only files are treated as `nil` so
    /// that a hand-truncated file behaves like a removed file.
    ///
    /// - Throws: `NtakkerError.ioError` if the file exists, has
    ///   non-empty content, but the content cannot be parsed as a
    ///   decimal `Int32`.
    public static func read(at url: URL) throws -> Int32? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NtakkerError.ioError(
                "failed to read PID file at \(url.path): \(error.localizedDescription)"
            )
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw NtakkerError.ioError(
                "PID file at \(url.path) is not valid UTF-8"
            )
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let pid = Int32(trimmed) else {
            throw NtakkerError.ioError(
                "PID file at \(url.path) does not contain a decimal integer (got: '\(trimmed)')"
            )
        }
        return pid
    }

    // MARK: - Write

    /// Writes `pid` to `url` at mode `0600`. Overwrites any existing
    /// file at the same path. Ensures the parent directory exists; if
    /// it does not, throws.
    ///
    /// The on-disk format is the decimal PID followed by a single
    /// trailing newline so that `cat <file>` is human-friendly. (The
    /// `read` side trims whitespace, so the trailing newline is
    /// invisible to readers.)
    ///
    /// - Parameters:
    ///   - url: Destination path.
    ///   - pid: PID value to write. Defaults to the current process's
    ///     PID — the typical caller (`RecordingSession.run` in detach
    ///     mode) wants `getpid()`.
    /// - Throws: `NtakkerError.pidFileWriteFailed(path:reason:)` on any
    ///   filesystem failure.
    public static func write(
        at url: URL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        let parentExists = fm.fileExists(atPath: parent.path, isDirectory: &isDir)
        guard parentExists, isDir.boolValue else {
            throw NtakkerError.pidFileWriteFailed(
                path: url.path,
                reason: "parent directory does not exist: \(parent.path)"
            )
        }

        let body = "\(pid)\n"
        guard let data = body.data(using: .utf8) else {
            throw NtakkerError.pidFileWriteFailed(
                path: url.path,
                reason: "could not encode PID as UTF-8"
            )
        }

        do {
            // Use atomic write via Data.write to avoid leaving a
            // partial file on disk if the process is killed mid-write.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw NtakkerError.pidFileWriteFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }

        // Defensive chmod 0600 — `Data.write` does not let us specify
        // the mode directly, and umask on the daemonized process can
        // be permissive (Daemonizer sets umask(0) per design §14.2).
        do {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw NtakkerError.pidFileWriteFailed(
                path: url.path,
                reason: "chmod 0600 failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Remove

    /// Best-effort remove. Idempotent — a missing file is not an
    /// error. Any other failure is logged at debug level (when a
    /// logger is supplied) and swallowed; the lifecycle contract in
    /// design §14 explicitly forbids propagating remove-failure as a
    /// session result.
    public static func remove(at url: URL, logger: Logger? = nil) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            logger?.debug("PidFile.remove: failed to remove \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Liveness

    /// Probes `pid` with `kill(pid, 0)` to determine whether a process
    /// with that PID is currently running.
    ///
    /// - Returns: `true` if `kill(pid, 0)` returned 0 (process alive
    ///   and signallable by us) OR returned `EPERM` (process exists
    ///   but we don't own it — still alive). `false` if `kill` set
    ///   `errno == ESRCH` (no such process).
    /// - Throws: `NtakkerError.ioError` for any other unexpected
    ///   `errno`.
    public static func isAlive(pid: Int32) throws -> Bool {
        // `kill(pid, 0)` performs no signal delivery; it only checks
        // permissions and existence. The standard POSIX semantics are:
        //   * returns 0 if the signal could be delivered (process
        //     exists and we own it).
        //   * returns -1 with errno == ESRCH if no process exists.
        //   * returns -1 with errno == EPERM if the process exists
        //     but we lack permission to signal it (different uid).
        //   * other errno values are exotic (EINVAL only on a bad
        //     signal number, which 0 is not).
        let rc = kill(pid, 0)
        if rc == 0 {
            return true
        }
        let err = errno
        switch err {
        case ESRCH:
            return false
        case EPERM:
            // Treat as alive (consistent with design §14.1: "treat as
            // alive; refuse to clobber"). The current Phase J caller
            // — RecordingSession's already-recording guard — wants
            // this as a refusal-to-start signal.
            return true
        default:
            throw NtakkerError.ioError(
                "kill(\(pid), 0) failed with errno \(err): \(String(cString: strerror(err)))"
            )
        }
    }
}
