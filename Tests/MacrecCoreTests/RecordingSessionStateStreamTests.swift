// MacrecCoreTests/RecordingSessionStateStreamTests.swift
//
// Phase A (plan-002 §3) — `RecordingSession.stateStream` emission
// sequence tests (FR-33, project-design §15.3.1).
//
// With the `PermissionGating` injection point introduced in this same
// phase, these tests can finally drive `RecordingSession.run()` to
// completion on the dev host (resolves ISSUE-02). They feed
// `FakeAudioSource` instances and a stub `PermissionGating` that
// always grants, then assert the emitted `SessionState` sequence
// matches project-design §15.3.1's transition table.
//
// Per R-22 / R-17 these tests compile but cannot be trusted on the dev
// host. Authored for a real test runner.

import Foundation
import Testing
@testable import MacrecCore

@Suite("RecordingSession.stateStream")
struct RecordingSessionStateStreamTests {

    // MARK: - Stub PermissionGating (always grants)

    struct AlwaysAuthorizedGate: PermissionGating {
        func snapshot() async -> PermissionGate.Snapshot {
            PermissionGate.Snapshot(screenRecording: .authorized, microphone: .authorized)
        }
        func requireBothOrThrow() async throws {
            // No-op: tests run without a real TCC grant.
        }
    }

    struct AlwaysDeniedGate: PermissionGating {
        func snapshot() async -> PermissionGate.Snapshot {
            PermissionGate.Snapshot(screenRecording: .denied, microphone: .denied)
        }
        func requireBothOrThrow() async throws {
            throw MacrecError.screenRecordingPermissionDenied
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionStateStreamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func makeOptions(in dir: URL) -> RecordingOptions {
        RecordingOptions(
            output: dir.appendingPathComponent("out.m4a"),
            format: .m4a,
            layout: .mixed,
            sampleRate: 48_000,
            overwrite: true,
            runMode: .foreground,
            pidFile: dir.appendingPathComponent("macrec.pid"),
            logFile: dir.appendingPathComponent("macrec.log")
        )
    }

    // MARK: - Stream existence

    @Test("stateStream is exposed publicly and ready before run()")
    func streamExposed() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let session = RecordingSession(
            options: makeOptions(in: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )
        // Subscribing before `run()` is supported — the stream is live
        // for the lifetime of the session.
        let stream: AsyncStream<SessionState> = session.stateStream
        _ = stream
        #expect(Bool(true))
    }

    // MARK: - Happy-path emission sequence

    /// Per project-design §15.3.1 the engine emits, in order:
    ///   `.starting` → `.recording` → `.stopping` → `.stopped`
    /// for a clean run-and-stop cycle.
    @Test("clean cycle emits .starting → .recording → .stopping → .stopped")
    func happyPathSequence() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let session = RecordingSession(
            options: makeOptions(in: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysAuthorizedGate()
        )

        // Collect states in a background task before kicking off run().
        let collector = Task<[SessionState], Never> { [stream = session.stateStream] in
            var collected: [SessionState] = []
            for await s in stream {
                collected.append(s)
            }
            return collected
        }

        // Schedule a stop after a short delay so `run()` completes.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            session.requestStop()
        }

        try await session.run()

        let collected = await collector.value
        #expect(collected.first == .starting)
        #expect(collected.contains(.recording))
        #expect(collected.contains(.stopping))
        #expect(collected.last == .stopped)
    }

    // MARK: - Failure path

    /// When the permission gate throws, the stream must terminate with
    /// `.failed(error)` and finish — never leak the consumer task.
    @Test("permission denial emits .starting then .failed then finishes")
    func deniedPath() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let session = RecordingSession(
            options: makeOptions(in: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysDeniedGate()
        )

        let collector = Task<[SessionState], Never> { [stream = session.stateStream] in
            var collected: [SessionState] = []
            for await s in stream {
                collected.append(s)
            }
            return collected
        }

        do {
            try await session.run()
            #expect(Bool(false), "expected permission denial throw")
        } catch let error as MacrecError {
            #expect(error.description.contains("screen") ||
                    error.description.contains("Screen") ||
                    error.description.contains("permission") ||
                    error.description.contains("Permission"))
        } catch {
            #expect(Bool(false), "expected MacrecError, got \(type(of: error))")
        }

        let collected = await collector.value
        #expect(collected.first == .starting)
        if case .failed = collected.last ?? .idle {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "expected last state to be .failed, got \(String(describing: collected.last))")
        }
    }

    // MARK: - Continuation finishes (R-28)

    /// The stream must `.finish()` so consumer tasks observe stream
    /// termination. Without this, `for await` loops leak. Project-design
    /// §15.3.1 R-28 mitigation.
    @Test("stateStream finishes after run() completes")
    func streamFinishes() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let session = RecordingSession(
            options: makeOptions(in: dir),
            systemSource: FakeAudioSource.makeSystem440Hz(),
            micSource: FakeAudioSource.makeMic880Hz(),
            permissionGate: AlwaysDeniedGate()
        )

        let collector = Task<Bool, Never> { [stream = session.stateStream] in
            var sawTerminal = false
            for await _ in stream {
                sawTerminal = true
            }
            // We get here only when the stream has finished.
            return sawTerminal
        }

        _ = try? await session.run()
        let observedSomething = await collector.value
        #expect(observedSomething == true)
    }
}
