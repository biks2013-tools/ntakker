// MacrecUIKit/RecordingController.swift — see project-design.md
// §15.4, §15.10, §15.12 and plan-002-toolbar-ui.md §3 Phase D.
//
// `@MainActor @Observable` view-model that owns all UI-visible state
// and routes user actions to the `SessionCoordinator` actor. This is
// the single source of truth for the SwiftUI views (Phase E builds on
// top of it).
//
// Threading:
//   * The controller is `@MainActor` so every observed-property write
//     happens on the main thread.
//   * `start()` constructs the `SessionCoordinator` and spawns an
//     unstructured `Task { for await event in coordinator.events { … } }`
//     loop. The loop body runs on the main actor (it is spawned from
//     a `@MainActor` method, which the unstructured `Task` inherits).
//     The `await` hop into the coordinator returns onto main.
//   * Per investigation Topic 2 / project-design §15.4 forbidden
//     operation: `runTask?.cancel()` is NEVER used to stop a recording
//     because that would interrupt `await session.run()` mid-finalize.
//     The controller forwards every stop through
//     `coordinator.stop()`. `cancelAll()` is reserved for app-shutdown
//     and only after `.stopped` is observed.

import Foundation
import Logging
import MacrecCore
import Observation

/// `@MainActor @Observable` view model for the toolbar UI. Owns the
/// observable `SessionState`, the elapsed-time counter, the latest
/// merged level samples, the array of completed segment URLs, the
/// configured `RecordingOptions` slot, and the publicly-observable
/// error message.
@MainActor
@Observable
public final class RecordingController {

    // MARK: - Observed state

    /// Current session state. Driven by the coordinator's events
    /// stream. Initial value `.idle`.
    public private(set) var state: SessionState = .idle

    /// Elapsed time in the active segment. Reset to zero on each
    /// resume / start. Updated by `elapsedTask` once per second while
    /// `state == .recording`.
    public private(set) var segmentElapsed: TimeInterval = 0

    /// Aggregate elapsed time across all completed + active segments.
    /// Updated by `elapsedTask` once per second while `state ==
    /// .recording`.
    public private(set) var totalElapsed: TimeInterval = 0

    /// Most-recent merged level sample, refreshed at 30 Hz by the
    /// `LevelMeterPublisher`. `nil` until the first sample arrives.
    public private(set) var latestLevels: MergedLevelSample?

    /// Completed segment URLs (post-rename for FR-34 multi-file
    /// recordings). Appended each time `.segmentCompleted(url)`
    /// arrives on the coordinator's events stream.
    public private(set) var completedSegments: [URL] = []

    /// Most-recent error surfaced by the engine. Cleared when a fresh
    /// session starts.
    public private(set) var latestError: MacrecError?

    /// Configured options for the next session. Set by the views via
    /// `setOptions(_:)`. `nil` until the user has provided enough
    /// inputs to construct a `RecordingOptions` (`output` is required).
    public private(set) var options: RecordingOptions?

    // MARK: - Private state

    private let logger: Logger
    private let clock: ContinuousClock

    /// Active coordinator. `nil` between sessions and after teardown.
    private var coordinator: SessionCoordinator?

    /// Event-forwarding task. Spawned in `start()`; cancelled in
    /// `cancelAll()` after `.stopped` is observed.
    private var eventsTask: Task<Void, Never>?

    /// 1 Hz elapsed-time tick task. Started in `start()` /
    /// `resume()` when the state becomes `.recording`; stopped on
    /// pause / stop / failure.
    private var elapsedTask: Task<Void, Never>?

    /// `ContinuousClock.Instant` of the active segment's most-recent
    /// `.recording` transition. Used to compute `segmentElapsed`.
    private var segmentStartedAt: ContinuousClock.Instant?

    // MARK: - Init

    /// Construct a controller. The coordinator is built lazily in
    /// `start()` from the supplied `RecordingOptions`.
    ///
    /// - Parameters:
    ///   - logger: Component-scoped logger
    ///     (label `macrec.ui.controller`).
    ///   - clock: Injectable clock for tests. Defaults to
    ///     `ContinuousClock()`.
    public init(
        logger: Logger,
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.logger = logger
        self.clock = clock
    }

    // MARK: - View inputs

    /// Set the `RecordingOptions` for the next session. Views call
    /// this whenever the user edits the filename / format / folder.
    /// No validation here — the coordinator's factory will pre-flight
    /// the options and surface any error via `.failed`.
    public func setOptions(_ options: RecordingOptions) {
        self.options = options
    }

    // MARK: - Lifecycle

