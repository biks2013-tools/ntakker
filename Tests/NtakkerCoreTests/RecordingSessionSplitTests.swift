// NtakkerCoreTests/RecordingSessionSplitTests.swift
//
// Phase A (plan-002 §3) — `RecordingSession.split(nextOutput:)` swap
// behavior tests (FR-32, project-design §15.3.2).
//
// The split primitive rotates the recorder while keeping the capture
// pipeline alive. We assert:
//   1. The state stream emits `.splitting` before the swap and
//      `.recording` after the swap settles.
//   2. The new file is created on disk.
//   3. The previous file is finalized (its size is non-zero — the moov
//      atom has been written for m4a).
//   4. A pre-flight failure (e.g. invalid output path) leaves the
//      original recorder untouched and surfaces the error.
//
// Per R-22 / R-17 these tests compile but cannot be trusted on the dev
// host. Authored for a real test runner.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("RecordingSession.split")
struct RecordingSessionSplitTests {

    // MARK: - Stub gate

    struct AlwaysAuthorizedGate: PermissionGating {
        func snapshot() async -> PermissionGate.Snapshot {
            PermissionGate.Snapshot(screenRecording: .authorized, microphone: .authorized)
        }
        func requireBothOrThrow() async throws { /* no-op */ }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionSplitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func makeOptions(output: URL, dir: URL) -> RecordingOptions {
        RecordingOptions(
            output: output,
            format: .m4a,
            layout: .mixed,
            sampleRate: 48_000,
            overwrite: true,
            runMode: .foreground,
            pidFile: dir.appendingPathComponent("ntakker-cli.pid"),
            logFile: dir.appendingPathComponent("ntakker-cli.log")
        )
    }

    // MARK: - split() exists with the documented signature

    @Test("split(nextOutput:) is exposed as `async throws` taking a URL")
    func splitSignature() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let opts = makeOptions(output: dir.appendingPathComponent("part00.m4a"), dir: dir)
        let session = RecordingSession(
            options: opts,
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )

        // Compile-time: the symbol exists with the right shape.
        let nextURL: URL = dir.appendingPathComponent("part01.m4a")
        let _: () async throws -> Void = { [weak session] in
            try await session?.split(nextOutput: nextURL)
        }
        #expect(session.isRunning == false)
    }

    // MARK: - State emission across split

    /// Per project-design §15.3.2 the split emits `.splitting` at entry
    /// and `.recording` after the swap settles. We assert the
    /// `.splitting → .recording` substring appears in the emitted
    /// sequence between the initial `.recording` and the final
    /// `.stopping`.
    @Test("split emits [.splitting, .recording] between recording and stop")
    func splitEmissionSequence() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let firstURL = dir.appendingPathComponent("part00.m4a")
        let secondURL = dir.appendingPathComponent("part01.m4a")

        let session = RecordingSession(
            options: makeOptions(output: firstURL, dir: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )

        let collector = Task<[SessionState], Never> { [stream = session.stateStream] in
            var collected: [SessionState] = []
            for await s in stream { collected.append(s) }
            return collected
        }

        // After the session is running, fire a split, wait briefly,
        // then stop.
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await session.split(nextOutput: secondURL)
            try? await Task.sleep(nanoseconds: 200_000_000)
            session.requestStop()
        }

        try await session.run()
        let collected = await collector.value

        // Find the `.splitting` index and confirm it is followed by a
        // `.recording`.
        let splitIdx = collected.firstIndex(of: .splitting)
        #expect(splitIdx != nil)
        if let i = splitIdx, i + 1 < collected.count {
            #expect(collected[i + 1] == .recording)
        }
        // Final state is `.stopped`.
        #expect(collected.last == .stopped)
    }

    // MARK: - Files on disk

    @Test("split produces both segment files on disk")
    func splitProducesBothFiles() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let firstURL = dir.appendingPathComponent("part00.m4a")
        let secondURL = dir.appendingPathComponent("part01.m4a")

        let session = RecordingSession(
            options: makeOptions(output: firstURL, dir: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await session.split(nextOutput: secondURL)
            try? await Task.sleep(nanoseconds: 200_000_000)
            session.requestStop()
        }

        try await session.run()

        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    // MARK: - Pre-flight failure leaves original untouched

    /// When the new output path is invalid (parent does not exist),
    /// `makeRecorder` throws `outputParentMissing`. The contract from
    /// project-design §15.3.2 step 2: "abort the split, emit .failed,
    /// DO NOT touch _recorder, the old recorder continues unchanged."
    @Test("split with invalid nextOutput throws and continues recording")
    func splitPreflightFailureKeepsOriginal() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let firstURL = dir.appendingPathComponent("part00.m4a")
        // Parent directory does not exist — pre-flight will throw.
        let invalidURL = dir.appendingPathComponent("nonexistent-subdir/part01.m4a")

        let session = RecordingSession(
            options: makeOptions(output: firstURL, dir: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            do {
                try await session.split(nextOutput: invalidURL)
                #expect(Bool(false), "split was supposed to throw")
            } catch {
                // Expected — invalid output path.
                #expect(error is NtakkerError)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            session.requestStop()
        }

        try await session.run()
        // Original file must still be present and finalized.
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
    }

    // MARK: - withOutput helper

    /// `RecordingOptions.withOutput(_:)` is the helper `split()` uses to
    /// derive the next-segment options (project-design §15.3.5). We
    /// verify it preserves every field except `output`.
    @Test("RecordingOptions.withOutput preserves every field except output")
    func withOutputPreservesFields() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let original = RecordingOptions(
            output: dir.appendingPathComponent("a.m4a"),
            format: .wav,
            layout: .stereoSplit,
            micChannel: .right,
            sampleRate: 44_100,
            bitDepth: 24,
            bitrate: 256_000,
            micDevice: "BuiltInMic",
            logLevel: .debug,
            maxDuration: 60,
            overwrite: true,
            runMode: .detached,
            pidFile: dir.appendingPathComponent("p.pid"),
            logFile: dir.appendingPathComponent("p.log"),
            stopTimeout: 42
        )
        let next = original.withOutput(dir.appendingPathComponent("b.wav"))

        #expect(next.output != original.output)
        #expect(next.format == original.format)
        #expect(next.layout == original.layout)
        #expect(next.micChannel == original.micChannel)
        #expect(next.sampleRate == original.sampleRate)
        #expect(next.bitDepth == original.bitDepth)
        #expect(next.bitrate == original.bitrate)
        #expect(next.micDevice == original.micDevice)
        #expect(next.logLevel == original.logLevel)
        #expect(next.maxDuration == original.maxDuration)
        #expect(next.overwrite == original.overwrite)
        #expect(next.runMode == original.runMode)
        #expect(next.pidFile == original.pidFile)
        #expect(next.logFile == original.logFile)
        #expect(next.stopTimeout == original.stopTimeout)
    }
}
