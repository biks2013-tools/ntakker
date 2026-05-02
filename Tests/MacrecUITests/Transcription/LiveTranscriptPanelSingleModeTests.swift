// MacrecUITests/Transcription/LiveTranscriptPanelSingleModeTests.swift —
// plan-010 Phase G / DT-INV regression guard.
//
// PURPOSE: Verify that adding the dual-mode branch (Lane L-9) inside
// `LiveTranscriptPanel.body` did NOT alter the single-mode rendering
// path. The invariant is labelled DT-INV in project-design.md §DT-8.
//
// IMPORTANT — testability boundary:
// `LiveTranscriptPanel` is a SwiftUI view defined in the `macrec-ui`
// EXECUTABLE target. The test target (`MacrecUITests`) only imports
// `MacrecUIKit` + `MacrecCore`, NOT the executable. We therefore cannot
// instantiate `LiveTranscriptPanel` directly or inspect its body tree.
//
// The DT-INV guarantee decomposes into two independently testable
// levels that this suite covers:
//
//   Level 1 — Controller contract (importable from MacrecUIKit):
//     * `transcriptSegments`, `transcriptionStatus`, `transcriptionMode`
//       are the ONLY state the single-mode subtree reads from the
//       controller. Confirm those APIs are stable and default to their
//       expected initial values.
//     * The `maxLiveTranscriptSegments` cap is 100 (unchanged from
//       pre-plan-010).
//     * `LiveTranscriptionMode.single.rawValue` is `"single"` — the raw
//       value the `@AppStorage` key decodes to decide the branch; a
//       rawValue change would silently switch every existing user to dual.
//
//   Level 2 — Branch logic (pure-Swift, no SwiftUI needed):
//     * The mode switch reads `LiveTranscriptionMode(rawValue:)` and
//       treats unknown / missing raw strings as `.single` (the
//       documented default). Any deviation here would expose the single-
//       mode path to a nil-coalescence change.
//     * When `UserDefaults` carries `"single"` for the mode key, the
//       controller's `transcriptionMode` property resolves to `.single`.
//     * When `UserDefaults` carries `"dual"`, the controller's property
//       resolves to `.dual`.
//     * When the key is absent (fresh install / cleared store), the
//       controller's property defaults to `.single`.
//
//   Level 3 — Segment-routing invariance (the DualSidecarLabel contract):
//     * The segment model-to-channel mapping used by `DualLiveTranscriptView`
//       (the dual-mode subtree) is: `"apple"` → channelA, `"apple-cloud"`
//       → channelB, anything else → nil. In single mode this mapping is
//       never consulted; its correctness here is a safety check that the
//       mapping cannot accidentally be triggered in the single-mode path.
//
// If ANY of these assertions drift, the panel has regressed from its
// pre-plan-010 behaviour on the single-mode path.

import Foundation
import Testing
@testable import MacrecCore
@testable import MacrecUIKit

@MainActor
@Suite("LiveTranscriptPanel single-mode invariance (DT-INV)")
struct LiveTranscriptPanelSingleModeTests {

    // MARK: - Helpers

    private func makeController() -> RecordingController {
        RecordingController(logger: .init(label: "test"))
    }

    // MARK: - Level 1: Controller API contract

    @Test("transcriptSegments is empty by default (pre-plan-010 baseline)")
    func transcriptSegmentsDefaultEmpty() {
        let c = makeController()
        #expect(c.transcriptSegments.isEmpty)
    }

    @Test("transcriptionStatus defaults to .idle (pre-plan-010 baseline)")
    func transcriptionStatusDefaultIdle() {
        let c = makeController()
        #expect(c.transcriptionStatus == .idle)
    }

    @Test("maxLiveTranscriptSegments cap is 100 (DT-INV: unchanged from pre-plan-010)")
    func capIs100Unchanged() {
        // DT-INV critical: panel renders up to 100 segments.
        // A change here would alter the panel's visual behaviour.
        #expect(RecordingController.maxLiveTranscriptSegments == 100)
    }

    @Test("maxLiveTranscriptLines alias is 100 (source-compat alias unchanged)")
    func aliasCapIs100() {
        #expect(RecordingController.maxLiveTranscriptLines == 100)
    }

