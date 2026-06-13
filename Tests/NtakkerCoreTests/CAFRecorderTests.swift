// NtakkerCoreTests/CAFRecorderTests.swift — see project-design.md §2.10 / §7.6
// and `docs/research/avassetwriter-aac.md` §1.3, §6.3.
//
// Phase H test coverage for `CAFRecorder`.
//
// v1 policy (from CAFRecorder.swift header): CAF is always PCM (no AAC-CAF).
// Tests verify PCM write path, on-disk format, split-layout naming, and
// idempotency. The file-format check uses `AVAudioFile(forReading:)` just
// as in WAVRecorderTests, noting that CAF big-endian PCM is transparently
// reported as `.pcmFormatFloat32` by AVAudioFile's processing format.
//
// Note (R-17): On a CLT-only host `swift test` exits 0 without firing
// Swift Testing assertions. Build status is the primary pass/fail signal.

import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Testing
@testable import NtakkerCore

@Suite("CAFRecorder")
struct CAFRecorderTests {

    // MARK: - Fixture helpers

    private static func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CAFRecorderTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("CAFRecorder mixed layout: file exists after finalize and is readable as PCM")
    func fullRoundTripMixed() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .mixed, bitDepth: 24)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 10)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))

        // File must be non-empty.
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)

        // Open with AVAudioFile — must succeed (PCM is universally decodeable).
        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.length > 0)
        // Processing format is always Float32 regardless of on-disk bit depth.
        #expect(audioFile.processingFormat.commonFormat == .pcmFormatFloat32)
        #expect(audioFile.processingFormat.channelCount == 2)
        #expect(audioFile.processingFormat.sampleRate == 48_000)
    }

    // MARK: - v1 policy: CAF is always PCM (per CAFRecorder.swift header)

    @Test("CAFRecorder output is readable as PCM, not AAC (v1 policy: no AAC-CAF)")
    func cafIsAlwaysPCM() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("pcm-check.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .mixed, bitDepth: 24)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        // Verify via AVAudioFile that the file's on-disk format is PCM (not AAC).
        // AVAudioFile.fileFormat.settings contains AVFormatIDKey for the on-disk codec.
        let audioFile = try AVAudioFile(forReading: output)
        let formatID = audioFile.fileFormat.settings[AVFormatIDKey] as? UInt32
        // kAudioFormatLinearPCM == 1819304813 ('lpcm')
        #expect(formatID == kAudioFormatLinearPCM)
    }

    // MARK: - 16-bit PCM

    @Test("CAFRecorder 16-bit setting writes a CAF with 16 bits per channel")
    func bitDepth16() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out16.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .mixed, bitDepth: 16)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    // MARK: - 24-bit PCM

    @Test("CAFRecorder 24-bit setting writes a CAF with 24 bits per channel")
    func bitDepth24() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out24.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .mixed, bitDepth: 24)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24)
    }

    // MARK: - Split layout naming convention

    @Test("CAFRecorder split layout writes <base>.mic.caf and <base>.system.caf")
    func splitLayoutSiblingFiles() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("rec.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .split, bitDepth: 24)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        let micFile    = dir.appendingPathComponent("rec.mic.caf")
        let systemFile = dir.appendingPathComponent("rec.system.caf")

        #expect(FileManager.default.fileExists(atPath: micFile.path))
        #expect(FileManager.default.fileExists(atPath: systemFile.path))

        // Both files must be non-empty PCM.
        let micAudio    = try AVAudioFile(forReading: micFile)
        let systemAudio = try AVAudioFile(forReading: systemFile)
        #expect(micAudio.length > 0)
        #expect(systemAudio.length > 0)

        // Both must be PCM.
        let micFmtID    = micAudio.fileFormat.settings[AVFormatIDKey] as? UInt32
        let sysFmtID    = systemAudio.fileFormat.settings[AVFormatIDKey] as? UInt32
        #expect(micFmtID    == kAudioFormatLinearPCM)
        #expect(sysFmtID    == kAudioFormatLinearPCM)
    }

    // MARK: - Stereo-split layout

    @Test("CAFRecorder stereoSplit layout writes a single file, no sidecar")
    func stereoSplitLayout() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("stereo.caf")
        let opts = RecordingOptions(
            output: output,
            format: .caf,
            layout: .stereoSplit,
            micChannel: .left,
            bitDepth: 24
        )
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames { try recorder.append(frame) }
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))
        let systemFile = dir.appendingPathComponent("stereo.system.caf")
        #expect(!FileManager.default.fileExists(atPath: systemFile.path))

        let audioFile = try AVAudioFile(forReading: output)
        #expect(audioFile.processingFormat.channelCount == 2)
    }

    // MARK: - Idempotency

    @Test("CAFRecorder finalize is idempotent: second call is a no-op and does not throw")
    func finalizeIsIdempotent() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("idem.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .mixed, bitDepth: 24)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 3)
        for frame in frames { try recorder.append(frame) }

        try await recorder.finalize(timeout: 10)
        try await recorder.finalize(timeout: 10)
    }

    // MARK: - Finalize without any frames appended

    @Test("CAFRecorder finalize with zero frames produces a valid-but-empty CAF")
    func finalizeZeroFrames() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("empty.caf")
        let opts = RecordingOptions(output: output, format: .caf, layout: .mixed, bitDepth: 24)
        let recorder = CAFRecorder(options: opts)

        try await recorder.start()
        // No frames appended.
        try await recorder.finalize(timeout: 10)

        // CAF is a sequentially-written container; AVAudioFile writes at least
        // the header even with zero audio frames.
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
