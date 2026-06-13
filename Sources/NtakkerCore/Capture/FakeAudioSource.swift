// NtakkerCore/Capture/FakeAudioSource.swift — see project-design.md §2.8.3
//
// Phase E (plan-001) — finalized in-process fake. Generates non-interleaved
// Float32 sine-wave (or silence / dirac) `CMSampleBuffer`s on a periodic
// `DispatchSourceTimer`, emits them through the `AudioSource.onSampleBuffer`
// callback, and supports both `SystemAudioSource` and `MicrophoneSource`
// roles via the `tag` initializer parameter.
//
// The fake is the linchpin of every `NtakkerCore` unit test: the aligner,
// silence-fill, mixer, and recorders all consume `CaptureBuffer`s
// indistinguishable in shape (format description, PTS domain, frame
// count) from what real `SCStream` and `AVCaptureSession` deliver. See
// `docs/research/scstream-audio-only.md` §1–§2 and §5 for the real-source
// shape this fake reproduces.
//
// CMSampleBuffer synthesis flow per tick (pseudo-code):
//
//   1. frames = Int(sampleRate * bufferDurationSeconds)
//   2. pts    = anchorPTS + CMTime(emittedFrames, timescale: sampleRate)
//   3. allocate one CMBlockBuffer of size
//        channelCount * frames * sizeof(Float32)
//      with CMBlockBufferCreateWithMemoryBlock(...)
//   4. for each channel c in 0..<channelCount:
//        for each frame f in 0..<frames:
//          let absoluteFrame = emittedFrames + f
//          samples[c * frames + f] = waveform.sample(absoluteFrame, ...)
//      then write `samples` into the block buffer via
//      CMBlockBufferReplaceDataBytes
//   5. timing = CMSampleTimingInfo(duration: frames@sampleRate,
//                                   pts: pts, dts: .invalid)
//   6. CMSampleBufferCreate(... sampleCount: frames,
//                                sampleSizeEntryCount: 0 ...)
//   7. emittedFrames += frames
//   8. wrap in CaptureBuffer(source: tag, buffer: sb)
//   9. invoke onSampleBuffer(captureBuffer)

import Foundation
import CoreMedia
import Logging

public final class FakeAudioSource: AudioSource, @unchecked Sendable {

    // MARK: - Public types

    /// What kind of audio data the fake synthesizes.
    public enum Waveform: Sendable, Equatable {
        /// Continuous sine at `frequencyHz`. Identical waveform on every
        /// channel.
        case sine(frequencyHz: Double)
        /// Pure silence (all samples = 0). Useful as a control case for
        /// the aligner / silence-fill verification.
        case silence
        /// A unit impulse: sample 0 of frame 0 of channel 0 = 1.0, rest
        /// = 0. Useful for round-trip latency tests.
        case dirac
    }

    // MARK: - Stored state

    /// The source tag carried on every emitted `CaptureBuffer`.
    public let tag: CaptureSourceTag

    private let waveform: Waveform
    private let sampleRate: Double
    private let channelCount: Int
    private let bufferDuration: TimeInterval
    private let hostClock: CMClock
    private let logger: Logger?

    /// Lazily built when `start()` is called (so the format description
    /// is available before the first emission).
    private var _formatDescription: CMAudioFormatDescription?

    /// Frames to emit per tick.
    private let framesPerBuffer: Int

    /// Serial queue that drives the timer and runs the synthesis. Named
    /// per role for legibility in stack traces.
    private let queue: DispatchQueue

    /// State guarded by `queue`.
    private var timer: DispatchSourceTimer?
    private var anchorPTS: CMTime = .invalid
    private var emittedFrames: Int64 = 0
    private var running: Bool = false
    private var skipNextTick: Bool = false
    private var pendingPTSJump: CMTime = .zero

    // MARK: - AudioSource conformance

    public var formatDescription: CMAudioFormatDescription? {
        // Computed up-front in `start()` so callers can read it
        // immediately after the source has been started.
        queue.sync { _formatDescription }
    }

    public var onSampleBuffer: ((CaptureBuffer) -> Void)?
    public var levelTap: ((CaptureBuffer) -> Void)?

    // MARK: - Init

