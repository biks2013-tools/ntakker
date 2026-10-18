// NtakkerCoreTests/FakeAudioSourceTests.swift — see project-design.md §2.8.3
//
// Phase G (plan-001) — unit tests for FakeAudioSource.
//
// Tests covering:
//   * Basic shape: format (Float32 non-interleaved, 48 kHz, 2ch), frame
//     count, monotonically increasing PTS across 5 collected buffers.
//   * skipNextEmission() causes a one-tick PTS gap.
//   * injectPTSJump(by:) shifts subsequent PTS.
//   * stop() cancels the timer — no further callbacks fire after stop.
//   * stop() is idempotent.
//   * Microphone tag propagation.
//   * Convenience factory methods.
//
// NOTE: `injectStop(error:)` does NOT exist in the FakeAudioSource API.
// Phase E removed this hook because the AudioSource protocol has no
// `onStopped` callback. This test file omits that case with this comment
// as the documented rationale (per the task guardrails).
//
// All tests use a short bufferDurationMs (5 ms) to keep per-test wall time
// well under the 1 s guardrail. The `collectBuffers` helper times out after
// 2 s to prevent infinite hangs.

import CoreMedia
import CoreAudio
import Foundation
import Testing
@testable import NtakkerCore

// MARK: - Synchronous coordination primitives
//
// `onSampleBuffer` is a *synchronous* closure called on the source's
// dispatch queue. Actor-isolated methods cannot be called directly from
// a synchronous context, so we use plain GCD semaphores here (safe for
// counting + signalling from synchronous code, safe to await from async
// test bodies via Task.sleep polling).

/// Collect exactly `count` CaptureBuffers from `source`, timing out after
/// `timeoutSeconds`. The source is started here; the caller is responsible
/// for stopping it via `defer { Task { await source.stop() } }`.
private func collectBuffers(
    from source: FakeAudioSource,
    count: Int,
    timeoutSeconds: Double = 2.0
) async throws -> [CaptureBuffer] {
    var collected: [CaptureBuffer] = []
    let lock = NSLock()
    let sem = DispatchSemaphore(value: 0)

    source.onSampleBuffer = { cb in
        lock.lock()
        let alreadyHaveEnough = collected.count >= count
        if !alreadyHaveEnough {
            collected.append(cb)
            if collected.count == count {
                sem.signal()
            }
        }
        lock.unlock()
    }

    try await source.start()

    // Wait up to timeoutSeconds for the semaphore.
    let deadline = DispatchTime.now() + timeoutSeconds
    _ = sem.wait(timeout: deadline)

    lock.lock()
    let result = collected
    lock.unlock()
    return result
}

// MARK: - Suite

@Suite("FakeAudioSource")
struct FakeAudioSourceTests {

    // MARK: - Basic shape and format

    @Test("5 buffers have correct format: Float32 non-interleaved, 48 kHz, 2 channels")
    func basicShapeAndFormat() async throws {
        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )
        defer { Task { await source.stop() } }

        let buffers = try await collectBuffers(from: source, count: 5)
        #expect(buffers.count == 5, "Expected 5 buffers, got \(buffers.count)")

        for (idx, cb) in buffers.enumerated() {
            let sb = cb.buffer

            // Frame count: 5 ms at 48 kHz = 240 frames.
            let expectedFrames = 240  // Int(0.005 * 48_000)
            #expect(CMSampleBufferGetNumSamples(sb) == expectedFrames,
                    "buffer[\(idx)] frame count mismatch")

