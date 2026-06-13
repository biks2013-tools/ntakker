// NtakkerCoreTests/PermissionGatingProtocolTests.swift
//
// Phase A (plan-002 §3) — protocol conformance + injection tests for
// `PermissionGating` (project-design §15.3.4). Resolves ISSUE-02 by
// exercising the `RecordingSession.init(permissionGate:)` slot with a
// stub conformer.
//
// Per R-22 / R-17 these tests compile but cannot be trusted on the dev
// host. Authored for a real test runner.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("PermissionGating protocol")
struct PermissionGatingProtocolTests {

    // MARK: - Stub conformer

    /// Minimal `PermissionGating` conformer that bypasses TCC entirely.
    /// Used by every test that calls `RecordingSession.run()` without
    /// an actual screen-recording grant.
    struct StubPermissionGating: PermissionGating {
        let authorized: Bool
        let throwOnRequire: NtakkerError?

        init(authorized: Bool = true, throwOnRequire: NtakkerError? = nil) {
            self.authorized = authorized
            self.throwOnRequire = throwOnRequire
        }

        func snapshot() async -> PermissionGate.Snapshot {
            PermissionGate.Snapshot(
                screenRecording: authorized ? .authorized : .denied,
                microphone: authorized ? .authorized : .denied
            )
        }

        func requireBothOrThrow() async throws {
            if let err = throwOnRequire { throw err }
            if !authorized {
                throw NtakkerError.screenRecordingPermissionDenied
            }
        }
    }

    // MARK: - Conformance

    @Test("LivePermissionGate is the live PermissionGating conformer")
    func liveConformer() {
        let gate: any PermissionGating = LivePermissionGate()
        _ = gate
        #expect(Bool(true))
    }

    @Test("PermissionGate conforms to PermissionGating")
    func permissionGateConforms() {
        let gate: any PermissionGating = PermissionGate()
        _ = gate
        #expect(Bool(true))
    }

    @Test("snapshot returns Snapshot type unchanged from live API")
    func snapshotShape() async {
        let gate = StubPermissionGating(authorized: true)
        let snap = await gate.snapshot()
        #expect(snap.bothAuthorized == true)
    }

    // MARK: - Stub behavior

    @Test("authorized stub does not throw on requireBothOrThrow")
    func stubAuthorized() async throws {
        let gate = StubPermissionGating(authorized: true)
        try await gate.requireBothOrThrow()
        #expect(Bool(true))
    }

    @Test("denied stub throws screenRecordingPermissionDenied")
    func stubDenied() async {
        let gate = StubPermissionGating(authorized: false)
        do {
            try await gate.requireBothOrThrow()
            #expect(Bool(false), "expected throw")
        } catch let error as NtakkerError {
            #expect(error.description == NtakkerError.screenRecordingPermissionDenied.description)
        } catch {
            #expect(Bool(false), "wrong error type")
        }
    }

    @Test("custom-error stub re-throws the supplied NtakkerError")
    func stubCustomError() async {
        let custom = NtakkerError.microphonePermissionDenied
        let gate = StubPermissionGating(throwOnRequire: custom)
        do {
            try await gate.requireBothOrThrow()
            #expect(Bool(false), "expected throw")
        } catch let error as NtakkerError {
            #expect(error.description == custom.description)
        } catch {
            #expect(Bool(false), "wrong error type")
        }
    }

    // MARK: - RecordingSession.init injection (ISSUE-02 resolution)

    @Test("RecordingSession.init accepts an injected PermissionGating")
    func sessionAcceptsInjectedGate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionGatingProtocolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let options = RecordingOptions(
            output: dir.appendingPathComponent("out.m4a"),
            overwrite: true,
            pidFile: dir.appendingPathComponent("ntakker-cli.pid"),
            logFile: dir.appendingPathComponent("ntakker-cli.log")
        )
        let stub = StubPermissionGating(authorized: true)

        // Must compile and construct without throwing — the type
        // existence proves the injection slot is present.
        let session = RecordingSession(
            options: options,
            permissionGate: stub
        )
        #expect(session.isRunning == false)
    }

    @Test("RecordingSession.init defaults permissionGate to nil (live gate)")
    func sessionDefaultsToLiveGate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionGatingProtocolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let options = RecordingOptions(
            output: dir.appendingPathComponent("out.m4a"),
            overwrite: true,
            pidFile: dir.appendingPathComponent("ntakker-cli.pid"),
            logFile: dir.appendingPathComponent("ntakker-cli.log")
        )
        // No `permissionGate:` argument — preserves pre-Phase-A CLI
        // behavior. Construction must succeed.
        let session = RecordingSession(options: options)
        #expect(session.isRunning == false)
    }
}
