// NtakkerCoreTests/RecordingSessionMuteTests.swift — 2026-10-21.
//
// Muting a source during a recording: the muted source's track is
// silence for exactly the muted time, the other track is untouched,
// and both tracks keep the same length.

import AVFoundation
import Foundation
import Testing
@testable import NtakkerCore

@Suite("RecordingSession mute")
struct RecordingSessionMuteTests {

    struct AlwaysAuthorizedGate: PermissionGating {
        func snapshot() async -> PermissionGate.Snapshot {
            PermissionGate.Snapshot(screenRecording: .authorized, microphone: .authorized)
        }
        func requireBothOrThrow() async throws {}
    }

    private func samples(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    private func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }

    @Test("mic muted from the start, unmuted mid-way: silent, then the live mic; system untouched")
    func muteThenUnmute() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionMuteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = RecordingSession(
            options: RecordingOptions(
                output: dir.appendingPathComponent("rec.wav"),
                format: .wav,
                layout: .split,
                sampleRate: 48_000,
                overwrite: true,
                runMode: .foreground,
                pidFile: dir.appendingPathComponent("ntakker-cli.pid"),
                logFile: dir.appendingPathComponent("ntakker-cli.log")
            ),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )
        session.setMuted(true, source: .microphone)
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            session.setMuted(false, source: .microphone)
            try? await Task.sleep(nanoseconds: 600_000_000)
            session.requestStop()
        }
        try await session.run()

        let mic = try samples(dir.appendingPathComponent("rec.mic.wav"))
        let sys = try samples(dir.appendingPathComponent("rec.system.wav"))
        #expect(mic.count == sys.count, "both tracks keep the same length")
        #expect(mic.count > 48_000, "about 1.2 s recorded, got \(mic.count) frames")

        // First 0.4 s: muted (well inside the 0.6 s before unmuting).
        #expect(rms(mic[0..<19_200]) < 0.0001, "muted mic is silence")
        // Last 0.3 s: unmuted (well after it).
        #expect(rms(mic[(mic.count - 14_400)...]) > 0.01, "unmuted mic is the live tone again")
        // System never muted.
        #expect(rms(sys[0..<19_200]) > 0.01)
        #expect(rms(sys[(sys.count - 14_400)...]) > 0.01)
    }
}
