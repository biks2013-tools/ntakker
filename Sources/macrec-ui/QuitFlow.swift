// macrec-ui/QuitFlow.swift — see project-design.md §15.11 and
// plan-002-toolbar-ui.md §3 Phase F.
//
// Encapsulates the quit-while-recording confirmation flow. Hooked into
// AppKit by `AppDelegate.applicationShouldTerminate(_:)`, which delegates
// the entire decision tree to `handleTerminationRequest()`.
//
// Flow (project-design §15.11):
//
//   1. Read `controller.state`.
//   2. If state is NOT in {.recording, .pausing, .paused, .resuming,
//      .splitting, .stopping}, return `.terminateNow` immediately.
//      Idle / stopped / failed sessions need no confirmation.
//   3. Otherwise, present an `NSAlert` ("Stop recording and quit?")
//      with a default button "Keep Recording" (cancel) and an
//      alternate button "Stop & Quit" (destructive).
//   4. If the user picks "Keep Recording": return `.terminateCancel`
//      and the recording continues untouched.
//   5. If the user picks "Stop & Quit":
//        - kick off `controller.stop()` (fire-and-forget — the
//          controller already spawns its own Task to await the
//          underlying coordinator finalize),
//        - spawn a `withObservationTracking` chain that watches the
//          `@Observable` `controller.state` for `.stopped` or
//          `.failed`,
//        - on terminal-state landing, call
//          `NSApplication.shared.reply(toApplicationShouldTerminate: true)`,
//        - return `.terminateLater` so AppKit defers the actual exit
//          (it keeps the run loop alive for up to 30 s waiting for the
//          reply).
//
// `NSAlert.runModal()` is synchronous and blocks the main thread, so the
// alert-result branch evaluates before this method returns. Only the
// post-confirmation finalize is asynchronous, which is exactly what
// `.terminateLater` is for. The closure-style API sketched in the Phase F
// brief is folded into a synchronous return value here — no
// `@escaping reply:` parameter is needed because the alert blocks.
//
// Concurrency: `@MainActor`-isolated. `NSAlert.runModal()` is main-thread
// only. The post-confirmation finalize uses `withObservationTracking`
// (also main-actor-friendly because `@Observable` types in Swift 5.9+
// integrate with `Observation` cleanly from the main actor) so we never
// hand off to a background queue.
//
// R-26 / R-28 safety: this type holds NO references to the `NSStatusItem`
// and does not finish any `AsyncStream` continuations. Its only side
// effects on app shutdown are (a) calling `controller.stop()` (which
// completes via the existing `coordinator.stop()` finalize path, no
// regression), and (b) calling `NSApplication.reply(toApplicationShouldTerminate:)`
// (the documented AppKit unblock for `.terminateLater`).
//
// NOTE: This file is manual-test only — AC-UI-13 (Phase K acceptance
// criteria) covers the user-facing behavior. The flow is
// AppKit-modal-heavy and exercising it in unit tests would require a UI
// test harness, which is out of scope for plan-002.

import AppKit
import Logging
import MacrecCore
import MacrecUIKit
import Observation

/// `@MainActor`-isolated helper that owns the quit-while-recording
/// confirmation flow. Instantiated once by `AppDelegate` after
/// `RecordingController` is constructed; held for the lifetime of the
/// app via a stored property on the delegate.
@MainActor
final class QuitFlow {

    // MARK: - Dependencies

    /// View-model whose `state` drives the decision (and whose `stop()`
    /// is kicked off when the user confirms). Strong-retained — the
    /// `AppDelegate` is the canonical owner of both the controller and
    /// this flow, so no retain cycle is possible.
    private let controller: RecordingController

    /// Component-scoped logger (label `macrec.ui.quitFlow`).
    private let logger: Logger

    // MARK: - Init

    /// Construct the flow.
    ///
    /// - Parameters:
    ///   - controller: Shared `RecordingController` whose lifecycle
    ///     state gates the confirm dialog.
    ///   - logger: Component-scoped logger; calls are emitted at
    ///     `.info` for the high-level decision tree and `.debug` for
    ///     intra-step bookkeeping.
    init(controller: RecordingController, logger: Logger) {
        self.controller = controller
        self.logger = logger
    }

    // MARK: - Public API

    /// Decide how to respond to AppKit's
    /// `applicationShouldTerminate(_:)` request. Synchronous — the
    /// returned value is the final AppKit reply for the idle / cancel
    /// branches and a `.terminateLater` promise for the
    /// stop-then-quit branch (the post-confirmation finalize signals
    /// AppKit later via `NSApplication.reply(toApplicationShouldTerminate:)`).
    ///
    /// - Returns: The `NSApplication.TerminateReply` to hand back to
    ///   `applicationShouldTerminate(_:)`.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        // 1. Decide whether confirmation is required at all.
        guard isActive(state: controller.state) else {
            logger.info(
                "quit: state=\(controller.state.description) — terminating immediately"
            )
            return .terminateNow
        }

        logger.info(
            "quit: state=\(controller.state.description) — presenting confirm alert"
        )

        // 2. Present the modal confirm alert. `runModal()` blocks the
        //    main thread until the user picks a button.
        let response = presentConfirmAlert()

