// NtakkerCoreTests/SoftwareAECProcessorTests.swift — AEC regression tests

import CoreMedia
import Foundation
import Testing
@testable import NtakkerCore

@Suite("SoftwareAECProcessor")
struct SoftwareAECProcessorTests {

    @Test("double-talk gate uses mean reference power, not full-window energy")
    func doubleTalkGateUsesComparablePowerScale() {
        let sampleRate = 48_000.0
        let filterLength = 32
        let frameCount = 128
        let pts = CMTime(value: 0, timescale: CMTimeScale(sampleRate))

        let processor = SoftwareAECProcessor(
            config: SoftwareAECProcessor.Configuration(
                filterLength: filterLength,
                stepSize: 0.01,
                regularization: 1e-2,
                channels: 1,
                sampleRate: sampleRate,
                stepMax: 1e-3,
                leakage: 1e-5,
                referenceActivityRMSThreshold: 1e-3,
                doubleTalkRatio: 4.0,
                divergenceResetHoldSec: 0.05,
                envelopeTimeConstantSec: 0.02,
                limiterCeiling: 0.95,
                limiterKnee: 0.7
            )
        )

        var cleanedBuffers = 0
        processor.onCleanedMic = { buffer in
            cleanedBuffers += 1
            #expect(buffer.source == .microphone)
        }

        // Reference RMS is 0.1, while the local mic speech proxy is
        // 1.0. On mean-power scale: mic power (1.0) > ref power
        // (0.01) * 4, so double-talk must freeze adaptation. Before
        // the fix, the gate compared mic power against full-window
        // energy (0.01 * filterLength), making the reference side
        // artificially ~15 dB larger for this test and ~36 dB larger
        // at the production filter length.
        let reference = [Float32](repeating: 0.1, count: frameCount)
        let mic = [Float32](repeating: 1.0, count: frameCount)

        processor.feedReference(
            makePCMBuffer(source: .system, channels: [reference], pts: pts, sampleRate: sampleRate)
        )
        processor.processMic(
            makePCMBuffer(source: .microphone, channels: [mic], pts: pts, sampleRate: sampleRate)
        )

        let stats = processor.snapshotStatistics()
        #expect(cleanedBuffers == 1)
        #expect(stats.samplesProcessed == UInt64(frameCount))
        // The first L-1 mic samples have no full reference window
        // behind them yet (the window ends at the mic sample's time).
        #expect(stats.samplesPassedThrough == UInt64(filterLength - 1))
        #expect(stats.updatesSkippedDoubleTalk > 0)
        #expect(stats.divergenceResets == 0)
    }

