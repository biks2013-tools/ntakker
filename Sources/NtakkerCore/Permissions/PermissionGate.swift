// NtakkerCore/Permissions/PermissionGate.swift
// Reference: project-design.md §2.6, §8 (decision trees), §15.3.4
//
// High-level orchestrator used by `StartCommand`,
// `CheckPermissionsCommand`, and `RecordingSession`. Exposes:
//   - `snapshot()`           — read both states without prompting.
//   - `requireBothOrThrow()` — gate recording: prompt on .notDetermined,
//                              throw the right NtakkerError otherwise.
//   - `printStatus(to:)`     — human-readable stderr report.
//
// The exact stderr strings emitted by `printStatus` and the error messages
// produced by `requireBothOrThrow` are locked by project-design.md §8 and
// §2.1. They MUST match those documents verbatim.
//
// Phase A (plan-002) — `PermissionGating` protocol extraction.
//   The two methods consumed by `RecordingSession` (`snapshot()` and
//   `requireBothOrThrow()`) are now declared on a `PermissionGating`
//   protocol. The existing `PermissionGate` struct conforms to it
//   unchanged (it is the "live" conformer; tests inject stubs that
//   bypass the TCC check). `LivePermissionGate` is a type alias for the
//   live conformer so call-sites that prefer the explicit name compile.
//   This resolves ISSUE-02 (project root `Issues - Pending Items.md`).
//
// Deviation note (preserved from Phase D Wave 2): the struct shape
// chosen by the original implementer is kept; the protocol is layered
// on top non-invasively. CLI call-sites are unchanged.

import Foundation
import Logging

// MARK: - PermissionGating protocol (project-design §15.3.4)

/// The narrow contract `RecordingSession` consumes from a permission
/// orchestrator. Tests inject a stub conformer (e.g.
/// `StubPermissionGating` that always returns `.bothAuthorized`) to
/// bypass the TCC check, unblocking pipeline tests on hosts without a
/// screen-recording grant. Resolves ISSUE-02.
///
/// The richer affordances on the live `PermissionGate` (`printStatus`,
/// `printSnapshot`, the `Logger` injection) are deliberately kept off
/// the protocol — only the two methods needed by `RecordingSession.run()`
/// are surfaced.
public protocol PermissionGating: Sendable {
    /// Read both permission states without prompting. Snapshot type is
    /// owned by the live `PermissionGate` — see project-design §15.3.4
    /// for the rationale.
    func snapshot() async -> PermissionGate.Snapshot

    /// Verify both permissions are authorized (with side-effects matching
    /// `PermissionGate.requireBothOrThrow()` for the live conformer).
    /// Throws the appropriate `NtakkerError` if not.
    func requireBothOrThrow() async throws
}

// MARK: - PermissionGate (live conformer)

public struct PermissionGate: PermissionGating {
    /// Snapshot of both permission states at a single point in time.
    public struct Snapshot: Sendable, Equatable {
        public let screenRecording: ScreenRecordingPermission.State
        public let microphone: MicrophonePermission.State

        public init(
            screenRecording: ScreenRecordingPermission.State,
            microphone: MicrophonePermission.State
        ) {
            self.screenRecording = screenRecording
            self.microphone = microphone
        }

        public var bothAuthorized: Bool {
            screenRecording == .authorized && microphone == .authorized
        }
    }

    private let logger: Logger?

    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Read the current state of both permissions without prompting.
    public func snapshot() async -> Snapshot {
        Snapshot(
            screenRecording: ScreenRecordingPermission.current(),
            microphone: MicrophonePermission.current()
        )
    }

    /// Verifies both permissions are `.authorized`. Behavior per §8 decision
    /// trees:
    ///   - `.notDetermined` → trigger the OS prompt, then throw the
    ///     `*PermissionNotDetermined` variant (exit 75 / EX_TEMPFAIL).
    ///     Same-process re-read is unreliable (see ScreenRecordingPermission
    ///     header), so we always exit and ask the user to relaunch.
    ///   - `.denied` / `.restricted` → throw the corresponding error
    ///     (exit 77 / EX_NOPERM).
    ///   - `.authorized` → proceed.
    ///
    /// Screen-recording is checked first so the user can address both prompts
    /// in a single relaunch cycle if the screen-recording state was already
    /// `.authorized` and only the mic was missing.
    public func requireBothOrThrow() async throws {
        // Screen Recording — synchronous, C-level.
        switch ScreenRecordingPermission.current() {
        case .authorized:
            break
        case .notDetermined:
            // Trigger the OS prompt. We do not trust the post-prompt return
            // value within the same process (research §6); ask the user to
            // relaunch.
            ScreenRecordingPermission.request()
            logger?.warning("screen recording prompt triggered; relaunch required")
            throw NtakkerError.screenRecordingPermissionNotDetermined
        case .denied:
            logger?.error("screen recording permission denied")
            throw NtakkerError.screenRecordingPermissionDenied
        }

        // Microphone — async, AVFoundation.
        switch MicrophonePermission.current() {
        case .authorized:
            break
        case .notDetermined:
            let post = await MicrophonePermission.request()
            if post == .authorized {
                // Rare but possible — the AVFoundation API delivers the
                // post-prompt state reliably within the same process, unlike
                // the screen-recording path. Allow the caller to proceed.
                logger?.info("microphone permission granted via prompt")
                return
            }
            logger?.warning("microphone prompt triggered; user did not authorize")
            switch post {
            case .denied:       throw NtakkerError.microphonePermissionDenied
            case .restricted:   throw NtakkerError.microphonePermissionRestricted
            case .notDetermined, .authorized:
                // .authorized handled above; .notDetermined shouldn't happen
                // after a prompt round-trip but treat it as "not determined".
                throw NtakkerError.microphonePermissionNotDetermined
            }
        case .denied:
            logger?.error("microphone permission denied")
            throw NtakkerError.microphonePermissionDenied
        case .restricted:
            logger?.error("microphone permission restricted")
            throw NtakkerError.microphonePermissionRestricted
        }
    }

