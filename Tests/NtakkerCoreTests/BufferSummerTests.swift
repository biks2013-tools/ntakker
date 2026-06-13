// NtakkerCoreTests/BufferSummerTests.swift — see project-design.md §2.9, §2.11
//
// Phase G (plan-001) — unit tests for BufferSummer.
//
// Covers the CMSampleBuffer overload (nil-tolerant path) and the
// AVAudioPCMBuffer overload (direct DSP path). Deterministic constant-valued
// Float32 buffers are used throughout so assertions are exact.

import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Testing
@testable import NtakkerCore

// MARK: - Test helpers

/// Build a Float32 non-interleaved AVAudioPCMBuffer where every sample on
/// every channel equals `value`.
private func makePCMBuffer(
    sampleRate: Double = 48_000,
    channelCount: Int = 2,
    frameCount: Int = 960,
    value: Float32 = 0
) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channelCount),
        interleaved: false
    )!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount))!
    buf.frameLength = AVAudioFrameCount(frameCount)
    guard let channelData = buf.floatChannelData else { return buf }
    for c in 0..<channelCount {
        for f in 0..<frameCount {
            channelData[c][f] = value
        }
    }
    return buf
}

/// Build a Float32 non-interleaved CMSampleBuffer filled with `value`,
/// with the given PTS.
private func makeSampleBuffer(
    sampleRate: Double = 48_000,
    channelCount: Int = 2,
    frameCount: Int = 960,
    value: Float32 = 0,
    pts: CMTime = CMTime(value: 0, timescale: 48_000)
) -> CMSampleBuffer {
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
    _ = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &fmt
    )
    let formatDescription = fmt!

    let totalBytes = frameCount * channelCount * MemoryLayout<Float32>.size
    let samples = [Float32](repeating: value, count: frameCount * channelCount)

    var blockBuffer: CMBlockBuffer?
    _ = CMBlockBufferCreateWithMemoryBlock(
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
    let bb = blockBuffer!
    _ = samples.withUnsafeBufferPointer { ptr -> OSStatus in
        CMBlockBufferReplaceDataBytes(
            with: UnsafeRawPointer(ptr.baseAddress!),
            blockBuffer: bb,
            offsetIntoDestination: 0,
            dataLength: totalBytes
        )
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    _ = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: bb,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: CMItemCount(frameCount),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}

/// Read all Float32 samples from a CMSampleBuffer into a flat array.
private func readSamples(from sb: CMSampleBuffer, total: Int) -> [Float32] {
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { return [] }
    var samples = [Float32](repeating: 0, count: total)
    _ = samples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
        CMBlockBufferCopyDataBytes(
            bb,
            atOffset: 0,
            dataLength: total * MemoryLayout<Float32>.size,
            destination: UnsafeMutableRawPointer(ptr.baseAddress!)
        )
    }
    return samples
}

// MARK: - Suite

@Suite("BufferSummer")
struct BufferSummerTests {

    // MARK: - CMSampleBuffer nil-tolerant overload

    @Test("Both inputs nil → returns nil")
    func bothNilReturnsNil() throws {
        let result = try BufferSummer.sum(nil as CMSampleBuffer?, nil as CMSampleBuffer?)
        #expect(result == nil)
    }

    @Test("Only A non-nil → returns A unchanged (identity)")
    func onlyANonNilReturnsA() throws {
        let a = makeSampleBuffer(value: 0.5)
        let result = try BufferSummer.sum(a, nil as CMSampleBuffer?)
        // The nil-tolerant overload must return `a` itself — not a copy.
        #expect(result === a)
    }

    @Test("Only B non-nil → returns B unchanged (identity)")
    func onlyBNonNilReturnsB() throws {
        let b = makeSampleBuffer(value: 0.25)
        let result = try BufferSummer.sum(nil as CMSampleBuffer?, b)
        #expect(result === b)
    }

    // MARK: - CMSampleBuffer element-wise sum and known values

