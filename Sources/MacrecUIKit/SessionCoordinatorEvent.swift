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
}