    /// Print a human-readable status report to the supplied file handle
    /// (default stderr). Used by the `check-permissions` subcommand.
    ///
    /// The strings are locked by project-design.md §2.1 / §8.
    public func printStatus(to handle: FileHandle = .standardError) async {
        let snap = await snapshot()
        await printSnapshot(snap, to: handle, screenPromptWasTriggered: false)
    }

    /// Print a pre-captured snapshot. Used by `check-permissions` after it
    /// has decided whether or not it triggered the screen-recording prompt,
    /// so the hint text can be honest about what happened.
    public func printSnapshot(
        _ snap: Snapshot,
        to handle: FileHandle = .standardError,
        screenPromptWasTriggered: Bool
    ) async {
        let screenLine = "Screen Recording: \(Self.label(for: snap.screenRecording))"
        Self.write(screenLine + "\n", to: handle)
        if let hint = Self.screenHint(for: snap.screenRecording,
                                      promptWasTriggered: screenPromptWasTriggered) {
            Self.write("  hint: " + hint + "\n", to: handle)
        }

        let micLine = "Microphone: \(Self.label(for: snap.microphone))"
        Self.write(micLine + "\n", to: handle)
        if let hint = Self.micHint(for: snap.microphone) {
            Self.write("  hint: " + hint + "\n", to: handle)
        }
    }

    // MARK: - Private formatters

    private static func label(for state: ScreenRecordingPermission.State) -> String {
        switch state {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .notDetermined: return "not determined"
        }
    }

    private static func label(for state: MicrophonePermission.State) -> String {
        switch state {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "not determined"
        }
    }

    /// Hint strings for screen-recording states. The denied/notDetermined
    /// strings come from project-design.md §2.1 / §8.1.
    ///
    /// `promptWasTriggered` toggles between two notDetermined messages:
    /// when a prompt was actually triggered we tell the user to approve and
    /// relaunch; when not (e.g. printStatus called without a request side
    /// effect) we tell them to run `check-permissions` to bootstrap.
    private static func screenHint(
        for state: ScreenRecordingPermission.State,
        promptWasTriggered: Bool = false
    ) -> String? {
        switch state {
        case .authorized:
            return nil
        case .denied:
            return "Open System Settings > Privacy & Security > Screen Recording and enable ntakker-cli, then re-run."
        case .notDetermined:
            if promptWasTriggered {
                return "Approve the prompt that just appeared, then re-run ntakker-cli check-permissions. (Same-process state cannot be re-read; relaunch is required.)"
            }
            return "Run 'ntakker-cli check-permissions' to trigger the system prompt."
        }
    }

    /// Hint strings for microphone states. Verbatim from project-design.md
    /// §2.1 / §8.2.
    private static func micHint(for state: MicrophonePermission.State) -> String? {
        switch state {
        case .authorized:
            return nil
        case .denied:
            return "Open System Settings > Privacy & Security > Microphone and enable ntakker-cli, then re-run."
        case .restricted:
            return "Contact your administrator; the tool cannot record audio under this restriction."
        case .notDetermined:
            return "Run 'ntakker-cli check-permissions' to trigger the system prompt. (If the binary lacks NSMicrophoneUsageDescription in its embedded Info.plist, the prompt will not appear — rebuild after Resources/Info.plist is in place.)"
        }
    }

    private static func write(_ string: String, to handle: FileHandle) {
        if let data = string.data(using: .utf8) {
            handle.write(data)
        }
    }
}

// MARK: - LivePermissionGate alias

/// Explicit name for the live `PermissionGating` conformer. Provided so
/// downstream call-sites (UI, future test plane) can refer to the
/// production gate by an unambiguous name without disturbing the
/// existing `PermissionGate(...)` constructor used throughout the CLI.
public typealias LivePermissionGate = PermissionGate

