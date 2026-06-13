// NtakkerCore/Transcription/TranscriptionProvider.swift — see project-design.md §LT-3.1
//
// Phase C (plan-004 rest-batch) — the public protocol every concrete
// transcription provider conforms to. The shape is locked by the rest-batch
// rewrite: instead of a streaming `run(audio:options:)` returning an event
// stream, the provider receives a fixed-format audio buffer and returns
// the verbatim transcription as a `String`. State (HTTP session reuse,
// model warm-up) belongs to the implementation, not the protocol.
//
// Concrete providers in v1:
//   * `NoOpTranscriptionProvider`         — true no-op (this phase).
//   * `FakeTranscriptionProvider`         — deterministic, test-driven (this phase).
//   * `GeminiRESTTranscriptionProvider`   — Google Gemini REST batch (Phase D).

import Foundation

/// A speech-to-text backend that takes a fixed-format audio buffer
/// and returns its verbatim transcription.
///
/// Implementations are stateless per call — any state (HTTP session
/// reuse, model warm-up) belongs to the implementation, not the
/// protocol. Implementations MUST be safe for concurrent calls; the
/// `TranscriptionManager` makes up to two parallel calls per source
/// under load.
///
/// Audio contract: `samples` is 16 kHz mono Float32 in `[-1, 1]`.
/// Returns `""` for non-speech input — does NOT throw.
/// Throws only on transport, auth, or decode failures.
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModes: Set<TranscriptionMode> { get }

    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String

    func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
}
