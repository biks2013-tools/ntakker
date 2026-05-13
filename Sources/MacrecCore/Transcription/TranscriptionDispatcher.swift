// MacrecCore/Transcription/TranscriptionDispatcher.swift
//
// Uniform façade over the live-transcription pipeline.
// `RecordingSession` holds one optional dispatcher and dispatches
// every transcription operation through this protocol.
//
// Sendability: the protocol is `AnyObject & Sendable` because the
// conforming types are reference types (`TranscriptionManager` is an
// actor, `SourceSplitTranscriptionManager` is an actor). Holding a
// `(any TranscriptionDispatcher)?` field on `RecordingSession` (a
// `@unchecked Sendable` final class) requires the existential to
// itself be `Sendable`.

import Foundation

/// Uniform façade for orchestrators that drive a transcription
/// pipeline for a single recording session.
///
/// **Conformance contract:**
///
/// * `start()` may be called at most once per instance. Returns the
///   `AsyncStream<TranscriptionEvent>` consumers iterate to receive
///   segment / metric / disclosure / error events. Throws on a hard
///   pre-flight failure that prevents the pipeline from coming up.
///
/// * `ingest(_:from:)` and `ingestFrame(_:from:)` are
///   fire-and-forget: implementations enqueue work onto an internal
///   per-source buffer and return without awaiting any provider
///   call. Calling either after `stop()` is a no-op.
///
/// * `rotateSidecar(toAudioURL:format:)` is called by
///   `RecordingSession.split(nextOutput:)` so the in-flight
///   transcript follows the rotated audio file. Throws on writer
///   construction error.
///
/// * `stop()` is idempotent. After `stop()` returns, the stream
///   returned by `start()` MUST have finished (`for await event in
///   stream` exits cleanly).
///
/// * `currentMetrics()` returns a single combined snapshot.
public protocol TranscriptionDispatcher: AnyObject, Sendable {

    /// Begin orchestration. Returns the event stream the caller must
    /// consume to receive segment / metric / disclosure / error
    /// events. Calling `start()` more than once on the same instance
    /// is a programmer error (implementations may precondition).
    func start() async throws -> AsyncStream<TranscriptionEvent>

    /// Append already-downsampled 16 kHz Float32 mono samples to the
    /// per-source / per-channel buffer(s). Fire-and-forget.
    func ingest(_ samples: [Float], from tag: SourceTag) async

    /// Receive an `AlignedFrame` from the capture aligner; the
    /// implementation is responsible for any downsampling needed.
    /// Fire-and-forget.
    func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async

    /// Drain remaining buffered audio, finalise pipelines, close
    /// sidecars, and finish the event stream. Idempotent — repeated
    /// calls are no-ops.
    func stop() async

    /// Replace the current sidecar writer with one targeting
    /// `toAudioURL`'s sibling — used by `RecordingSession.split(...)`
    /// when the audio file rotates so the transcript follows.
    func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws

    /// Snapshot of the current metrics — read by the UI badge and by
    /// `RecordingSession`'s summary line at stop time. Async because
    /// implementations are typically actors.
    func currentMetrics() async -> TranscriptionMetrics
}
