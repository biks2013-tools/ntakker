import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NtakkerUIKit

/// EVAL-2026-10-16 M1 / M2 / UI-5 (plan-022 T3): the meters use a dBFS
/// scale, the publisher skips ticks that would draw the same bars, and
/// it yields nothing while paused.
@Suite("Level meter scale and gate")
struct LevelMeterGateTests {

    @Test("linear magnitudes map onto a −60 dBFS … 0 dBFS display scale")
    func dbfsScale() {
        #expect(LevelMeterScale.normalized(0) == 0)
        #expect(LevelMeterScale.normalized(1) == 1)
        #expect(LevelMeterScale.normalized(2) == 1, "clamped above full scale")
        #expect(LevelMeterScale.normalized(0.000_5) == 0, "below the floor")
        #expect(abs(LevelMeterScale.normalized(0.031_62) - 0.5) < 0.001, "−30 dBFS is half the bar")
        // Speech around 0.05 linear fills most of the bar, not 5 % of it.
        #expect(LevelMeterScale.normalized(0.05) > 0.5)
    }

    @Test("unchanged levels publish once; paused publishes nothing")
    func dedupAndPause() async throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        )!
        let publisher = try LevelMeterPublisher(micFormat: format, systemFormat: format, logger: .init(label: "test"))
        let counter = Counter()
        let drain = Task {
            for await _ in publisher.stream { counter.increment() }
        }
        defer {
            publisher.finish()
            drain.cancel()
        }

        // A steady level for ~300 ms (about 9 publisher ticks).
        for _ in 0..<10 {
            publisher.handleMic(buffer(value: 0.1))
            try await Task.sleep(for: .milliseconds(35))
        }
        let steady = counter.value
        #expect(steady >= 1 && steady <= 2, "a steady level should publish once, got \(steady)")

        publisher.setPaused(true)
        for _ in 0..<6 {
            publisher.handleMic(buffer(value: 0.5))
            try await Task.sleep(for: .milliseconds(35))
        }
        #expect(counter.value == steady, "nothing is published while paused")

        publisher.setPaused(false)
        try await Task.sleep(for: .milliseconds(120))
        #expect(counter.value == steady + 1, "resuming publishes the current level once")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// 1 024 frames of stereo Float32 non-interleaved, every sample `value`.
    private func buffer(value: Float32) -> CMSampleBuffer {
        let frames = 1_024
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let samples = [Float32](repeating: value, count: frames * 2)
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
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        return sb!
    }
}