            // Format description.
            let fmtDesc = try #require(CMSampleBufferGetFormatDescription(sb),
                                       "buffer[\(idx)] has no format description")
            let asbdPtr = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
                                       "buffer[\(idx)] has no ASBD")
            let asbd = asbdPtr.pointee
            #expect(asbd.mSampleRate == 48_000, "buffer[\(idx)] wrong sample rate")
            #expect(asbd.mChannelsPerFrame == 2, "buffer[\(idx)] wrong channel count")
            #expect(asbd.mBitsPerChannel == 32, "buffer[\(idx)] wrong bit depth")
            #expect((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                    "buffer[\(idx)] not Float32")
            #expect((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0,
                    "buffer[\(idx)] not non-interleaved")
            #expect(asbd.mFormatID == kAudioFormatLinearPCM,
                    "buffer[\(idx)] not LPCM")

            // Source tag.
            #expect(cb.source == .system, "buffer[\(idx)] has wrong source tag")
        }
    }

    @Test("PTS is monotonically increasing across 5 consecutive buffers")
    func ptsMonotonicallyIncreasing() async throws {
        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )
        defer { Task { await source.stop() } }

        let buffers = try await collectBuffers(from: source, count: 5)
        let pts = buffers.map { CMSampleBufferGetPresentationTimeStamp($0.buffer) }
        for i in 1..<pts.count {
            #expect(CMTimeCompare(pts[i], pts[i - 1]) > 0,
                    "PTS[\(i)] not greater than PTS[\(i-1)]")
        }
    }

    @Test("PTS advances by exactly framesPerBuffer/sampleRate seconds per emission")
    func ptsAdvancesByExactlyOneBufferDuration() async throws {
        let sampleRate: Double = 48_000
        let bufferMs: Double = 5
        let framesPerBuffer = Int(bufferMs / 1_000.0 * sampleRate) // 240

        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: sampleRate,
            bufferDurationMs: bufferMs
        )
        defer { Task { await source.stop() } }

        let buffers = try await collectBuffers(from: source, count: 5)
        let pts = buffers.map { CMSampleBufferGetPresentationTimeStamp($0.buffer) }

        let expectedStepSec = Double(framesPerBuffer) / sampleRate
        for i in 1..<pts.count {
            let diffSec = CMTimeGetSeconds(CMTimeSubtract(pts[i], pts[i - 1]))
            #expect(abs(diffSec - expectedStepSec) < 1e-6,
                    "PTS step [\(i-1)→\(i)] = \(diffSec)s, expected \(expectedStepSec)s")
        }
    }

    // MARK: - skipNextEmission

    @Test("skipNextEmission produces a one-tick PTS gap")
    func skipNextEmissionPTSGap() async throws {
        let sampleRate: Double = 48_000
        let bufferMs: Double = 5
        let framesPerBuffer = Int(bufferMs / 1_000.0 * sampleRate)  // 240
        let expectedStep = Double(framesPerBuffer) / sampleRate      // 0.005 s

        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: sampleRate,
            bufferDurationMs: bufferMs
        )
        defer { Task { await source.stop() } }

        // We need to: collect 2, inject skip, collect 2 more.
        // Strategy: collect all 4 in one pass, inject the skip after the
        // second one lands using a separate GCD semaphore.

        // Under a loaded test run the waiter can wake several ticks after
        // buffer 2, so "buffer 4" may already precede the injection. Wait
        // instead for three buffers emitted after it (one tick may already be running) (`target`, set when
        // injecting).
        var allBuffers: [CaptureBuffer] = []
        var target = Int.max
        let lock = NSLock()
        let got2 = DispatchSemaphore(value: 0)
        let gotAfter = DispatchSemaphore(value: 0)

        source.onSampleBuffer = { cb in
            lock.lock()
            allBuffers.append(cb)
            let n = allBuffers.count
            let reached = n == target
            lock.unlock()
            if n == 2 { got2.signal() }
            if reached { gotAfter.signal() }
        }

        try await source.start()

        // Wait for buffer 2, then inject skip.
        _ = got2.wait(timeout: .now() + 2.0)
        lock.lock()
        source.skipNextEmission()
        target = allBuffers.count + 3
        lock.unlock()

        // Wait for three buffers after the skip.
        _ = gotAfter.wait(timeout: .now() + 2.0)

        lock.lock()
        let collected = allBuffers
        lock.unlock()

        guard collected.count >= 4 else {
            Issue.record("Did not collect 4 buffers (got \(collected.count))")
            return
        }

        // Exactly one consecutive pair is ~2 × step apart, because one
        // tick was skipped (emittedFrames advanced but no buffer was
        // emitted). Which pair depends on how many 5 ms ticks fired
        // between buffer 2 arriving and the skip being injected — under
        // a loaded test run that can be one or two more, so the test
        // no longer pins it to buffers 1→2.
        let gaps = zip(collected, collected.dropFirst()).map { a, b in
            CMTimeGetSeconds(CMTimeSubtract(
                CMSampleBufferGetPresentationTimeStamp(b.buffer),
                CMSampleBufferGetPresentationTimeStamp(a.buffer)))
        }
        let skipped = gaps.filter { $0 > expectedStep * 1.5 }
        #expect(skipped.count == 1, "Expected one ~\(expectedStep * 2)s gap after the skip, got gaps \(gaps)")
    }

    // MARK: - injectPTSJump

    @Test("injectPTSJump shifts subsequent PTS by the requested delta")
    func injectPTSJumpShiftsPTS() async throws {
        let sampleRate: Double = 48_000
        let bufferMs: Double = 5
        let framesPerBuffer = Int(bufferMs / 1_000.0 * sampleRate)
        let normalStep = Double(framesPerBuffer) / sampleRate
        let jumpSeconds: Double = 1.0
        let jumpDelta = CMTime(seconds: jumpSeconds, preferredTimescale: CMTimeScale(sampleRate))

        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: sampleRate,
            bufferDurationMs: bufferMs
        )
        defer { Task { await source.stop() } }

        // Under a loaded test run the waiter can wake several ticks after
        // buffer 2, so "buffer 4" may already precede the injection. Wait
        // instead for three buffers emitted after it (one tick may already be running) (`target`, set when
        // injecting).
        var allBuffers: [CaptureBuffer] = []
        var target = Int.max
        let lock = NSLock()
        let got2 = DispatchSemaphore(value: 0)
        let gotAfter = DispatchSemaphore(value: 0)

        source.onSampleBuffer = { cb in
            lock.lock()
            allBuffers.append(cb)
            let n = allBuffers.count
            let reached = n == target
            lock.unlock()
            if n == 2 { got2.signal() }
            if reached { gotAfter.signal() }
        }

        try await source.start()
        _ = got2.wait(timeout: .now() + 2.0)
        lock.lock()
        source.injectPTSJump(by: jumpDelta)
        target = allBuffers.count + 3
        lock.unlock()
        _ = gotAfter.wait(timeout: .now() + 2.0)

        lock.lock()
        let collected = allBuffers
        lock.unlock()

        guard collected.count >= 4 else {
            Issue.record("Did not collect 4 buffers (got \(collected.count))")
            return
        }

        // Exactly one consecutive pair differs by ≈ jumpSeconds +
        // normalStep — not pinned to buffers 1→2, for the same reason as
        // the skip test above.
        let diffs = zip(collected, collected.dropFirst()).map { a, b in
            CMTimeGetSeconds(CMTimeSubtract(
                CMSampleBufferGetPresentationTimeStamp(b.buffer),
                CMSampleBufferGetPresentationTimeStamp(a.buffer)))
        }
        let expectedDiff = jumpSeconds + normalStep
        let jumps = diffs.filter { abs($0 - expectedDiff) < 0.01 }
        #expect(jumps.count == 1, "Expected one PTS diff ~\(expectedDiff)s after the jump, got \(diffs)")
    }

    // MARK: - stop()

    @Test("stop() cancels the timer — no further callbacks fire after stop")
    func stopCancelsTimer() async throws {
        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )

        // Collect 3 buffers to confirm the source is running.
        let before = try await collectBuffers(from: source, count: 3)
        #expect(before.count == 3, "Sanity: should collect 3 buffers before stop")

        await source.stop()

        // Replace callback with a counter; wait 100 ms (>> 5 ms buffer period).
        var postStopCount = 0
        let lock = NSLock()
        source.onSampleBuffer = { _ in
            lock.lock()
            postStopCount += 1
            lock.unlock()
        }
        try await Task.sleep(nanoseconds: 100_000_000)  // 100 ms

        lock.lock()
        let count = postStopCount
        lock.unlock()
        #expect(count == 0, "Callback fired \(count) time(s) after stop() — timer not cancelled")
    }

    @Test("stop() is idempotent — calling twice does not crash")
    func stopIdempotent() async throws {
        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )
        try await source.start()
        await source.stop()
        await source.stop() // must not crash
    }

    @Test("start() is idempotent — calling twice does not crash or duplicate emissions")
    func startIdempotent() async throws {
        let source = FakeAudioSource(
            tag: .system,
            frequencyHz: 440,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )
        defer { Task { await source.stop() } }
        try await source.start()
        try await source.start()  // must not crash
        let buffers = try await collectBuffers(from: source, count: 2)
        #expect(buffers.count == 2)
    }

    // MARK: - Source tags

    @Test("FakeAudioSource with tag .microphone emits CaptureBuffers tagged .microphone")
    func microphoneTag() async throws {
        let source = FakeAudioSource(
            tag: .microphone,
            frequencyHz: 880,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )
        defer { Task { await source.stop() } }

        let buffers = try await collectBuffers(from: source, count: 3)
        for (i, cb) in buffers.enumerated() {
            #expect(cb.source == .microphone, "buffer[\(i)] has wrong tag")
        }
    }

    // MARK: - Convenience factories

    @Test("makeSystem440Hz factory sets tag=.system and emits .system buffers")
    func factorySystem440Hz() async throws {
        let source = FakeAudioSource.makeSystem440Hz()
        defer { Task { await source.stop() } }
        #expect(source.tag == .system)
        let buffers = try await collectBuffers(from: source, count: 1)
        #expect(buffers.first?.source == .system)
    }

    @Test("makeMic880Hz factory sets tag=.microphone and emits .microphone buffers")
    func factoryMic880Hz() async throws {
        let source = FakeAudioSource.makeMic880Hz()
        defer { Task { await source.stop() } }
        #expect(source.tag == .microphone)
        let buffers = try await collectBuffers(from: source, count: 1)
        #expect(buffers.first?.source == .microphone)
    }

    // MARK: - Waveform initializer

    @Test("Waveform initializer with .silence produces all-zero samples")
    func silenceWaveformAllZero() async throws {
        let source = FakeAudioSource(
            tag: .system,
            waveform: .silence,
            channelCount: 2,
            sampleRate: 48_000,
            bufferDurationMs: 5
        )
        defer { Task { await source.stop() } }

        let buffers = try await collectBuffers(from: source, count: 2)
        for (idx, cb) in buffers.enumerated() {
            let sb = cb.buffer
            let frameCount = CMSampleBufferGetNumSamples(sb)
            let channelCount = 2
            let total = frameCount * channelCount
            guard let bb = CMSampleBufferGetDataBuffer(sb) else {
                Issue.record("buffer[\(idx)] has no data buffer")
                continue
            }
            var samples = [Float32](repeating: 1.0, count: total)
            _ = samples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    bb,
                    atOffset: 0,
                    dataLength: total * MemoryLayout<Float32>.size,
                    destination: UnsafeMutableRawPointer(ptr.baseAddress!)
                )
            }
            #expect(samples.allSatisfy { $0 == 0.0 }, "buffer[\(idx)] silence has non-zero samples")
        }
    }

    // MARK: - Note: injectStop(error:) is absent by design
    //
    // `injectStop(error:)` does NOT exist in the FakeAudioSource API.
    // Phase E removed this hook because the AudioSource protocol has no
    // `onStopped` mechanism. Any test targeting it would fail to compile.
    // This comment serves as the documented rationale for the omission.
}
