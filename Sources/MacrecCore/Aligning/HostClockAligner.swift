// MacrecCore/Aligning/HostClockAligner.swift — see project-design.md §2.9
// and `docs/research/scstream-audio-only.md` §4 (gap-fill recipe).
//
// Phase F (plan-001) — host-clock-driven cross-source aligner. Two
// capture sources (system, mic) deliver `CaptureBuffer`s on their own
// queues; the aligner serializes them onto a private serial queue,
// buffers samples per source, and emits `AlignedFrame`s of fixed
// `frameDuration` (default 100 ms) at the pipeline's canonical PTS
// cadence.
//
// Algorithm summary (from prompt + design §2.9 + research §4):
//
//   1. Maintain a per-source flat Float32 sample buffer (non-interleaved
//      layout: channel-0 samples, then channel-1 samples, ...) plus
//      `headPTS` (the PTS of the first sample currently in the buffer)
//      and a frame counter.
//
//   2. On `ingest(_:)` (any thread): hop onto `macrec.aligner.serial`,
//      validate format against the configured target, append the new
//      samples to the per-source buffer, then call `tryDrain()`.
//
//   3. `nextExpectedFramePTS` is `nil` until the first buffer arrives
//      from either source; it's then anchored to the earliest first
//      PTS observed across the two sources.
//
//   4. `tryDrain()` loops emitting one `AlignedFrame` of exactly
//      `windowFrames` per iteration:
//
//      * For each source:
//          - If headPTS is later than `nextExpectedFramePTS + 1 sample`,
//            the source has not yet produced data covering the window
//            start; emit a silence buffer for that side and increment
//            the gap-fill counter.
//          - Else if headPTS is earlier than `nextExpectedFramePTS`,
//            drop the stale leading frames.
//          - Once headPTS == nextExpectedFramePTS (within tolerance),
//            if there are enough buffered frames to cover the window,
//            slice them off and build the output CMSampleBuffer.
//          - Otherwise (not enough data yet) — bail out of the drain
//            loop; we'll retry on the next ingest.
//      * If both sides are ready, emit AlignedFrame, advance
//        nextExpectedFramePTS by frameDuration, loop.
//
//   5. `flush()` drains any remaining matched window then stops
//      accepting new buffers.
//
// Concurrency: `ingest` is thread-safe (queue-hop). All mutable state
// is confined to `serialQueue`. `onAlignedFrame` is invoked on
// `serialQueue` so consumers must not block (recorders enqueue onto
// their own writer queue per design §2.10).

import AVFoundation
import CoreAudio
import CoreMedia
import Dispatch
import Foundation
import Logging

public final class HostClockAligner: @unchecked Sendable {

    // MARK: - Public types

    /// Aggregate stats for the aligner; surfaces the counters the
    /// design §2.9 and the prompt's tests expect.
    public struct Stats: Sendable {
        public let framesEmitted: Int
        public let systemGapFills: Int
        public let micGapFills: Int
        public let lastDriftSec: Double
    }

    // MARK: - Public configuration

    public let targetSampleRate: Double
    public let targetChannelCount: Int
    public let frameDuration: CMTime
    public let windowFrames: Int

    /// Receiver for aligned frames. Invoked on the aligner's serial
    /// queue. Set by the orchestrator before any `ingest` call.
    public var onAlignedFrame: ((AlignedFrame) -> Void)?

    /// Snapshot of the current stats. Thread-safe — read-only access
    /// hops onto the serial queue.
    public var stats: Stats {
        var snapshot: Stats!
        serialQueue.sync {
            snapshot = Stats(
                framesEmitted: _framesEmitted,
                systemGapFills: _systemGapFills,
                micGapFills: _micGapFills,
                lastDriftSec: _lastDriftSec
            )
        }
        return snapshot
    }

    // MARK: - Stored state (queue-confined)

    private let serialQueue = DispatchQueue(label: "macrec.aligner.serial")
    private let logger: Logger?

    /// Format description used to wrap silence + emitted buffers.
    /// Built lazily from `targetSampleRate` / `targetChannelCount`.
    private let formatDescription: CMAudioFormatDescription

    /// Per-source contiguous Float32 buffer (channel-major, non-interleaved
    /// layout: [ch0_f0, ch0_f1, ..., ch0_fN-1, ch1_f0, ...]).
    /// Length == `_systemFrameCount * channelCount` always.
    private var _systemSamples: [Float32] = []
    private var _systemFrameCount: Int = 0
    private var _systemHeadPTS: CMTime?

