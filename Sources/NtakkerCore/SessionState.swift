// NtakkerCore/SessionState.swift — see project-design.md §15.3.1 and
// plan-002-toolbar-ui.md §3 Phase A.
//
// FR-33: observable session state. Emitted by `RecordingSession.stateStream`
// at every lifecycle transition the engine knows about, and synthesized by
// the UI's `SessionCoordinator` for the additional pause / resume states
// that the engine itself does not model.
//
// AMB-1 resolution (plan-002 §0): `splitting` is a discrete enum case (not
// a transient flag on `recording`). This keeps the FR-33 enum exhaustive
// and lets tests deterministically assert `[.splitting, .recording]` after
// `split(nextOutput:)`.
//
// `Equatable` conformance is hand-rolled because `NtakkerError` (the payload
// of `.failed`) carries a non-`Equatable` `Error` in some cases (e.g.
// `.writerFailedToStart(underlying: Error)`). Two `.failed` states are
// considered equal when the contained `NtakkerError` produces the same
// `description` — this is sufficient for state-stream assertions and avoids
// requiring `NtakkerError: Equatable` (which would cascade through all
// `underlying: Error` payloads).

import Foundation

/// Lifecycle state of a recording session, observable via
/// `RecordingSession.stateStream` and (for the synthesized cases)
/// the UI's `SessionCoordinator.stateStream`.
///
/// Transitions emitted by the engine (`RecordingSession`):
///
///   `.idle` → `.starting` → `.recording`
///                              ↓                    (split rotates output)
///                          `.splitting` → `.recording`
///                              ↓
///                          `.stopping` → `.stopped` | `.failed(error)`
///
/// The `pausing` / `paused` / `resuming` cases are NEVER emitted by the
/// engine; they are synthesized by the UI-layer `SessionCoordinator`
/// when a stop-and-stitch pause/resume cycle is in flight. They are
/// declared here so the enum is the single source of truth for any
/// observer that bridges engine + coordinator streams.
public enum SessionState: Sendable {
    /// No session is active. Initial state.
    case idle
    /// `run()` has been called and is bootstrapping (permission gate,
    /// source/recorder construction). No buffers are flowing yet.
    case starting
    /// Sources are running and frames are reaching the recorder.
    case recording
    /// Synthesized by `SessionCoordinator`: the current segment is
    /// finalizing because the user pressed Pause. Engine never emits.
    case pausing
    /// Synthesized by `SessionCoordinator`: previous segment finalized,
    /// no engine session live. Engine never emits.
    case paused
    /// Synthesized by `SessionCoordinator`: a fresh `RecordingSession`
    /// is starting after Resume. Engine never emits.
    case resuming
    /// `split(nextOutput:)` is mid-swap: the new recorder has been
    /// pre-flighted and the encoder reference is being rotated.
    /// Transient (~52 ms upper bound for m4a; project-design §15.3.2).
    case splitting
    /// `requestStop()` (or SIGINT/SIGTERM/maxDuration) has fired; the
    /// pipeline is draining and the recorder is finalizing.
    case stopping
    /// Terminal: the session finished cleanly and the file is on disk.
    case stopped
    /// Terminal: the session aborted with the supplied error.
    case failed(NtakkerError)

    /// Short, log-friendly label for this state. Avoids dumping the
    /// full localized description of a `.failed` payload.
    public var description: String {
        switch self {
        case .idle:        return "idle"
        case .starting:    return "starting"
        case .recording:   return "recording"
        case .pausing:     return "pausing"
        case .paused:      return "paused"
        case .resuming:    return "resuming"
        case .splitting:   return "splitting"
        case .stopping:    return "stopping"
        case .stopped:     return "stopped"
        case .failed(let err):
            return "failed(\(err.description))"
        }
    }
}

// MARK: - Equatable

/// Hand-rolled `Equatable` conformance.
///
/// All non-payload cases are compared by case identity. `.failed(a)` and
/// `.failed(b)` are equal when the two `NtakkerError` payloads produce the
/// same `description` string (which is locked by project-design §2.1).
/// This is sufficient for state-stream assertions in tests and avoids
/// requiring `NtakkerError: Equatable` (which would cascade through every
/// `underlying: Error` payload).
extension SessionState: Equatable {
    public static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.starting, .starting),
             (.recording, .recording),
             (.pausing, .pausing),
             (.paused, .paused),
             (.resuming, .resuming),
             (.splitting, .splitting),
             (.stopping, .stopping),
             (.stopped, .stopped):
            return true
        case (.failed(let a), .failed(let b)):
            return a.description == b.description
        default:
            return false
        }
    }
}
