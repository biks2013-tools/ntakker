import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NtakkerCore

/// EVAL-2026-10-16 CAP-1 / CAP-2 / C5 / flush padding (plan-021): the
/// aligner places samples by PTS, silence-fills holes and stalled
/// sources, pads the tail on flush, and reports the residual skew.
@Suite("HostClockAligner placement")
struct HostClockAlignerPlacementTests {

    private static let rate = 48_000.0
    private static let window = 4_800

    private func makeAligner() -> (HostClockAligner, Collector) {
        let aligner = HostClockAligner(
            targetSampleRate: Self.rate,
            targetChannelCount: 2,
            frameDuration: CMTime(value: CMTimeValue(Self.window), timescale: 48_000)
        )
        let collector = Collector()
        aligner.onAlignedFrame = { collector.append($0) }
        return (aligner, collector)
    }

    @Test("an in-stream hole is silence at its true position, not collapsed")
    func holeIsPlacedByPTS() {
        let (aligner, collector) = makeAligner()
        // Mic: contiguous 2 windows. System: 1 000 frames, a 2 000-frame
        // hole (dropped buffer), then the rest of the 2 windows.
        aligner.ingest(capture(.microphone, start: 0, frames: 9_600, value: 0.5))
        aligner.ingest(capture(.system, start: 0, frames: 1_000, value: 1))
        aligner.ingest(capture(.system, start: 3_000, frames: 6_600, value: 1))
        aligner.flush()

        let frames = collector.frames
        #expect(frames.count == 2)
        let sys = frames.flatMap { channel0($0.systemBuffer) }
        #expect(sys.count == 9_600)
        #expect(sys[0..<1_000].allSatisfy { $0 == 1 })
        #expect(sys[1_000..<3_000].allSatisfy { $0 == 0 }, "the hole stays a hole")
        #expect(sys[3_000..<9_600].allSatisfy { $0 == 1 }, "data after the hole keeps its PTS")
        #expect(aligner.stats.systemGapFills == 1, "one window touches the hole")
        #expect(aligner.stats.micGapFills == 0)
    }

    @Test("PTS jitter within the snap tolerance stays contiguous")
    func jitterIsSnapped() {
        let (aligner, collector) = makeAligner()
        aligner.ingest(capture(.microphone, start: 0, frames: 9_600, value: 0.5))
        // 3-frame jitter (~0.06 ms) on every system buffer.
        var start: Int64 = 0
        for i in 0..<8 {
            // The first buffer is on time (a first chunk keeps its true
            // PTS); later ones jitter around the contiguous position.
            let jitter: Int64 = i == 0 ? 0 : (i.isMultiple(of: 2) ? 3 : -3)
            aligner.ingest(capture(.system, start: max(0, start + jitter), frames: 1_200, value: 1))
            start += 1_200
        }
        aligner.flush()

        let sys = collector.frames.flatMap { channel0($0.systemBuffer) }
        #expect(sys.allSatisfy { $0 == 1 }, "no holes or clicks from jitter")
        #expect(aligner.stats.systemGapFills == 0)
    }

    @Test("an absent source never blocks output (CAP-2)")
    func absentSourceDoesNotBlock() {
        let (aligner, collector) = makeAligner()
        // Only the system source delivers 1 s; the mic never starts.
        for i in 0..<10 {
            aligner.ingest(capture(.system, start: Int64(i * Self.window), frames: Self.window, value: 1))
        }
        // Before flush: every window more than 400 ms behind the system
        // head has been emitted with a silent mic.
        let beforeFlush = aligner.stats.framesEmitted
        #expect(beforeFlush >= 5, "expected stalled-mic windows to flow, got \(beforeFlush)")
        #expect(aligner.stats.micGapFills == beforeFlush)

        aligner.flush()
        #expect(collector.frames.count == 10, "flush emits the rest")
        #expect(collector.frames.allSatisfy { channel0($0.micBuffer).allSatisfy { $0 == 0 } })
    }

    @Test("flush pads the final partial window instead of dropping it")
    func flushPadsTail() {
        let (aligner, collector) = makeAligner()
        aligner.ingest(capture(.system, start: 0, frames: 7_200, value: 1))
        aligner.ingest(capture(.microphone, start: 0, frames: 7_200, value: 0.5))
        aligner.flush()

        let frames = collector.frames
        #expect(frames.count == 2)
        let sys = frames.flatMap { channel0($0.systemBuffer) }
        #expect(sys[0..<7_200].allSatisfy { $0 == 1 }, "the 50 ms tail is kept")
        #expect(sys[7_200...].allSatisfy { $0 == 0 })
        #expect(aligner.stats.systemGapFills == 0, "padding is not a gap-fill")
    }

    @Test("lastDriftSec reports the residual skew between the tracks (C5)")
    func driftReflectsSkew() {
        let (aligner, _) = makeAligner()
        aligner.ingest(capture(.system, start: 0, frames: 1_200, value: 1))
        aligner.ingest(capture(.microphone, start: 0, frames: 1_200, value: 1))
        // System lands 96 frames (2 ms) late, mic on time: both snapped.
        aligner.ingest(capture(.system, start: 1_296, frames: 1_200, value: 1))
        aligner.ingest(capture(.microphone, start: 1_200, frames: 1_200, value: 1))
        let drift = aligner.stats.lastDriftSec
        #expect(abs(drift - 0.002) < 0.000_1, "expected ~2 ms, got \(drift)")
        aligner.flush()
    }

    // MARK: - Helpers

    private func capture(_ tag: CaptureSourceTag, start: Int64, frames: Int, value: Float32) -> CaptureBuffer {
        let channels = 2
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let samples = [Float32](repeating: value, count: frames * channels)
        let bytes = samples.count * 4
        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: start, timescale: 48_000),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        return CaptureBuffer(source: tag, buffer: sb!)
    }

    /// Channel-0 samples of an output buffer (channel-major layout).
    private func channel0(_ buffer: CMSampleBuffer?) -> [Float32] {
        guard let buffer, let bb = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let frames = CMSampleBufferGetNumSamples(buffer)
        var out = [Float32](repeating: -1, count: frames)
        out.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: frames * 4, destination: raw.baseAddress!)
        }
        return out
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [AlignedFrame] = []
        func append(_ f: AlignedFrame) { lock.lock(); _frames.append(f); lock.unlock() }
        var frames: [AlignedFrame] { lock.lock(); defer { lock.unlock() }; return _frames }
    }
}
