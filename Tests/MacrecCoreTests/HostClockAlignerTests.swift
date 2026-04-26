// MacrecCoreTests/HostClockAlignerTests.swift — see project-design.md §2.9.
//
// Phase F (plan-001) — verify the cross-source aligner's algorithm:
//   1. Basic two-source alignment (10 windows in ~1 second of capture).
//   2. Gap-fill on system stall (skipNextEmission).
//   3. Gap-fill on mic stall.
//   4. Drift bound (< 20 ms — NFR-4).
//   5. Format mismatch is rejected (logged, not crashed).
//
// Tests #1, #4 use the real FakeAudioSource (real-time timer). Tests #2,
// #3, #5 synthesize CaptureBuffers directly so we can drive deterministic
// PTS sequences without racing the timer.

import CoreAudio
import CoreMedia
import Dispatch
import Foundation
import Testing
@testable import MacrecCore

@Suite("HostClockAligner")
struct HostClockAlignerTests {

    // MARK: - 1) Basic two-source alignment via FakeAudioSource

    @Test("Two FakeAudioSources produce ~10 aligned frames per second")
    func basicTwoSourceAlignment() async throws {
        let aligner = HostClockAligner(
            targetSampleRate: 48_000,
            targetChannelCount: 2,
            frameDuration: CMTime(value: 4_800, timescale: 48_000) // 100 ms
        )

        // Collect emitted frames on a dedicated queue (thread-safe).
        let collector = FrameCollector()
        aligner.onAlignedFrame = { frame in
            collector.append(frame)
        }

        let system = FakeAudioSource.makeSystem440Hz()
        let mic = FakeAudioSource.makeMic880Hz()
        system.onSampleBuffer = { aligner.ingest($0) }
        mic.onSampleBuffer = { aligner.ingest($0) }

        try await system.start()
        try await mic.start()

        // Run for ~1.1 s to allow at least 10 windows of 100 ms.
        try await Task.sleep(nanoseconds: 1_100_000_000)

        await system.stop()
        await mic.stop()
        aligner.flush()

        let count = collector.count
        #expect(count >= 9, "expected at least 9 aligned frames in ~1.1 s, got \(count)")
        #expect(count <= 12, "expected at most 12 aligned frames in ~1.1 s, got \(count)")

        // No frame should have a nil sub-buffer in the steady-state test —
        // the aligner gap-fills with synthesized silence.
        let frames = collector.snapshot()
        for frame in frames {
            #expect(frame.systemBuffer != nil)
            #expect(frame.micBuffer != nil)
        }
    }

    // MARK: - 2) Gap-fill on system stall

    @Test("System-side stall produces a silence-fill window (systemGapFills == 1)")
    func gapFillOnSystemStall() async throws {
        let aligner = HostClockAligner(
            targetSampleRate: 48_000,
            targetChannelCount: 2,
            frameDuration: CMTime(value: 4_800, timescale: 48_000) // 100 ms
        )
        let collector = FrameCollector()
        aligner.onAlignedFrame = { collector.append($0) }

        // Drive the aligner with deterministic CaptureBuffers. Both
        // sources start at PTS = 0; mic feeds 2 windows worth of data;
        // system feeds 1 window then "stalls" for 1 window then resumes.
        // Aligner should produce 3 windows: window 0 (real both), window 1
        // (system silence-filled, mic real), window 2 (real both).
        let pts0 = CMTime(value: 0, timescale: 48_000)
        let perBufferFrames = 4_800 // 1 window per buffer for simplicity
        let frameDur = CMTime(value: CMTimeValue(perBufferFrames), timescale: 48_000)

        // Window 0: both sources have a buffer.
        aligner.ingest(makeCaptureBuffer(
            tag: .system,
            pts: pts0,
            frameCount: perBufferFrames
        ))
        aligner.ingest(makeCaptureBuffer(
            tag: .microphone,
            pts: pts0,
            frameCount: perBufferFrames
        ))

        // Window 1: ONLY mic feeds. System "stalls" — its next PTS jumps
        // to window 2.
        let pts1 = CMTimeAdd(pts0, frameDur)
        aligner.ingest(makeCaptureBuffer(
            tag: .microphone,
            pts: pts1,
            frameCount: perBufferFrames
        ))

        // Window 2: both sources resume. System's next buffer arrives
        // with PTS = pts2 (skipping pts1 entirely). The aligner sees the
        // late head-PTS and silence-fills window 1.
        let pts2 = CMTimeAdd(pts1, frameDur)
        aligner.ingest(makeCaptureBuffer(
            tag: .system,
            pts: pts2,
            frameCount: perBufferFrames
        ))
        aligner.ingest(makeCaptureBuffer(
            tag: .microphone,
            pts: pts2,
            frameCount: perBufferFrames
        ))

        // Drain.
        aligner.flush()

        let stats = aligner.stats
        #expect(stats.framesEmitted == 3, "expected 3 windows emitted, got \(stats.framesEmitted)")
        #expect(stats.systemGapFills == 1, "expected 1 system gap-fill, got \(stats.systemGapFills)")
        #expect(stats.micGapFills == 0, "expected 0 mic gap-fills, got \(stats.micGapFills)")
        #expect(collector.count == 3)
    }

    // MARK: - 3) Gap-fill on mic stall

