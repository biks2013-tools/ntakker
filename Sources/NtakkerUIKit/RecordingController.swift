// NtakkerUIKit/RecordingController.swift — see project-design.md
// §15.4, §15.10, §15.12 and plan-002-toolbar-ui.md §3 Phase D.
//
// `@MainActor @Observable` view-model that owns all UI-visible state
// and routes user actions to the `SessionCoordinator` actor. This is
// the single source of truth for the SwiftUI views (Phase E builds on
// top of it).
//
// Plan-004 Phase H — UI integration with rest-batch transcription. The
// transcription side-channel switched from a streaming
// `partial`/`final` event surface to a coalesced `[TranscriptSegment]`
// model driven by `TranscriptionEvent.segmentAppended` /
// `.segmentUpdated`. The controller now exposes the segments array
// directly (instead of a synthesised `TranscriptLine` shape), plus a
// metrics snapshot, an opt-in privacy-disclosure label, and a transient
// last-error string for the amber banner.
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

import AVFoundation
import Foundation
import Logging
import NtakkerCore
import Observation

// MARK: - Transcription view-model types (plan-004 Phase H)

/// High-level state of the transcription side-channel for the UI. The
/// rest-batch shape (plan-004) does not expose connection-level state;
/// the manager either is producing segments and metric ticks (`.active`)
/// or it is not (`.idle`). A non-fatal error from the provider sets
/// `.error(message)` until the next event clears it.
public enum TranscriptionUIState: Sendable, Equatable {
    /// Transcription is disabled OR the session has not yet produced any
    /// events.
    case idle
    /// Transcription is enabled and producing events.
    case active
    /// Most recent non-fatal error message from the provider/sidecar.
    case error(String)
}

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

    /// M2 (EVAL 2026-10-16): whether any level meter is on screen. Set
    /// by the popover as it shows and closes. While false the level
    /// publisher stops yielding and `latestLevels` is cleared, so a
    /// hidden popover costs no main-actor work per tick.
    public var levelMetersVisible: Bool = true {
        didSet {
            guard levelMetersVisible != oldValue else { return }
            levelMeterPublisher?.setPaused(!levelMetersVisible)
            if !levelMetersVisible { latestLevels = nil }
        }
    }

    /// Completed segment URLs (post-rename for FR-34 multi-file
    /// recordings). Appended each time `.segmentCompleted(url)`
    /// arrives on the coordinator's events stream.
    public private(set) var completedSegments: [URL] = []

    /// Most-recent error surfaced by the engine. Cleared when a fresh
    /// session starts.
    public private(set) var latestError: NtakkerError?

    /// Sources muted in the current recording (2026-10-21): recorded and
    /// transcribed as silence until unmuted. Cleared when a recording
    /// starts; kept across pause / resume / split.
    public private(set) var mutedSources: Set<CaptureSourceTag> = []

    /// Whether a source can be muted now: while a recording is running
    /// or paused (not before it starts or after it stops).
    public var canMute: Bool {
        guard coordinator != nil else { return false }
        switch state {
        case .starting, .recording, .pausing, .paused, .resuming, .splitting: return true
        case .idle, .stopping, .stopped, .failed: return false
        }
    }

    /// Mute or unmute `source` in the current recording.
    public func setMuted(_ muted: Bool, source: CaptureSourceTag) {
        guard canMute, let coordinator else { return }
        if muted { mutedSources.insert(source) } else { mutedSources.remove(source) }
        logger.info("\(source.rawValue) \(muted ? "muted" : "unmuted") by the user")
        // Chained so quick mute / unmute clicks reach the coordinator
        // in the order they were made.
        let previous = muteTask
        muteTask = Task {
            await previous?.value
            await coordinator.setMuted(muted, source: source)
        }
    }

    /// The latest mute change on its way to the coordinator.
    private var muteTask: Task<Void, Never>?

    /// Flip `source` between muted and unmuted.
    public func toggleMute(_ source: CaptureSourceTag) {
        setMuted(!mutedSources.contains(source), source: source)
    }

    /// Configured options for the next session. Set by the views via
    /// `setOptions(_:)`. `nil` until the user has provided enough
    /// inputs to construct a `RecordingOptions` (`output` is required).
    public private(set) var options: RecordingOptions?

    // MARK: - Transcription observed state (plan-004 Phase H)

    /// High-level lifecycle state of the active transcription pipeline.
    /// Driven by the rest-batch event stream — stays `.idle` until the
    /// first `segmentAppended` / `metricsTick` arrives, flips back to
    /// `.idle` at session teardown.
    public private(set) var transcriptionStatus: TranscriptionUIState = .idle

    /// Append-only list of coalesced transcript segments. Each event
    /// from `TranscriptionEvent.segmentAppended` / `.segmentUpdated`
    /// mutates this array per the index payload. Capped at the most
    /// recent `maxLiveTranscriptSegments` entries so memory stays
    /// bounded for long recordings.
    public private(set) var transcriptSegments: [TranscriptSegment] = []

    /// Every transcript segment of the current session, uncapped
    /// (EVAL-2026-10-16 UI-6). Ask "Full" / "15 min" and Save's
    /// in-memory fallback read this; the live panel keeps reading the
    /// capped `transcriptSegments`. Not cleared by
    /// `clearTranscriptSegments()` (that only clears the panel); reset
    /// when a new recording starts and by `resetToIdle()`. A session's
    /// text is small (an hour is roughly 1–2 k segments).
    public private(set) var sessionTranscript: [TranscriptSegment] = []

    /// Position of each segment id in `sessionTranscript`.
    @ObservationIgnored private var sessionTranscriptIndex: [UUID: Int] = [:]

    /// Aggregated transcription metrics from the manager. Updated on
    /// every `metricsTick` event.
    public private(set) var transcriptionMetrics: TranscriptionMetrics = TranscriptionMetrics()

    /// Provider display name pending a privacy-disclosure prompt. Set
    /// by `TranscriptionEvent.privacyDisclosure(...)`; cleared by the
    /// view layer once the user acknowledges.
    public private(set) var pendingDisclosure: String?

    /// Most-recent non-fatal transcription error message — surfaced as
    /// a transient amber banner in the live transcript panel. Cleared
    /// when a new `metricsTick` arrives (next successful round-trip).
    public private(set) var lastTranscriptionError: String?

    /// Whether the active provider needs an API key but the resolved
    /// `RecordingOptions.transcriptionApiKey` is `nil`. Drives the
    /// red-dot `TranscriptionMissingKeyBadge` in the picker. Updated
    /// each time `setOptions(_:)` is called.
    public private(set) var transcriptionMissingKey: Bool = false

    /// Maximum number of segments retained in `transcriptSegments`.
    /// Older segments are dropped from the head of the array when the
    /// cap is exceeded — the sidecar file remains the persistent
    /// record. The same constant is also used by tests / panels that
    /// previously talked about "lines"; kept under the historical
    /// `maxLiveTranscriptLines` symbol for source-compat.
    public static let maxLiveTranscriptSegments: Int = 100
    public static let maxLiveTranscriptLines: Int = maxLiveTranscriptSegments

    // MARK: - Private state

    private let logger: Logger
    private let clock: ContinuousClock

    /// Active coordinator. `nil` between sessions and after teardown.
    private var coordinator: SessionCoordinator?

    /// Event-forwarding task. Spawned in `start()`; cancelled in
    /// `cancelAll()` after `.stopped` is observed.
    private var eventsTask: Task<Void, Never>?

    /// Per-session level-meter publisher. Constructed in `start()`,
    /// fed by the session's per-source `levelTap` closures (wired
    /// via `coordinator.setLevelTapSink(...)` → `RecordingSession.levelTapSink`).
    /// Drained by `levelMeterDrainTask` into `applyLevels(_:)`.
    /// Torn down in `cancelAll()` and on `.stopped` / `.failed`.
    private var levelMeterPublisher: LevelMeterPublisher?

    /// Drain task pumping `levelMeterPublisher.stream` into
    /// `applyLevels(_:)` on the main actor. Cancelled when the
    /// publisher is torn down.
    private var levelMeterDrainTask: Task<Void, Never>?

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
    ///     (label `ntakker-cli.ui.controller`).
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
        // Recompute the missing-key state. A provider whose
        // `requiredApiKey` is non-nil but whose resolved
        // `transcriptionApiKey` is nil/empty is missing its key.
        if let providerId = options.transcriptionProviderId,
           !providerId.isEmpty,
           providerId.lowercased() != "none",
           providerId.lowercased() != "noop"
        {
            // v1 supports the Gemini rest-batch provider under the
            // canonical id `"gemini"`. The deprecated alias
            // `"gemini-live"` is still accepted by the resolver and
            // also requires a key.
            let needsKey: Bool
            switch providerId.lowercased() {
            case "gemini", "gemini-live":
                needsKey = true
            default:
                needsKey = false
            }
            if needsKey {
                let key = options.transcriptionApiKey
                self.transcriptionMissingKey = (key == nil) || (key?.isEmpty ?? true)
            } else {
                self.transcriptionMissingKey = false
            }
        } else {
            self.transcriptionMissingKey = false
        }
    }

    /// Acknowledge the most-recent privacy disclosure. Called by the
    /// view layer once the user dismisses the modal sheet — clears the
    /// `pendingDisclosure` slot so the sheet does not re-fire on the
    /// next render pass.
    public func acknowledgePendingDisclosure() {
        pendingDisclosure = nil
    }

    /// Dismiss the transient transcription-error banner.
    public func dismissTranscriptionError() {
        lastTranscriptionError = nil
    }

    /// Clear the live transcript panel without touching the underlying
    /// session. Resets `transcriptSegments` (the rolling in-memory cap)
    /// and the transient error banner; leaves `transcriptionStatus` and
    /// `transcriptionMetrics` alone so an in-flight session keeps
    /// reporting cost / latency and a still-active provider can keep
    /// appending fresh segments. The on-disk sidecar file is the
    /// persistent record and is unaffected.
    public func clearTranscriptSegments() {
        transcriptSegments = []
        lastTranscriptionError = nil
    }

    /// Reset the controller from `.stopped` (or `.failed`) back to
    /// `.idle` so the popover's bottom action area renders the Start
    /// button again instead of the `[ New Session ][ Save… ]` pair.
    /// Clears the in-memory transcript, the completed-segments list
    /// (which hides `SavedToDisclosure`), the elapsed counters, the
    /// transcription metrics, and the last-error banner. Safe to call
    /// from any non-active state; ignored otherwise so it cannot
    /// abort an in-flight recording.
    public func resetToIdle() {
        switch state {
        case .idle, .stopped, .failed:
            break
        default:
            logger.warning("resetToIdle() ignored — controller state is \(state.description)")
            return
        }
        completedSegments = []
        transcriptSegments = []
        resetSessionTranscript()
        latestError = nil
        lastTranscriptionError = nil
        segmentElapsed = 0
        totalElapsed = 0
        latestLevels = nil
        transcriptionMetrics = TranscriptionMetrics()
        transcriptionStatus = .idle
        state = .idle
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

        // H1 (EVAL 2026-06-12): transition OUT of the startable states
        // synchronously, before any Task is spawned. Without this, a
        // second start() arriving before the coordinator's async
        // `.starting` event (double-click, Try-Again, clearSession
        // restart) passed the guard above, built a SECOND coordinator,
        // and overwrote `self.coordinator` — orphaning a live session
        // that kept capturing and could never be stopped. On failure
        // the coordinator emits `.stateChanged(.failed)`, which reopens
        // the gate via the events forwarder.
        state = .starting

        // Reset per-session bookkeeping.
        completedSegments = []
        mutedSources = []
        latestError = nil
        segmentElapsed = 0
        totalElapsed = 0
        latestLevels = nil
        // Reset transcription state. `transcriptionStatus` will flip
        // to `.active` on the first event the manager forwards.
        transcriptSegments = []
        resetSessionTranscript()
        transcriptionMetrics = TranscriptionMetrics()
        pendingDisclosure = nil
        lastTranscriptionError = nil
        transcriptionStatus = .idle

        let coord = SessionCoordinator(
            baseOptions: options,
            logger: logger
        )
        self.coordinator = coord
        startEventsForwarder(coord)

        // Build the level-meter publisher and install its capture-tap
        // sink on the next session built by the coordinator. Both
        // capture sources emit `CaptureBuffer`s in the pipeline
        // canonical format (Float32, 48 kHz, stereo, non-interleaved
        // — see CaptureBuffer.swift §3.4 doc-comment), so a single
        // shared format works for both publisher taps. The sink
        // dispatches by `CaptureBuffer.source`.
        let mergedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
        // Build the level-meter publisher and the sink closure NOW;
        // sequencing is critical: the sink MUST be installed on the
        // coordinator BEFORE `coord.start()` is awaited, because the
        // session reads `levelTapSink` once during its capture-source
        // wiring step (RecordingSession.swift Step 7). If the sink
        // arrives later, the source-side `levelTap` closures stay nil
        // forever and the meters are dead. Both calls are made on a
        // single Task so the actor sees them in deterministic order.
        let sinkClosure: (@Sendable (CaptureBuffer) -> Void)?
        if let mergedFormat {
            do {
                let publisher = try LevelMeterPublisher(
                    micFormat: mergedFormat,
                    systemFormat: mergedFormat,
                    logger: Logger(label: "ntakker-cli.ui.levelMeter")
                )
                self.levelMeterPublisher = publisher
                publisher.setPaused(!levelMetersVisible)
                // Strong capture (see comment in `cancelAll()` for why).
                let strongPublisher = publisher
                // H3/H4 (EVAL 2026-06-12): this closure runs on the
                // capture queues for EVERY audio buffer — it must stay
                // free of locks, logging, and allocation. The previous
                // LEVELMETER_RT diagnostic counters (an
                // OSAllocatedUnfairLock acquisition per buffer plus
                // always-on warning-level logs) were leftover debug
                // scaffolding and have been removed.
                sinkClosure = { capture in
                    switch capture.source {
                    case .system:
                        strongPublisher.handleSystem(capture.buffer)
                    case .microphone:
                        strongPublisher.handleMic(capture.buffer)
                    }
                }
                let stream = publisher.stream
                self.levelMeterDrainTask = Task { @MainActor [weak self] in
                    for await sample in stream {
                        guard let self else { return }
                        self.applyLevels(sample)
                    }
                }
            } catch {
                logger.warning("level-meter publisher init failed: \(error.localizedDescription) — bars will stay flat")
                sinkClosure = nil
            }
        } else {
            sinkClosure = nil
        }

        Task { [weak self] in
            do {
                // Install the sink first, THEN start. Sequencing on a
                // single Task guarantees the actor sees `setLevelTapSink`
                // before `start()`'s `buildAndRun` reads `levelTapSink`.
                if let sinkClosure {
                    await coord.setLevelTapSink(sinkClosure)
                }
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
        levelMeterDrainTask?.cancel()
        levelMeterDrainTask = nil
        // Clear the coordinator's sink first so it drops its strong
        // reference to the publisher; THEN finish + release the
        // publisher locally.
        if let coordinator {
            Task { await coordinator.setLevelTapSink(nil) }
        }
        levelMeterPublisher?.finish()
        levelMeterPublisher = nil
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
        case .transcriptEvent(let trEvent):
            applyTranscriptionEvent(trEvent)
        case .transcriptionMetrics(let metrics):
            transcriptionMetrics = metrics
            // A fresh metrics tick implies the most recent provider
            // round-trip succeeded; clear the transient error banner
            // so it does not stick around forever.
            lastTranscriptionError = nil
            if transcriptionStatus == .idle {
                transcriptionStatus = .active
            }
        case .transcriptSegmentBoundary(let label):
            // Segment boundary marker from SessionCoordinator (plan-002
            // FR-32 / R-31). No transcript-side action — segments
            // naturally re-anchor on the next .segmentAppended event
            // from the new manager.
            logger.debug("transcript segment boundary: \(label)")
        }
    }

    /// Apply a single `TranscriptionEvent` to the controller's observed
    /// state. The rest-batch shape (plan-004) replaces the historical
    /// `partial` / `final` event pair with `segmentAppended` /
    /// `segmentUpdated`, and replaces `providerStateChange` /
    /// `sessionEnded` with `metricsTick` + the manager's final tick at
    /// `stop()`.
    ///
    /// Access is `internal` (not `private`) so the unit-test target can
    /// drive the controller via `@testable import NtakkerUIKit` — see
    /// `RecordingControllerLongSessionTests`. Production callers MUST
    /// continue to go through the events-forwarder loop.
    internal func applyTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        // H4 (EVAL 2026-06-12): per-event logs run several times per
        // second on streaming providers — keep them at .trace so the
        // default level pays no string-interpolation cost.
        case let .segmentAppended(index, segment):
            logger.trace("transcript event: segmentAppended idx=\(index) text='\(segment.text.prefix(40))…' total=\(transcriptSegments.count + 1)")
            appendOrInsertSegment(at: index, segment: segment)
            transcriptionStatus = .active
        case let .segmentUpdated(index, segment):
            logger.trace("transcript event: segmentUpdated idx=\(index) text='\(segment.text.prefix(40))…'")
            updateSegment(at: index, segment: segment)
            transcriptionStatus = .active
        case let .segmentFinalized(index, segment):
            logger.trace("transcript event: segmentFinalized idx=\(index) text='\(segment.text.prefix(40))…'")
            // Phase H (plan-005): wire the streaming "settled" visual
            // treatment to this event. The replacement segment carries
            // a non-nil `durationSec` (set by the streaming pipeline's
            // finalize handler) and the winning `language` tag, both of
            // which are required by the row view to render the
            // "settled" style and the language chip.
            finalizeSegment(at: index, segment: segment)
            transcriptionStatus = .active
        case let .privacyDisclosure(providerDisplayName):
            logger.info("transcript event: privacyDisclosure provider=\(providerDisplayName)")
            pendingDisclosure = providerDisplayName
        case let .metricsTick(metrics):
            logger.debug("transcript event: metricsTick chunks=\(metrics.chunksSent) errors=\(metrics.errorCount)")
            transcriptionMetrics = metrics
            lastTranscriptionError = nil
            if transcriptionStatus == .idle {
                transcriptionStatus = .active
            }
        case let .error(detail):
            logger.error("transcript event: error \(detail)")
            lastTranscriptionError = detail
            transcriptionStatus = .error(detail)
        }
    }

    // MARK: - Segment store
    //
    // The streaming pipeline emits monotonic absolute indices
    // (`StreamingTranscriptionPipeline.nextSegmentIndex` keeps growing
    // for the lifetime of the session). The previous implementation
    // treated those indices as positions inside this length-capped
    // array — once the cap engaged (~100 utterances ≈ 8–12 min on
    // Soniox cadence), every absolute index >= count produced a
    // duplicate row: the first partial appended at the end, subsequent
    // partials silently no-oped (`index < count` was false), and the
    // final appended a *second* row. The user observed this as "each
    // line rendered twice" plus accelerated eviction of older content.
    //
    // The fix keys the store on `TranscriptSegment.id` (the utterance
    // UUID, which is identical across `.segmentAppended`,
    // `.segmentUpdated`, and `.segmentFinalized` for the same
    // utterance — see `StreamingTranscriptionPipeline.handle(_:)`).
    // The `index` payload is now advisory (kept in the signature so
    // call sites are unchanged); routing decisions are made by id.

    /// Append a new segment, or replace an existing entry that already
    /// carries the same `id`. The rolling cap is enforced after each
    /// mutation. The sidecar file remains the persistent record for
    /// everything dropped from the head.
    private func appendOrInsertSegment(at index: Int, segment: TranscriptSegment) {
        _ = index  // advisory — segment.id is the source of truth
        if let existing = transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
            transcriptSegments[existing] = segment
        } else {
            transcriptSegments.append(segment)
        }
        enforceSegmentCap()
        recordInSessionTranscript(segment)
    }

    /// Replace an existing entry that already carries the same `id`.
    /// No-op when the segment has already been evicted by the rolling
    /// cap (subsequent partials for an evicted utterance are silently
    /// dropped — the sidecar file still records them).
    private func updateSegment(at index: Int, segment: TranscriptSegment) {
        _ = index
        if let existing = transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
            transcriptSegments[existing] = segment
        }
        recordInSessionTranscript(segment)
    }

    /// Plan-005 Phase H: replace the entry carrying `segment.id` with
    /// its finalised counterpart (non-nil `durationSec`, populated
    /// `language` tag). Falls back to `append` when the row was already
    /// evicted — the late-arriving final still surfaces in the panel
    /// instead of being dropped silently.
    private func finalizeSegment(at index: Int, segment: TranscriptSegment) {
        _ = index
        if let existing = transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
            transcriptSegments[existing] = segment
        } else {
            transcriptSegments.append(segment)
            enforceSegmentCap()
        }
        recordInSessionTranscript(segment)
    }

    /// UI-6: insert or replace `segment` in the uncapped session list.
    private func recordInSessionTranscript(_ segment: TranscriptSegment) {
        if let existing = sessionTranscriptIndex[segment.id] {
            sessionTranscript[existing] = segment
        } else {
            sessionTranscriptIndex[segment.id] = sessionTranscript.count
            sessionTranscript.append(segment)
        }
    }

    private func resetSessionTranscript() {
        sessionTranscript = []
        sessionTranscriptIndex = [:]
    }

    /// Drop the oldest segments until `transcriptSegments.count` no
    /// longer exceeds `maxLiveTranscriptSegments`.
    private func enforceSegmentCap() {
        if transcriptSegments.count > Self.maxLiveTranscriptSegments {
            let overflow = transcriptSegments.count - Self.maxLiveTranscriptSegments
            transcriptSegments.removeFirst(overflow)
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
            if case .stopped = newState {
                // Session ended — reset the transcription pipeline
                // status so the panel collapses cleanly on the next
                // start.
                transcriptionStatus = .idle
                tearDownLevelMeter()
            }
        case .failed:
            stopElapsedTimer()
            transcriptionStatus = .idle
            tearDownLevelMeter()
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

    /// Apply a merged level sample. Wired by `start()` from the
    /// `LevelMeterPublisher`'s 30 Hz stream.
    public func applyLevels(_ sample: MergedLevelSample) {
        latestLevels = sample
    }

    /// Tear down the level-meter publisher when a session ends
    /// (`.stopped` / `.failed`). Idempotent. Drops the latest sample
    /// to nil so the meter view collapses to its at-rest state.
    private func tearDownLevelMeter() {
        levelMeterDrainTask?.cancel()
        levelMeterDrainTask = nil
        if let coordinator {
            Task { await coordinator.setLevelTapSink(nil) }
        }
        levelMeterPublisher?.finish()
        levelMeterPublisher = nil
        latestLevels = nil
    }

}
