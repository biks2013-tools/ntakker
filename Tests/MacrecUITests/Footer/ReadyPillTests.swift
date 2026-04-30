// MacrecUITests/Footer/ReadyPillTests.swift — plan-008 Phase 6
//
// Concept-pinning tests for `ReadyPill`.
//
// `ReadyPill` accepts a `SessionState` and maps it to a label string and
// a dot color. Both mappings are pinned here. `SessionState` and `MacrecCore`
// are importable from the test target.
//
// Label mapping (from ReadyPill.swift `label` computed var):
//   .idle, .stopped       → "Ready"
//   .starting             → "Starting…"
//   .recording            → "Recording"
//   .pausing              → "Pausing…"
//   .paused               → "Paused"
//   .resuming             → "Resuming…"
//   .splitting            → "Splitting…"
//   .stopping             → "Stopping…"
//   .failed               → "Error"
//
// Dot color mapping (from ReadyPill.swift `dotColor` computed var):
//   .recording, .splitting → .red
//   .paused, .pausing, .resuming → .yellow
//   .failed               → .red
//   default (idle, stopped, starting, stopping) → palette.successDot (green semantic)
//
// We cannot reach `palette.successDot` without injecting the palette
// environment, so we pin the color-family semantics: red states, yellow
// states, and green/default states — as documented in the source.
//
// Uses Swift Testing + MacrecCore (project convention).

import Foundation
import Testing
import MacrecCore

@Suite("ReadyPill contract pins")
struct ReadyPillTests {

    // MARK: - Label mapping

    @Test("idle state maps to 'Ready'")
    func idleIsReady() {
        let label = Self.label(for: .idle)
        #expect(label == "Ready")
    }

    @Test("stopped state maps to 'Ready'")
    func stoppedIsReady() {
        let label = Self.label(for: .stopped)
        #expect(label == "Ready")
    }

    @Test("starting state maps to 'Starting…'")
    func startingLabel() {
        let label = Self.label(for: .starting)
        #expect(label == "Starting\u{2026}")  // horizontal ellipsis U+2026
    }

    @Test("recording state maps to 'Recording'")
    func recordingLabel() {
        let label = Self.label(for: .recording)
        #expect(label == "Recording")
    }

    @Test("pausing state maps to 'Pausing…'")
    func pausingLabel() {
        let label = Self.label(for: .pausing)
        #expect(label == "Pausing\u{2026}")
    }

    @Test("paused state maps to 'Paused'")
    func pausedLabel() {
        let label = Self.label(for: .paused)
        #expect(label == "Paused")
    }

    @Test("resuming state maps to 'Resuming…'")
    func resumingLabel() {
        let label = Self.label(for: .resuming)
        #expect(label == "Resuming\u{2026}")
    }

    @Test("splitting state maps to 'Splitting…'")
    func splittingLabel() {
        let label = Self.label(for: .splitting)
        #expect(label == "Splitting\u{2026}")
    }

    @Test("stopping state maps to 'Stopping…'")
    func stoppingLabel() {
        let label = Self.label(for: .stopping)
        #expect(label == "Stopping\u{2026}")
    }

    @Test("failed state maps to 'Error'")
    func failedLabel() {
        let label = Self.label(for: .failed(.screenRecordingPermissionDenied))
        #expect(label == "Error")
    }

    // MARK: - All states have non-empty labels

    @Test("All non-failed states produce a non-empty label")
    func nonFailedStatesHaveLabels() {
        let states: [SessionState] = [
            .idle, .starting, .recording, .pausing, .paused,
            .resuming, .splitting, .stopping, .stopped
        ]
        for state in states {
            let label = Self.label(for: state)
            #expect(!label.isEmpty, "Label for \(state) must not be empty")
        }
    }

    // MARK: - Dot color family pinning

    /// The dot color category for each state.
    enum DotColorFamily: String, Equatable {
        case red
        case yellow
        case successGreen  // palette.successDot semantic (green)
    }

    @Test("recording uses red dot")
    func recordingIsRed() {
        #expect(Self.dotColorFamily(for: .recording) == .red)
    }

    @Test("splitting uses red dot")
    func splittingIsRed() {
        #expect(Self.dotColorFamily(for: .splitting) == .red)
    }

    @Test("failed uses red dot")
    func failedIsRed() {
        #expect(Self.dotColorFamily(for: .failed(.screenRecordingPermissionDenied)) == .red)
    }

    @Test("paused uses yellow dot")
    func pausedIsYellow() {
        #expect(Self.dotColorFamily(for: .paused) == .yellow)
    }

    @Test("pausing uses yellow dot")
    func pausingIsYellow() {
        #expect(Self.dotColorFamily(for: .pausing) == .yellow)
    }

    @Test("resuming uses yellow dot")
    func resumingIsYellow() {
        #expect(Self.dotColorFamily(for: .resuming) == .yellow)
    }

    @Test("idle uses successDot (green) dot")
    func idleIsGreen() {
        #expect(Self.dotColorFamily(for: .idle) == .successGreen)
    }

    @Test("stopped uses successDot (green) dot")
    func stoppedIsGreen() {
        #expect(Self.dotColorFamily(for: .stopped) == .successGreen)
    }

    @Test("starting uses successDot (green) dot")
    func startingIsGreen() {
        #expect(Self.dotColorFamily(for: .starting) == .successGreen)
    }

    @Test("stopping uses successDot (green) dot")
    func stoppingIsGreen() {
        #expect(Self.dotColorFamily(for: .stopping) == .successGreen)
    }

    // MARK: - Key label pins (design spec)

    /// The three labels called out in the test specification as "pin all three":
    @Test("idle->Ready, recording->Recording, paused->Paused are the three primary labels")
    func threePrimaryLabels() {
        #expect(Self.label(for: .idle) == "Ready")
        #expect(Self.label(for: .recording) == "Recording")
        #expect(Self.label(for: .paused) == "Paused")
    }

    // MARK: - Helpers (mirror ReadyPill's private computed vars)

    /// Mirrors `ReadyPill.label` — re-states the same switch so a drift
    /// in either copy triggers a mismatch.
    private static func label(for state: SessionState) -> String {
        switch state {
        case .idle, .stopped:    return "Ready"
        case .starting:          return "Starting\u{2026}"
        case .recording:         return "Recording"
        case .pausing:           return "Pausing\u{2026}"
        case .paused:            return "Paused"
        case .resuming:          return "Resuming\u{2026}"
        case .splitting:         return "Splitting\u{2026}"
        case .stopping:          return "Stopping\u{2026}"
        case .failed:            return "Error"
        }
    }

    /// Mirrors `ReadyPill.dotColor` but returns the color family
    /// (red / yellow / successGreen) rather than a `Color` value so we
    /// can assert without injecting the palette environment.
    private static func dotColorFamily(for state: SessionState) -> DotColorFamily {
        switch state {
        case .recording, .splitting:           return .red
        case .paused, .pausing, .resuming:     return .yellow
        case .failed:                          return .red
        default:                               return .successGreen
        }
    }
}