        // 3. Branch on the response. `alertFirstButtonReturn` is the
        //    FIRST button passed to `addButton(withTitle:)` — which we
        //    add as "Keep Recording" so it is the default (rightmost,
        //    blue, also bound to Return).
        switch response {
        case .alertFirstButtonReturn:
            // "Keep Recording" — user backs out, recording continues.
            logger.info("quit: user picked Keep Recording — terminateCancel")
            return .terminateCancel

        case .alertSecondButtonReturn:
            // "Stop & Quit" — kick off stop and defer the actual quit
            // until the controller reports a terminal state.
            logger.info("quit: user picked Stop & Quit — starting finalize")
            controller.stop()
            observeTerminalStateThenReply()
            return .terminateLater

        default:
            // Unreachable in practice — the alert only has two buttons —
            // but cover the API surface defensively. Treat any unknown
            // response as Cancel so an unexpected modal dismissal does
            // NOT lose a recording.
            logger.warning(
                "quit: unexpected NSAlert response rawValue=\(response.rawValue) — treating as Keep Recording"
            )
            return .terminateCancel
        }
    }

    // MARK: - Internal — state predicate

    /// Active session predicate. Matches project-design §15.11's
    /// "active set" exactly: any state in which a recording is in
    /// flight (engine-running, draining, or transitioning between
    /// segments). `.starting` is included because a session that's
    /// bootstrapping has already opened TCC permissions and may have
    /// allocated capture queues; canceling at that point would orphan
    /// engine resources, so it's safer to confirm.
    private func isActive(state: SessionState) -> Bool {
        switch state {
        case .recording, .pausing, .paused, .resuming, .splitting,
             .stopping, .starting:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }

    // MARK: - Internal — confirm alert

    /// Build and run the confirm alert modally. Returns the user's
    /// response. All user-facing strings are routed through
    /// `String(localized:)` per project-design §15.11.
    private func presentConfirmAlert() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Stop recording and quit?",
            comment: "Confirmation dialog title shown when the user attempts to quit macrec-ui while a recording is in progress."
        )
        alert.informativeText = String(
            localized: "macrec-ui is currently recording. The current file will be finalized before quitting.",
            comment: "Confirmation dialog body shown when the user attempts to quit macrec-ui while a recording is in progress."
        )

        // Default button (rightmost, bound to Return, blue): Keep
        // Recording. Added FIRST so it maps to `.alertFirstButtonReturn`.
        // This is intentional — the safe action (do nothing destructive)
        // is the default per macOS HIG.
        alert.addButton(withTitle: String(
            localized: "Keep Recording",
            comment: "Default button on the quit-while-recording alert; cancels the quit and keeps the recording running."
        ))

        // Alternate button (leftmost): Stop & Quit. Maps to
        // `.alertSecondButtonReturn`. Marked as `hasDestructiveAction`
        // so the system can render it with destructive styling on
        // macOS versions that surface that affordance.
        let stopButton = alert.addButton(withTitle: String(
            localized: "Stop & Quit",
            comment: "Alternate (destructive) button on the quit-while-recording alert; finalizes the current recording and quits."
        ))
        stopButton.hasDestructiveAction = true

        return alert.runModal()
    }

    // MARK: - Internal — terminal-state observer

    /// Watch `controller.state` for `.stopped` or `.failed` and, on
    /// landing, call
    /// `NSApplication.shared.reply(toApplicationShouldTerminate: true)`
    /// to release AppKit's `.terminateLater` hold.
    ///
    /// Implemented with `withObservationTracking` because
    /// `RecordingController` is `@MainActor @Observable` and its `state`
    /// property is observable that way. The pattern mirrors
    /// `AppDelegate.startStateObserver()` exactly: read the property to
    /// register a one-shot observation, and re-arm in the `onChange`
    /// callback.
    ///
    /// The first sample is checked synchronously before arming the
    /// observation in case `controller.stop()` resolved the state to
    /// `.stopped` / `.failed` between the time the user clicked
    /// "Stop & Quit" and the time we got here. This is unlikely
    /// because `controller.stop()` itself spawns a Task, but the
    /// guard keeps the method correct under any scheduling order.
    private func observeTerminalStateThenReply() {
        // Fast path: already terminal — reply right away. (Edge case
        // only; the gate in `handleTerminationRequest()` ensures we
        // never enter here from a terminal state.)
        if isTerminal(state: controller.state) {
            logger.info(
                "quit: controller already terminal (\(controller.state.description)) — replying"
            )
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
            return
        }

        withObservationTracking { [weak self] in
            // Touch the observed property to register the dependency.
            _ = self?.controller.state
        } onChange: { [weak self] in
            // `withObservationTracking`'s `onChange` fires on the
            // mutator's actor, BEFORE the mutation is visible to other
            // observers. Hop onto MainActor to (a) read the post-change
            // value safely, and (b) keep the AppKit reply call on the
            // main thread (NSApplication.reply is main-thread only).
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newState = self.controller.state
                if self.isTerminal(state: newState) {
                    self.logger.info(
                        "quit: controller reached terminal state \(newState.description) — replying to AppKit"
                    )
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    return
                }
                // Not terminal yet — re-arm.
                self.logger.debug(
                    "quit: state=\(newState.description) (non-terminal) — re-arming observation"
                )
                self.observeTerminalStateThenReply()
            }
        }
    }

    /// Terminal-state predicate: true for the two states that signal
    /// the engine has fully released its resources (file finalized OR
    /// aborted). The session can never leave these without a fresh
    /// `start()`, so they are the safe gate for replying to AppKit.
    private func isTerminal(state: SessionState) -> Bool {
        switch state {
        case .stopped, .failed:
            return true
        case .idle, .starting, .recording, .pausing, .paused,
             .resuming, .splitting, .stopping:
            return false
        }
    }
}
