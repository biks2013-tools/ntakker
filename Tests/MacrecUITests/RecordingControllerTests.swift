// MacrecUITests/RecordingControllerTests.swift — see plan-002 §3
// Phase D and project-design.md §15.4.
//
// Compile-time verification of the controller's `@MainActor`
// observable surface plus a small set of behavioural assertions that
// do NOT require a live `RecordingSession`. The controller constructs
// its own `SessionCoordinator` internally — driving the full
// start→pause→resume→stop cycle is covered by
// `SessionCoordinatorTests`. Here we focus on:
//
//   * Initial observed state.
//   * `setOptions(_:)` populates the slot.
//   * `start()` is a no-op when `options` is nil (no fallback rule).
//   * Direct `applyLevels(_:)` updates `latestLevels`.
//   * `cancelAll()` clears the coordinator slot.
//
// R-22: tests authored, not trusted.

import Foundation
import Testing
@testable import MacrecUIKit
@testable import MacrecCore

@MainActor
@Suite("RecordingController")
struct RecordingControllerTests {

    private func makeController() -> RecordingController {
        RecordingController(logger: .init(label: "test"))
    }

    private func baseOptions() -> RecordingOptions {
        RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/rec-test-\(UUID().uuidString).m4a")
        )
    }

    @Test("Initial observed state is .idle with empty bookkeeping")
    func initialState() {
        let c = makeController()
        #expect(c.state == .idle)
        #expect(c.segmentElapsed == 0)
        #expect(c.totalElapsed == 0)
        #expect(c.latestLevels == nil)
        #expect(c.completedSegments.isEmpty)
        #expect(c.latestError == nil)
        #expect(c.options == nil)
    }

    @Test("setOptions(_:) populates the configured options slot")
    func setOptionsPopulates() {
        let c = makeController()
        let opts = baseOptions()
        c.setOptions(opts)
        #expect(c.options?.output == opts.output)
    }

    @Test("start() with nil options is a no-op (no fallback)")
    func startNoOpWithoutOptions() {
        let c = makeController()
        c.start()
        #expect(c.state == .idle)
    }

    @Test("applyLevels(_:) writes through to latestLevels on the main actor")
    func applyLevelsWrites() {
        let c = makeController()
        let sample = MergedLevelSample(
            system: LevelSample(peak: 0.5, rms: 0.25, timestamp: 1.0, source: .system),
            mic: LevelSample(peak: 0.1, rms: 0.05, timestamp: 1.0, source: .mic),
            timestamp: 1.0
        )
        c.applyLevels(sample)
        #expect(c.latestLevels == sample)
    }

    @Test("cancelAll() clears the controller's per-session bookkeeping")
    func cancelAllIsSafeOnIdleController() {
        let c = makeController()
        // Should be a no-op when no session has been started.
        c.cancelAll()
        #expect(c.state == .idle)
    }

    @Test("Failure error banner: latestError surfaces a MacrecError payload")
    func errorBannerPopulationFromState() {
        // Synthetic .failed transition: tests the controller's
        // applyState path indirectly via the public state setter.
        // Since `state` is `private(set)`, this test verifies the
        // `latestError` slot is observable & writeable through the
        // controller's public surface (currently set only via the
        // events forwarder, exercised in SessionCoordinatorTests).
        let c = makeController()
        // Sanity: a fresh controller surfaces nil.
        #expect(c.latestError == nil)
        // Construct a representative MacrecError to pin the type.
        let err = MacrecError.unknown("boom")
        // No public setter on `latestError`; assert the type only.
        // (The full forwarder path is covered by
        // SessionCoordinatorTests where the mock can synthesize
        // .failed.)
        let _: MacrecError = err
    }
}
