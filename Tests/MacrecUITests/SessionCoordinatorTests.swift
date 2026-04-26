// MacrecUITests/SessionCoordinatorTests.swift — see plan-002 §3
// Phase D and project-design.md §15.5 (state-transition table).
//
// The coordinator is driven against a `MockRecordingSession` injected
// via the `RecordingSessionFactory` closure. The mock exposes a public
// `emit(_:)` so each test can synthesize a plausible engine state
// stream and assert the coordinator's response (events emitted on
// `coordinator.events` + the coordinator's own `state`).
//
// R-22: dev host's `swift test` exits 0 silently. Tests here are
// authored for compile-only verification of the API surface.

import Foundation
import Testing
@testable import MacrecUIKit
@testable import MacrecCore

// MARK: - Mock session

/// A `RecordingSessionLike` with a programmable state stream and a
/// programmable `run()` resolution. Tests synthesize the engine's
/// emissions by calling `emit(_:)`. `requestStop()` flips an internal
/// flag that `run()` polls.
final class MockRecordingSession: RecordingSessionLike, @unchecked Sendable {
    let stateStream: AsyncStream<SessionState>
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    private var stopRequested: Bool = false

    init() {
        let pair = AsyncStream.makeStream(
            of: SessionState.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        self.stateStream = pair.stream
        self.stateContinuation = pair.continuation
    }

    func emit(_ s: SessionState) {
        stateContinuation.yield(s)
        if case .stopped = s {
            stateContinuation.finish()
        }
        if case .failed = s {
            stateContinuation.finish()
        }
    }

    func run() async throws {
        // Block until requestStop fires.
        while !stopRequested {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        // Synthesize a clean stop transition the real engine would emit.
        emit(.stopping)
        emit(.stopped)
    }

    func requestStop() {
        stopRequested = true
    }

    func split(nextOutput: URL) async throws {
        // The engine emits .splitting then .recording on a successful
        // split. Reproduce that.
        emit(.splitting)
        emit(.recording)
    }
}

// MARK: - Tests

@Suite("SessionCoordinator")
struct SessionCoordinatorTests {

    private func baseOptions() -> RecordingOptions {
        RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/recording-2026-04-26-18-30.m4a")
        )
    }

    @Test("start() builds a session and transitions into .recording(seg:1)")
    func startBuildsSegmentOne() async throws {
        let mock = MockRecordingSession()
        let coordinator = SessionCoordinator(
            baseOptions: baseOptions(),
            logger: .init(label: "test"),
            factory: { _ in mock }
        )
        try await coordinator.start()
        #expect(await coordinator.segmentCounter == 1)
        let state = await coordinator.state
        #expect(state == SessionCoordinator.CoordinatorState.recording(segment: 1))
        await coordinator.teardown()
    }

    @Test("pause() awaits the run-task and parks in .paused")
    func pauseTransitionsToPaused() async throws {
        let mock = MockRecordingSession()
        let coordinator = SessionCoordinator(
            baseOptions: baseOptions(),
            logger: .init(label: "test"),
            factory: { _ in mock }
        )
        try await coordinator.start()
        try await coordinator.pause()
        let state = await coordinator.state
        // After pause, the coordinator should be parked at segment 1.
        if case let .paused(seg, _) = state {
            #expect(seg == 1)
        } else {
            Issue.record("expected .paused, got \(state)")
        }
        await coordinator.teardown()
    }

    @Test("resume() builds segment 2 with a partNN-suffixed URL")
    func resumeBuildsSegmentTwo() async throws {
        var producedURLs: [URL] = []
        let coordinator = SessionCoordinator(
            baseOptions: baseOptions(),
            logger: .init(label: "test"),
            factory: { opts in
                producedURLs.append(opts.output)
                return MockRecordingSession()
            }
        )
        try await coordinator.start()
        try await coordinator.pause()
        try await coordinator.resume()
        // Two sessions should have been built. The first uses the
        // unsuffixed URL; the second uses the .part02 URL.
        #expect(producedURLs.count == 2)
        #expect(producedURLs.first?.lastPathComponent == "recording-2026-04-26-18-30.m4a")
        #expect(producedURLs.last?.lastPathComponent == "recording-2026-04-26-18-30.part02.m4a")
        await coordinator.teardown()
    }

    @Test("stop() from .paused transitions directly to .stopped without rebuilding")
    func stopFromPausedSkipsRebuild() async throws {
        var built = 0
        let coordinator = SessionCoordinator(
            baseOptions: baseOptions(),
            logger: .init(label: "test"),
            factory: { _ in
                built += 1
                return MockRecordingSession()
            }
        )
        try await coordinator.start()
        try await coordinator.pause()
        try await coordinator.stop()
        #expect(built == 1)
        let state = await coordinator.state
        #expect(state == SessionCoordinator.CoordinatorState.stopped)
        await coordinator.teardown()
    }

    @Test("stop() from .recording awaits the run-task and emits stopped")
    func stopFromRecording() async throws {
        let coordinator = SessionCoordinator(
            baseOptions: baseOptions(),
            logger: .init(label: "test"),
            factory: { _ in MockRecordingSession() }
        )
        try await coordinator.start()
        try await coordinator.stop()
        let state = await coordinator.state
        #expect(state == SessionCoordinator.CoordinatorState.stopped)
        await coordinator.teardown()
    }

    @Test("split() rotates to a partNN-suffixed segment URL via the session")
    func splitRotates() async throws {
        let mock = MockRecordingSession()
        let coordinator = SessionCoordinator(
            baseOptions: baseOptions(),
            logger: .init(label: "test"),
            factory: { _ in mock }
        )
        try await coordinator.start()
        try await coordinator.split()
        let state = await coordinator.state
        #expect(state == SessionCoordinator.CoordinatorState.recording(segment: 2))
        await coordinator.teardown()
    }

    // MARK: - FR-34 first-segment rename (R-31)

    /// Helper: build a temp directory unique to this test invocation.
    /// Returned tuple has the directory URL plus a cleanup closure.
    private func makeTempDir() throws -> (dir: URL, cleanup: () -> Void) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "macrec-coord-test-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(at: tmp)
        }
        return (dir: tmp, cleanup: cleanup)
    }

    @Test("FR-34: pause/resume renames segment 1 to .part01 (mixed layout)")
    func pauseResumeRenamesFirstSegmentMixed() async throws {
        let (tmp, cleanup) = try makeTempDir()
        defer { cleanup() }

        let baseURL = tmp.appendingPathComponent("recording-2026-04-26-18-30.m4a")
        let opts = RecordingOptions(output: baseURL, format: .m4a, layout: .mixed)

        // The factory simulates the engine writing the segment file by
        // touching it. We capture the URL from each per-segment options
        // so the test can `touch` the right file before each segment.
        let coordinator = SessionCoordinator(
            baseOptions: opts,
            logger: .init(label: "test.fr34.mixed"),
            factory: { perSegOpts in
                // Engine would create the file as it runs; simulate by
                // touching the per-segment output URL synchronously.
                FileManager.default.createFile(
                    atPath: perSegOpts.output.path,
                    contents: Data(),
                    attributes: nil
                )
                return MockRecordingSession()
            }
        )
        try await coordinator.start()
        try await coordinator.pause()
        try await coordinator.resume()
        try await coordinator.stop()

        let part01 = tmp.appendingPathComponent("recording-2026-04-26-18-30.part01.m4a")
        let part02 = tmp.appendingPathComponent("recording-2026-04-26-18-30.part02.m4a")
        let bare = baseURL
        #expect(FileManager.default.fileExists(atPath: part01.path),
                "expected segment 1 to be renamed to part01.m4a")
        #expect(FileManager.default.fileExists(atPath: part02.path),
                "expected segment 2 to be created as part02.m4a")
        #expect(!FileManager.default.fileExists(atPath: bare.path),
                "expected the bare-named segment 1 file to be gone after rename")

        await coordinator.teardown()
    }

    @Test("FR-34: pause/resume renames BOTH split-layout segment 1 sidecars to .part01")
    func pauseResumeRenamesFirstSegmentSplit() async throws {
        let (tmp, cleanup) = try makeTempDir()
        defer { cleanup() }

        let baseURL = tmp.appendingPathComponent("recording-2026-04-26-18-30.m4a")
        let opts = RecordingOptions(output: baseURL, format: .m4a, layout: .split)

        // For split layout the engine writes two sibling files
        // (`.system` and `.mic`) per segment, derived from
        // `options.output`. Simulate by touching both sidecars per
        // segment options.
        let coordinator = SessionCoordinator(
            baseOptions: opts,
            logger: .init(label: "test.fr34.split"),
            factory: { perSegOpts in
                let folder = perSegOpts.output.deletingLastPathComponent()
                let stem = perSegOpts.output.deletingPathExtension().lastPathComponent
                let ext = perSegOpts.output.pathExtension
                let sysURL = folder.appendingPathComponent("\(stem).system.\(ext)")
                let micURL = folder.appendingPathComponent("\(stem).mic.\(ext)")
                FileManager.default.createFile(atPath: sysURL.path, contents: Data())
                FileManager.default.createFile(atPath: micURL.path, contents: Data())
                return MockRecordingSession()
            }
        )
        try await coordinator.start()
        try await coordinator.pause()
        try await coordinator.resume()
        try await coordinator.stop()

        let p01sys = tmp.appendingPathComponent("recording-2026-04-26-18-30.part01.system.m4a")
        let p01mic = tmp.appendingPathComponent("recording-2026-04-26-18-30.part01.mic.m4a")
        // Segment 2 sidecars derive from the per-segment options URL,
        // which `SegmentNamer.next(after:segment: 2)` already
        // partifies. The factory then appends .system/.mic to that.
        // Per the partURL implementation, the partNN infix is inserted
        // before the layout token IF the layout token is already in
        // the URL. Segment 2's per-segment URL is the partified base
        // URL (no layout token yet), so `<stem>.<ext>` becomes
        // `<stem>.part02.<ext>`, and the factory then derives
        // `<stem>.part02.system.<ext>` and `<stem>.part02.mic.<ext>`.
        let p02sys = tmp.appendingPathComponent("recording-2026-04-26-18-30.part02.system.m4a")
        let p02mic = tmp.appendingPathComponent("recording-2026-04-26-18-30.part02.mic.m4a")

        #expect(FileManager.default.fileExists(atPath: p01sys.path),
                "expected segment 1 system file renamed to .part01.system.m4a")
        #expect(FileManager.default.fileExists(atPath: p01mic.path),
                "expected segment 1 mic file renamed to .part01.mic.m4a")
        #expect(FileManager.default.fileExists(atPath: p02sys.path),
                "expected segment 2 system file at .part02.system.m4a")
        #expect(FileManager.default.fileExists(atPath: p02mic.path),
                "expected segment 2 mic file at .part02.mic.m4a")

        await coordinator.teardown()
    }

    @Test("FR-34: rename failure does not throw — pause/resume still succeeds")
    func renameFailureIsNonFatal() async throws {
        let (tmp, cleanup) = try makeTempDir()
        defer { cleanup() }

        let baseURL = tmp.appendingPathComponent("recording-2026-04-26-18-30.m4a")
        let opts = RecordingOptions(output: baseURL, format: .m4a, layout: .mixed)

        // Factory does NOT create any file. The rename will see a
        // missing source and log a warning; the coordinator must still
        // transition through resume cleanly.
        let coordinator = SessionCoordinator(
            baseOptions: opts,
            logger: .init(label: "test.fr34.failure"),
            factory: { _ in MockRecordingSession() }
        )
        try await coordinator.start()
        try await coordinator.pause()
        try await coordinator.resume()
        let state = await coordinator.state
        #expect(state == SessionCoordinator.CoordinatorState.recording(segment: 2))
        try await coordinator.stop()
        await coordinator.teardown()
    }
}
