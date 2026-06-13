// NtakkerCore/Daemon/Daemonizer.swift — see plan-001 §K (FR-25, R-14)
// and project-design.md §14.2 (double-fork pseudo-Swift).
//
// Phase K finalization.
//
// Performs the canonical Stevens APUE §13.3 double-fork sequence so the
// caller can return a shell prompt to the invoking user immediately
// while the recording continues in the background. Only the final
// "grandchild" process returns from `detach(_:)`; the parent and
// intermediate parent both `_exit(0)` from inside the function.
//
// CRITICAL: This function MUST be called BEFORE any thread is created
// in the process. `fork()` after thread creation is unsafe on macOS:
// only the calling thread survives in the child, so any framework that
// owns a worker thread (libdispatch, Foundation runloops, AVFoundation,
// etc.) will be left in an indeterminate state. The CLI calls
// `detach()` BEFORE constructing `RecordingSession` so that no
// `DispatchSource`, GCD queue, AVCaptureSession, or `SCStream` has yet
// spun up its threads.
//
// Why `_exit(0)` and not `exit(0)`? `exit()` runs every registered
// `atexit` handler and the Swift runtime / Foundation register handlers
// that flush logging, run deinitializers, and (in some configurations)
// call `objc_terminate()`. Running these in the parent forks would (a)
// flush log output to the parent's inherited-but-soon-to-be-redirected
// stderr, polluting the user's terminal, and (b) double-run any
// deinitializer that has live state captured by the soon-to-be-
// grandchild. `_exit()` skips all of that and goes straight to the
// kernel `exit(2)` syscall. This is the standard Stevens APUE §13.3
// rule for daemonization.

import Darwin
import Foundation

// MARK: - libc bridges
//
// Apple's Swift overlay for `Darwin` marks `fork()` as `@available(*,
// unavailable, message: "Please use threads or posix_spawn*()")`. That
// guidance is correct for application code but does not apply to the
// canonical Stevens APUE §13.3 daemonization sequence: we *must* call
// `fork()` directly (twice) and we *must* do so before any framework
// thread has been created. We therefore re-declare the symbol via
// `@_silgen_name` to bypass the unavailability annotation. This is the
// standard, documented workaround in the Swift / SwiftPM communities
// when a process genuinely needs `fork()` (e.g. server frameworks
// implementing privilege separation).
@_silgen_name("fork") private func _ntakker_fork() -> pid_t

/// Performs the canonical POSIX double-fork sequence to detach the
/// running process from the controlling terminal. After successful
/// return (in the grandchild), `stdin` is connected to `/dev/null` and
/// `stdout`/`stderr` are redirected to the configured log file.
public enum Daemonizer {

    /// Configuration for `Daemonizer.detach`. All paths are resolved
    /// by the caller (no tilde expansion is performed here).
    public struct Options: Sendable {
        /// PID file path. Recorded only for logging / observability;
        /// `Daemonizer.detach` does NOT write the PID file itself —
        /// `RecordingSession` owns the lifecycle hook (FR-27).
        public let pidFile: URL

        /// Log file destination. Opened with `O_WRONLY | O_CREAT |
        /// O_APPEND` at mode `0600`. `stdout` and `stderr` of the
        /// grandchild are redirected to this file.
        public let logFile: URL

        /// Working directory for the grandchild. Typically `/`. We do
        /// NOT pin the user's CWD because the user may delete or
        /// `cd` away from it after backgrounding the recording.
        public let workingDirectory: URL

        public init(
            pidFile: URL,
            logFile: URL,
            workingDirectory: URL = URL(fileURLWithPath: "/")
        ) {
            self.pidFile = pidFile
            self.logFile = logFile
            self.workingDirectory = workingDirectory
        }
    }

