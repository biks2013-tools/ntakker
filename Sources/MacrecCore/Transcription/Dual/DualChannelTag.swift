// MacrecCore/Transcription/Dual/DualChannelTag.swift — see project-design.md §DT-3, plan-010-dual-transcription.md §Wave-1 (FR-4)
//
// Phase A (plan-010) — the per-channel routing tag used internally by
// `DualTranscriptionManager` and embedded in
// `MacrecError.transcriptionDualChannelFailure(channel:underlying:)`
// + `TranscriptionEvent.dualChannelError(channel:detail:)`.
//
// IMPORTANT: This is a **routing tag**, not a primary key on
// `TranscriptSegment`. The investigator's recommendation (no schema
// change to `TranscriptSegment`) is ratified at the design level —
// `TranscriptSegment.model` ("apple" vs "apple-cloud") plus
// `TranscriptSegment.language` (BCP-47) already uniquely identifies
// the channel for the v1 provider pair. Adding a hard `channel`
// field would couple the data model to the dual-mode feature and
// require a Codable migration. See §DT-3 / DT-ADR-5.

import Foundation

/// Routing tag identifying one of the two concurrent provider lanes in
/// dual transcription mode.
///
/// `Sendable` so the value can cross actor boundaries between
/// `DualTranscriptionManager`, the per-channel drain `Task`s, and the
/// merged event stream consumer in `RecordingController`. `Codable` for
/// JSONL convenience encoding of the optional `channel` sidecar field.
/// `CaseIterable` to drive UI rendering of the two lanes in
/// `LiveTranscriptPanel` (dual-mode branch).
public enum DualChannelTag: String, Codable, Sendable, CaseIterable {
    /// Apple on-device — `SpeechAnalyzer + SpeechTranscriber` (macOS 26).
    /// Default locale: English variant per UI selection.
    /// Locale set: `SpeechTranscriber.supportedLocales` (~42 locales,
    /// English variants present, NO Greek).
    case channelA

    /// Apple Cloud — `SFSpeechRecognizer` with
    /// `requiresOnDeviceRecognition = false`. Default locale: `el-GR`.
    /// Locale set: `SFSpeechRecognizer.supportedLocales()` (~57 locales,
    /// includes Greek).
    case channelB
}