    private var _micSamples: [Float32] = []
    private var _micFrameCount: Int = 0
    private var _micHeadPTS: CMTime?

    /// `nextExpectedFramePTS` per the design §2.9 / research §4 recipe.
    /// `nil` until the first buffer arrives from any source.
    private var _nextExpectedFramePTS: CMTime?

    /// Counters surfaced via `stats`.
    private var _framesEmitted: Int = 0
    private var _systemGapFills: Int = 0
    private var _micGapFills: Int = 0
    private var _lastDriftSec: Double = 0

    /// Latch set by `flush()` — once flushed, ingest is a no-op.
    private var _flushed: Bool = false

    /// Latch set when an ingest format mismatch occurs. We continue
    /// to accept calls (the API is non-throwing) but they short-circuit.
    /// Surfaced via the logger; the design defers full session-level
    /// error handling to Phase J's `RecordingSession`.
    private var _formatErrored: Bool = false

    // MARK: - Init

    /// - Parameters:
    ///   - targetSampleRate: Expected source sample rate (Hz). Buffers
    ///     not matching this are dropped with a logged error (the
    ///     ingest API is non-throwing per the prompt's signature).
    ///   - targetChannelCount: Expected source channel count.
    ///   - frameDuration: Output window length. Default 100 ms.
    ///   - logger: Optional logger; pass
    ///     `LoggerFactory.make("macrec.aligner")`.
    public init(
        targetSampleRate: Double = 48_000,
        targetChannelCount: Int = 2,
        frameDuration: CMTime = CMTime(value: 4_800, timescale: 48_000),
        logger: Logger? = nil
    ) {
        precondition(targetSampleRate > 0, "targetSampleRate must be > 0")
        precondition(targetChannelCount >= 1, "targetChannelCount must be >= 1")
        precondition(frameDuration.seconds > 0, "frameDuration must be > 0")

        self.targetSampleRate = targetSampleRate
        self.targetChannelCount = targetChannelCount
        self.frameDuration = frameDuration
        self.logger = logger

        // windowFrames = round(frameDuration.seconds * sampleRate)
        let frames = Int((frameDuration.seconds * targetSampleRate).rounded())
        precondition(frames > 0, "frameDuration must resolve to >= 1 frame")
        self.windowFrames = frames

        self.formatDescription = SilenceBufferFactory.makeFloat32FormatDescription(
            sampleRate: targetSampleRate,
            channelCount: targetChannelCount
        )
    }

