// NtakkerUIKit/SessionCoordinator.swift — see project-design.md §15.5
// and plan-002-toolbar-ui.md §3 Phase D.
//
// Stop-and-stitch orchestrator for the toolbar UI. The coordinator
// owns the segment counter, the active `RecordingSession`, and the
// `currentRunTask`. It synthesizes `.pausing → .paused → .resuming`
// transitions between two sequential `RecordingSession` instances per
// the OQ-UI-2 lock (multi-file pause/resume).
//
// State machine (§15.5 verbatim):
//
//   idle
//     ↓ start()
//   recording(seg:1)
//     ↓ pause()                        ↓ stop()
//   paused(seg:1, lastFile)            stopped
//     ↓ resume()                       ↓
//   recording(seg:2)                   (terminal)
//     ↓ pause() …
//
// The coordinator is an `actor` so the segment counter, current
// session reference, and lifecycle bookkeeping are serialized without
// locks. Public methods are `async` and forward to the underlying
// `RecordingSession` while emitting `SessionCoordinatorEvent`s onto
// `events`.
//
// Threading boundary with `RecordingController`:
//
//   * `RecordingController` (`@MainActor`) calls coordinator methods
//     via `await coordinator.start()` / `pause()` / `resume()` /
//     `stop()` / `split()`. The `await` hops off the main thread,
//     onto the coordinator's executor, performs work, and returns.
//   * The coordinator's `events` `AsyncStream<SessionCoordinatorEvent>`
//     is consumed by the controller in a `Task { for await … }` loop
//     spawned from a `@MainActor` method — the loop body runs back on
//     the main actor, where observed-state writes are legal.
//
// Test injection: the active `RecordingSession` is built by a
// `RecordingSessionFactory` closure passed at init. Production wires
// the closure to `RecordingSession(options:logger:...)`. Tests pass a
// closure that returns a mock conforming to `RecordingSessionLike` so
// the coordinator's state machine can be driven without TCC prompts.

import Foundation
import Logging
import NtakkerCore

// MARK: - RecordingSessionLike protocol

/// The narrow contract the coordinator consumes from a recording
/// session. The production `NtakkerCore.RecordingSession` is wrapped
/// via the `LiveRecordingSessionAdapter` below so it conforms to this
/// protocol non-invasively. Tests pass a `MockRecordingSession` that
/// emits a programmable sequence of states.
public protocol RecordingSessionLike: AnyObject, Sendable {
    /// Observable lifecycle stream — same shape as
    /// `RecordingSession.stateStream`.
    var stateStream: AsyncStream<SessionState> { get }

    /// Observable transcript-events stream. Empty (immediately
    /// finishing) when transcription is disabled. The coordinator
    /// fans the stream out onto its `events` stream as
    /// `.transcriptEvent(...)` per the design §LT-8.5 mapping.
    /// (plan-003 Phase G).
    var transcriptEvents: AsyncStream<TranscriptionEvent> { get }

    /// Run to completion. Throws on failure. On success, the stream
    /// terminates with `.stopped`.
    func run() async throws

    /// Idempotent stop request. Resolves the session into the drain-
    /// and-finalize path.
    func requestStop()

    /// Rotate the encoder while the session continues. See
    /// `RecordingSession.split(nextOutput:)`.
    func split(nextOutput: URL) async throws

    /// Install a per-`CaptureBuffer` level-tap sink. The session
    /// forwards every captured frame from its mic + system sources
    /// to this closure (in addition to the recorder/aligner path).
    /// Set BEFORE `run()` is invoked. nil means "no level metering"
    /// (the CLI path has no UI to feed). Mock sessions may ignore
    /// this; the production session wires it into the capture
    /// sources' `levelTap` properties.
    func setLevelTapSink(_ sink: (@Sendable (CaptureBuffer) -> Void)?)
}

/// Closure factory that builds a `RecordingSessionLike` for the given
/// per-segment options. Production wires this to a closure that
/// constructs `RecordingSession`; tests pass a closure that returns a
/// pre-programmed mock.
public typealias RecordingSessionFactory =
    @Sendable (RecordingOptions) throws -> any RecordingSessionLike

