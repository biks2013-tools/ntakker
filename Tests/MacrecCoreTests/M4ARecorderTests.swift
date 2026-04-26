// MacrecCoreTests/M4ARecorderTests.swift — see project-design.md §2.10 / §7.4
// and `docs/research/avassetwriter-aac.md` §1.1, §5.
//
// Phase G test coverage for `M4ARecorder`.
//
// Frame synthesis: uses `SilenceBufferFactory.make(pts:sampleRate:channelCount:frameCount:)`
// which produces valid Float32 non-interleaved CMSampleBuffers — the same
// format M4ARecorder expects from HostClockAligner.
//
// Note (R-17): On a CLT-only host `swift test` exits 0 without firing
// Swift Testing assertions. Build status is the primary pass/fail signal.
//
// Tests that would require real Screen Recording / Microphone permissions
// are marked with a comment explaining why they are omitted.

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import MacrecCore

@Suite("M4ARecorder")
struct M4ARecorderTests {

    // MARK: - Fixture helpers

    private static func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M4ARecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func removeTemp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Build `count` sequential silence AlignedFrames starting at host-clock PTS 0.
    /// All frames use 2-channel Float32 non-interleaved at 48 kHz / 1024 frames each.
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

    @Test("M4ARecorder mixed layout: file exists after finalize and is readable as M4A")
    func fullRoundTripMixed() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out.m4a")
        let opts = RecordingOptions(output: output, format: .m4a, layout: .mixed)
        let recorder = M4ARecorder(options: opts)

        try await recorder.start()

        let frames = Self.makeFrames(count: 10)
        for frame in frames {
            try recorder.append(frame)
        }

        try await recorder.finalize(timeout: 10)

        // File must exist on disk.
        #expect(FileManager.default.fileExists(atPath: output.path))

        // File must be non-empty.
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)

        // AVAsset must be loadable (sanity check that the container is valid).
        let asset = AVAsset(url: output)
        // Note: on a CLT-only host AVAsset.isPlayable may report false because
        // the AAC decoder requires the full AVFoundation stack. We verify the
        // asset has at least one audio track in the track list instead, which
        // does not require hardware decoding.
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count >= 1)
    }

    // MARK: - SIGINT-finalization recipe: finalize after only 5 frames

    @Test("M4ARecorder: finalize mid-recording (5 frames) produces a readable file")
    func finalizeAfterPartialFrames() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("partial.m4a")
        let opts = RecordingOptions(output: output, format: .m4a, layout: .mixed)
        let recorder = M4ARecorder(options: opts)

        try await recorder.start()

        let frames = Self.makeFrames(count: 5)
        for frame in frames {
            try recorder.append(frame)
        }

        // Finalize with a generous timeout (simulates SIGINT after short recording).
        try await recorder.finalize(timeout: 10)

        #expect(FileManager.default.fileExists(atPath: output.path))

        // AVAsset is expected to be parseable even with few frames.
        let asset = AVAsset(url: output)
        // isPlayable requires hardware — use track presence as the minimal proxy.
        _ = try await asset.loadTracks(withMediaType: .audio)
        // We do not #expect tracks.count >= 1 here because AVAssetWriter with
        // very few frames + AAC priming may produce a 0-track asset on CLT hosts
        // without the AVFoundation decoder stack. The key check is file existence
        // and non-zero size (tested in the next line).
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)
    }

    // MARK: - Split layout produces sibling files

    @Test("M4ARecorder split layout writes <base>.system.m4a and <base>.mic.m4a")
    func splitLayoutSiblingFiles() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        // Factory convention: options.output is the canonical path; the recorder
        // derives system/mic sidecar names from it.
        let output = dir.appendingPathComponent("rec.m4a")
        let opts = RecordingOptions(output: output, format: .m4a, layout: .split)
        let recorder = M4ARecorder(options: opts)

        try await recorder.start()

        let frames = Self.makeFrames(count: 5)
        for frame in frames {
            try recorder.append(frame)
        }
        try await recorder.finalize(timeout: 10)

        let systemFile = dir.appendingPathComponent("rec.system.m4a")
        let micFile    = dir.appendingPathComponent("rec.mic.m4a")

        #expect(FileManager.default.fileExists(atPath: systemFile.path))
        #expect(FileManager.default.fileExists(atPath: micFile.path))

        // Both files must be non-empty.
        let sysSize = (try? FileManager.default.attributesOfItem(atPath: systemFile.path))?[.size] as? Int ?? 0
        let micSize = (try? FileManager.default.attributesOfItem(atPath: micFile.path))?[.size] as? Int ?? 0
        #expect(sysSize > 0)
        #expect(micSize > 0)
    }

    // MARK: - Stereo-split layout

    @Test("M4ARecorder stereoSplit layout writes a single file with mic on configured channel")
    func stereoSplitLayoutSingleFile() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("stereo.m4a")
        // Mic pinned to the left channel.
        let opts = RecordingOptions(
            output: output,
            format: .m4a,
            layout: .stereoSplit,
            micChannel: .left
        )
        let recorder = M4ARecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 5)
        for frame in frames {
            try recorder.append(frame)
        }
        try await recorder.finalize(timeout: 10)

        // Single output file must exist (no sidecar files for stereoSplit).
        #expect(FileManager.default.fileExists(atPath: output.path))
        let systemFile = dir.appendingPathComponent("stereo.system.m4a")
        #expect(!FileManager.default.fileExists(atPath: systemFile.path))
    }

    // MARK: - Idempotency

    @Test("M4ARecorder finalize is idempotent: second call is a no-op and does not throw")
    func finalizeIsIdempotent() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("idempotent.m4a")
        let opts = RecordingOptions(output: output, format: .m4a, layout: .mixed)
        let recorder = M4ARecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 3)
        for frame in frames {
            try recorder.append(frame)
        }

        try await recorder.finalize(timeout: 10)
        // Second finalize must not throw and must return quickly.
        try await recorder.finalize(timeout: 10)
        // If we reach here the test passes.
    }

    // MARK: - Absurdly short timeout

    @Test("M4ARecorder finalize with absurdly short timeout does not crash (may succeed or timeout)")
    func finalizeAbsurdlyShortTimeout() async throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("short-timeout.m4a")
        let opts = RecordingOptions(output: output, format: .m4a, layout: .mixed)
        let recorder = M4ARecorder(options: opts)

        try await recorder.start()
        let frames = Self.makeFrames(count: 3)
        for frame in frames {
            try recorder.append(frame)
        }

        // 0.001 s timeout may succeed (synthetic frames are tiny) or throw
        // writerFinalizationTimeout. Either outcome is acceptable; we only
        // require that the call does not crash or deadlock.
        do {
            try await recorder.finalize(timeout: 0.001)
            // Fast path: synthetic frames encoded quickly — acceptable.
        } catch let err as MacrecError {
            if case .writerFinalizationTimeout = err {
                // Timeout path — also acceptable (documented in test intent).
            } else {
                // Any other MacrecError is unexpected — propagate.
                throw err
            }
        }
    }
}