    @Test("Mic-side stall produces a silence-fill window (micGapFills == 1)")
    func gapFillOnMicStall() async throws {
        let aligner = HostClockAligner(
            targetSampleRate: 48_000,
            targetChannelCount: 2,
            frameDuration: CMTime(value: 4_800, timescale: 48_000)
        )
        let collector = FrameCollector()
        aligner.onAlignedFrame = { collector.append($0) }

        let pts0 = CMTime(value: 0, timescale: 48_000)
        let perBufferFrames = 4_800
        let frameDur = CMTime(value: CMTimeValue(perBufferFrames), timescale: 48_000)

        aligner.ingest(makeCaptureBuffer(tag: .system, pts: pts0, frameCount: perBufferFrames))
        aligner.ingest(makeCaptureBuffer(tag: .microphone, pts: pts0, frameCount: perBufferFrames))

        let pts1 = CMTimeAdd(pts0, frameDur)
        // Only system has data for window 1.
        aligner.ingest(makeCaptureBuffer(tag: .system, pts: pts1, frameCount: perBufferFrames))

        let pts2 = CMTimeAdd(pts1, frameDur)
        aligner.ingest(makeCaptureBuffer(tag: .system, pts: pts2, frameCount: perBufferFrames))
        aligner.ingest(makeCaptureBuffer(tag: .microphone, pts: pts2, frameCount: perBufferFrames))

        aligner.flush()

        let stats = aligner.stats
        #expect(stats.framesEmitted == 3)
        #expect(stats.systemGapFills == 0)
        #expect(stats.micGapFills == 1)
    }

    // MARK: - 4) Drift bound (NFR-4: < 20 ms)

    @Test("Drift between system and mic stays under 20 ms")
    func driftBound() async throws {
        let aligner = HostClockAligner(
            targetSampleRate: 48_000,
            targetChannelCount: 2,
            frameDuration: CMTime(value: 4_800, timescale: 48_000)
        )
        let collector = FrameCollector()
        aligner.onAlignedFrame = { collector.append($0) }

        let system = FakeAudioSource.makeSystem440Hz()
        let mic = FakeAudioSource.makeMic880Hz()
        system.onSampleBuffer = { aligner.ingest($0) }
        mic.onSampleBuffer = { aligner.ingest($0) }
        try await system.start()
        try await mic.start()

        // Run for ~2 seconds. Real time, but this test only needs
        // enough frames to validate the drift bound on the most recent.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        await system.stop()
        await mic.stop()
        aligner.flush()

        let stats = aligner.stats
        // Both sub-buffers in any emitted frame share the window's
        // start PTS by construction, so lastDriftSec should be 0 in
        // steady state. NFR-4 allows up to 20 ms.
        #expect(stats.lastDriftSec < 0.020,
                "lastDriftSec=\(stats.lastDriftSec) exceeds NFR-4 bound (0.020 s)")
    }

    // MARK: - 5) Format mismatch is rejected (logged, not crashed)

    @Test("Buffer at 44.1 kHz against a 48 kHz aligner is dropped (no frames emitted)")
    func formatMismatchDropped() async throws {
        let aligner = HostClockAligner(
            targetSampleRate: 48_000,
            targetChannelCount: 2,
            frameDuration: CMTime(value: 4_800, timescale: 48_000)
        )
        let collector = FrameCollector()
        aligner.onAlignedFrame = { collector.append($0) }

        // Send a buffer at 44.1 kHz (mismatched against the aligner's 48 kHz).
        let mismatched = makeCaptureBuffer(
            tag: .system,
            pts: CMTime(value: 0, timescale: 44_100),
            frameCount: 4_410,
            sampleRate: 44_100,
            channelCount: 2
        )
        aligner.ingest(mismatched)

        // Even feeding a properly-formatted mic buffer afterward shouldn't
        // produce frames — once the aligner is format-errored, ingest is
        // a no-op.
        aligner.ingest(makeCaptureBuffer(
            tag: .microphone,
            pts: CMTime(value: 0, timescale: 48_000),
            frameCount: 4_800
        ))

        aligner.flush()
        #expect(collector.count == 0)
        #expect(aligner.stats.framesEmitted == 0)
    }
}

// MARK: - Test helpers

/// Thread-safe collector for emitted frames.
private final class FrameCollector: @unchecked Sendable {
    private var frames: [AlignedFrame] = []
    private let lock = NSLock()

    func append(_ frame: AlignedFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func snapshot() -> [AlignedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }
}

/// Build a deterministic Float32 non-interleaved CaptureBuffer with
/// the given PTS and frame count. All samples are 0 (we don't care
/// about audio content for aligner correctness).
private func makeCaptureBuffer(
    tag: CaptureSourceTag,
    pts: CMTime,
    frameCount: Int,
    sampleRate: Double = 48_000,
    channelCount: Int = 2
) -> CaptureBuffer {
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
    let fmtStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &fmt
    )
    precondition(fmtStatus == noErr, "format-description create failed: \(fmtStatus)")

    let bytesPerSample = MemoryLayout<Float32>.size
    let totalBytes = bytesPerSample * frameCount * channelCount

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
    precondition(bbStatus == kCMBlockBufferNoErr, "block buffer alloc failed: \(bbStatus)")
    let fillStatus = CMBlockBufferFillDataBytes(
        with: 0,
        blockBuffer: blockBuffer!,
        offsetIntoDestination: 0,
        dataLength: totalBytes
    )
    precondition(fillStatus == kCMBlockBufferNoErr, "block buffer fill failed: \(fillStatus)")

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
        formatDescription: fmt,
        sampleCount: CMItemCount(frameCount),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    precondition(sbStatus == noErr, "sample buffer create failed: \(sbStatus)")

    return CaptureBuffer(source: tag, buffer: sampleBuffer!)
}
