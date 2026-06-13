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
        #expect(stats.samplesPassedThrough == UInt64(filterLength * 2))
        #expect(stats.updatesSkippedDoubleTalk > 0)
        #expect(stats.divergenceResets == 0)
    }
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
