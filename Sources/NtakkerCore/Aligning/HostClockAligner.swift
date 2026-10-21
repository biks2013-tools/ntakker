// NtakkerCore/Aligning/HostClockAligner.swift — see project-design.md §2.9
// and `docs/research/scstream-audio-only.md` §4 (gap-fill recipe).
//
// Host-clock-driven cross-source aligner. Two capture sources (system,
// mic) deliver `CaptureBuffer`s on their own queues; the aligner
// serializes them onto a private serial queue, places their samples on a
// shared sample timeline by PTS, and emits `AlignedFrame`s of fixed
// `frameDuration` (default 100 ms).
//
// Algorithm (rewritten 2026-10-16, EVAL-2026-10-16 CAP-1 / CAP-2 / C1 /
// C5, plan-021):
//
//   1. Timeline. Every PTS is converted to an absolute sample index at
//      `targetSampleRate`. Windows start at the first ingested buffer's
//      sample index and advance by `windowFrames`. `cursor` is the start
//      of the next window to emit; nothing before it is ever emitted
//      again (the aligner never goes back in time).
//
//   2. Per source, a queue of chunks (one per ingested buffer, samples
//      copied once, channel-major). A chunk is placed at its PTS:
//        * within `snapToleranceFrames` of the previous chunk's end →
//          snapped to it (contiguous; absorbs PTS jitter);
//        * further ahead → a hole: left empty (emitted as silence) and
//          counted once as a gap-fill (CAP-1 — the old flat buffer
//          collapsed such holes, shifting the track);
//        * behind → the overlapping head is trimmed.
//      Samples before `cursor` are dropped on arrival.
//
//   3. A window [ws, we) is emitted when each source either covers `we`
//      (its last chunk ends at or past it) or lags the other source by
//      more than `maxSkewFrames` (stalled or absent — CAP-2; the old code
//      waited forever and the other source's backlog grew without
//      bound). A stalled window is silence-filled and counted.
//
//   4. Emission copies each chunk's overlap with the window straight
//      into the output block buffer; fully consumed chunks are dropped.
//      No per-ingest or per-window rebuilds of the whole backlog (C1).
//
//   5. `flush()` drains complete windows, then emits the remaining
//      partial windows padded with silence (the tail used to be
//      discarded). Padding windows are not counted as gap-fills.
//
//   6. `lastDriftSec` is the absolute difference between the two
//      sources' current snap deviations — the residual misalignment
//      between the tracks (C5; it used to compare two PTS that were
//      equal by construction).
//
// Concurrency: `ingest` is thread-safe (queue-hop). All mutable state is
// confined to `serialQueue`. `onAlignedFrame` is invoked on
// `serialQueue` so consumers must not block (recorders enqueue onto their
// own writer queue per design §2.10).

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

    // MARK: - Live taps (Phase B / plan-003 §LT-6)

    /// Token returned by `addLiveTap(_:)`. Pass back to `removeLiveTap(_:)`
    /// to detach the tap. The token is opaque and identity-based — taps
    /// are looked up by reference equality, not by closure identity (Swift
    /// closures are not `Equatable`).
    ///
    /// `final class` so multiple taps can be distinguished by `===`.
    public final class TapToken: Sendable {
        // The closure is held on the aligner's side; the token is just
        // an identity handle. Sendable because it carries no mutable
        // state.
        fileprivate init() {}
    }

    /// Install a synchronous, non-blocking tap that observes every
    /// `AlignedFrame` AFTER the recorder write callback runs.
    ///
    /// **Threading**: the closure is invoked on the aligner's serial
    /// dispatch queue (`ntakker-cli.aligner.serial`), inline with the
    /// recorder's write. **The closure MUST be lossy / non-blocking**:
    ///
    /// 1. No `await`, no `try await`, no `Task.sleep`.
    /// 2. No allocation > 1 KB; no I/O; no logging (logging is async
    ///    deferred — typically it routes through a `nonisolated`
    ///    actor entry point that yields onto an `AsyncStream`).
    /// 3. No actor hops that suspend. Calling a `nonisolated` function
    ///    on an actor is fine if that function is itself synchronous.
    /// 4. No re-entrant calls back into the aligner (`ingest`, `flush`,
    ///    `addLiveTap`, `removeLiveTap`). Such a call would dead-lock on
    ///    the serial queue.
    ///
    /// Violating any of the above blocks the aligner's queue and
    /// therefore stalls the recorder — see project-design.md §LT-6.2.
    ///
    /// `addLiveTap(_:)` is idempotent in the sense that calling it
    /// multiple times with the same closure registers the closure
    /// multiple times; each call returns a distinct `TapToken`.
    ///
    /// - Parameter closure: The synchronous tap.
    /// - Returns: A `TapToken` to pass to `removeLiveTap(_:)` for
    ///   detachment.
    @discardableResult
    public func addLiveTap(_ closure: @escaping @Sendable (AlignedFrame) -> Void) -> TapToken {
        let token = TapToken()
        serialQueue.sync {
            _liveTaps.append((token, closure))
        }
        return token
    }

    /// Detach a previously-installed live tap.
    ///
    /// The lookup is by reference equality on the returned
    /// `TapToken`; passing a stale or unknown token is a no-op
    /// (the tap is simply not found). Safe to call from any thread.
    public func removeLiveTap(_ token: TapToken) {
        serialQueue.sync {
            _liveTaps.removeAll { $0.token === token }
        }
    }

    /// Mute or unmute a source (2026-10-21). A muted source's slice of
    /// every following window is emitted as silence — to the recorder
    /// and every live tap (transcription) alike — while its timing and
    /// the other source are untouched, so the tracks stay aligned.
    /// The source keeps being captured (meters and the echo-canceller
    /// reference still see it). Takes effect from the next window.
    /// Thread-safe; must not be called from a tap closure.
    public func setMuted(_ muted: Bool, for source: CaptureSourceTag) {
        serialQueue.sync {
            if muted { _muted.insert(source) } else { _muted.remove(source) }
        }
    }

    /// The sources currently muted. Thread-safe.
    public var mutedSources: Set<CaptureSourceTag> {
        serialQueue.sync { _muted }
    }

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

    private let serialQueue = DispatchQueue(label: "ntakker-cli.aligner.serial")
    private let logger: Logger?

    /// Live taps registered via `addLiveTap(_:)`. Mutated only on
    /// `serialQueue`; read on `serialQueue` inside `emitWindow(...)` so
    /// the dispatch is consistent with `onAlignedFrame`. The tuple keeps
    /// the token alongside the closure so `removeLiveTap(_:)` can look
    /// up entries by reference equality.
    private var _liveTaps: [(token: TapToken, closure: @Sendable (AlignedFrame) -> Void)] = []

    /// Sources emitted as silence (see `setMuted(_:for:)`).
    private var _muted: Set<CaptureSourceTag> = []

    /// Format description used to wrap silence + emitted buffers.
    private let formatDescription: CMAudioFormatDescription

    /// Integral sample rate used as the CMTime timescale of the timeline.
    private let timescale: CMTimeScale

    /// PTS deviation (in frames) absorbed by snapping a chunk onto the
    /// previous one. Larger deviations are real holes / overlaps.
    static let snapToleranceSeconds: Double = 0.005
    private let snapToleranceFrames: Int64

    /// How far one source may run ahead of the other before the lagging
    /// one is treated as stalled for the next window.
    static let maxSkewSeconds: Double = 0.4
    private let maxSkewFrames: Int64

    /// One ingested buffer, placed on the timeline.
    private struct Chunk {
        /// Absolute sample index of the first frame.
        var start: Int64
        var frames: Int
        /// Channel-major samples (`frames` per channel).
        var samples: [Float32]
        var end: Int64 { start + Int64(frames) }
    }

    /// Per-source placement state.
    private struct Track {
        var chunks: [Chunk] = []
        /// Index of the first live chunk (amortised O(1) pops).
        var head: Int = 0
        /// End of the last placed chunk; `nil` until the first buffer.
        var lastEnd: Int64?
        /// Snap deviation of the most recent chunk, in frames (for C5).
        var lastDeviation: Int64 = 0
        /// Holes inside the stream not yet past the cursor; `counted`
        /// once the hole has been tallied as a gap-fill.
        var gaps: [(range: Range<Int64>, counted: Bool)] = []

        var live: ArraySlice<Chunk> { chunks[head...] }

        mutating func popConsumed(before position: Int64) {
            while head < chunks.count, chunks[head].end <= position { head += 1 }
            if head > 32, head * 2 > chunks.count {
                chunks.removeFirst(head)
                head = 0
            }
            gaps.removeAll { $0.range.upperBound <= position }
        }

        mutating func reset() {
            chunks.removeAll(keepingCapacity: false)
            head = 0
            gaps.removeAll()
        }
    }

    private var _system = Track()
    private var _mic = Track()

    /// Start of the next window to emit; `nil` until the first buffer.
    private var _cursor: Int64?

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
    ///     `LoggerFactory.make("ntakker-cli.aligner")`.
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
        self.timescale = CMTimeScale(targetSampleRate.rounded())
        self.snapToleranceFrames = Int64((Self.snapToleranceSeconds * targetSampleRate).rounded())
        self.maxSkewFrames = Int64((Self.maxSkewSeconds * targetSampleRate).rounded())

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
    /// queue: returns after any in-flight ingest has completed, every
    /// complete window has been emitted, and the remaining partial
    /// windows have been emitted padded with silence.
    public func flush() {
        serialQueue.sync { [self] in
            guard !self._flushed else { return }
            self._flushed = true
            self.tryDrain()
            self.drainTailPadded()
            self._system.reset()
            self._mic.reset()
        }
    }

    /// Design §2.9 alias for `flush()`.
    public func drain() {
        flush()
    }

    // MARK: - Core algorithm (queue-confined)

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

        // One copy: block buffer → channel-major Float32 array.
        var samples = [Float32](repeating: 0, count: frameCount * targetChannelCount)
        let totalBytes = frameCount * targetChannelCount * MemoryLayout<Float32>.size
        guard let bb = CMSampleBufferGetDataBuffer(sb) else {
            logger?.error("aligner: ingest dropped — buffer has no data buffer")
            return
        }
        let copyStatus = samples.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: totalBytes, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            logger?.error("aligner: CMBlockBufferCopyDataBytes failed (status=\(copyStatus))")
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let start = sampleIndex(of: pts)
        if _cursor == nil { _cursor = start }

        switch capture.source {
        case .system:
            place(Chunk(start: start, frames: frameCount, samples: samples), on: &_system)
        case .microphone:
            place(Chunk(start: start, frames: frameCount, samples: samples), on: &_mic)
        }
        updateDrift()
        tryDrain()
    }

    /// Absolute sample index of `pts` on the aligner's timeline.
    private func sampleIndex(of pts: CMTime) -> Int64 {
        CMTimeConvertScale(pts, timescale: timescale, method: .roundHalfAwayFromZero).value
    }

    /// Place `chunk` on `track` per the snap / hole / overlap rules.
    private func place(_ chunk: Chunk, on track: inout Track) {
        var chunk = chunk
        if let lastEnd = track.lastEnd {
            let deviation = chunk.start - lastEnd
            if abs(deviation) <= snapToleranceFrames {
                chunk.start = lastEnd
                track.lastDeviation = deviation
            } else if deviation > 0 {
                // A hole inside the stream (dropped buffer, PTS jump,
                // capture restart): keep the true placement.
                track.gaps.append((range: lastEnd..<chunk.start, counted: false))
                track.lastDeviation = 0
            } else {
                // Overlap: the head of this chunk duplicates time already
                // placed. Trim it.
                track.lastDeviation = 0
                chunk = trimmed(chunk, droppingFrames: Int(-deviation))
            }
        }
        // Never place anything before the emission cursor.
        if let cursor = _cursor, chunk.start < cursor {
            chunk = trimmed(chunk, droppingFrames: Int(cursor - chunk.start))
        }
        guard chunk.frames > 0 else {
            track.lastEnd = max(track.lastEnd ?? chunk.start, chunk.start)
            return
        }
        track.lastEnd = chunk.end
        track.chunks.append(chunk)
    }

    /// Drop the first `n` frames of every channel of `chunk`.
    private func trimmed(_ chunk: Chunk, droppingFrames n: Int) -> Chunk {
        let drop = min(max(0, n), chunk.frames)
        guard drop > 0 else { return chunk }
        let remaining = chunk.frames - drop
        var out = Chunk(start: chunk.start + Int64(drop), frames: remaining, samples: [])
        guard remaining > 0 else { return out }
        out.samples.reserveCapacity(remaining * targetChannelCount)
        for c in 0..<targetChannelCount {
            let base = c * chunk.frames + drop
            out.samples.append(contentsOf: chunk.samples[base..<(base + remaining)])
        }
        return out
    }

    private func updateDrift() {
        let diff = abs(_system.lastDeviation - _mic.lastDeviation)
        _lastDriftSec = Double(diff) / targetSampleRate
    }

    /// Emit every window both sources are ready for.
    private func tryDrain() {
        while let ws = _cursor {
            let we = ws + Int64(windowFrames)
            guard let sysStalled = readiness(of: _system, other: _mic, windowEnd: we),
                  let micStalled = readiness(of: _mic, other: _system, windowEnd: we)
            else { return }
            emitWindow(at: ws, countSystemStall: sysStalled, countMicStall: micStalled)
        }
    }

    /// `nil` when `track` is not ready for the window ending at
    /// `windowEnd`; otherwise whether it is being stall-filled.
    private func readiness(of track: Track, other: Track, windowEnd: Int64) -> Bool? {
        if let end = track.lastEnd, end >= windowEnd { return false }
        // Not covered. Ready only if the other source is far enough
        // ahead that this one counts as stalled (or absent).
        if let otherEnd = other.lastEnd, otherEnd >= windowEnd + maxSkewFrames { return true }
        return nil
    }

    /// Emit the remaining partial windows, padded with silence, until
    /// both sources' data has been written out.
    private func drainTailPadded() {
        let furthest = max(_system.lastEnd ?? Int64.min, _mic.lastEnd ?? Int64.min)
        while let ws = _cursor, ws < furthest {
            emitWindow(at: ws, countSystemStall: false, countMicStall: false)
        }
    }

    /// Build and dispatch one `AlignedFrame` for the window at `ws`.
    private func emitWindow(at ws: Int64, countSystemStall: Bool, countMicStall: Bool) {
        let we = ws + Int64(windowFrames)
        let systemBuffer = render(&_system, tag: .system, windowStart: ws, windowEnd: we, stalled: countSystemStall)
        let micBuffer = render(&_mic, tag: .microphone, windowStart: ws, windowEnd: we, stalled: countMicStall)

        let pts = CMTime(value: ws, timescale: timescale)
        let frame = AlignedFrame(
            pts: pts,
            duration: frameDuration,
            systemBuffer: systemBuffer,
            micBuffer: micBuffer
        )
        _framesEmitted += 1
        _cursor = we
        onAlignedFrame?(frame)

        // Live taps (Phase B / project-design §LT-6). Snapshot the array
        // BEFORE invoking each tap so a tap that hypothetically called
        // `removeLiveTap(_:)` would not mutate the array we are
        // iterating. The current contract forbids re-entrant calls back
        // into the aligner from a tap closure (it would dead-lock the
        // serial queue), but the snapshot is cheap and keeps the
        // iteration safe under any future relaxation of that rule.
        let snapshot = _liveTaps
        for entry in snapshot {
            entry.closure(frame)
        }
    }

    /// Render one source's slice of the window [ws, we): chunk overlaps
    /// copied in place, silence elsewhere. Updates gap-fill counters and
    /// drops consumed chunks.
    private func render(
        _ track: inout Track,
        tag: CaptureSourceTag,
        windowStart ws: Int64,
        windowEnd we: Int64,
        stalled: Bool
    ) -> CMSampleBuffer {
        // Gap-fill tally: each hole once (at the first window it
        // touches, so a hole straddling a window boundary is one fill),
        // plus one per stall-filled window.
        var fills = stalled ? 1 : 0
        for i in track.gaps.indices where !track.gaps[i].counted
            && track.gaps[i].range.lowerBound < we && track.gaps[i].range.upperBound > ws {
            track.gaps[i].counted = true
            fills += 1
        }
        switch tag {
        case .system: _systemGapFills += fills
        case .microphone: _micGapFills += fills
        }

        let overlapping = track.live.filter { $0.start < we && $0.end > ws }
        let buffer: CMSampleBuffer
        if overlapping.isEmpty || _muted.contains(tag) {
            buffer = SilenceBufferFactory.make(
                pts: CMTime(value: ws, timescale: timescale),
                sampleRate: targetSampleRate,
                channelCount: targetChannelCount,
                frameCount: windowFrames
            )
        } else {
            buffer = buildSampleBuffer(windowStart: ws, chunks: overlapping)
        }

        track.popConsumed(before: we)
        if stalled {
            // The stalled window is now emitted as silence; data for it
            // that arrives later is dropped by the cursor check.
            track.lastEnd = max(track.lastEnd ?? we, we)
        }
        return buffer
    }

    /// One window of channel-major Float32, written straight into the
    /// output block buffer: zeros, then each chunk's overlap.
    private func buildSampleBuffer(windowStart ws: Int64, chunks: [Chunk]) -> CMSampleBuffer {
        let channelCount = targetChannelCount
        let frames = windowFrames
        let totalBytes = MemoryLayout<Float32>.size * frames * channelCount

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
        var dataPointer: UnsafeMutablePointer<CChar>?
        let ptrStatus = CMBlockBufferGetDataPointer(
            bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer
        )
        guard ptrStatus == kCMBlockBufferNoErr, let raw = dataPointer else {
            assertionFailure("aligner: CMBlockBufferGetDataPointer failed (status=\(ptrStatus))")
            fatalError("aligner: CMBlockBufferGetDataPointer failed (status=\(ptrStatus))")
        }
        raw.withMemoryRebound(to: Float32.self, capacity: frames * channelCount) { out in
            out.initialize(repeating: 0, count: frames * channelCount)
            for chunk in chunks {
                let from = max(chunk.start, ws)
                let to = min(chunk.end, ws + Int64(frames))
                guard to > from else { continue }
                let count = Int(to - from)
                let srcOffset = Int(from - chunk.start)
                let dstOffset = Int(from - ws)
                chunk.samples.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    for c in 0..<channelCount {
                        (out + c * frames + dstOffset).update(
                            from: srcBase + c * chunk.frames + srcOffset, count: count)
                    }
                }
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: ws, timescale: timescale),
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
}
