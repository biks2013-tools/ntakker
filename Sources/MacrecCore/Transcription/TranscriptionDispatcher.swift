// MacrecCore/Transcription/TranscriptionDispatcher.swift — see
// docs/design/project-design.md §DT-4 (Interfaces) and
// docs/design/plan-010-dual-transcription.md §Phase C (Lane L-4).
//
// Phase C / Lane L-4 (plan-010) — uniform façade over both the
// single-mode `TranscriptionManager` (existing) and the dual-mode
// `DualTranscriptionManager` (added in Wave 2 / Lane L-3). The
// `RecordingSession` orchestrator holds ONE optional dispatcher,
// chosen ONCE at construction time, and dispatches every
// transcription operation through this protocol — there are no
// per-callsite `if mode == .dual { ... } else { ... }` branches in
// `RecordingSession` (DT-INV: §DT-4 "the choice between Single and
// Dual is made ONCE at `RecordingSession` construction time; there is
// NO per-callsite enum discriminator").
//
// The protocol intentionally tracks the existing
// `TranscriptionManager`'s public surface 1:1 — the protocol was
// extracted from that surface — so the existing single-mode
// implementation conforms with no behavioural change. The dual
// manager (Wave 2) was already implemented to the same shape.
//
// Dual-only surface NOT on this protocol:
//   * `DualTranscriptionManager.currentDualMetrics() async -> DualChannelMetrics`
//     — consumers that need per-channel metrics downcast (`as? DualTranscriptionManager`)
//     and call directly. Keeps the protocol minimal while letting the
//     dual manager expose extra methods that have no single-mode
//     analogue.
//
// Sendability: the protocol is `AnyObject & Sendable` because both
// conforming types are reference types (`TranscriptionManager` is an
// actor, `DualTranscriptionManager` is an actor). Holding a `(any
// TranscriptionDispatcher)?` field on `RecordingSession` (a
// `@unchecked Sendable` final class) requires the existential to
// itself be `Sendable`.

import Foundation

/// Uniform façade for orchestrators that drive one (single mode) or
/// two (dual mode) transcription pipelines for a single recording
/// session. `RecordingSession` holds one of these and dispatches
/// every transcription operation through the protocol — see
/// project-design §DT-4.
///
/// **Conformance contract:**
///
/// * `start()` may be called at most once per instance. Returns the
///   `AsyncStream<TranscriptionEvent>` consumers iterate to receive
///   segment / metric / disclosure / per-channel-error events.
///   Throws on a hard pre-flight failure that prevents any pipeline
///   from coming up; in dual mode, single-channel failures are
///   reported via `.dualChannelError(...)` events on the stream
///   instead of throwing (the surviving channel keeps running).
///
/// * `ingest(_:from:)` and `ingestFrame(_:from:)` are
///   fire-and-forget: implementations enqueue work onto an internal
///   per-source / per-channel buffer and return without awaiting any
///   provider call. Calling either after `stop()` is a no-op.
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
/// * `currentMetrics()` returns a single combined snapshot. In dual
///   mode this is the field-wise sum across both channels (see
///   `DualTranscriptionManager.currentMetrics()` for the merge
///   convention).
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
