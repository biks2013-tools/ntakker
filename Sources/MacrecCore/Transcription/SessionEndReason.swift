// MacrecCore/Transcription/SessionEndReason.swift — see project-design.md §LT-3.2
//
// Phase A (plan-003) — value type carried by `TranscriptionEvent.sessionEnded`
// to explain why a transcription session terminated. Decoupled from
// `MacrecError` because session ends are NOT recording-fatal: the audio
// pipeline keeps writing even after the transcript stream has finished.

import Foundation

/// Why a transcription session ended. Surfaced by the post-stop disclosure
/// in the UI and persisted to the sidecar (jsonl footer).
///
/// `Codable` so the sidecar writer can round-trip these values verbatim.
public enum SessionEndReason: String, Sendable, Codable, Equatable {

    /// Provider closed cleanly (WebSocket close code 1000 or equivalent).
    case normalClose

    /// User stopped the recording / transcription session.
    case userStopped

    /// Configured maximum session duration was reached (e.g. provider's
    /// session-time cap; not yet exposed as configuration in v1).
    case maxDurationReached

    /// Reconnect attempts were exhausted (default 3 failures within 60 s);
    /// transcription escalates to a "paused" state for the rest of the
    /// recording. The recording itself is unaffected.
    case providerSessionExhausted

    /// A non-recoverable error closed the session (auth failure, malformed
    /// wire data, etc.). The matching `.error(isFatal: true)` event is
    /// emitted just before this reason.
    case unrecoverableError
}