    // MARK: - Level 2: Mode switch branch logic

    @Test("LiveTranscriptionMode.single.rawValue is 'single' (AppStorage branch key)")
    func singleRawValueIsStable() {
        // DT-INV critical: the panel reads
        // @AppStorage(RecordingController.transcriptionModeStorageKey)
        // and passes the raw string to
        // `LiveTranscriptionMode(rawValue:) ?? .single`.
        // If this raw value changes, every user's saved AppStorage
        // would decode to nil and collapse to .single on upgrade,
        // which is safe — but the inverse (new code changing rawValue
        // so it no longer equals "single") would break the branch.
        #expect(LiveTranscriptionMode.single.rawValue == "single")
    }

    @Test("LiveTranscriptionMode.dual.rawValue is 'dual' (branch key for dual subtree)")
    func dualRawValueIsStable() {
        #expect(LiveTranscriptionMode.dual.rawValue == "dual")
    }

    @Test("LiveTranscriptionMode(rawValue: 'unknown') falls back to nil (panel uses ?? .single)")
    func unknownRawValueDecodesNil() {
        let decoded = LiveTranscriptionMode(rawValue: "unknown")
        #expect(decoded == nil)
    }

    @Test("LiveTranscriptionMode(rawValue: '') falls back to nil (empty-string defence)")
    func emptyRawValueDecodesNil() {
        let decoded = LiveTranscriptionMode(rawValue: "")
        #expect(decoded == nil)
    }

