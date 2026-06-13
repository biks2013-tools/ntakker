// NtakkerUIKit/LevelMeterTap.swift — see project-design.md §15.7 and
// plan-002-toolbar-ui.md §3 Phase D (FR-43).
//
// Pure level-extraction primitive: given a `CMSampleBuffer` from a
// capture source and a pre-allocated scratch `AVAudioPCMBuffer`,
// compute peak (vDSP_maxmgv) and RMS (vDSP_rmsqv) over channel 0 and
// return them inside a `LevelSample`.
//
// The function is **non-allocating on the audio thread** (the scratch
// buffer is owned by the caller — typically `LevelMeterPublisher`'s
// per-source `LevelMeterTap`). It is **single-channel by design**: the
// engine's pipeline already downmixes both sources to a stereo Float32
// non-interleaved layout, and FR-43 only requires a single peak/RMS
// pair per source — so this helper reads channel 0 only and documents
// the assumption with the comment block on `extractLevels`.
//
// The dB conversion is performed by the consumer of this sample (e.g.
// `LevelMeterView`). We deliberately keep the linear magnitudes here so
// tests can assert exact values without floating-point dB cliff-edges
// (`20*log10(0)` is `-inf`, which is a pain to compare).

import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import Logging

/// Per-source level-meter tap. Owns a pre-allocated scratch
/// `AVAudioPCMBuffer` and yields coalesced `LevelSample`s onto an
/// `AsyncStream`. One instance per source (system + mic) is held by
/// `LevelMeterPublisher`.
///
/// Threading: `ingest(_:)` is invoked on the engine's capture queue
/// (`ntakker-cli.capture.system` or `ntakker-cli.capture.mic`). The scratch
/// buffer and the lock-protected `lastEmitTimestamp` are confined to
/// that one queue per instance. The `AsyncStream.Continuation` is
/// thread-safe.
public final class LevelMeterTap: @unchecked Sendable {

    /// Source attribution for every emitted sample.
    public let source: LevelSampleSource

    /// 30 Hz coalescing interval — emit at most once per 33 ms. Phase
    /// D contract verbatim (project-design §15.7). Implemented as a
    /// stored constant so tests can lower it in custom subclasses if
    /// needed.
    public let coalescingIntervalSeconds: TimeInterval = 1.0 / 30.0

    private let scratch: AVAudioPCMBuffer
    private var lastEmitTimestamp: TimeInterval = 0

    private let continuation: AsyncStream<LevelSample>.Continuation

    /// `AsyncStream` of coalesced level samples. Buffering policy is
    /// `.bufferingNewest(2)` — a slow consumer keeps only the two most
    /// recent samples, which matches the level-meter UX (visual lag is
    /// expected to be ≤ 67 ms / 2 frames).
    public let stream: AsyncStream<LevelSample>