    /// Performs the POSIX double-fork. The original parent process and
    /// the intermediate parent both `_exit(0)` from inside this call;
    /// only the final detached child returns from this function.
    ///
    /// On any failure encountered before the first fork (e.g. unable
    /// to open the log file), throws `NtakkerError.ioError(...)` and
    /// the caller may continue running normally.
    ///
    /// MUST be called BEFORE any thread is created in the process.
    ///
    /// Algorithm (per project-design.md §14.2):
    ///   1. Open the log file for `O_WRONLY | O_CREAT | O_APPEND` at
    ///      mode `0600`. Done before forking so a misconfigured log
    ///      path errors out cleanly in the user's shell.
    ///   2. `fork()` (first) — parent `_exit(0)`; child continues.
    ///   3. `setsid()` — become session leader, detach from any
    ///      controlling terminal.
    ///   4. `fork()` (second) — intermediate `_exit(0)`; grandchild
    ///      continues. Prevents reacquiring a tty.
    ///   5. `chdir(options.workingDirectory.path)` — release the
    ///      caller's CWD.
    ///   6. `umask(0)` — permissive umask; `PidFile.write` chmods
    ///      0600 explicitly when it lands.
    ///   7. Redirect `stdin` ← `/dev/null` and `stdout`/`stderr` →
    ///      log fd via `dup2`.
    ///   8. Close the original log fd (we still have two duped
    ///      copies as fd-1 and fd-2).
    ///   9. Return.
    ///
    /// - Parameter options: Daemonization configuration.
    /// - Throws: `NtakkerError.ioError` if the log file cannot be
    ///   opened. Other syscalls failing inside the child fork halt
    ///   the child process via `_exit(1)`; the original parent
    ///   never observes the failure (this is consistent with the
    ///   Stevens APUE recipe).
    public static func detach(_ options: Options) throws {
        // ---- Step 1: Open the log fd BEFORE forking. -----------------
        // Easier to error-handle: a misconfigured logFile surfaces
        // synchronously to the user's shell instead of silently
        // failing inside the daemon.
        let logFD = open(
            options.logFile.path,
            O_WRONLY | O_CREAT | O_APPEND,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard logFD >= 0 else {
            let reason = String(cString: strerror(errno))
            throw NtakkerError.ioError(
                "failed to open log file at \(options.logFile.path): \(reason)"
            )
        }

        // ---- Step 2: First fork. -------------------------------------
        let pid1 = _ntakker_fork()
        if pid1 < 0 {
            let reason = String(cString: strerror(errno))
            close(logFD)
            throw NtakkerError.ioError("first fork() failed: \(reason)")
        }
        if pid1 > 0 {
            // Parent: return the shell prompt immediately. Use
            // `_exit(0)` so we skip atexit handlers (see file header).
            close(logFD)
            _exit(0)
        }

        // ---- Step 3: setsid — become session leader. -----------------
        if setsid() < 0 {
            // We cannot recover here. Exit the child silently; the
            // user's shell already has its prompt back, so a thrown
            // error would never be observed.
            close(logFD)
            _exit(1)
        }

        // ---- Step 4: Second fork. ------------------------------------
        let pid2 = _ntakker_fork()
        if pid2 < 0 {
            close(logFD)
            _exit(1)
        }
        if pid2 > 0 {
            // Intermediate parent (the session leader) — `_exit(0)` so
            // we cannot reacquire a controlling terminal.
            close(logFD)
            _exit(0)
        }

        // ---- We are now the grandchild. ------------------------------

        // ---- Step 5: chdir. ------------------------------------------
        // Tolerate a chdir failure (e.g. workingDirectory disappeared
        // between the caller building it and us reaching here) by
        // falling back to "/". Daemonization should not fail on this
        // edge case.
        if chdir(options.workingDirectory.path) < 0 {
            _ = chdir("/")
        }

        // ---- Step 6: umask. ------------------------------------------
        umask(0)

        // ---- Step 7: redirect stdin/stdout/stderr. -------------------
        // stdin ← /dev/null (read-only).
        let nullFD = open("/dev/null", O_RDONLY)
        if nullFD >= 0 {
            dup2(nullFD, STDIN_FILENO)
            if nullFD != STDIN_FILENO {
                close(nullFD)
            }
        }

        // stdout → log file
        dup2(logFD, STDOUT_FILENO)
        // stderr → log file (same fd; swift-log's StreamLogHandler
        // writes here)
        dup2(logFD, STDERR_FILENO)

        // ---- Step 8: close the original log fd. ----------------------
        // Both fd-1 and fd-2 are now duped copies; the original is
        // redundant.
        if logFD != STDOUT_FILENO && logFD != STDERR_FILENO {
            close(logFD)
        }

        // ---- Step 9: return — caller continues as detached daemon. --
    }
}