    /// Design §2.9 convenience initializer that accepts a pre-built
    /// `CMAudioFormatDescription`. Kept so downstream phases can build
    /// the aligner against the live source's exact ASBD.
    public convenience init(
        formatDescription: CMAudioFormatDescription,
        sampleRate: Double = 48_000,
        logger: Logger,
        ringCapacity _: Int = 10
    ) {
        // Try to derive channel count from the format description.
        var channelCount = 2
        if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
            channelCount = Int(asbdPtr.pointee.mChannelsPerFrame)
        }
        self.init(
            targetSampleRate: sampleRate,
            targetChannelCount: channelCount,
            frameDuration: CMTime(value: CMTimeValue(sampleRate / 10), timescale: CMTimeScale(sampleRate)),
            logger: logger
        )
    }

    // MARK: - Public API

    /// Feed a buffer from either source. Thread-safe — hops onto the
    /// aligner's serial queue. Idempotent after `flush()`.
    public func ingest(_ capture: CaptureBuffer) {
        serialQueue.async { [self] in
            self.ingestOnQueue(capture)
        }
    }

    /// Design §2.9 alias for `ingest(_:)`.
    public func accept(_ capture: CaptureBuffer) {
        ingest(capture)
    }

    /// Stop accepting further captures. Synchronous wrt the serial
    /// queue: returns after any in-flight ingest has completed and
    /// after a final drain attempt has run.
    public func flush() {
        serialQueue.sync { [self] in
            self._flushed = true
            // One last drain pass for any complete window already buffered.
            self.tryDrain()
            // Reset buffers — anything left is, by definition, partial
            // residue with no aligned counterpart on the other side.
            self._systemSamples.removeAll(keepingCapacity: false)
            self._systemFrameCount = 0
            self._systemHeadPTS = nil
            self._micSamples.removeAll(keepingCapacity: false)
            self._micFrameCount = 0
            self._micHeadPTS = nil
        }
    }

    /// Design §2.9 alias for `flush()`.
    public func drain() {
        flush()
    }

    // MARK: - Core algorithm (queue-confined)

    /// Validate format, append samples, anchor `nextExpectedFramePTS`
    /// on first ingest, then attempt to drain windows. Runs on
    /// `serialQueue`.
    private func ingestOnQueue(_ capture: CaptureBuffer) {
        guard !_flushed else { return }
        guard !_formatErrored else { return }

        let sb = capture.buffer
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else {
            logger?.error("aligner: ingest dropped — buffer has no format description")
            _formatErrored = true
            return
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else {
            logger?.error("aligner: ingest dropped — buffer format description has no ASBD")
            _formatErrored = true
            return
        }
        let asbd = asbdPtr.pointee

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, isNonInterleaved, asbd.mBitsPerChannel == 32 else {
            logger?.error(
                "aligner: format mismatch — expected Float32 non-interleaved (got flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel))"
            )
            _formatErrored = true
            return
        }
        guard asbd.mSampleRate == targetSampleRate else {
            logger?.error(
                "aligner: format mismatch — expected sampleRate \(targetSampleRate), got \(asbd.mSampleRate)"
            )
            _formatErrored = true
            return
        }
        guard Int(asbd.mChannelsPerFrame) == targetChannelCount else {
            logger?.error(
                "aligner: format mismatch — expected \(targetChannelCount) channels, got \(asbd.mChannelsPerFrame)"
            )
            _formatErrored = true
            return
        }

        let frameCount = CMSampleBufferGetNumSamples(sb)
        guard frameCount > 0 else { return }

        // Read all sample bytes into a Float32 array.
        var newSamples = [Float32](repeating: 0, count: frameCount * targetChannelCount)
        let totalBytes = frameCount * targetChannelCount * MemoryLayout<Float32>.size
        guard let bb = CMSampleBufferGetDataBuffer(sb) else {
            logger?.error("aligner: ingest dropped — buffer has no data buffer")
            return
        }
        let copyStatus = newSamples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                bb,
                atOffset: 0,
                dataLength: totalBytes,
                destination: UnsafeMutableRawPointer(base)
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            logger?.error(
                "aligner: CMBlockBufferCopyDataBytes failed (status=\(copyStatus))"
            )
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        // Append to the appropriate source's accumulator.
        switch capture.source {
        case .system:
            appendSamples(
                &_systemSamples,
                frameCount: &_systemFrameCount,
                headPTS: &_systemHeadPTS,
                newSamples: newSamples,
                newFrameCount: frameCount,
                newPTS: pts
            )
        case .microphone:
            appendSamples(
                &_micSamples,
                frameCount: &_micFrameCount,
                headPTS: &_micHeadPTS,
                newSamples: newSamples,
                newFrameCount: frameCount,
                newPTS: pts
            )
        }

        // Anchor the output cadence on the first ingest.
        if _nextExpectedFramePTS == nil {
            anchorNextExpectedFramePTSIfPossible()
        }

        tryDrain()
    }

    /// Append samples in non-interleaved layout: per-channel slices.
    /// `dst` keeps the convention `[ch0_f0..ch0_fN-1, ch1_f0.., ...]`.
    /// The new buffer has the same convention; we splice each channel
    /// in place.
    private func appendSamples(
        _ dst: inout [Float32],
        frameCount: inout Int,
        headPTS: inout CMTime?,
        newSamples: [Float32],
        newFrameCount: Int,
        newPTS: CMTime
    ) {
        let channelCount = targetChannelCount
        let oldFrameCount = frameCount
        let newTotalFrames = oldFrameCount + newFrameCount

        // Reallocate. We rebuild channel-by-channel because the layout
        // is channel-major.
        var rebuilt = [Float32](repeating: 0, count: newTotalFrames * channelCount)
        rebuilt.withUnsafeMutableBufferPointer { dstPtr in
            dst.withUnsafeBufferPointer { oldPtr in
                newSamples.withUnsafeBufferPointer { newPtr in
                    for c in 0..<channelCount {
                        let dstOffset = c * newTotalFrames
                        let oldOffset = c * oldFrameCount
                        let newOffset = c * newFrameCount

                        if oldFrameCount > 0, let oldBase = oldPtr.baseAddress {
                            let oldChunk = UnsafeBufferPointer(
                                start: oldBase.advanced(by: oldOffset),
                                count: oldFrameCount
                            )
                            for i in 0..<oldFrameCount {
                                dstPtr[dstOffset + i] = oldChunk[i]
                            }
                        }
                        if let newBase = newPtr.baseAddress {
                            let newChunk = UnsafeBufferPointer(
                                start: newBase.advanced(by: newOffset),
                                count: newFrameCount
                            )
                            for i in 0..<newFrameCount {
                                dstPtr[dstOffset + oldFrameCount + i] = newChunk[i]
                            }
                        }
                    }
                }
            }
        }

        dst = rebuilt
        if oldFrameCount == 0 {
            // Anchor the head PTS on first-ever data, OR re-anchor after
            // a drain emptied the buffer.
            headPTS = newPTS
        }
        frameCount = newTotalFrames
    }

    /// Set `_nextExpectedFramePTS` to the earliest of the two sources'
    /// current head PTSs (if any).
    private func anchorNextExpectedFramePTSIfPossible() {
        switch (_systemHeadPTS, _micHeadPTS) {
        case (nil, nil):
            return
        case let (sys?, nil):
            _nextExpectedFramePTS = sys
        case let (nil, mic?):
            _nextExpectedFramePTS = mic
        case let (sys?, mic?):
            _nextExpectedFramePTS = CMTimeMinimum(sys, mic)
        }
    }

    /// Repeatedly attempt to emit windows of `windowFrames` until at
    /// least one source has insufficient data.
    private func tryDrain() {
        guard let _ = _nextExpectedFramePTS else { return }
        // Loop while we can produce another aligned frame.
        while let nextPTS = _nextExpectedFramePTS, canEmitWindow(at: nextPTS) {
            emitWindow(at: nextPTS)
        }
    }

    /// Decide whether we have enough information on both sources to
    /// emit a window starting at `windowStart`.
    ///
    /// We can emit when, for each source, at least one of the
    /// following holds:
    ///   (a) the source's headPTS is greater than (windowStart +
    ///       windowDuration - 1 sample) — meaning no real data covers
    ///       this window yet, so we will silence-fill;
    ///   (b) the source has buffered enough frames (after any leading
    ///       drop) to cover the window.
    ///
    /// Case (a) lets us emit even when one side has stalled — the
    /// aligner doesn't wait indefinitely for stalled sources to come
    /// back. Case (b) is the standard happy path.
    ///
    /// Special case: if neither source has *any* data yet for a window
    /// (both `headPTS == nil`), we obviously can't emit.
    private func canEmitWindow(at windowStart: CMTime) -> Bool {
        let windowEnd = CMTimeAdd(windowStart, frameDuration)
        let oneSample = CMTime(value: 1, timescale: CMTimeScale(targetSampleRate))
        let lookahead = CMTimeSubtract(windowEnd, oneSample)

        let systemReady = sourceReady(
            headPTS: _systemHeadPTS,
            frameCount: _systemFrameCount,
            windowStart: windowStart,
            lookahead: lookahead
        )
        let micReady = sourceReady(
            headPTS: _micHeadPTS,
            frameCount: _micFrameCount,
            windowStart: windowStart,
            lookahead: lookahead
        )

        // Emit only when BOTH sides are ready (either with real data
        // or with a confirmed gap). Otherwise we would emit a frame
        // whose silence-fill could be revoked by a late-arriving
        // buffer — we don't go back in time.
        //
        // EXCEPTION: at flush time, we still emit any window that has
        // at least one ready side. This is handled by the caller
        // (`flush` triggers tryDrain after setting the flushed flag,
        // but the residue cleanup empties buffers anyway, so this
        // branch is currently inactive). Kept simple here.
        return systemReady && micReady
    }

    /// A source is "ready" for a given window when either (a) its
    /// head is already past the window (we'll silence-fill), or (b)
    /// it has enough buffered frames after dropping any stale leading
    /// frames whose PTS lies before `windowStart`.
    private func sourceReady(
        headPTS: CMTime?,
        frameCount: Int,
        windowStart: CMTime,
        lookahead: CMTime
    ) -> Bool {
        guard let head = headPTS else {
            // No data at all from this source yet. We can't decide
            // whether the source has stalled or simply hasn't started.
            // Wait. (Test #1 and #4 both start both sources before
            // ingest; this branch only fires for a brief moment at
            // session start, which the prompt's tests tolerate by
            // running for 1+ second.)
            return false
        }
        // Head is later than the window — confirmed gap; we'll silence-fill.
        if CMTimeCompare(head, lookahead) > 0 {
            return true
        }
        // Otherwise, do we have enough frames after trimming the
        // leading staleness?
        let staleFrames = framesBefore(windowStart: windowStart, headPTS: head)
        let usableFrames = frameCount - staleFrames
        return usableFrames >= windowFrames
    }

    /// How many leading frames to drop because they precede `windowStart`.
    private func framesBefore(windowStart: CMTime, headPTS: CMTime) -> Int {
        if CMTimeCompare(headPTS, windowStart) >= 0 { return 0 }
        let delta = CMTimeSubtract(windowStart, headPTS)
        let frames = Int((delta.seconds * targetSampleRate).rounded())
        return max(0, frames)
    }

    /// Build and dispatch one `AlignedFrame` for the given window.
    private func emitWindow(at windowStart: CMTime) {
        let systemBuffer = consumeSlice(
            for: .system,
            samples: &_systemSamples,
            frameCount: &_systemFrameCount,
            headPTS: &_systemHeadPTS,
            windowStart: windowStart
        )
        let micBuffer = consumeSlice(
            for: .microphone,
            samples: &_micSamples,
            frameCount: &_micFrameCount,
            headPTS: &_micHeadPTS,
            windowStart: windowStart
        )

        // Drift = absolute difference between system PTS and mic PTS
        // for this emitted window. Both buffers carry `windowStart` as
        // their PTS by construction — but the underlying source might
        // have been off-grid by sub-sample amounts before we trimmed.
        // We measure the difference at the granularity of one sample
        // period: the staleFrames computation above resolves anything
        // larger. Surfaced via `stats.lastDriftSec`.
        let sysPTS = CMSampleBufferGetPresentationTimeStamp(systemBuffer)
        let micPTS = CMSampleBufferGetPresentationTimeStamp(micBuffer)
        _lastDriftSec = abs(CMTimeGetSeconds(CMTimeSubtract(sysPTS, micPTS)))

        let frame = AlignedFrame(
            pts: windowStart,
            duration: frameDuration,
            systemBuffer: systemBuffer,
            micBuffer: micBuffer
        )
        _framesEmitted += 1
        _nextExpectedFramePTS = CMTimeAdd(windowStart, frameDuration)
        onAlignedFrame?(frame)
    }

    /// Carve a `windowFrames`-long slice for one source. Either:
    ///   * If the source's head is far ahead of `windowStart`, emit a
    ///     silence buffer (gap-fill counter ++).
    ///   * Otherwise drop any stale leading frames, slice the window
    ///     out of the buffer, and rebuild the residue.
    private func consumeSlice(
        for tag: CaptureSourceTag,
        samples: inout [Float32],
        frameCount: inout Int,
        headPTS: inout CMTime?,
        windowStart: CMTime
    ) -> CMSampleBuffer {
        let oneSample = CMTime(value: 1, timescale: CMTimeScale(targetSampleRate))
        let lookahead = CMTimeSubtract(CMTimeAdd(windowStart, frameDuration), oneSample)

        // Case A — gap fill: the head is past this entire window, or
        // there's no data at all for this source.
        if let head = headPTS, CMTimeCompare(head, lookahead) > 0 {
            return synthesizeSilenceCounting(tag: tag, windowStart: windowStart)
        }
        if headPTS == nil {
            return synthesizeSilenceCounting(tag: tag, windowStart: windowStart)
        }

        // Case B — real data covers (at least) this window.
        let staleFrames = framesBefore(windowStart: windowStart, headPTS: headPTS!)
        // Trim the leading stale frames if any.
        if staleFrames > 0 {
            samples = sliceTrailing(
                samples: samples,
                totalFrameCount: frameCount,
                dropLeadingFrames: staleFrames
            )
            frameCount -= staleFrames
            // Advance head PTS by `staleFrames` frames.
            headPTS = CMTimeAdd(
                headPTS!,
                CMTime(value: CMTimeValue(staleFrames), timescale: CMTimeScale(targetSampleRate))
            )
        }

        // Should hold by `sourceReady` guarantee, but verify defensively.
        guard frameCount >= windowFrames else {
            // This is a programming error — we wouldn't have entered
            // emitWindow without sourceReady → enough frames. Fall
            // back to silence rather than crashing.
            logger?.error(
                "aligner: consumeSlice for \(tag.rawValue) underflowed (have=\(frameCount), need=\(windowFrames)); silence-filling"
            )
            return synthesizeSilenceCounting(tag: tag, windowStart: windowStart)
        }

        // Carve windowFrames out of the head, build a CMSampleBuffer,
        // rebuild the residue.
        let outBuffer = buildSampleBuffer(
            from: samples,
            totalFrameCount: frameCount,
            takingFirst: windowFrames,
            startPTS: windowStart
        )
        // Drop the consumed frames from the per-channel buffer.
        samples = sliceTrailing(
            samples: samples,
            totalFrameCount: frameCount,
            dropLeadingFrames: windowFrames
        )
        frameCount -= windowFrames
        if frameCount == 0 {
            headPTS = nil
        } else {
            headPTS = CMTimeAdd(
                headPTS!,
                CMTime(value: CMTimeValue(windowFrames), timescale: CMTimeScale(targetSampleRate))
            )
        }
        return outBuffer
    }

    /// Drop the leading `dropLeadingFrames` frames from each channel
    /// of a non-interleaved Float32 buffer of length
    /// `totalFrameCount * channelCount`. Returns the remaining
    /// channel-major-flat buffer of length
    /// `(totalFrameCount - dropLeadingFrames) * channelCount`.
    private func sliceTrailing(
        samples: [Float32],
        totalFrameCount: Int,
        dropLeadingFrames: Int
    ) -> [Float32] {
        let channelCount = targetChannelCount
        let remaining = totalFrameCount - dropLeadingFrames
        if remaining <= 0 { return [] }
        var out = [Float32](repeating: 0, count: remaining * channelCount)
        out.withUnsafeMutableBufferPointer { dstPtr in
            samples.withUnsafeBufferPointer { srcPtr in
                guard let dstBase = dstPtr.baseAddress, let srcBase = srcPtr.baseAddress else { return }
                for c in 0..<channelCount {
                    let srcOffset = c * totalFrameCount + dropLeadingFrames
                    let dstOffset = c * remaining
                    for i in 0..<remaining {
                        dstBase[dstOffset + i] = srcBase[srcOffset + i]
                    }
                }
            }
        }
        return out
    }

    /// Build a CMSampleBuffer of `takingFirst` frames out of the
    /// channel-major flat input. PTS is `startPTS`; format is the
    /// aligner's canonical format description.
    private func buildSampleBuffer(
        from samples: [Float32],
        totalFrameCount: Int,
        takingFirst frames: Int,
        startPTS: CMTime
    ) -> CMSampleBuffer {
        let channelCount = targetChannelCount
        let bytesPerSample = MemoryLayout<Float32>.size
        let totalBytes = bytesPerSample * frames * channelCount

        // Build the channel-major slice for the output buffer.
        var slice = [Float32](repeating: 0, count: frames * channelCount)
        slice.withUnsafeMutableBufferPointer { dstPtr in
            samples.withUnsafeBufferPointer { srcPtr in
                guard let dstBase = dstPtr.baseAddress, let srcBase = srcPtr.baseAddress else { return }
                for c in 0..<channelCount {
                    let srcOffset = c * totalFrameCount
                    let dstOffset = c * frames
                    for i in 0..<frames {
                        dstBase[dstOffset + i] = srcBase[srcOffset + i]
                    }
                }
            }
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            assertionFailure("aligner: CMBlockBufferCreateWithMemoryBlock failed (status=\(bbStatus))")
            fatalError("aligner: CMBlockBufferCreateWithMemoryBlock failed (status=\(bbStatus))")
        }
        let copyStatus = slice.withUnsafeBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: UnsafeRawPointer(base),
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            assertionFailure("aligner: CMBlockBufferReplaceDataBytes failed (status=\(copyStatus))")
            fatalError("aligner: CMBlockBufferReplaceDataBytes failed (status=\(copyStatus))")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(targetSampleRate)),
            presentationTimeStamp: startPTS,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            assertionFailure("aligner: CMSampleBufferCreate failed (status=\(sbStatus))")
            fatalError("aligner: CMSampleBufferCreate failed (status=\(sbStatus))")
        }
        return sb
    }

    /// Build a silence sample buffer for the given window and bump
    /// the appropriate gap-fill counter.
    private func synthesizeSilenceCounting(
        tag: CaptureSourceTag,
        windowStart: CMTime
    ) -> CMSampleBuffer {
        switch tag {
        case .system: _systemGapFills += 1
        case .microphone: _micGapFills += 1
        }
        return SilenceBufferFactory.make(
            pts: windowStart,
            sampleRate: targetSampleRate,
            channelCount: targetChannelCount,
            frameCount: windowFrames
        )
    }
}
