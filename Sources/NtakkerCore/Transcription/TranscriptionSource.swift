// NtakkerCore/Transcription/TranscriptionSource.swift — see project-design.md §LT-1 / §LT-6
//
// Phase B (plan-003) — the **session-level** routing decision for the
// transcription side-channel. Distinct from `SourceTag` (which is the
// per-chunk attribution `system | microphone` re-exported from
// `CaptureSourceTag`):
//
//   * `SourceTag`               — per-buffer label produced by the capture
//                                  layer; values `system | microphone`.
//   * `TranscriptionSource`     — per-session routing choice resolved at
//                                  `RecordingSession.start()` time;
//                                  values `system | mic | mixed | both`.
//                                  Drives which tap point the
//                                  `TranscriptionDriver` subscribes to,
//                                  and how many driver instances are
//                                  created (`.both` ⇒ two drivers).
//
// Plan-003 §4 Phase B "Open question" called out the need for this
// four-case enum; this file is its home. The CLI / config layer (Phase C)
// parses user input into this enum; `ConfigResolver` validates and lowers
// the `String` form into `TranscriptionSource`.

import Foundation

/// Session-level routing decision for live transcription.
///
/// Mapped to tap-point selection per §LT-1 of the project design:
///
/// | Value     | Tap installed on                                            | Driver count |
/// |-----------|-------------------------------------------------------------|--------------|
/// | `.system` | `SCKitSystemAudioSource.transcriptionTap`                   | 1            |
/// | `.mic`    | `AVMicrophoneSource.transcriptionTap`                       | 1            |
/// | `.mixed`  | `RecordingSession.transcriptionTap` (post-aligner, summed)  | 1            |
/// | `.both`   | both per-source taps in parallel                            | 2            |
///
/// `Equatable + Sendable` because the value crosses actor boundaries
/// (resolver → `RecordingSession` → `TranscriptionDriver` → tests).
public enum TranscriptionSource: String, Sendable, Equatable, CaseIterable, Codable {

    /// Transcribe only the system-audio side (apps playing through the
    /// default output device).
    case system

    /// Transcribe only the microphone side.
    case mic

    /// Transcribe the post-`BufferSummer` mix of system + mic. Default
    /// for v1 (one transcript per recording).
    case mixed

    /// Transcribe BOTH sides independently — two `TranscriptionDriver`
    /// instances run in parallel, each writing its own sidecar with the
    /// matching source label.
    case both
}