// MARK: - Live adapter wrapping NtakkerCore.RecordingSession

/// Bridges the production `NtakkerCore.RecordingSession` to
/// `RecordingSessionLike`. The wrapper is `@unchecked Sendable`
/// because `RecordingSession` is itself `@unchecked Sendable` (its
/// internal mutable state is queue-confined).
public final class LiveRecordingSessionAdapter: RecordingSessionLike, @unchecked Sendable {
    private let session: RecordingSession

    public init(_ session: RecordingSession) {
        self.session = session
    }

    public var stateStream: AsyncStream<SessionState> {
        session.stateStream
    }

    public var transcriptEvents: AsyncStream<TranscriptionEvent> {
        session.transcriptEvents
    }

    public func run() async throws {
        try await session.run()
    }

    public func requestStop() {
        session.requestStop()
    }

    public func split(nextOutput: URL) async throws {
        try await session.split(nextOutput: nextOutput)
    }

    public func setLevelTapSink(_ sink: (@Sendable (CaptureBuffer) -> Void)?) {
        session.levelTapSink = sink
    }
}

/// Default factory used in production. Constructs a real
/// `RecordingSession` from the supplied options. The session's
/// `stateStream` is preserved.
public func makeLiveRecordingSessionFactory(
    logger: Logger
) -> RecordingSessionFactory {
    return { options in
        let session = RecordingSession(options: options, logger: logger)
        return LiveRecordingSessionAdapter(session)
    }
}

// MARK: - SessionCoordinator

