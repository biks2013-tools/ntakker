// MacrecUIKit/RecordingController.swift — see project-design.md
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
import MacrecCore
import Observation
import struct os.OSAllocatedUnfairLock

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

    // MARK: - Dual-mode observed state (plan-010 Phase C / Lane L-5)
    //
    // Frozen contract (project-design §DT-13 inter-lane contract #5).
    // Property names and types here are consumed by L-7 (mode switch +
    // single sub-view), L-8 (dual controls panel), L-9 (dual live
    // transcript view), and L-11 (per-channel metrics view). Do not
    // rename or change types without coordinating across those lanes.

    /// `UserDefaults` / `@AppStorage` key carrying the persisted
    /// live-transcription mode. The single canonical spelling for this
    /// key. SwiftUI's `@AppStorage("com.macrec.ui.transcriptionMode")`
    /// in the picker views writes to the same `UserDefaults.standard`
    /// slot this controller observes (mirroring §DT-9 / DT-ADR-13).
    public nonisolated static let transcriptionModeStorageKey: String = "com.macrec.ui.transcriptionMode"

    /// Mirror of the `@AppStorage("com.macrec.ui.transcriptionMode")`
    /// value, kept in sync via a `UserDefaults.didChangeNotification`
    /// observer registered in `init`. Default `.single` (matches
    /// `LiveTranscriptionMode`'s documented default — first launch and
    /// any value the resolver cannot decode collapse to `.single`).
    ///
    /// Per the L-5 lane spec: this value drives (a) the UI gating
    /// decision (which sub-view L-7/L-8/L-9 renders) and (b) whether
    /// the controller attempts to populate `dualMetrics` from the
    /// in-flight dispatcher. The controller itself does NOT construct
    /// the dispatcher (that is L-4's territory in `RecordingSession`);
    /// it merely observes the mode value the user has selected so the
    /// rest of the UI can branch correctly.
    public private(set) var transcriptionMode: LiveTranscriptionMode = .single

    /// Per-channel split of the active transcription pipeline's
    /// metrics. `nil` when the session is not running OR when
    /// `transcriptionMode == .single` OR when (defensively) the
    /// dispatcher in flight does not match the published mode.
    ///
    /// Populated by `applyDualMetrics(_:)`, which L-11's per-channel
    /// metrics view will drive on the same cadence as the existing
    /// `transcriptionMetrics` poll once L-4 exposes the dispatcher
    /// reference through `SessionCoordinator`. Until L-4 lands the
    /// dispatcher protocol and the `currentDualMetrics()` downcast
    /// pathway, this property remains `nil` — single-mode UI ignores
    /// it and dual-mode UI renders a graceful "—" placeholder.
    public private(set) var dualMetrics: DualChannelMetrics?

    /// Per-channel error map populated from
    /// `TranscriptionEvent.dualChannelError(channel:, detail:)` events.
    /// Keyed by `DualChannelTag` so an arrival on Channel A does NOT
    /// clear an existing Channel B error (and vice versa). Cleared
    /// wholesale at the next `start()` call.
    ///
    /// Consumed by L-8 (controls panel inline error label per channel)
    /// and L-9 (per-lane error badge). Read access pattern is
    /// `dualChannelErrors[.channelA]` / `dualChannelErrors[.channelB]`.
    public private(set) var dualChannelErrors: [DualChannelTag: String] = [:]

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

    /// `UserDefaults.didChangeNotification` observer token that keeps
    /// `transcriptionMode` in sync with whatever SwiftUI's
    /// `@AppStorage("com.macrec.ui.transcriptionMode")` writes to the
    /// shared store. Released in `cancelAll()` and on deinit.
    /// Pattern mirrors `PopoverController.sizeObserver` (the existing
    /// AppStorage-bridge idiom in this codebase).
    private var transcriptionModeObserver: NSObjectProtocol?

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
        // Plan-010 / L-5: seed `transcriptionMode` from the persisted
        // UserDefaults value (set by SwiftUI's `@AppStorage` in the
        // mode-switch view, or by an earlier session). Bad / missing
        // values collapse to `.single` (the documented default — see
        // `LiveTranscriptionMode`). Subsequent writes by the picker
        // are picked up by the notification observer below.
        self.transcriptionMode = Self.loadTranscriptionMode()
        installTranscriptionModeObserver()
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

    // MARK: - Lifecycle

    /// Start a session. Builds a `SessionCoordinator` from the
    /// configured `options` and spawns the events-forwarder task. If
    /// `options` is `nil`, logs a warning and returns — there is no
    /// fallback (project rule: no fallback configuration values).
    public func start() {
        Logger(label: "macrec.ui.controller.start").warning("LEVELMETER_RT controller.start() entered")
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
        // Reset transcription state. `transcriptionStatus` will flip
        // to `.active` on the first event the manager forwards.
        transcriptSegments = []
        transcriptionMetrics = TranscriptionMetrics()
        pendingDisclosure = nil
        lastTranscriptionError = nil
        transcriptionStatus = .idle
        // Plan-010 / L-5: reset dual-mode per-session state. The dual
        // metrics slot stays nil until L-11 wires the dispatcher
        // downcast; the per-channel error map is cleared so a stale
        // error from a prior session does not leak into the new one.
        dualMetrics = nil
        dualChannelErrors = [:]

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
        Logger(label: "macrec.ui.controller.fmt").warning("LEVELMETER_RT mergedFormat=\(mergedFormat == nil ? "NIL" : "ok")")
        if let mergedFormat {
            do {
                let publisher = try LevelMeterPublisher(
                    micFormat: mergedFormat,
                    systemFormat: mergedFormat,
                    logger: Logger(label: "macrec.ui.levelMeter")
                )
                self.levelMeterPublisher = publisher
                // Strong capture (see comment in `cancelAll()` for why).
                let strongPublisher = publisher
                // Fresh post-bootstrap logger (the cached
                // AppDelegate-level loggers route to a no-op handler
                // because they were created before LoggerFactory.bootstrap).
                let sinkLogger = Logger(label: "macrec.ui.controller.sink")
                let sinkCounter = OSAllocatedUnfairLock<(system: Int, mic: Int)>(
                    initialState: (0, 0)
                )
                sinkClosure = { capture in
                    let count = sinkCounter.withLock { state -> (Int, String) in
                        switch capture.source {
                        case .system:
                            state.system += 1
                            return (state.system, "system")
                        case .microphone:
                            state.mic += 1
                            return (state.mic, "mic")
                        }
                    }
                    if count.0 == 1 || count.0 % 200 == 0 {
                        sinkLogger.warning("LEVELMETER_RT sink \(count.1) hit count=\(count.0)")
                    }
                    switch capture.source {
                    case .system:
                        strongPublisher.handleSystem(capture.buffer)
                    case .microphone:
                        strongPublisher.handleMic(capture.buffer)
                    }
                }
                let stream = publisher.stream
                let drainLogger = Logger(label: "macrec.ui.controller.drain")
                self.levelMeterDrainTask = Task { @MainActor [weak self] in
                    var drainCount = 0
                    for await sample in stream {
                        guard let self else { return }
                        drainCount += 1
                        if drainCount == 1 || drainCount % 60 == 0 {
                            let sysPeak = sample.system?.peak ?? -1
                            let micPeak = sample.mic?.peak ?? -1
                            drainLogger.warning("LEVELMETER_RT drain count=\(drainCount) sysPeak=\(sysPeak) micPeak=\(micPeak)")
                        }
                        self.applyLevels(sample)
                    }
                    drainLogger.warning("LEVELMETER_RT drain ENDED count=\(drainCount)")
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
        if let token = transcriptionModeObserver {
            NotificationCenter.default.removeObserver(token)
            transcriptionModeObserver = nil
        }
    }

    deinit {
        // Defensive: in tests / short-lived controllers `cancelAll()`
        // may not be invoked. Drop the notification observer here too
        // so the controller releases cleanly. Other state (event task,
        // coordinator) is owned by the host app's `cancelAll()` call.
        //
        // Plan-010 Wave-3 / Lane L-4 build-fix: Swift 6's stricter
        // actor isolation rules forbid a non-isolated deinit from
        // reading a `@MainActor`-isolated property. Snapshot the token
        // through `MainActor.assumeIsolated` — at deinit time there is
        // no other reference to `self`, so the snapshot is race-free
        // (Swift's deinit guarantees serialise here). The observer
        // removal itself is safe to call from any thread per
        // `NotificationCenter`'s documented contract.
        let token = MainActor.assumeIsolated { transcriptionModeObserver }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
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
    /// drive the controller via `@testable import MacrecUIKit` — see
    /// `RecordingControllerLongSessionTests`. Production callers MUST
    /// continue to go through the events-forwarder loop.
    internal func applyTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case let .segmentAppended(index, segment):
            logger.info("transcript event: segmentAppended idx=\(index) text='\(segment.text.prefix(40))…' total=\(transcriptSegments.count + 1)")
            appendOrInsertSegment(at: index, segment: segment)
            transcriptionStatus = .active
        case let .segmentUpdated(index, segment):
            logger.info("transcript event: segmentUpdated idx=\(index) text='\(segment.text.prefix(40))…'")
            updateSegment(at: index, segment: segment)
            transcriptionStatus = .active
        case let .segmentFinalized(index, segment):
            logger.info("transcript event: segmentFinalized idx=\(index) text='\(segment.text.prefix(40))…'")
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
        case let .dualChannelError(channel, detail):
            // Plan-010 Phase C / L-5: route the per-channel error to the
            // dedicated `dualChannelErrors` keyed-by-channel surface
            // (frozen contract #5; consumed by L-7/L-8/L-9/L-11).
            //
            // KEY semantics (per L-5 prompt): per-channel; arrival of an
            // A-error does NOT clear an existing B-error. Each entry is
            // overwritten only by a subsequent error on the SAME channel
            // (or cleared at the next session start in `start()`).
            //
            // Coexistence with `lastTranscriptionError`: the single-mode
            // amber-banner consumer reads `lastTranscriptionError`; the
            // dual-mode per-lane error badges read `dualChannelErrors`.
            // Single-mode UI is, by construction, never wired to
            // `.dualChannelError` events (a `TranscriptionManager` does
            // not emit them); dual-mode UI is wired to
            // `dualChannelErrors`. The two surfaces therefore do not
            // overlap in normal operation. To keep the existing single-
            // mode `lastTranscriptionError`-based amber banner usable
            // for backward compat (e.g. a dual session viewed by a
            // panel that has not yet been migrated to per-channel UI),
            // we ALSO set `lastTranscriptionError` to a channel-tagged
            // message and flip `transcriptionStatus` to `.error(...)`.
            // Once L-7..L-11 land their per-channel surfaces, panels in
            // dual mode should ignore these legacy fields and read
            // `dualChannelErrors` instead.
            let label: String
            switch channel {
            case .channelA: label = "Channel A"
            case .channelB: label = "Channel B"
            }
            let tagged = "\(label): \(detail)"
            logger.error("transcript event: dualChannelError \(tagged)")
            dualChannelErrors[channel] = detail
            // Backward-compat surface (kept until per-channel UI lands):
            lastTranscriptionError = tagged
            transcriptionStatus = .error(tagged)
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
        // Diagnostic: use a fresh logger created post-bootstrap so it
        // actually reaches OSLog (the cached AppDelegate.controllerLogger
        // was created pre-bootstrap and routes to a no-op handler).
        struct ApplyCounter { static var n: Int = 0 }
        ApplyCounter.n += 1
        if ApplyCounter.n == 1 || ApplyCounter.n % 60 == 0 {
            let fresh = Logger(label: "macrec.ui.controller.levels")
            let sysPeak = sample.system?.peak ?? -1
            let micPeak = sample.mic?.peak ?? -1
            fresh.warning("LEVELMETER_RT applyLevels n=\(ApplyCounter.n) sysPeak=\(sysPeak) micPeak=\(micPeak)")
        }
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

    // MARK: - Plan-010 / L-5 — dual-mode helpers

    /// Apply a `DualChannelMetrics` snapshot taken from a downcast of
    /// the in-flight `DualTranscriptionManager` (via
    /// `currentDualMetrics()`). Public surface kept narrow: only the
    /// per-channel metrics view (L-11) and the SessionCoordinator-
    /// adjacent polling task (Phase I) call this. Documented contract:
    ///
    ///   * If `transcriptionMode == .dual`, the supplied snapshot is
    ///     stored verbatim. Subsequent UI reads of `dualMetrics` see
    ///     the new value.
    ///   * If `transcriptionMode == .single`, the call is treated as
    ///     defensive noise (the dispatcher is a `TranscriptionManager`,
    ///     not a `DualTranscriptionManager`, so there is no per-channel
    ///     split to publish). A debug log line is emitted; the slot
    ///     stays nil to keep the contract tight.
    public func applyDualMetrics(_ snapshot: DualChannelMetrics?) {
        guard transcriptionMode == .dual else {
            if snapshot != nil {
                logger.debug("applyDualMetrics ignored — controller is in single mode")
            }
            // Make sure the slot is empty in single mode; defensive
            // against a leftover dual-mode value from a prior session.
            dualMetrics = nil
            return
        }
        dualMetrics = snapshot
    }

    /// Load the persisted live-transcription mode from
    /// `UserDefaults.standard`. Bad / missing values collapse to
    /// `.single` (matches `LiveTranscriptionMode`'s documented default
    /// — first launch and unparseable raw values).
    ///
    /// Marked `nonisolated` (2026-05-02) — pure read against
    /// `UserDefaults.standard` (itself thread-safe) with no
    /// actor-isolated state touched. Lets the
    /// `installTranscriptionModeObserver()` `@Sendable` closure call
    /// it synchronously without the Swift 6 strict-concurrency
    /// implicit-async-call warning.
    private nonisolated static func loadTranscriptionMode() -> LiveTranscriptionMode {
        guard let raw = UserDefaults.standard.string(forKey: transcriptionModeStorageKey),
              let parsed = LiveTranscriptionMode(rawValue: raw)
        else {
            return .single
        }
        return parsed
    }

    /// Register a `UserDefaults.didChangeNotification` observer so the
    /// `transcriptionMode` published property tracks
    /// `@AppStorage("com.macrec.ui.transcriptionMode")` writes from
    /// the SwiftUI mode-switch view (L-7). Pattern mirrors
    /// `PopoverController.sizeObserver` (the existing in-process
    /// AppStorage-bridge idiom in this codebase) — `@AppStorage` only
    /// writes through a plain string key, which the notification
    /// observes uniformly.
    private func installTranscriptionModeObserver() {
        // Tear down any prior token defensively (init is normally
        // single-shot but callers may re-register in tests).
        if let token = transcriptionModeObserver {
            NotificationCenter.default.removeObserver(token)
            transcriptionModeObserver = nil
        }
        // `addObserver(forName:object:queue:)` invokes the block on
        // the supplied queue (`.main`). The closure is `@Sendable`;
        // we use `MainActor.assumeIsolated` to enter the controller's
        // actor isolation for the mutation site (matches the project's
        // existing main-thread bridge idiom in `PopoverController`).
        transcriptionModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            // The notification fires for every defaults write across
            // the whole process. Re-read our specific key and only
            // mutate the published slot when it materially changed —
            // avoids spurious Observation churn.
            let newValue = Self.loadTranscriptionMode()
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.transcriptionMode != newValue {
                    self.transcriptionMode = newValue
                    self.logger.debug("transcriptionMode updated from AppStorage: \(newValue.rawValue)")
                    // Mode flip implies the dual-metrics slot might be
                    // stale (e.g. user toggled back to single mid-
                    // session). Drop it; the next applyDualMetrics
                    // call (or session start) will repopulate.
                    if newValue == .single && self.dualMetrics != nil {
                        self.dualMetrics = nil
                    }
                }
            }
        }
    }
}
