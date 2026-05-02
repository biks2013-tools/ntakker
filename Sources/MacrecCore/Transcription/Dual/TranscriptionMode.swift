// MacrecCore/Transcription/Dual/TranscriptionMode.swift — see project-design.md §DT-3, plan-010-dual-transcription.md §Wave-1 (FR-1)
//
// Phase A (plan-010) — top-level mode toggle for the live-transcription
// subsystem. Drives both the UI mode-switch (`@AppStorage("com.macrec.ui.transcriptionMode")`)
// and the Manager-construction branch in `RecordingSession`
// (`.single` ⇒ `TranscriptionManager`, `.dual` ⇒ `DualTranscriptionManager`).
//
// Default (initial value at every UI launch and when no value has yet
// been persisted): `.single`. The `dual` selection requires that
// `RecordingOptions.dualTranscription` be non-nil at start time;
// `.single` requires it to be nil.
//
// Naming deviation note. The plan-010 spec references this type as
// `TranscriptionMode`, but the name is already taken by a pre-existing
// enum at `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`
// (which carries `case batch | case streaming` and indicates which
// programmatic surface a `TranscriptionProvider` supports). The two
// concepts are orthogonal and the older type's name predates the
// dual-transcription feature; renaming the new type to
// `LiveTranscriptionMode` keeps the dual feature additive without
// touching the locked provider protocol. The `@AppStorage` raw key
// remains `"com.macrec.ui.transcriptionMode"` per §DT-9.

import Foundation

/// Top-level live-transcription mode for a `RecordingSession`.
///
/// `Sendable` so the value can cross actor boundaries (UI → controller →
/// manager). `Codable` for persistence and CLI parsing. `CaseIterable`
/// drives the SwiftUI segmented-control source in `Sources/macrec-ui/Views/Transcription/`.
public enum LiveTranscriptionMode: String, Codable, Sendable, CaseIterable {
    /// Single-provider live transcription — exactly one `TranscriptionManager`
    /// is constructed at session start. This is the v1.5 default and the
    /// only mode that exists pre-plan-010.
    case single

    /// Dual-provider live transcription — `DualTranscriptionManager` is
    /// constructed; two `TranscriptionProvider` instances run concurrently
    /// (`apple` for Channel A on-device + `apple-cloud` for Channel B
    /// cloud), fed identical audio frames, writing into one merged sidecar.
    case dual
}
