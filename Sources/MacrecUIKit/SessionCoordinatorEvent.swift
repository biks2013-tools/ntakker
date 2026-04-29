// MacrecUIKit/SessionCoordinatorEvent.swift — see project-design.md
// §15.5 and plan-002-toolbar-ui.md §3 Phase D.
//
// Public event type emitted on `SessionCoordinator.events`. The
// coordinator publishes one event per discrete observation that the UI
// (`RecordingController`) needs to react to:
//
//   * `.stateChanged(_)`     — every `SessionState` transition the
//     coordinator forwards (engine-emitted) or synthesizes (its own
//     `.pausing`/`.paused`/`.resuming`).
//   * `.segmentCompleted(_)` — fired immediately after a segment file
//     has finalized on disk and (for FR-34 multi-file recordings) any
//     `partNN` rename has settled. The URL is the user-visible final
//     path. `RecordingController` appends it to `completedSegments`,
//     which drives the SavedToDisclosure view.
//   * `.errorOccurred(_)`    — terminal `MacrecError` from the engine.
//     A `.stateChanged(.failed(error))` is also emitted for the same
//     transition, but `errorOccurred` lets the controller surface the
//     error banner without inspecting the state payload.
//
// Plan-004 Phase H — the rest-batch transcription pipeline streams
// `TranscriptionEvent` values that already contain a `metricsTick`
// case. The coordinator forwards those events verbatim via
// `.transcriptEvent(...)`, and additionally re-publishes the metric
// payload as a dedicated `.transcriptionMetrics(...)` event so views
// that only care about the metric snapshot do not have to pattern-
// match inside the larger event enum.
//
// This is a `Sendable` enum so it can cross the actor → `@MainActor`
// boundary on the coordinator's `AsyncStream<SessionCoordinatorEvent>`
// stream.

import Foundation
import MacrecCore

/// Discrete event emitted by `SessionCoordinator.events` for the UI's
/// `RecordingController` to consume. The full UI-visible state machine
/// is reconstructible from the sequence of these events.
public enum SessionCoordinatorEvent: Sendable {
    /// A `SessionState` transition. Either forwarded from the active
    /// `RecordingSession.stateStream` or synthesized by the
    /// coordinator (`.pausing`, `.paused`, `.resuming`).
    case stateChanged(SessionState)

    /// A segment file has finalized on disk. The URL is the user-
    /// visible final path (post-rename if FR-34 has kicked in).
    case segmentCompleted(URL)

    /// A terminal `MacrecError` has propagated out of the engine.
    /// Always paired with a `.stateChanged(.failed(error))` so
    /// observers that prefer to dispatch on `SessionState` see the
    /// same transition.
    case errorOccurred(MacrecError)

    // -- Live transcription (plan-003 Phase G; design §LT-8.5 — refreshed
    //    in plan-004 Phase H for the rest-batch event shape) --

    /// A transcription event forwarded from the active session's
    /// `transcriptEvents` stream. The controller demultiplexes this
    /// into the `transcriptSegments` array, the metrics snapshot, the
    /// pending privacy-disclosure label, and the transient
    /// `lastTranscriptionError` slot.
    case transcriptEvent(TranscriptionEvent)

    /// Convenience metric tick — re-emitted by the coordinator each
    /// time the upstream `TranscriptionEvent.metricsTick` arrives so
    /// metric-only consumers can subscribe without unpacking the full
    /// event enum.
    case transcriptionMetrics(TranscriptionMetrics)

    /// A segment rotation marker. Inserted by the coordinator at
    /// pause / resume / split boundaries so the transcript panel can
    /// render a horizontal-rule separator (AC-LT-20). The string is
    /// the user-visible label (e.g. `"part02"`).
    case transcriptSegmentBoundary(label: String)
}
