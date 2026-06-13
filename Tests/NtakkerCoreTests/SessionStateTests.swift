// NtakkerCoreTests/SessionStateTests.swift
//
// Phase A (plan-002 §3) — exhaustiveness + Equatable round-trip tests
// for `SessionState` (project-design §15.3.1, FR-33).
//
// Per R-22 / R-17 these tests compile but cannot be trusted on the dev
// host (the CLT `swift test` runner exits 0 silently). They are
// authored for a real test runner (CI image with full Xcode).

import Foundation
import Testing
@testable import NtakkerCore

@Suite("SessionState")
struct SessionStateTests {

    // MARK: - Exhaustive switch coverage

    /// Every declared case must be reachable through an exhaustive
    /// `switch`. The compiler enforces this at build time, but we
    /// codify it in a runtime test so a future addition that omits
    /// the test forces the test author to extend coverage.
    @Test("every case is reachable via an exhaustive switch")
    func exhaustiveSwitch() {
        let allEngineCases: [SessionState] = [
            .idle, .starting, .recording,
            .pausing, .paused, .resuming,
            .splitting, .stopping, .stopped,
            .failed(.screenRecordingPermissionDenied),
        ]
        for state in allEngineCases {
            let label: String
            switch state {
            case .idle:        label = "idle"
            case .starting:    label = "starting"
            case .recording:   label = "recording"
            case .pausing:     label = "pausing"
            case .paused:      label = "paused"
            case .resuming:    label = "resuming"
            case .splitting:   label = "splitting"
            case .stopping:    label = "stopping"
            case .stopped:     label = "stopped"
            case .failed:      label = "failed"
            }
            #expect(!label.isEmpty)
        }
        #expect(allEngineCases.count == 10)
    }

    // MARK: - Equatable round-trip

    @Test("non-payload cases compare by case identity")
    func nonPayloadEquality() {
        #expect(SessionState.idle == .idle)
        #expect(SessionState.starting == .starting)
        #expect(SessionState.recording == .recording)
        #expect(SessionState.splitting == .splitting)
        #expect(SessionState.stopping == .stopping)
        #expect(SessionState.stopped == .stopped)
        #expect(SessionState.pausing == .pausing)
        #expect(SessionState.paused == .paused)
        #expect(SessionState.resuming == .resuming)

        #expect(SessionState.idle != .starting)
        #expect(SessionState.recording != .splitting)
        #expect(SessionState.stopped != .stopping)
    }

    @Test("failed payload equality matches NtakkerError descriptions")
    func failedPayloadMatch() {
        let a: SessionState = .failed(.screenRecordingPermissionDenied)
        let b: SessionState = .failed(.screenRecordingPermissionDenied)
        #expect(a == b)

        let c: SessionState = .failed(.microphonePermissionDenied)
        #expect(a != c)
    }

    @Test("failed never compares equal to non-failed")
    func failedDistinctFromOtherCases() {
        let f: SessionState = .failed(.screenRecordingPermissionDenied)
        #expect(f != .stopped)
        #expect(f != .recording)
        #expect(f != .idle)
    }

    // MARK: - description (logging helper)

    @Test("description returns a non-empty short label for every case")
    func descriptionLabels() {
        let cases: [SessionState] = [
            .idle, .starting, .recording, .pausing, .paused,
            .resuming, .splitting, .stopping, .stopped,
            .failed(.screenRecordingPermissionDenied),
        ]
        for c in cases {
            #expect(!c.description.isEmpty)
        }
        // `failed` description embeds the error description.
        let f: SessionState = .failed(.screenRecordingPermissionDenied)
        #expect(f.description.contains("failed"))
    }

    // MARK: - Sendable

    /// `SessionState: Sendable` is required by FR-33 so the
    /// `AsyncStream<SessionState>` consumer can be `@MainActor`-isolated
    /// while the producer fires from `RecordingSession.serialQueue`.
    /// The compile-time check is implicit; this runtime assert just
    /// documents the requirement.
    @Test("SessionState conforms to Sendable")
    func sendableConformance() {
        let s: any Sendable = SessionState.recording
        _ = s
        #expect(Bool(true))
    }
}
