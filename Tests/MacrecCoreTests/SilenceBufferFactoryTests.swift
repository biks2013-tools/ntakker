// MacrecCoreTests/SilenceBufferFactoryTests.swift — see project-design.md §2.9
//
// Phase F (plan-001) — verify the silence-buffer synthesizer's shape
// (frame count, format flags, all-zero samples) and PTS round-trip.

import CoreAudio
import CoreMedia
import Foundation
import Testing
@testable import MacrecCore

@Suite("SilenceBufferFactory")
struct SilenceBufferFactoryTests {

    // MARK: - Shape (frame count, format, all-zero samples)

    @Test("48 kHz / 2-channel / 4800-frame silence buffer has correct shape and is all zero")
    func shape48k2chFullWindow() throws {
        let pts = CMTime(value: 0, timescale: 48_000)
        let sb = SilenceBufferFactory.make(
            pts: pts,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 4_800
        )

        // Sample count
        #expect(CMSampleBufferGetNumSamples(sb) == 4_800)

        // Format description must be Float32 non-interleaved 48 kHz / 2ch.
        let fmt = try #require(CMSampleBufferGetFormatDescription(sb))
        let asbdPtr = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(fmt))
        let asbd = asbdPtr.pointee
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mBitsPerChannel == 32)
        #expect((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
        #expect((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)
        #expect((asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)

        // All samples zero. Read the entire payload (channelCount * frames * 4)
        // out of the block buffer.
        let frames = 4_800
        let channelCount = 2
        let totalBytes = frames * channelCount * MemoryLayout<Float32>.size
        let bb = try #require(CMSampleBufferGetDataBuffer(sb))
        var samples = [Float32](repeating: 1.0, count: frames * channelCount)
        let copyStatus = samples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            CMBlockBufferCopyDataBytes(
                bb,
                atOffset: 0,
                dataLength: totalBytes,
                destination: UnsafeMutableRawPointer(ptr.baseAddress!)
            )
        }
        #expect(copyStatus == kCMBlockBufferNoErr)
        #expect(samples.allSatisfy { $0 == 0.0 })
    }

    // MARK: - PTS round-trip

    @Test("PTS round-trips through the factory unchanged")
    func ptsRoundTrip() {
        // Use a non-zero PTS at the canonical 48 kHz timescale so we
        // can compare exactly without rounding in CMTime arithmetic.
        let inputPTS = CMTime(value: 123_456, timescale: 48_000)
        let sb = SilenceBufferFactory.make(
            pts: inputPTS,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 960
        )
        let outputPTS = CMSampleBufferGetPresentationTimeStamp(sb)
        #expect(CMTimeCompare(outputPTS, inputPTS) == 0)
    }

    // MARK: - Single-channel / odd frame count works

    @Test("Mono / 1-frame buffer is also valid")
    func minimalShape() {
        let sb = SilenceBufferFactory.make(
            pts: CMTime(value: 0, timescale: 48_000),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )
        #expect(CMSampleBufferGetNumSamples(sb) == 1)
    }

    // MARK: - Design-§2.9 signature: makeSilence(startPTS:duration:formatDescription:)

    @Test("makeSilence(startPTS:duration:formatDescription:) returns a valid buffer")
    func makeSilenceWithFormatDescription() throws {
        let fmt = SilenceBufferFactory.makeFloat32FormatDescription(
            sampleRate: 48_000,
            channelCount: 2
        )
        let duration = CMTime(value: 4_800, timescale: 48_000) // 100 ms
        let startPTS = CMTime(value: 1_000, timescale: 48_000)

        let sb = try SilenceBufferFactory.makeSilence(
            startPTS: startPTS,
            duration: duration,
            formatDescription: fmt,
            sampleRate: 48_000
        )
        #expect(CMSampleBufferGetNumSamples(sb) == 4_800)
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), startPTS) == 0)
    }
}