    /// Start a session. Builds a `SessionCoordinator` from the
    /// configured `options` and spawns the events-forwarder task. If
    /// `options` is `nil`, logs a warning and returns — there is no
    /// fallback (project rule: no fallback configuration values).
    public func start() {
        guard let options else {
            logger.warning("start() called without options; ignoring")
            return
        }
        // Allow start from `.idle` / `.stopped` / `.failed` only;
        // every other state means a session is already in flight.
        switch state {
        case .idle, .stopped, .failed:
            break
        default:
            logger.warning("start() ignored — controller state is \(state.description)")
            return
        }

        // Reset per-session bookkeeping.
        completedSegments = []
        latestError = nil
        segmentElapsed = 0
        totalElapsed = 0
        latestLevels = nil

        let coord = SessionCoordinator(
            baseOptions: options,
            logger: logger
        )
        self.coordinator = coord
        startEventsForwarder(coord)
        Task { [weak self] in
            do {
                try await coord.start()
            } catch {
                self?.logger.error("coordinator.start failed: \(error.localizedDescription)")
            }
        }
    }

    /// Programmatic stop. Forwards to `coordinator.stop()`. Never
    /// cancels the run-task — see file-level note.
    public func stop() {
        guard let coordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.stop()
            } catch {
                self?.logger.error("coordinator.stop failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pause the current segment.
    public func pause() {
        guard let coordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.pause()
            } catch {
                self?.logger.error("coordinator.pause failed: \(error.localizedDescription)")
            }
        }
    }

    /// Resume from pause.
    public func resume() {
        guard let coordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.resume()
            } catch {
                self?.logger.error("coordinator.resume failed: \(error.localizedDescription)")
            }
        }
    }

    /// Manual split (FR-32). Rotates the encoder while the session
    /// continues.
    public func split() {
        guard let coordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.split()
            } catch {
                self?.logger.error("coordinator.split failed: \(error.localizedDescription)")
            }
        }
    }

    /// Dismiss the latest engine error so the SwiftUI `ErrorBanner`
    /// can hide. Phase G entry point invoked by every banner button
    /// (Open Settings / Try Again / Dismiss / X close). Independent
    /// of the underlying `state` — clearing the error banner does
    /// NOT walk the session back to `.idle`; that is the engine's
    /// job via the next user-initiated start.
    public func dismissError() {
        latestError = nil
    }

    /// Tear down all internal tasks. Called from
    /// `AppDelegate.applicationWillTerminate(_:)` after `.stopped` is
    /// observed (or unconditionally on app shutdown).
    public func cancelAll() {
        eventsTask?.cancel()
        eventsTask = nil
        stopElapsedTimer()
        if let coordinator {
            Task { await coordinator.teardown() }
        }
        coordinator = nil
    }

    // MARK: - Internal — event forwarding

    /// Spawn the events-forwarder task. Runs on the main actor so
    /// observed-property writes are legal. Cancelled in `cancelAll()`.
    private func startEventsForwarder(_ coordinator: SessionCoordinator) {
        eventsTask?.cancel()
        let stream = coordinator.events
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.handle(event)
                }
            }
        }
    }

    /// Apply an event to observed state. `@MainActor`-isolated.
    private func handle(_ event: SessionCoordinatorEvent) {
        switch event {
        case .stateChanged(let newState):
            applyState(newState)
        case .segmentCompleted(let url):
            completedSegments.append(url)
        case .errorOccurred(let error):
            latestError = error
        }
    }

    /// Apply a `SessionState` to the controller. Drives the elapsed-
    /// timer lifecycle.
    private func applyState(_ newState: SessionState) {
        let previous = state
        state = newState
        switch newState {
        case .recording:
            // Each transition into `.recording` (initial start, after
            // resuming, after a split) marks a new segment window.
            segmentStartedAt = clock.now
            segmentElapsed = 0
            startElapsedTimer()
        case .pausing, .stopping, .splitting:
            // Freeze the elapsed counter at its last value; do not
            // restart.
            stopElapsedTimer()
        case .paused, .stopped:
            stopElapsedTimer()
        case .failed:
            stopElapsedTimer()
        case .idle, .starting, .resuming:
            // No timer change.
            break
        }
        _ = previous  // (keep around in case future logic needs it)
    }

    // MARK: - Internal — elapsed-time tick

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.tickElapsed()
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func tickElapsed() {
        guard case .recording = state else { return }
        guard let started = segmentStartedAt else { return }
        let now = clock.now
        let elapsed = now - started
        // `Duration` → `TimeInterval` via component math (seconds +
        // attoseconds). We only need second resolution.
        let comps = elapsed.components
        let seconds = TimeInterval(comps.seconds)
        segmentElapsed = seconds
        totalElapsed += 1
    }

    // MARK: - Internal — level metering

    /// Apply a merged level sample. Wired from the
    /// `LevelMeterPublisher` (Phase E will set up the merging task).
    /// Public so future Phase E plumbing can call it directly.
    public func applyLevels(_ sample: MergedLevelSample) {
        latestLevels = sample
    }
}