/// Stop-and-stitch coordinator. Orchestrates multi-segment
/// pause/resume on top of a single-segment `RecordingSession`.
public actor SessionCoordinator {

    // MARK: - Internal state

    /// Internal coordinator state machine. Mirrors the rows of the
    /// project-design §15.5 transition table.
    public enum CoordinatorState: Sendable, Equatable {
        case idle
        case recording(segment: Int)
        case paused(segment: Int, lastFile: URL)
        case stopping
        case stopped
        case failed(NtakkerError)

        public static func == (lhs: CoordinatorState, rhs: CoordinatorState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.stopping, .stopping), (.stopped, .stopped):
                return true
            case let (.recording(a), .recording(b)):
                return a == b
            case let (.paused(a, ua), .paused(b, ub)):
                return a == b && ua == ub
            case let (.failed(a), .failed(b)):
                return a.description == b.description
            default:
                return false
            }
        }
    }

    /// Current state. Exposed for tests; the UI consumes
    /// `.events` instead.
    public private(set) var state: CoordinatorState = .idle

    /// 1-based segment counter. Incremented on each `start()` /
    /// `resume()` / `split()`.
    public private(set) var segmentCounter: Int = 0

    /// The session's first-segment output URL. Computed from the
    /// supplied `baseOptions.output` at construction. Used by
    /// `SegmentNamer` to derive `partNN`-suffixed URLs for segments
    /// 2..N.
    private let firstSegmentURL: URL

    /// Base options passed at init. The coordinator derives per-
    /// segment options via `withOutput(_:)` for each new segment.
    private let baseOptions: RecordingOptions

    /// Factory used to build each segment's session. Injected by tests.
    private let factory: RecordingSessionFactory

    /// The live session for the active segment. `nil` between
    /// `pause` and `resume`, and after `stop`.
    private var current: (any RecordingSessionLike)?

    /// The `Task` running `current!.run()`. Awaited on `pause` / `stop`.
    private var currentRunTask: Task<Void, Error>?

    /// The forwarder task consuming `current!.stateStream` and
    /// re-emitting onto `events`. Cancelled on segment teardown so the
    /// next segment's forwarder starts cleanly.
    private var stateForwardTask: Task<Void, Never>?

    /// Forwarder task consuming the active session's
    /// `transcriptEvents` and re-emitting onto `events` as
    /// `.transcriptEvent(...)`. One per segment; cancelled when the
    /// segment tears down. (plan-003 Phase G)
    private var transcriptForwardTask: Task<Void, Never>?

    private let logger: Logger

    // MARK: - Public events stream

    /// Coalesced event stream consumed by `RecordingController`. All
    /// state transitions, segment-completed events, and errors are
    /// delivered through this single stream so the controller has one
    /// `for await` loop per session.
    ///
    /// Unbounded (EVAL-2026-10-16 UI-4): transcript partials share this
    /// stream with state and error events, so a bounded "newest N"
    /// buffer could drop a `.stateChanged(.recording)` during a
    /// partial burst and leave the controller stuck in `.starting`.
    /// The controller drains the stream continuously and every event
    /// is small, so the buffer stays short in practice.
    public nonisolated let events: AsyncStream<SessionCoordinatorEvent>
    private nonisolated let eventsContinuation: AsyncStream<SessionCoordinatorEvent>.Continuation

    // MARK: - Init

    /// Construct a coordinator. `baseOptions.output` is treated as the
    /// first-segment URL. Per-segment URLs for segments 2..N are
    /// derived via `SegmentNamer.next(after: firstSegmentURL,
    /// segment: N)`.
    ///
    /// - Parameters:
    ///   - baseOptions: Base recording options for every segment.
    ///   - logger: Component-scoped logger
    ///     (label `ntakker-cli.ui.coordinator`).
    ///   - factory: Recording-session factory. Defaults to a closure
    ///     that builds a live `NtakkerCore.RecordingSession`. Tests
    ///     inject a mock.
    public init(
        baseOptions: RecordingOptions,
        logger: Logger,
        factory: RecordingSessionFactory? = nil
    ) {
        self.baseOptions = baseOptions
        self.firstSegmentURL = baseOptions.output
        self.logger = logger
        self.factory = factory ?? makeLiveRecordingSessionFactory(logger: logger)
        let pair = AsyncStream.makeStream(
            of: SessionCoordinatorEvent.self,
            bufferingPolicy: .unbounded
        )
        self.events = pair.stream
        self.eventsContinuation = pair.continuation
    }

    // MARK: - Lifecycle (public API)

    /// Start segment 1. Builds the session, spawns the run-task, and
    /// starts forwarding `stateStream` onto `events`.
    ///
    /// - Throws: any error from the recording-session factory.
    /// - Note: returns once the session has been built and the run-
    ///   task has been spawned. The session itself starts asynchronously
    ///   and emits `.starting` → `.recording` transitions.
    public func start() async throws {
        guard case .idle = state else {
            logger.warning("start() ignored — coordinator state is \(state)")
            return
        }
        segmentCounter = 1
        let url = SegmentNamer.next(after: firstSegmentURL, segment: 1)
        try buildAndRun(segmentNumber: 1, url: url)
    }

    /// Pause the current segment. Stops the active session, awaits
    /// the run-task to complete (so the file is finalized on disk),
    /// then parks in `.paused`.
    ///
    /// Emits: synth `.pausing` → synth `.paused`. The engine's own
    /// `.stopping` / `.stopped` are not forwarded (UI-3).
    ///
    /// FR-34 first-segment rename: when this is the first pause of a
    /// recording (i.e. transitioning from segment 1 → segment 2 on
    /// resume), the just-finalized segment-1 file is renamed in-place
    /// from `<basename>.<ext>` to `<basename>.part01.<ext>` so
    /// subsequent segments are siblings (`.part02`, `.part03`, …). The
    /// rename is performed AFTER `stopCurrentAndAwait()` returns so the
    /// file is fully closed on disk. Rename failures are logged and
    /// swallowed — the user already paused, the new file simply will
    /// not be a `partNN` sibling.
    public func pause() async throws {
        guard case let .recording(seg) = state else {
            logger.warning("pause() ignored — coordinator state is \(state)")
            return
        }
        emit(.stateChanged(.pausing))
        let bareLastFile = SegmentNamer.next(after: firstSegmentURL, segment: seg)
        // UI-3: the engine's `.stopping` / `.stopped` belong to the
        // segment change, not to the session — keep them off `events`
        // so the UI goes `.pausing` → `.paused` without a `.stopped`
        // in between (which tore the meters down and flashed Save).
        relayingPauseStop = true
        await stopCurrentAndAwait()
        relayingPauseStop = false
        // FR-34 first-segment rename: if this was segment 1, rename the
        // finalized file(s) so segment 2 is a `.part02` sibling.
        let lastFile: URL
        if seg == 1 {
            lastFile = renameFirstSegmentOnDisk(bareURL: bareLastFile)
        } else {
            lastFile = bareLastFile
        }
        // The session's stateStream has already emitted `.stopping`
        // and `.stopped`; `relay(state:)` held them back (UI-3).
        emit(.segmentCompleted(lastFile))
        emit(.stateChanged(.paused))
        state = .paused(segment: seg, lastFile: lastFile)
    }

    /// Resume from `.paused`. Increments the segment counter, builds
    /// the next-segment session, and spawns a fresh run-task.
    ///
    /// Emits: synth `.resuming` → forwarded `.starting` → forwarded
    /// `.recording`.
    public func resume() async throws {
        guard case let .paused(seg, _) = state else {
            logger.warning("resume() ignored — coordinator state is \(state)")
            return
        }
        let next = seg + 1
        segmentCounter = next
        emit(.stateChanged(.resuming))
        // Emit a segment-boundary marker for the transcript panel.
        // AC-LT-20: the panel renders this as a horizontal-rule
        // separator with the next part's index.
        emit(.transcriptSegmentBoundary(label: String(format: "part%02d", next)))
        let url = SegmentNamer.next(after: firstSegmentURL, segment: next)
        try buildAndRun(segmentNumber: next, url: url)
    }

    /// Manual split (FR-32). Rotates the encoder in-place; the session
    /// stays alive. Emits forwarded `.splitting` → `.recording`.
    ///
    /// FR-34 first-segment rename: same semantics as `pause()` — when
    /// this is the first split of a recording (segment 1 → segment 2),
    /// the just-finalized segment-1 file is renamed in-place to
    /// `<basename>.part01.<ext>`. The atomic-swap on
    /// `RecordingSession.split(nextOutput:)` finalizes the previous
    /// recorder before resolving, so the rename is safe to perform
    /// after the await.
    public func split() async throws {
        guard case let .recording(seg) = state else {
            logger.warning("split() ignored — coordinator state is \(state)")
            return
        }
        guard let current = current else {
            logger.error("split() called with no active session")
            return
        }
        let next = seg + 1
        let url = SegmentNamer.next(after: firstSegmentURL, segment: next)
        try await current.split(nextOutput: url)
        // Emit a segment-boundary marker for the transcript panel.
        // AC-LT-20: the panel renders this as a horizontal-rule
        // separator with the next part's index.
        emit(.transcriptSegmentBoundary(label: String(format: "part%02d", next)))
        // The session's stateStream emits `.splitting` → `.recording`
        // already; we just track the new segment number.
        let bareCompletedURL = SegmentNamer.next(after: firstSegmentURL, segment: seg)
        let completedURL: URL
        if seg == 1 {
            completedURL = renameFirstSegmentOnDisk(bareURL: bareCompletedURL)
        } else {
            completedURL = bareCompletedURL
        }
        emit(.segmentCompleted(completedURL))
        segmentCounter = next
        state = .recording(segment: next)
    }

    /// Stop the session entirely. From `.recording` it triggers the
    /// engine's stop path; from `.paused` it just transitions to
    /// `.stopped`.
    ///
    /// We explicitly emit `.stateChanged(.stopped)` after the engine's
    /// run-task completes instead of relying on the `stateForwardTask`
    /// to relay the engine's own `.stopped`. The forwarder is cancelled
    /// inside `stopCurrentAndAwait()` as soon as `currentRunTask`
    /// resolves, and since the engine yields `.stopping` / `.stopped`
    /// into a buffered AsyncStream, a buffered tail can still be sitting
    /// unread when the forwarder is cancelled — `Task.cancel()` on a
    /// task awaiting an AsyncStream iterator returns `nil` from
    /// `next()` and skips remaining buffered items. The result was the
    /// controller staying parked in `.stopping`, which the ControlBar
    /// matrix treats as a transient state with no buttons visible (UX
    /// bug: Start/Stop disappear after Stop). Synthesising the
    /// transition here mirrors what `pause()` already does and makes
    /// the UI independent of the forwarder race. `applyState(.stopped)`
    /// in the controller is idempotent, so a duplicate emission (if the
    /// forwarder happened to win the race anyway) is harmless.
    public func stop() async throws {
        switch state {
        case .recording(let seg):
            state = .stopping
            let lastFile = SegmentNamer.next(after: firstSegmentURL, segment: seg)
            await stopCurrentAndAwait()
            emit(.segmentCompleted(lastFile))
            emit(.stateChanged(.stopped))
            state = .stopped
        case .paused:
            state = .stopped
            emit(.stateChanged(.stopped))
        case .idle, .stopped, .stopping, .failed:
            logger.warning("stop() ignored — coordinator state is \(state)")
        }
    }

    /// Tear down everything. Cancels the forwarder tasks and finishes
    /// Install (or clear) the per-`CaptureBuffer` level-tap sink.
    /// Stored on the coordinator AND propagated to the in-flight
    /// session (if any). Subsequent sessions built by `buildAndRun`
    /// inherit the sink automatically. Called by `RecordingController`
    /// in `start()` to wire its `LevelMeterPublisher`.
    public func setLevelTapSink(_ sink: (@Sendable (CaptureBuffer) -> Void)?) {
        self.levelTapSink = sink
        current?.setLevelTapSink(sink)
    }

    /// Stored sink — applied to every newly-built session in
    /// `buildAndRun(...)`. Backs `setLevelTapSink(_:)`.
    private var levelTapSink: (@Sendable (CaptureBuffer) -> Void)?

    /// the events stream so consumers' `for await` loops exit. Called
    /// by `RecordingController.cancelAll()` on app shutdown.
    public func teardown() {
        stateForwardTask?.cancel()
        stateForwardTask = nil
        transcriptForwardTask?.cancel()
        transcriptForwardTask = nil
        currentRunTask?.cancel()
        currentRunTask = nil
        current = nil
        eventsContinuation.finish()
    }

    // MARK: - Private helpers

    /// Build a session for the given segment, spawn the run-task, and
    /// start forwarding its state stream. On factory failure, emits
    /// `.failed(error)` and re-throws so callers can surface the error.
    private func buildAndRun(segmentNumber: Int, url: URL) throws {
        let opts = baseOptions.withOutput(url)
        let session: any RecordingSessionLike
        do {
            session = try factory(opts)
        } catch {
            let mError: NtakkerError
            if let m = error as? NtakkerError {
                mError = m
            } else {
                mError = .unknown(error.localizedDescription)
            }
            state = .failed(mError)
            emit(.errorOccurred(mError))
            emit(.stateChanged(.failed(mError)))
            throw error
        }
        current = session
        // Inherit any level-tap sink installed on the coordinator
        // (typically by `RecordingController` immediately after
        // `start()`). The sink is per-coordinator-lifetime and
        // applies to every segment.
        if let sink = levelTapSink {
            session.setLevelTapSink(sink)
        }
        state = .recording(segment: segmentNumber)
        startStateForward(for: session)
        startTranscriptForward(for: session)
        currentRunTask = Task { [weak self] in
            do {
                try await session.run()
            } catch {
                await self?.handleSessionFailure(error)
            }
        }
    }

    /// Start a forwarder task that copies the session's
    /// `transcriptEvents` stream onto our events stream as
    /// `.transcriptEvent(...)`. Empty / immediately-finishing when
    /// transcription is disabled (the upstream simply yields nothing
    /// and finishes when the session's `run()` returns).
    ///
    /// Plan-004 Phase H: when the upstream event is a
    /// `.metricsTick(metrics:)`, the coordinator additionally emits a
    /// `.transcriptionMetrics(metrics)` event so metric-only
    /// subscribers (status bar, footer view) do not have to unpack the
    /// full `TranscriptionEvent` enum.
    private func startTranscriptForward(for session: any RecordingSessionLike) {
        let stream = session.transcriptEvents
        let coordLogger = self.logger
        transcriptForwardTask = Task { [weak self] in
            coordLogger.info("coordinator transcript forward: starting drain of session.transcriptEvents")
            var seen = 0
            for await event in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                seen += 1
                // H4 (EVAL 2026-06-12): .trace — this fires for every
                // transcript partial (several per second on streaming
                // providers); the String(describing:) render must not
                // run at the default log level.
                coordLogger.trace("coordinator transcript forward: emitting event #\(seen) \(String(describing: event).prefix(60))")
                self.emit(.transcriptEvent(event))
                if case let .metricsTick(metrics) = event {
                    self.emit(.transcriptionMetrics(metrics))
                }
            }
            coordLogger.info("coordinator transcript forward: session.transcriptEvents ended after \(seen) events")
        }
    }

    /// Start a forwarder task that copies the session's stateStream
    /// onto our events stream. Cancelled when the session ends.
    private func startStateForward(for session: any RecordingSessionLike) {
        let stream = session.stateStream
        stateForwardTask = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.relay(state: s)
            }
        }
    }

    /// UI-3: true while `pause()` stops the current segment's engine.
    private var relayingPauseStop = false

    /// Push a `SessionState` onto `events`. Called from the forwarder.
    private func relay(state: SessionState) {
        if relayingPauseStop {
            switch state {
            case .stopping, .stopped:
                return
            default:
                break
            }
        }
        emit(.stateChanged(state))
        if case let .failed(err) = state {
            self.state = .failed(err)
            emit(.errorOccurred(err))
        }
    }

    /// Handle a thrown error from `run()`. Updates state and emits.
    private func handleSessionFailure(_ error: Error) {
        let mError: NtakkerError
        if let m = error as? NtakkerError {
            mError = m
        } else {
            mError = .unknown(error.localizedDescription)
        }
        state = .failed(mError)
        emit(.errorOccurred(mError))
        emit(.stateChanged(.failed(mError)))
    }

    /// Stop the current session and await its run-task. Idempotent.
    private func stopCurrentAndAwait() async {
        guard let current = current else { return }
        current.requestStop()
        if let task = currentRunTask {
            _ = try? await task.value
        }
        // Tear the forwarder(s) down — their source streams have finished.
        stateForwardTask?.cancel()
        stateForwardTask = nil
        transcriptForwardTask?.cancel()
        transcriptForwardTask = nil
        currentRunTask = nil
        self.current = nil
    }

    /// Yield onto the events stream. `nonisolated` so it can be called
    /// from the forwarder task that is not in the coordinator's
    /// isolation domain (it hops on every relay).
    private nonisolated func emit(_ event: SessionCoordinatorEvent) {
        eventsContinuation.yield(event)
    }

    /// FR-34 first-segment rename. Called when the coordinator is
    /// transitioning from segment 1 to segment 2 (first `pause()` or
    /// first `split()`). Renames the bare-named segment-1 file(s) on
    /// disk to their `.part01.` siblings so that segments 1 and 2 sort
    /// adjacently as `<basename>.part01.<ext>` and
    /// `<basename>.part02.<ext>`.
    ///
    /// For `--layout split` (`baseOptions.layout == .split`), the
    /// engine writes TWO sibling files per segment (`.system` and
    /// `.mic`). Both are renamed.
    ///
    /// Errors are logged at `.warning` and swallowed — the user already
    /// paused; failing the pause path because of a rename hiccup would
    /// be more disruptive than the cosmetic naming inconsistency. The
    /// returned URL points at the renamed location when the rename
    /// succeeded, otherwise at the original `bareURL` so downstream
    /// `segmentCompleted` events still describe a real file on disk.
    ///
    /// - Parameter bareURL: The URL the engine wrote (e.g.
    ///   `recording-2026-04-26-18-30.m4a`). For split-layout
    ///   recordings, this is the `RecordingOptions.output` value (which
    ///   is the same as `firstSegmentURL`); the per-side filenames are
    ///   derived from it via `SegmentNamer.splitSidecarURLs(baseURL:)`.
    /// - Returns: The URL of the renamed segment-1 file (the mixed/
    ///   stereo-split single-file case) or, for split layout, the
    ///   renamed `.system` URL (the engine produces two files; we
    ///   surface the system side as the canonical "segment 1" URL,
    ///   matching what the rest of the coordinator already does).
    private func renameFirstSegmentOnDisk(bareURL: URL) -> URL {
        let fm = FileManager.default
        renameFirstSegmentTranscriptSidecars(fm: fm)
        switch baseOptions.layout {
        case .split:
            // Engine wrote two sibling files. Rename both. The bareURL
            // we were handed by the caller is the engine's
            // `options.output` (i.e. `firstSegmentURL`); the per-side
            // URLs are derived deterministically.
            let pair = SegmentNamer.splitSidecarURLs(baseURL: firstSegmentURL)
            let renamedSystem = SegmentNamer.renameForFirstSegment(pair.system)
            let renamedMic = SegmentNamer.renameForFirstSegment(pair.mic)
            renameFile(at: pair.system, to: renamedSystem, fm: fm, label: "system")
            renameFile(at: pair.mic, to: renamedMic, fm: fm, label: "mic")
            // Surface the system URL as the canonical completion URL.
            // Callers that care about the mic file can derive it via
            // `SegmentNamer.splitSidecarURLs(baseURL:)`.
            return fm.fileExists(atPath: renamedSystem.path) ? renamedSystem : pair.system

        case .mixed, .stereoSplit:
            // Single-file output. Rename in place.
            let renamed = SegmentNamer.renameForFirstSegment(bareURL)
            renameFile(at: bareURL, to: renamed, fm: fm, label: "single")
            return fm.fileExists(atPath: renamed.path) ? renamed : bareURL
        }
    }

    /// EVAL-2026-10-16 UI-1: segment 1's transcript sidecars are named
    /// after the bare output URL (`<stem>.transcript.<fmt>`, plus the
    /// `.system` / `.microphone` per-source variants). Rename every one
    /// that exists to its `.part01` sibling — the naming segment 2+ uses
    /// (`<stem>.part02.transcript.jsonl`) — so Save finds every part's
    /// transcript next to its audio.
    private func renameFirstSegmentTranscriptSidecars(fm: FileManager) {
        let sourceTags: [SourceTag?] = [nil, .system, .microphone]
        for format in TranscriptFormat.allCases {
            for tag in sourceTags {
                let src = SidecarPathBuilder.sidecarURL(
                    forRecording: firstSegmentURL, format: format, sourceTag: tag)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = SidecarPathBuilder.sidecarURL(
                    forRecording: firstSegmentURL, format: format, partNumber: 1, sourceTag: tag)
                renameFile(at: src, to: dst, fm: fm, label: "transcript")
            }
        }
    }

    /// Move `src` to `dst`. Logs a warning on failure rather than
    /// throwing — the caller (`renameFirstSegmentOnDisk`) is on the
    /// pause/split path and prefers cosmetic-naming graceful
    /// degradation over a thrown error.
    private func renameFile(at src: URL, to dst: URL, fm: FileManager, label: String) {
        guard fm.fileExists(atPath: src.path) else {
            logger.warning(
                "FR-34 rename: source missing for \(label) — \(src.path) (file may have been moved by user)"
            )
            return
        }
        if fm.fileExists(atPath: dst.path) {
            logger.warning(
                "FR-34 rename: destination exists for \(label) — \(dst.path) (skipping rename)"
            )
            return
        }
        do {
            try fm.moveItem(at: src, to: dst)
            logger.debug("FR-34 rename: \(label) \(src.lastPathComponent) → \(dst.lastPathComponent)")
        } catch {
            logger.warning(
                "FR-34 rename failed for \(label) (\(src.lastPathComponent) → \(dst.lastPathComponent)): \(error.localizedDescription)"
            )
        }
    }
}
