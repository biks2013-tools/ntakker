// MacrecCore/Capture/CaptureBuffer.swift — see project-design.md §3.4
//
// Phase E (plan-001) — finalized type. Envelope around a CMSampleBuffer that
// carries source attribution. Used by the aligner and recorders to route a
// buffer to its per-source ring or per-source recorder. The buffer's
// `presentationTimeStamp` is expected to live in the host-clock domain
// (`CMClockGetHostTimeClock()`), as guaranteed by both `SCStream` (audio
// frames) and `AVCaptureSession` once `synchronizationClock` has been set
// to the host clock — see FR-22 and `docs/research/scstream-audio-only.md`
// §4 for the interaction guarantee between the two capture stacks.

import Foundation
import CoreMedia

/// Source attribution for a captured `CMSampleBuffer`.
///
/// Carried inside `CaptureBuffer` so that the aligner and recorders can
/// distinguish system-audio frames from microphone frames after both
/// streams have been merged onto the same delivery path.
public enum CaptureSourceTag: String, Sendable, CaseIterable {
    case system
    case microphone
}

/// Envelope carrying a captured `CMSampleBuffer` plus its source tag.
///
/// `CMSampleBuffer` is a Core Foundation type (reference-counted, not
/// `Sendable`-checked by the compiler), but its retain semantics are
/// safe across thread boundaries once authored. We mark the envelope
/// `@unchecked Sendable` to keep the rest of the pipeline free of
/// `@preconcurrency` shims while still letting buffers cross queues
/// (capture queue → aligner queue → recorder queue).
public struct CaptureBuffer: @unchecked Sendable {
    /// Which source produced this buffer.
    public let source: CaptureSourceTag

    /// The captured audio sample buffer. Already converted to the
    /// pipeline canonical format (Float32, 48 kHz, stereo,
    /// non-interleaved) by the per-source `AVAudioConverter` (real
    /// sources) or generated directly in that format (`FakeAudioSource`).
    public let buffer: CMSampleBuffer

    public init(source: CaptureSourceTag, buffer: CMSampleBuffer) {
        self.source = source
        self.buffer = buffer
    }
}
