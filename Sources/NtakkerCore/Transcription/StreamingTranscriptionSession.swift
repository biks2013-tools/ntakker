// NtakkerCore/Transcription/StreamingTranscriptionSession.swift —
// see docs/design/plan-005-apple-speech-streaming.md §"Phase A".
//
// Phase A (plan-005) — public surface for streaming transcription
// providers. The existing `TranscriptionProvider` protocol shipped in
// plan-004 (rest-batch) returns a single string per chunk — fine for
// REST/batch backends, useless for streaming backends like Apple's
// `SpeechAnalyzer + SpeechTranscriber` which emit volatile partials
// followed by a stable final per utterance.
//
// `StreamingTranscriptionSession` extends the provider surface without
// breaking the batch surface: a provider declares its `supportedModes`
// (batch / streaming / both) on `TranscriptionProvider`, and a caller
// who wants streaming opens a session via `openStreamingSession(...)`.
//
// The session is fed sample buffers via `ingest(_:)` (fire-and-forget
// from the caller's perspective) and emits `StreamingTranscriptionEvent`
// values on `events` until `finish()` is called. The closing of the
// `events` stream is the caller's signal that the session has fully
// drained.

import Foundation

/// Mode declared by a `TranscriptionProvider` to indicate which
/// programmatic surfaces it supports.
public enum TranscriptionMode: Sendable, Codable, Equatable, Hashable {
    /// Batch: caller hands the full chunk to `transcribe(...)` and
    /// awaits one verbatim string. The shape used by plan-004 (NoOp,
    /// Fake, Gemini REST).
    case batch

    /// Streaming: caller opens a session via `openStreamingSession(...)`,
    /// pushes samples through `ingest(_:)`, and consumes
    /// `StreamingTranscriptionEvent` values from `events`.
    case streaming
}

/// Per-session streaming surface. One session per source per
/// recording. Implementations are `Sendable` actors / structs and
/// must internally serialise concurrent `ingest(_:)` and `finish()`
/// calls.
public protocol StreamingTranscriptionSession: Sendable {
    /// Append samples to the session. Fire-and-forget from the
    /// caller's perspective: returns once the bytes are queued
    /// internally; the actual provider call happens asynchronously.
    func ingest(_ samples: [Float]) async

    /// Stream of streaming-side events. Closes when the provider
    /// signals end-of-stream OR when `finish()` has been awaited and
    /// all in-flight finals have drained.
    var events: AsyncStream<StreamingTranscriptionEvent> { get }

    /// Drain remaining buffered audio, wait for any in-flight final
    /// results, then close `events`. Idempotent.
    func finish() async
}

/// Events emitted by a `StreamingTranscriptionSession`.
///
/// `partial` events are volatile updates for an in-flight utterance —
/// they may be revised arbitrarily until the matching `final` arrives.
/// A `final` is the stable form of the utterance with the same
/// `utteranceId`; it carries the wall-clock time range, the resolved
/// language tag (BCP-47), and any provider-supplied confidence.
public enum StreamingTranscriptionEvent: Sendable {
    /// Volatile partial for an in-flight utterance.
    ///
    /// `speaker` carries the diarisation label for the active utterance
    /// when the provider supports it (Soniox `spk:N` after plan-012
    /// Phase A). Providers without diarisation pass `nil`.
    case partial(utteranceId: UUID,
                 text: String,
                 confidence: Float?,
                 speaker: String?)

    /// Stable final for `utteranceId`. Subsequent partials with the
    /// same id MUST NOT be emitted by the provider; subsequent
    /// utterances arrive with a fresh id.
    ///
    /// `speaker` carries the diarisation label for the utterance when
    /// the provider supports it; `nil` otherwise.
    case final(utteranceId: UUID,
               text: String,
               confidence: Float?,
               range: ClosedRange<Date>,
               language: String,
               speaker: String?)

    /// Snapshot of the per-session streaming metrics. Caller receives
    /// these on the same channel as transcript events so a single
    /// consumer can drive both UI badges and metrics overlays.
    case metrics(StreamingProviderMetrics)

    /// Non-fatal provider/transport error. The session may keep
    /// running after these — only the closure of the `events` stream
    /// signals "done".
    case error(detail: String)
}

/// Per-session streaming metrics. Mirrors the shape of
/// `TranscriptionMetrics` (plan-004) but split out so streaming-only
/// counters do not bleed into the batch metrics struct that the UI
/// already consumes.
public struct StreamingProviderMetrics: Sendable, Codable, Equatable {
    /// Cumulative number of `partial` events emitted on this session.
    public var partialsEmitted: Int = 0

    /// Cumulative number of `final` events emitted on this session.
    public var finalsEmitted: Int = 0

    /// Wall-clock latency between the most recent `ingest(_:)` call
    /// that contained the underlying audio and the resulting `partial`
    /// emission. Zero until the first partial lands.
    public var lastPartialLatencyMs: Int = 0

    /// Wall-clock latency between the most recent `ingest(_:)` call
    /// that contained the underlying audio and the resulting `final`
    /// emission. Zero until the first final lands.
    public var lastFinalLatencyMs: Int = 0

    /// Cumulative count of `.error(...)` events emitted on this
    /// session. Caller may surface this in the UI as a non-fatal
    /// "transcription degraded" badge.
    public var errorCount: Int = 0

    public init() {}
}