    @Test("A=0.3 + B=0.4 → sum samples equal 0.7")
    func sumKnownConstantSamples() throws {
        let frameCount = 960
        let channelCount = 2
        let a = makeSampleBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.3)
        let b = makeSampleBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.4)
        let result = try #require(try BufferSummer.sum(a, b))
        let samples = readSamples(from: result, total: frameCount * channelCount)
        let expected = Float32(0.7)
        for s in samples {
            #expect(abs(s - expected) < 1e-5, "sample \(s) not close to \(expected)")
        }
    }

    // MARK: - Clamping

    @Test("Clamping positive: A=0.8, B=0.8 → sum (1.6) clamped to 1.0")
    func clampingPositive() throws {
        let frameCount = 480
        let channelCount = 2
        let a = makeSampleBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.8)
        let b = makeSampleBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.8)
        let result = try #require(try BufferSummer.sum(a, b))
        let samples = readSamples(from: result, total: frameCount * channelCount)
        for s in samples {
            #expect(s <= 1.0, "sample \(s) exceeds +1.0 — clamping failed")
            #expect(abs(s - 1.0) < 1e-5, "expected 1.0 got \(s)")
        }
    }

    @Test("Clamping negative: A=-0.8, B=-0.8 → sum (-1.6) clamped to -1.0")
    func clampingNegative() throws {
        let frameCount = 480
        let channelCount = 2
        let a = makeSampleBuffer(channelCount: channelCount, frameCount: frameCount, value: -0.8)
        let b = makeSampleBuffer(channelCount: channelCount, frameCount: frameCount, value: -0.8)
        let result = try #require(try BufferSummer.sum(a, b))
        let samples = readSamples(from: result, total: frameCount * channelCount)
        for s in samples {
            #expect(s >= -1.0, "sample \(s) below -1.0 — clamping failed")
            #expect(abs(s - (-1.0)) < 1e-5, "expected -1.0 got \(s)")
        }
    }

    // MARK: - PTS and frame count preservation

    @Test("Output PTS matches input A's PTS")
    func outputPTSMatchesA() throws {
        let pts = CMTime(value: 123_456, timescale: 48_000)
        let a = makeSampleBuffer(value: 0.1, pts: pts)
        let b = makeSampleBuffer(value: 0.1, pts: CMTime(value: 0, timescale: 48_000))
        let result = try #require(try BufferSummer.sum(a, b))
        let outPTS = CMSampleBufferGetPresentationTimeStamp(result)
        #expect(CMTimeCompare(outPTS, pts) == 0)
    }

    @Test("Output frame count matches input frame count")
    func outputFrameCountMatches() throws {
        let frameCount = 960
        let a = makeSampleBuffer(frameCount: frameCount, value: 0.1)
        let b = makeSampleBuffer(frameCount: frameCount, value: 0.1)
        let result = try #require(try BufferSummer.sum(a, b))
        #expect(CMSampleBufferGetNumSamples(result) == frameCount)
    }

    // MARK: - CMSampleBuffer format mismatch errors

    @Test("Different sample rates → throws NtakkerError.ioError")
    func sampleRateMismatchThrows() {
        let a = makeSampleBuffer(sampleRate: 48_000)
        let b = makeSampleBuffer(sampleRate: 44_100)
        #expect(throws: NtakkerError.self) {
            _ = try BufferSummer.sum(a, b)
        }
    }

    @Test("Different channel counts → throws NtakkerError.ioError")
    func channelCountMismatchThrows() {
        let a = makeSampleBuffer(channelCount: 2)
        let b = makeSampleBuffer(channelCount: 1)
        #expect(throws: NtakkerError.self) {
            _ = try BufferSummer.sum(a, b)
        }
    }

    @Test("Different frame counts → throws NtakkerError.ioError")
    func frameCountMismatchThrows() {
        let a = makeSampleBuffer(frameCount: 960)
        let b = makeSampleBuffer(frameCount: 480)
        #expect(throws: NtakkerError.self) {
            _ = try BufferSummer.sum(a, b)
        }
    }

    // MARK: - AVAudioPCMBuffer overload

    @Test("AVAudioPCMBuffer: A=0.2 + B=0.3 → 0.5")
    func pcmBufferSum() throws {
        let frameCount = 960
        let channelCount = 2
        let a = makePCMBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.2)
        let b = makePCMBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.3)
        let result = try BufferSummer.sum(a, b)
        guard let channelData = result.floatChannelData else {
            Issue.record("floatChannelData unavailable")
            return
        }
        for c in 0..<channelCount {
            for f in 0..<frameCount {
                #expect(abs(channelData[c][f] - 0.5) < 1e-5, "ch\(c) f\(f) = \(channelData[c][f])")
            }
        }
    }

    @Test("AVAudioPCMBuffer: clamping — 0.9 + 0.9 clamped to 1.0")
    func pcmBufferClamping() throws {
        let frameCount = 480
        let channelCount = 2
        let a = makePCMBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.9)
        let b = makePCMBuffer(channelCount: channelCount, frameCount: frameCount, value: 0.9)
        let result = try BufferSummer.sum(a, b)
        guard let channelData = result.floatChannelData else {
            Issue.record("floatChannelData unavailable")
            return
        }
        for c in 0..<channelCount {
            for f in 0..<frameCount {
                #expect(channelData[c][f] <= 1.0, "sample exceeds +1.0")
                #expect(abs(channelData[c][f] - 1.0) < 1e-5)
            }
        }
    }

    @Test("AVAudioPCMBuffer: format mismatch (different sample rates) → throws")
    func pcmBufferFormatMismatchSampleRate() {
        let a = makePCMBuffer(sampleRate: 48_000)
        let b = makePCMBuffer(sampleRate: 44_100)
        #expect(throws: NtakkerError.self) {
            _ = try BufferSummer.sum(a, b)
        }
    }

    @Test("AVAudioPCMBuffer: format mismatch (different channel counts) → throws")
    func pcmBufferFormatMismatchChannelCount() {
        let a = makePCMBuffer(channelCount: 2)
        let b = makePCMBuffer(channelCount: 1)
        #expect(throws: NtakkerError.self) {
            _ = try BufferSummer.sum(a, b)
        }
    }

    @Test("AVAudioPCMBuffer: frame length mismatch → throws")
    func pcmBufferFrameLengthMismatch() {
        let a = makePCMBuffer(frameCount: 960)
        let b = makePCMBuffer(frameCount: 480)
        #expect(throws: NtakkerError.self) {
            _ = try BufferSummer.sum(a, b)
        }
    }

    @Test("AVAudioPCMBuffer: output frameLength equals input frameLength")
    func pcmBufferOutputFrameLength() throws {
        let frameCount = 960
        let a = makePCMBuffer(frameCount: frameCount, value: 0.1)
        let b = makePCMBuffer(frameCount: frameCount, value: 0.1)
        let result = try BufferSummer.sum(a, b)
        #expect(result.frameLength == AVAudioFrameCount(frameCount))
    }

    @Test("AVAudioPCMBuffer: per-source gain is applied before clamping")
    func pcmBufferGainApplied() throws {
        let frameCount = 960
        let channelCount = 2
        // A=1.0 * gainA=0.5 + B=1.0 * gainB=0.25 = 0.75
        let a = makePCMBuffer(channelCount: channelCount, frameCount: frameCount, value: 1.0)
        let b = makePCMBuffer(channelCount: channelCount, frameCount: frameCount, value: 1.0)
        let result = try BufferSummer.sum(a, b, gainA: 0.5, gainB: 0.25)
        guard let channelData = result.floatChannelData else {
            Issue.record("floatChannelData unavailable")
            return
        }
        for c in 0..<channelCount {
            for f in 0..<frameCount {
                #expect(abs(channelData[c][f] - 0.75) < 1e-5, "expected 0.75 got \(channelData[c][f])")
            }
        }
    }
}
