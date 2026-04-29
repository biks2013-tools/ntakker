// MacrecCore/Transcription/Persistence/TranscriptFormatWriter.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers") — protocol abstraction
// over the four supported sidecar transcript formats: `jsonl`, `srt`,
// `vtt`, `txt`.
//
// Compared with Phase D (plan-003), the protocol now reflects the
// id-keyed in-place rewrite model demanded by the REST-batch
// transcription pipeline: each format writer owns its own `FileHandle`
// (opened in its `init`) and exposes two distinct operations:
//
//   * `appendSegment(_:)` — emit a brand-new segment at end-of-file and
//     remember the byte range it occupies (keyed by `TranscriptSegment.id`).
//   * `updateSegment(_:)` — rewrite an existing segment in place. Short-
//     grow rewrites pad with whitespace; long-grow rewrites tombstone
//     the original location and append the new rendering at end-of-file.
//
// Errors thrown from either method propagate to the calling
// `TranscriptSidecarWriter` actor, which logs them at `.warning` and
// transitions to a broken state — the recording itself is never
// affected (best-effort persistence — design §LT-9.2 / NFR-17).
//
// `Sendable` is intentionally NOT required: each per-format writer is a
// `final class` with mutable state (file handle, byte index) and is
// only ever touched by the owning `TranscriptSidecarWriter` actor,
// which provides isolation by construction. The actor stores writers
// behind `any TranscriptFormatWriter`, so cross-isolation transfer
// never happens at runtime.

import Foundation

/// Append-only / in-place rewrite writer for one transcript sidecar
/// file in a single format. Implementations open and own a
/// `FileHandle` for the lifetime of the sidecar; the owning
/// `TranscriptSidecarWriter` actor serializes all calls.
public protocol TranscriptFormatWriter: AnyObject {

    /// The sidecar file the writer is currently appending to.
    var url: URL { get }

    /// Append a new segment (at end-of-file). The writer records the
    /// byte range so a later `updateSegment(_:)` for the same id can
    /// rewrite it in place.
    func appendSegment(_ segment: TranscriptSegment) throws

    /// Rewrite the segment with `segment.id` in place. If the id is
    /// not known to the writer, the segment is appended instead
    /// (matches the natural "first-time-seen" path of the coalescer).
    func updateSegment(_ segment: TranscriptSegment) throws

    /// Final flush + close. Idempotent in spirit — implementations
    /// may close their `FileHandle` here. The owning actor calls this
    /// exactly once on session end.
    func close() throws
}