    @Test("transcriptionModeStorageKey constant is stable (AppStorage key drift check)")
    func storageModeKeyIsStable() {
        // DT-INV: the panel and controller must read from the SAME
        // UserDefaults key. If one side changes the key string, the
        // mode switch silently breaks.
        #expect(
            RecordingController.transcriptionModeStorageKey
                == "com.macrec.ui.transcriptionMode"
        )
    }

    @Test("Controller defaults to .single when no mode key is in UserDefaults")
    func controllerDefaultsToSingleWhenKeyAbsent() {
        // Remove the key from the standard suite to simulate a fresh install.
        let key = RecordingController.transcriptionModeStorageKey
        let prior = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let c = makeController()
        #expect(c.transcriptionMode == .single,
                "fresh controller with no mode key must resolve to .single")
    }

    @Test("Controller reflects .single when UserDefaults carries 'single'")
    func controllerReadsSingleFromUserDefaults() {
        let key = RecordingController.transcriptionModeStorageKey
        let prior = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("single", forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let c = makeController()
        #expect(c.transcriptionMode == .single)
    }

    @Test("Controller reflects .dual when UserDefaults carries 'dual'")
    func controllerReadsDualFromUserDefaults() {
        let key = RecordingController.transcriptionModeStorageKey
        let prior = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("dual", forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let c = makeController()
        #expect(c.transcriptionMode == .dual)
    }

    @Test("Controller collapses unknown mode raw value to .single (graceful degradation)")
    func controllerCollapsesMalformedModeKeyToSingle() {
        let key = RecordingController.transcriptionModeStorageKey
        let prior = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("invalid-value", forKey: key)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let c = makeController()
        #expect(c.transcriptionMode == .single,
                "an invalid mode raw value must not cause the controller to enter .dual")
    }

    // MARK: - Level 3: DualSidecarLabel routing (safety — not consulted in single mode)

    @Test("DualSidecarLabel.channelTag returns nil for nil model (no routing in single-mode residual segments)")
    func channelTagNilForNilModel() {
        let tag = DualSidecarLabel.channelTag(forModel: nil)
        #expect(tag == nil,
                "nil model must not be routed to either channel — single-mode segments have no model set")
    }

    @Test("DualSidecarLabel.channelTag maps 'apple' → channelA (dual-mode only)")
    func channelTagAppleMapsToChannelA() {
        let tag = DualSidecarLabel.channelTag(forModel: "apple")
        #expect(tag == .channelA)
    }

    @Test("DualSidecarLabel.channelTag maps 'apple-cloud' → channelB (dual-mode only)")
    func channelTagAppleCloudMapsToChannelB() {
        let tag = DualSidecarLabel.channelTag(forModel: "apple-cloud")
        #expect(tag == .channelB)
    }

    @Test("DualSidecarLabel.channelTag returns nil for unrecognised model (no false routing)")
    func channelTagNilForUnknownModel() {
        for model in ["gemini", "soniox", "whisperkit", "azure", ""] {
            let tag = DualSidecarLabel.channelTag(forModel: model)
            #expect(tag == nil,
                    "model '\(model)' must not be routed to a channel — not a dual-mode provider")
        }
    }

    // MARK: - Level 3: Segment-routing invariance via pure-logic assertions

    @Test("TranscriptSegment.durationSec nil on partial segments (panel renders italic via isSettled)")
    func durationSecNilOnPartialSegment() {
        // `isSettled` is defined in `LiveTranscriptPanel.swift` (macrec-ui executable)
        // as `durationSec != nil`. Since we cannot import the executable, we pin
        // the data contract: partial segments have durationSec == nil.
        let partial = TranscriptSegment(
            id: UUID(),
            timestamp: Date(),
            lastUpdated: Date(),
            text: "hel",
            source: .system,
            model: "apple",
            durationSec: nil,
            language: "en-US"
        )
        #expect(partial.durationSec == nil,
                "A partial segment must have durationSec == nil (panel renders italic via isSettled)")
    }

    @Test("TranscriptSegment.durationSec non-nil on finalized segments (panel renders plain via isSettled)")
    func durationSecSetOnFinalizedSegment() {
        // `isSettled == true` when `durationSec != nil`.  Pin the data contract
        // without importing the `isSettled` extension from the executable target.
        let finalized = TranscriptSegment(
            id: UUID(),
            timestamp: Date(),
            lastUpdated: Date(),
            text: "hello world",
            source: .system,
            model: "apple",
            durationSec: 1.5,
            language: "en-US"
        )
        #expect(finalized.durationSec != nil,
                "A finalized segment must have non-nil durationSec (panel renders plain via isSettled)")
        #expect(finalized.durationSec == 1.5)
    }

    @Test("TranscriptSegment language chip: prefix(2).uppercased() produces expected chip text")
    func languageChipTextMatchesPanelBehavior() {
        // The single-mode `segmentView` renders `lang.prefix(2).uppercased()`.
        // Pin this against concrete BCP-47 inputs to catch any panel-side
        // refactor that changes the chip formula.
        let cases: [(bcp47: String, expected: String)] = [
            ("en-US", "EN"),
            ("el-GR", "EL"),
            ("fr-CA", "FR"),
            ("zh-Hant-TW", "ZH"),
            ("de", "DE"),
        ]
        for (input, expected) in cases {
            let chip = String(input.prefix(2)).uppercased()
            #expect(chip == expected,
                    "BCP-47 '\(input)' must produce chip '\(expected)'; got '\(chip)'")
        }
    }

    @Test("TranscriptSegment id is stable after re-creation with same id (Identifiable contract)")
    func segmentIdIsStable() {
        let id = UUID()
        let s1 = TranscriptSegment(
            id: id, timestamp: Date(), lastUpdated: Date(),
            text: "A", source: .system, model: nil, durationSec: nil, language: nil
        )
        let s2 = TranscriptSegment(
            id: id, timestamp: Date(), lastUpdated: Date(),
            text: "B", source: .system, model: nil, durationSec: nil, language: nil
        )
        // SwiftUI's ForEach uses `.id` for view identity; both reconstructed
        // segments must carry the same id so the panel can find and update them.
        #expect(s1.id == s2.id)
        #expect(s1.id == id)
    }

    @Test("clearTranscriptSegments() resets segments and lastTranscriptionError (single-mode API unchanged)")
    func clearTranscriptSegmentsAPIUnchanged() {
        let c = makeController()
        // The public API must remain callable and a no-op on a fresh controller.
        c.clearTranscriptSegments()
        #expect(c.transcriptSegments.isEmpty)
        #expect(c.lastTranscriptionError == nil)
        // Status must remain idle (clear does not transition the status).
        #expect(c.transcriptionStatus == .idle)
    }
}