    /// White noise from a fixed-seed LCG, in [-amplitude, amplitude].
    private static func noise(count: Int, amplitude: Float, seed: UInt64) -> [Float32] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)    // [0, 1)
            return (unit * 2 - 1) * amplitude
        }
    }

    private static func rms(_ x: ArraySlice<Float32>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// Run `seconds` of a synthetic echo (`mic = gain · ref` delayed by
    /// `delay` samples) through a processor and return the mic and
    /// cleaned-output RMS over the last 100 ms.
    private func runEcho(
        channels: Int,
        identicalMicChannels: Bool,
        delay: Int = 10,
        gain: Float = 0.5,
        seconds: Double = 1.0
    ) -> (mic: Float, residual: Float) {
        let sampleRate = 48_000.0
        let block = 96
        let blocks = Int(seconds * sampleRate) / block
        let processor = SoftwareAECProcessor(
            config: SoftwareAECProcessor.Configuration(
                filterLength: 64,
                stepSize: 0.5,
                regularization: 1e-6,
                channels: channels,
                sampleRate: sampleRate,
                stepMax: 1,
                leakage: 0,
                referenceActivityRMSThreshold: 1e-4,
                doubleTalkRatio: 1_000,
                divergenceResetHoldSec: 1,
                envelopeTimeConstantSec: 0.02,
                limiterCeiling: 0.95,
                limiterKnee: 0.7
            )
        )
        let total = blocks * block
        let refs = (0..<channels).map { Self.noise(count: total, amplitude: 0.3, seed: UInt64(7 + $0)) }
        // The echo heard at mic time t is the reference played at
        // t - delay: the mean of the channels for an upmixed mono mic,
        // the matching channel for a stereo mic.
        var out: [Float32] = []
        processor.onCleanedMic = { buffer in
            out.append(contentsOf: channel0(of: buffer.buffer))
        }
        for b in 0..<blocks {
            let start = b * block
            let pts = CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate))
            let refBlock = refs.map { Array($0[start..<(start + block)]) }
            let micSlice = (0..<block).map { n -> Float32 in
                let t = start + n
                guard t >= delay else { return 0 }
                var sum: Float = 0
                for ch in 0..<channels { sum += refs[ch][t - delay] }
                return gain * sum / Float(channels)
            }
            let micBlock: [[Float32]] = identicalMicChannels
                ? Array(repeating: micSlice, count: channels)
                : (0..<channels).map { ch in
                    (0..<block).map { n -> Float32 in
                        let t = start + n
                        return t >= delay ? gain * refs[ch][t - delay] : 0
                    }
                }
            processor.feedReference(makePCMBuffer(source: .system, channels: refBlock, pts: pts, sampleRate: sampleRate))
            processor.processMic(makePCMBuffer(source: .microphone, channels: micBlock, pts: pts, sampleRate: sampleRate))
        }
        let tail = 4_800
        let micTail = (identicalMicChannels || channels == 1)
            ? Array((0..<tail).map { n -> Float32 in
                let t = total - tail + n
                var sum: Float = 0
                for ch in 0..<channels { sum += refs[ch][t - delay] }
                return gain * sum / Float(channels)
            })
            : (0..<tail).map { n in gain * refs[0][total - tail + n - delay] }
        return (Self.rms(micTail[...]), Self.rms(out[(out.count - tail)...]))
    }

    @Test("NLMS cancels a delayed echo: the window ends at the mic sample's own time")
    func cancelsDelayedEcho() {
        let (mic, residual) = runEcho(channels: 1, identicalMicChannels: false)
        #expect(mic > 0.05)
        #expect(residual < mic * 0.05, "residual \(residual) vs mic \(mic): the echo was not cancelled")
    }

    @Test("an upmixed mono mic is cancelled by one filter against the mono reference")
    func cancelsUpmixedMonoEcho() {
        let (mic, residual) = runEcho(channels: 2, identicalMicChannels: true)
        #expect(residual < mic * 0.05, "residual \(residual) vs mic \(mic)")
    }

    @Test("a true stereo mic still runs one filter per channel")
    func cancelsStereoEcho() {
        let (mic, residual) = runEcho(channels: 2, identicalMicChannels: false)
        #expect(residual < mic * 0.05, "residual \(residual) vs mic \(mic)")
    }
}

/// Channel-0 samples of a non-interleaved Float32 buffer.
private func channel0(of buffer: CMSampleBuffer) -> [Float32] {
    guard let bb = CMSampleBufferGetDataBuffer(buffer) else { return [] }
    let frames = CMSampleBufferGetNumSamples(buffer)
    var out = [Float32](repeating: 0, count: frames)
    out.withUnsafeMutableBytes { raw in
        _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: frames * 4, destination: raw.baseAddress!)
    }
    return out
}

private func makePCMBuffer(
    source: CaptureSourceTag,
    channels: [[Float32]],
    pts: CMTime,
    sampleRate: Double
) -> CaptureBuffer {
    precondition(!channels.isEmpty)
    let frameCount = channels[0].count
    precondition(frameCount > 0)
    precondition(channels.allSatisfy { $0.count == frameCount })

    let formatDescription = SilenceBufferFactory.makeFloat32FormatDescription(
        sampleRate: sampleRate,
        channelCount: channels.count
    )

    let flattened = channels.flatMap { $0 }
    let totalBytes = flattened.count * MemoryLayout<Float32>.size

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
    precondition(bbStatus == kCMBlockBufferNoErr, "CMBlockBufferCreateWithMemoryBlock failed: \(bbStatus)")
    guard let blockBuffer else {
        preconditionFailure("CMBlockBufferCreateWithMemoryBlock returned nil")
    }

    flattened.withUnsafeBytes { bytes in
        let replaceStatus = CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: totalBytes
        )
        precondition(replaceStatus == kCMBlockBufferNoErr, "CMBlockBufferReplaceDataBytes failed: \(replaceStatus)")
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sbStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
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
    precondition(sbStatus == noErr, "CMSampleBufferCreate failed: \(sbStatus)")
    guard let sampleBuffer else {
        preconditionFailure("CMSampleBufferCreate returned nil")
    }

    return CaptureBuffer(source: source, buffer: sampleBuffer)
}