    public init(
        tag: CaptureSourceTag,
        frequencyHz: Double,
        channelCount: Int = 2,
        sampleRate: Double = 48_000,
        bufferDurationMs: Double = 20,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        logger: Logger? = nil
    ) {
        precondition(channelCount >= 1, "channelCount must be >= 1")
        precondition(sampleRate > 0, "sampleRate must be > 0")
        precondition(bufferDurationMs > 0, "bufferDurationMs must be > 0")

        self.tag = tag
        self.waveform = .sine(frequencyHz: frequencyHz)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferDuration = bufferDurationMs / 1_000.0
        self.hostClock = hostClock
        self.logger = logger
        self.framesPerBuffer = Int((bufferDurationMs / 1_000.0) * sampleRate)
        self.queue = DispatchQueue(label: "ntakker-cli.capture.fake.\(tag.rawValue)")
    }

    /// Designated initializer accepting an explicit `Waveform`. Used by
    /// tests that need silence or dirac fakes.
    public init(
        tag: CaptureSourceTag,
        waveform: Waveform,
        channelCount: Int = 2,
        sampleRate: Double = 48_000,
        bufferDurationMs: Double = 20,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        logger: Logger? = nil
    ) {
        precondition(channelCount >= 1, "channelCount must be >= 1")
        precondition(sampleRate > 0, "sampleRate must be > 0")
        precondition(bufferDurationMs > 0, "bufferDurationMs must be > 0")

        self.tag = tag
        self.waveform = waveform
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferDuration = bufferDurationMs / 1_000.0
        self.hostClock = hostClock
        self.logger = logger
        self.framesPerBuffer = Int((bufferDurationMs / 1_000.0) * sampleRate)
        self.queue = DispatchQueue(label: "ntakker-cli.capture.fake.\(tag.rawValue)")
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if running {
                    cont.resume()
                    return
                }
                do {
                    _formatDescription = try Self.makeFormatDescription(
                        sampleRate: sampleRate,
                        channelCount: channelCount
                    )
                    anchorPTS = CMClockGetTime(hostClock)
                    emittedFrames = 0
                    skipNextTick = false
                    pendingPTSJump = .zero

                    let t = DispatchSource.makeTimerSource(queue: queue)
                    let intervalNs = UInt64(bufferDuration * 1_000_000_000.0)
                    t.schedule(
                        deadline: .now() + .nanoseconds(Int(intervalNs)),
                        repeating: .nanoseconds(Int(intervalNs)),
                        leeway: .milliseconds(1)
                    )
                    t.setEventHandler { [weak self] in
                        self?.tick()
                    }
                    timer = t
                    running = true
                    t.resume()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if !running {
                    cont.resume()
                    return
                }
                timer?.cancel()
                timer = nil
                running = false
                cont.resume()
            }
        }
    }

    /// Skip exactly the next emission to simulate a momentary capture
    /// stall — useful for exercising the aligner's gap-fill logic.
    public func skipNextEmission() {
        queue.async { [self] in
            skipNextTick = true
        }
    }

    /// Advance the next emitted PTS by `delta` (in addition to the
    /// regular per-buffer increment) — useful for testing aligner
    /// robustness against clock anomalies.
    public func injectPTSJump(by delta: CMTime) {
        queue.async { [self] in
            pendingPTSJump = CMTimeAdd(pendingPTSJump, delta)
        }
    }

    // MARK: - Convenience factories (per design §2.8.3)

    public static func makeSystem440Hz(logger: Logger? = nil) -> FakeAudioSource {
        FakeAudioSource(tag: .system, frequencyHz: 440, logger: logger)
    }

    public static func makeMic880Hz(logger: Logger? = nil) -> FakeAudioSource {
        FakeAudioSource(tag: .microphone, frequencyHz: 880, logger: logger)
    }

    // MARK: - Synthesis

    /// One timer tick on `queue`. Synthesizes a buffer (unless skipped)
    /// and dispatches it through `onSampleBuffer`.
    private func tick() {
        guard running else { return }

        if skipNextTick {
            skipNextTick = false
            // Keep `emittedFrames` advancing so the next emitted PTS
            // reflects the gap — that's what real capture stacks do
            // when they drop a buffer, and it's what the aligner expects
            // to detect via `nextExpectedAudioTime` mismatch.
            emittedFrames &+= Int64(framesPerBuffer)
            return
        }

        do {
            let sb = try makeSampleBuffer()
            let cb = CaptureBuffer(source: tag, buffer: sb)
            // Capture the callback under the queue, then invoke it
            // outside any lock — the contract says the callback runs on
            // the source's delivery queue, which `queue` is.
            onSampleBuffer?(cb)
            emittedFrames &+= Int64(framesPerBuffer)
        } catch {
            logger?.error("FakeAudioSource synthesis failed: \(error)")
        }
    }

    /// Build one Float32 non-interleaved CMSampleBuffer of
    /// `framesPerBuffer` frames at the configured rate.
    private func makeSampleBuffer() throws -> CMSampleBuffer {
        guard let fmt = _formatDescription else {
            throw FakeAudioSourceError.notStarted
        }

        let frames = framesPerBuffer
        let bytesPerSample = MemoryLayout<Float32>.size
        let bytesPerChannel = frames * bytesPerSample
        let totalBytes = bytesPerChannel * channelCount

        // 1. Compute PTS for this tick (host-clock domain).
        //    pts = anchorPTS + emittedFrames @ sampleRate, plus any
        //    injected PTS jump.
        let frameOffset = CMTime(
            value: emittedFrames,
            timescale: CMTimeScale(sampleRate)
        )
        var pts = CMTimeAdd(anchorPTS, frameOffset)
        if pendingPTSJump != .zero {
            pts = CMTimeAdd(pts, pendingPTSJump)
            pendingPTSJump = .zero
        }

        // 2. Allocate a zeroed CMBlockBuffer big enough for all channels
        //    concatenated (non-interleaved layout).
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
            throw FakeAudioSourceError.blockBufferAllocationFailed(bbStatus)
        }

        // 3. Fill with samples for the chosen waveform. Layout is
        //    non-interleaved: channel 0's `frames` floats, then channel
        //    1's `frames` floats, ...
        var samples = [Float32](repeating: 0, count: frames * channelCount)
        switch waveform {
        case .silence:
            // already zeroed
            break

        case .sine(let freq):
            let twoPiFOverFs = 2.0 * .pi * freq / sampleRate
            for f in 0..<frames {
                let absoluteFrame = Double(emittedFrames) + Double(f)
                let v = Float32(sin(twoPiFOverFs * absoluteFrame))
                for c in 0..<channelCount {
                    samples[c * frames + f] = v
                }
            }

        case .dirac:
            // First sample of channel 0 = 1.0, everything else stays 0.
            // Only emit the impulse on the very first buffer of the
            // session (emittedFrames == 0); subsequent buffers stay
            // silent so the impulse is a single, locatable event.
            if emittedFrames == 0 {
                samples[0] = 1.0
            }
        }

        // 4. Copy the float buffer into the CMBlockBuffer.
        let copyStatus = samples.withUnsafeBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: UnsafeRawPointer(base),
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw FakeAudioSourceError.blockBufferFillFailed(copyStatus)
        }

        // 5. Build timing info. The duration is one frame at the configured
        //    sample rate; CoreMedia multiplies by `numSamples` internally.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        // 6. Create the sample buffer. For non-interleaved LPCM the
        //    sample size is constant (encoded in the format description),
        //    so we pass sampleSizeEntryCount: 0 / sampleSizeArray: nil.
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw FakeAudioSourceError.sampleBufferCreateFailed(sbStatus)
        }
        return sb
    }

    // MARK: - Format description

    private static func makeFormatDescription(
        sampleRate: Double,
        channelCount: Int
    ) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            throw FakeAudioSourceError.formatDescriptionCreateFailed(status)
        }
        return fmt
    }
}

// MARK: - Marker conformances

extension FakeAudioSource: SystemAudioSource { }
extension FakeAudioSource: MicrophoneSource { }

// MARK: - Errors

public enum FakeAudioSourceError: Error, CustomStringConvertible {
    case notStarted
    case formatDescriptionCreateFailed(OSStatus)
    case blockBufferAllocationFailed(OSStatus)
    case blockBufferFillFailed(OSStatus)
    case sampleBufferCreateFailed(OSStatus)

    public var description: String {
        switch self {
        case .notStarted:
            return "FakeAudioSource.makeSampleBuffer called before start()"
        case .formatDescriptionCreateFailed(let s):
            return "CMAudioFormatDescriptionCreate failed (status=\(s))"
        case .blockBufferAllocationFailed(let s):
            return "CMBlockBufferCreateWithMemoryBlock failed (status=\(s))"
        case .blockBufferFillFailed(let s):
            return "CMBlockBufferReplaceDataBytes failed (status=\(s))"
        case .sampleBufferCreateFailed(let s):
            return "CMSampleBufferCreate failed (status=\(s))"
        }
    }
}
