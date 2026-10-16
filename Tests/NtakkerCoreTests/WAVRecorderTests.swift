// NtakkerCoreTests/WAVRecorderTests.swift — see project-design.md §2.10 / §7.5
// and `docs/research/avassetwriter-aac.md` §1.2, §6.2.
//
// Phase H test coverage for `WAVRecorder`.
//
// Pipeline: AlignedFrame (Float32 non-interleaved) → AVAudioFile (Int16 or
// Int24 on-disk PCM). Tests verify the full write path, the on-disk format
// via `AVAudioFile(forReading:)`, split-layout naming, and idempotency.
//
// Note (R-17): On a CLT-only host `swift test` exits 0 without firing
// Swift Testing assertions. Build status is the primary pass/fail signal.

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NtakkerCore

@Suite("WAVRecorder")
struct WAVRecorderTests {

    // MARK: - Fixture helpers

    private static func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func removeTemp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Build `count` sequential silence AlignedFrames at 48 kHz, 2 ch, 1024 frames.
    private static func makeFrames(count: Int, sampleRate: Double = 48_000, frameCount: Int = 1024) -> [AlignedFrame] {
        let timescale = CMTimeScale(sampleRate)
        return (0..<count).map { i in
            let pts = CMTime(value: CMTimeValue(i * frameCount), timescale: timescale)
            let duration = CMTime(value: CMTimeValue(frameCount), timescale: timescale)
            let buf = SilenceBufferFactory.make(
                pts: pts,
                sampleRate: sampleRate,
                channelCount: 2,
                frameCount: frameCount
            )
            return AlignedFrame(
                pts: pts,
                duration: duration,
                systemBuffer: buf,
                micBuffer: buf
            )
        }
    }

    // MARK: - Full round-trip: start → append 10 frames → finalize

    @Test("WAVRecorder mixed layout: file exists and opens as PCM via AVAudioFile")
    func fullRoundTripMixed() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .mixed, bitDepth: 16)
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 10)
        for frame in frames {
            try recorder.append(frame)
        }
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))

        // Open with AVAudioFile and verify it's readable PCM.
        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.length > 0)
        // The processing format should be Float32 non-interleaved (AVAudioFile
        // always presents Float32 to the processing pipeline regardless of
        // the on-disk format).
        #expect(audioFile.processingFormat.commonFormat == .pcmFormatFloat32)
        #expect(audioFile.processingFormat.channelCount == 2)
        #expect(audioFile.processingFormat.sampleRate == 48_000)
    }

    // MARK: - Bit-depth: 16-bit

    @Test("WAVRecorder 16-bit setting writes a WAV with 16 bits per channel")
    func bitDepth16() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out16.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .mixed, bitDepth: 16)
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))

        // AVAudioFile exposes the on-disk format via `fileFormat`.
        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    // MARK: - Bit-depth: 24-bit

    @Test("WAVRecorder 24-bit setting writes a WAV with 24 bits per channel")
    func bitDepth24() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out24.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .mixed, bitDepth: 24)
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))

        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24)
    }

    // MARK: - Split layout naming convention

    @Test("WAVRecorder split layout writes <base>.mic.wav and <base>.system.wav")
    func splitLayoutSiblingFiles() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("rec.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .split, bitDepth: 16)
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        let micFile    = dir.appendingPathComponent("rec.mic.wav")
        let systemFile = dir.appendingPathComponent("rec.system.wav")

        #expect(FileManager.default.fileExists(atPath: micFile.path))
        #expect(FileManager.default.fileExists(atPath: systemFile.path))

        // Both files must be non-empty and readable.
        let micAudio    = try AVAudioFile(forReading: micFile)
        let systemAudio = try AVAudioFile(forReading: systemFile)
        #expect(micAudio.length > 0)
        #expect(systemAudio.length > 0)
    }

    // MARK: - Stereo-split layout: single output file, no sidecars

    @Test("WAVRecorder stereoSplit layout writes a single file with mic on configured channel")
    func stereoSplitLayout() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("stereo.wav")
        let opts = RecordingOptions(
            output: output,
            format: .wav,
            layout: .stereoSplit,
            micChannel: .left,
            bitDepth: 16
        )
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))
        // No sidecar files for stereoSplit.
        let systemFile = dir.appendingPathComponent("stereo.system.wav")
        #expect(!FileManager.default.fileExists(atPath: systemFile.path))

        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.processingFormat.channelCount == 2)
    }

    // MARK: - Idempotency

    @Test("WAVRecorder finalize is idempotent: second call is a no-op and does not throw")
    func finalizeIsIdempotent() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("idem.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .mixed, bitDepth: 16)
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 3)
        for frame in frames { try recorder.append(frame) }

        try await recorder.finalize(timeout: 10)
        // Second call must be silent.
        try await recorder.finalize(timeout: 10)
    }

    // MARK: - Finalize without any frames appended

    @Test("WAVRecorder finalize with zero frames produces an empty-but-valid WAV")
    func finalizeZeroFrames() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("empty.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .mixed, bitDepth: 16)
        let recorder = WAVRecorder(options: opts)

        try await recorder.start()
        // Do not append any frames.
        try await recorder.finalize(timeout: 10)

        // File may or may not exist depending on whether AVAudioFile flushes a
        // zero-length RIFF header. WAV is a RIFF container — AVAudioFile writes
        // at least the 44-byte header even with no audio. We verify existence.
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - EVAL-2026-10-16 CAP-7: async write errors are surfaced

    @Test("WAVRecorder latches a writer-queue error and rethrows it from finalize and append")
    func writeErrorIsSurfaced() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("latched.wav")
        let opts = RecordingOptions(output: output, format: .wav, layout: .mixed, bitDepth: 16)
        let recorder = WAVRecorder(options: opts)

        // Deliberately skip start(): the writer-queue append fails
        // ("called before start()"). Before CAP-7 this was only logged
        // and finalize reported success.
        let frame = Self.makeFrames(count: 1)[0]
        try recorder.append(frame)   // hops queues — cannot throw yet

        await #expect(throws: (any Error).self) {
            try await recorder.finalize(timeout: 10)
        }
        #expect(throws: (any Error).self) {
            try recorder.append(frame)
        }
    }
}
