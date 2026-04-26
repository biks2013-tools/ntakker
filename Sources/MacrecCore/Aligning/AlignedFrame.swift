// MacrecCore/Aligning/AlignedFrame.swift — see project-design.md §3.3
//
// Phase F (plan-001) — finalized type. One time-aligned pair of buffers
// covering the same wall-clock interval. The aligner emits one of these
// per output tick. The sub-buffer fields are `Optional` so that:
//
//   * Initial / end-of-stream conditions where exactly one source has
//     not yet (or has stopped) producing data can be represented
//     without forcing the caller to allocate a silence buffer.
//   * Phase F can choose between "synthesize silence inline" (the design
//     §2.9 recipe) and "emit nil and let the consumer decide" (used by
//     `split`-layout passthrough). In `mixed`/`stereo-split` mode the
//     aligner still calls `SilenceBufferFactory` and the field is
//     non-nil; in those cases the gap is observable via
//     `HostClockAligner.stats.systemGapFills` / `.micGapFills`.
//
// `CMSampleBuffer` is a Core-Foundation type with safe cross-thread
// retain semantics, so the envelope is `@unchecked Sendable` (matching
// the `CaptureBuffer` envelope it complements).

import CoreMedia
import Foundation

public struct AlignedFrame: @unchecked Sendable {
    /// Host-clock PTS for this frame's start. Identical for both
    /// sub-buffers when they are non-nil.
    public let pts: CMTime

    /// Length of this frame. Identical for both sub-buffers when they
    /// are non-nil.
    public let duration: CMTime

    /// System-audio sub-buffer for this slice. `nil` if no system data
    /// is available and no silence fill was synthesized (e.g. before
    /// the system source has produced its first buffer, or after it
    /// has stopped).
    public let systemBuffer: CMSampleBuffer?

    /// Microphone sub-buffer for this slice. Same nil-semantics as
    /// `systemBuffer`.
    public let micBuffer: CMSampleBuffer?

    public init(
        pts: CMTime,
        duration: CMTime,
        systemBuffer: CMSampleBuffer?,
        micBuffer: CMSampleBuffer?
    ) {
        self.pts = pts
        self.duration = duration
        self.systemBuffer = systemBuffer
        self.micBuffer = micBuffer
    }
}