    /// Construct a tap for `source`. The scratch buffer is allocated
    /// once at construction and reused on every `ingest`. The buffer
    /// is sized for 4096 frames of stereo Float32 non-interleaved —
    /// SCStream and AVCaptureSession both deliver ≤ ~1024 frames per
    /// callback at 48 kHz, so 4096 gives 4× headroom.
    ///
    /// - Parameters:
    ///   - source: Source attribution (mic or system).
    ///   - format: The `AVAudioFormat` of the buffers `ingest` will
    ///     receive. Must be Float32 non-interleaved. The scratch
    ///     buffer is allocated against this format.
    ///   - frameCapacity: Optional override for the scratch buffer's
    ///     frame capacity. Defaults to 4096.
    public init(
        source: LevelSampleSource,
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount = 4096
    ) throws {
        self.source = source
        guard let scratch = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: frameCapacity) else {
            throw LevelMeterTapError.scratchAllocationFailed(
                frameCapacity: Int(frameCapacity),
                channels: Int(format.channelCount)
            )
        }
        self.scratch = scratch
        let pair = AsyncStream.makeStream(
            of: LevelSample.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    /// Yield the stream's terminator on deinit so any consumer
    /// `for await` loop unblocks.
    deinit {
        continuation.finish()
    }

    /// Ingest a `CMSampleBuffer`. Coalesces to 30 Hz and yields a
    /// `LevelSample` onto `stream` if the coalescing window has
    /// elapsed.
    ///
    /// Called on the source's capture queue. Allocation-free
    /// (assumes `scratch` is large enough; oversized buffers are
    /// silently truncated to the scratch's capacity).
    ///
    /// - Parameter sampleBuffer: The captured `CMSampleBuffer`. Its
    ///   format must match the format passed at construction (the
    ///   engine downmixes everything to Float32 stereo
    ///   non-interleaved before invoking the tap).
    public func ingest(_ sampleBuffer: CMSampleBuffer) {
        // Coalesce: 30 Hz cap.
        let now = Date().timeIntervalSince1970
        if now - lastEmitTimestamp < coalescingIntervalSeconds {
            return
        }
        lastEmitTimestamp = now

        guard let level = LevelMeterTap.extractLevels(
            from: sampleBuffer,
            scratch: scratch,
            source: source,
            timestamp: now
        ) else {
            return
        }
        continuation.yield(level)
    }

    // MARK: - Pure extraction

    /// Pure peak/RMS extraction over channel 0 of `sampleBuffer`.
    /// Reuses `scratch` for the CMSampleBuffer→AVAudioPCMBuffer copy
    /// (no allocation on the audio thread).
    ///
    /// **Assumption** (locked by the engine pipeline): `sampleBuffer`
    /// carries Float32 non-interleaved samples whose layout matches
    /// `scratch.format`. If the engine ever changes the canonical
    /// pipeline format, this helper must be updated in lockstep.
    /// FR-43 requires a single peak/RMS pair per source — multi-
    /// channel meters are out of v1 scope, so we read channel 0 only.
    ///
    /// Returns `nil` if the buffer cannot be read (e.g. zero frame
    /// length, malformed buffer); the caller should swallow that case
    /// and wait for the next buffer.
    public static func extractLevels(
        from sampleBuffer: CMSampleBuffer,
        scratch: AVAudioPCMBuffer,
        source: LevelSampleSource,
        timestamp: TimeInterval
    ) -> LevelSample? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        let capped = min(frameCount, Int(scratch.frameCapacity))

        // Set frameLength BEFORE asking for the ABL — `mutableAudioBufferList`
        // reports each buffer's `mDataByteSize` based on the current
        // `frameLength * stride`, NOT `frameCapacity * stride`. If we
        // leave frameLength at 0 (its default) the ABL is reported as
        // empty and `CMSampleBufferCopyPCMDataIntoAudioBufferList`
        // fails with `kCMSampleBufferError_AudioBufferListAndSampleBufferHaveDifferentTotalLengths`
        // (-12731).
        scratch.frameLength = AVAudioFrameCount(capped)

        // Copy frames into the scratch buffer's channel-0 backing.
        // We use CMSampleBufferCopyPCMDataIntoAudioBufferList which
        // is the supported API for moving CMSampleBuffer audio into
        // an AudioBufferList — the AVAudioPCMBuffer wraps one.
        let abl = scratch.mutableAudioBufferList
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(capped),
            into: abl
        )
        guard status == noErr else { return nil }

        // Read channel 0. AVAudioPCMBuffer's `floatChannelData` is a
        // pointer to an array of channel pointers (non-interleaved
        // layout).
        guard let channels = scratch.floatChannelData else { return nil }
        let channel0 = channels[0]
        let n = vDSP_Length(capped)

        // vDSP_maxmgv: maximum magnitude (|x|).
        var peak: Float = 0
        vDSP_maxmgv(channel0, 1, &peak, n)

        // vDSP_rmsqv: root mean square.
        var rms: Float = 0
        vDSP_rmsqv(channel0, 1, &rms, n)

        return LevelSample(
            peak: peak,
            rms: rms,
            timestamp: timestamp,
            source: source
        )
    }
}

// MARK: - Errors

/// Errors thrown by `LevelMeterTap.init`. Construction failure is
/// fatal for the meter — the caller surfaces it as a `NtakkerError`.
public enum LevelMeterTapError: Error, CustomStringConvertible {
    /// `AVAudioPCMBuffer` initializer returned `nil` (typically because
    /// the format had a zero channel count or the frame capacity was
    /// out of range).
    case scratchAllocationFailed(frameCapacity: Int, channels: Int)

    public var description: String {
        switch self {
        case let .scratchAllocationFailed(frameCapacity, channels):
            return "level-meter scratch buffer allocation failed (frameCapacity=\(frameCapacity), channels=\(channels))"
        }
    }
}
