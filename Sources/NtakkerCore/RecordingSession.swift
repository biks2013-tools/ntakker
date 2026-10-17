// NtakkerCore/RecordingSession.swift — see project-design.md §2.18 / §2.11
// and §14 (detach mode), and plan-001 §J (FR-1, FR-6, FR-25, FR-27, FR-28).
//
// Phase J (plan-001 Wave 4) — orchestrator that wires the entire
// capture pipeline:
//
//     Sources (system + mic) → HostClockAligner → Recorder
//
// `RecordingSession.run()` is the single entrypoint the CLI shell
// (`StartCommand`, owned by Phase K) invokes after it has built a
// `RecordingOptions`. The session:
//
//   1. Bootstraps `~/.tool-agents/ntakker-cli/` (FR-13).
//   2. Gates on Screen Recording + Microphone permission (FR-10).
//   3. In detach mode, refuses to start if a live PID file already
//      claims the slot (FR-28); otherwise removes a stale PID file
//      and continues.
//   4. Builds sources, the aligner, and a recorder; wires their
//      callbacks; starts everything in the order writer-first,
//      sources-after.
//   5. In detach mode, writes the PID file IMMEDIATELY after
//      `recorder.start()` returns (FR-25 / FR-27, design §14.1
//      step [6]).
//   6. Installs SIGINT/SIGTERM signal sources and an optional
//      max-duration timer.
//   7. Suspends until any of {signal, max-duration, programmatic
//      `requestStop()`, terminal recorder error} resolves the
//      run-loop.
//   8. Drains the pipeline and finalizes the writer.
//   9. On every clean exit path (success, signal, timer, error), the
//      PID file is removed (detach mode only). On crash, the file
//      is left behind as a stale marker for the next `stop` to
//      reclaim.
//
// Concurrency:
//
//   * `run()` runs on the caller's task (`StartCommand.run`); its
//     `await` points are the permission gate, the recorder/source
//     `start()` calls, the suspension point itself, and the stop /
//     finalize sequence.
//   * `serialQueue` ("ntakker-cli.session") owns the mutable state
//     transitions: the running flag, the stop-resolution path, the
//     error capture, and the signal/timer scheduling.
//   * Signal handlers and the max-duration timer post resolution onto
//     `serialQueue` and resolve the suspended continuation exactly
//     once.
//
// PID-file lifecycle (FR-25/FR-27/FR-28, design §14):
//
//   * Detach mode write: AFTER `recorder.start()` returns, BEFORE
//     either source's `start()` is called. The contract is "PID file
//     in place by the time the first capture buffer flows". Writing
//     before any source has started guarantees this — buffers cannot
//     arrive until the sources have been started, which happens after
//     the PID file write below.
//   * Detach mode remove: in the FINAL cleanup at the end of `run()`,
//     regardless of outcome (success, throw, signal, timer). The
//     cleanup is idempotent.
//   * Foreground mode: NEVER writes or removes the PID file.

import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import Logging
// `OSAllocatedUnfairLock` lives in the `os` umbrella module, but
// `import os` (and `import os.lock`) also pulls in `os.Logger`, which
// shadows `Logging.Logger`. Importing only the symbol we need keeps
// the `Logger` name unambiguously bound to swift-log.
import struct os.OSAllocatedUnfairLock

// MARK: - StopReason (kept for design compatibility / future Phase K usage)

/// Reason the session terminated. Reported via the session's
/// internal logger. The orchestrator's public API surfaces success
/// vs. thrown error; the *reason* is informational.
public enum StopReason: Sendable, Equatable {
    case signal(Int32)
    case maxDuration
    case programmatic
    case error
}

// MARK: - Transcription factory typealias (plan-003 Phase G)

/// Test seam for injecting a fake `TranscriptionProvider` into a
/// `RecordingSession`. Production passes `nil` (the session falls back
/// to `TranscriptionProviderFactory.make(...)`); tests pass a closure
/// that returns a `FakeTranscriptionProvider` so the integration tests
/// can run without network access.
///
/// The closure receives the resolved `RecordingOptions` so a test can
/// inspect the chosen provider id / source / format and decide what
/// fake to return. The closure throws if the options are malformed —
/// the throw propagates out of `RecordingSession.run()` as a
/// `NtakkerError`.
public typealias TranscriptionProviderFactoryClosure =
    @Sendable (RecordingOptions) throws -> any TranscriptionProvider

// MARK: - RecordingSession

/// Orchestrates a single recording session end-to-end. Construct,
/// call `run()`, await its completion. Calling `requestStop()` from
/// anywhere triggers the same drain-and-finalize path as a SIGTERM
/// would.
///
/// `@unchecked Sendable` because all mutable state is confined to
/// `serialQueue`. Closures captured in source / aligner / recorder
/// callbacks weakly reference `self` to avoid retain cycles.
public final class RecordingSession: @unchecked Sendable {

    // MARK: - Public stats snapshot

    /// Aggregate observability snapshot. Surfaces the aligner's
    /// counters for Phase 10 / verifier consumption.
    public struct Stats: Sendable {
        public let framesEmitted: Int
        public let systemGapFills: Int
        public let micGapFills: Int
        public let lastDriftSec: Double

        public init(
            framesEmitted: Int,
            systemGapFills: Int,
            micGapFills: Int,
            lastDriftSec: Double
        ) {
            self.framesEmitted = framesEmitted
            self.systemGapFills = systemGapFills
            self.micGapFills = micGapFills
            self.lastDriftSec = lastDriftSec
        }
    }

    // MARK: - Stored configuration

    private let options: RecordingOptions
    private let logger: Logger
    private let pidLogger: Logger

    // MARK: - Transcription wiring (plan-004 Phase G)

    /// Optional injected provider factory. When `nil`, the session
    /// falls through to `TranscriptionProviderFactory.build(...)`.
    /// Tests inject a closure returning `FakeTranscriptionProvider`.
    private let transcriptionProviderFactory: TranscriptionProviderFactoryClosure?

    /// Active transcription dispatcher for this session. Created in
    /// `run()` when transcription is enabled (`options.transcriptionProviderId
    /// != "none"`); stopped in the finalize path. `nil` when
    /// transcription is disabled — the recording path is byte-identical
    /// in that case (NFR-17 / AC-LT-2).
    ///
    /// Every subsequent operation (`ingestFrame`, `rotateSidecar`,
    /// `stop`, `currentMetrics`) goes through the
    /// `TranscriptionDispatcher` protocol; the session itself is
    /// mode-agnostic. The dispatcher owns its own per-session sidecar
    /// writer (plan-004 Phase E rewrite).
    private var _transcriptionDispatcher: (any TranscriptionDispatcher)?

    /// Token for the live tap installed on the aligner. Removed on
    /// teardown so a misbehaving manager can never starve the recorder
    /// post-finalize.
    private var _transcriptionTapToken: HostClockAligner.TapToken?

    /// Ordered, bounded per-source lanes between the live tap and the
    /// dispatcher (TR-14 / F1). Drained on teardown before the
    /// dispatcher stops.
    private var _transcriptionFeeder: TranscriptionFrameFeeder?

    /// Forwarder Task that drains the manager's events stream into the
    /// public `transcriptEvents` stream consumed by the UI. Sidecar
    /// writes are owned inside the manager itself (plan-004 Phase E).
    /// Awaited in the finalize path.
    private var _transcriptionForwarderTask: Task<Void, Never>?

    /// Public events stream — populated when transcription is active,
    /// otherwise simply finishes the moment `run()` exits without ever
    /// having yielded an event. UI consumers iterate via
    /// `for await event in session.transcriptEvents { ... }`.
    public nonisolated let transcriptEvents: AsyncStream<TranscriptionEvent>
    private nonisolated let _transcriptEventsContinuation: AsyncStream<TranscriptionEvent>.Continuation

    /// Serial queue protecting all mutable orchestrator state.
    private let serialQueue = DispatchQueue(
        label: "ntakker-cli.session.serial",
        qos: .userInitiated
    )

    /// Optional dependency-injection slots. Production usage uses
    /// the live capture sources; tests pass `FakeAudioSource`s here.
    private let injectedSystemSource: (any SystemAudioSource)?
    private let injectedMicSource: (any MicrophoneSource)?

    // MARK: - Mutable state (queue-confined)

    /// True between `start()` of the recorder and the end of the
    /// finalize sequence. Read by `isRunning`.
    private var _running: Bool = false

    /// Latch used to make `requestStop()` idempotent and to short-
    /// circuit duplicate signal/timer fires.
    private var _stopRequested: Bool = false

    /// The continuation returned from the suspension model — resolved
    /// exactly once, by whichever resolver fires first (signal,
    /// max-duration timer, programmatic `requestStop`, terminal
    /// recorder error). Set under `serialQueue`.
    private var _runContinuation: CheckedContinuation<StopReason, Never>?

    /// Captured terminal recorder error (latest wins). Surfaced from
    /// `run()` AFTER finalize / PID cleanup so we always release
    /// resources before throwing.
    private var _recorderError: Error?

    // Lifecycle objects retained for the run-loop's duration. Held on
    // `serialQueue` for cancellation safety.
    private var _signalSources: [DispatchSourceSignal] = []
    private var _maxDurationTimer: DispatchSourceTimer?
    private var _terminalErrorPollTimer: DispatchSourceTimer?
    private var _aligner: HostClockAligner?

    /// Current encoder. Wrapped in an `OSAllocatedUnfairLock` so the
    /// `aligner.onAlignedFrame` callback (which fires on the aligner's
    /// own serial queue) can read it atomically while
    /// `split(nextOutput:)` rotates it on `serialQueue`. Investigation
    /// Topic 4 / project-design §15.3.2 / AMB-2.
    private let _recorderLock = OSAllocatedUnfairLock<Recorder?>(initialState: nil)

    private var _systemSource: (any SystemAudioSource)?
    private var _micSource: (any MicrophoneSource)?
    /// plan-013 (revised) — software AEC processor. Constructed in
    /// `run()` only when `options.micAEC == true`; nil otherwise. Held
    /// for the lifetime of the session so its NLMS-filter state
    /// converges across the whole recording instead of restarting per
    /// buffer. Released when `run()` exits.
    private var _aecProcessor: SoftwareAECProcessor?

    /// Optional side-channel for per-source level metering.
    /// `RecordingController` sets this to forward each captured
    /// `CaptureBuffer` to a `LevelMeterPublisher`. Wired into
    /// `systemSource.levelTap` and `micSource.levelTap` in Step 7's
    /// callback wiring (capture → tap call sites). nil means "no level
    /// metering" (the CLI path has no UI to feed).
    ///
    /// `didSet` re-installs the closures on the LIVE sources if they
    /// already exist — this handles the race where `setLevelTapSink`
    /// arrives AFTER `run()` has already wired the source callbacks.
    /// Without this, a late sink would only take effect on the NEXT
    /// session and the meters would stay dark for the current one.
    public var levelTapSink: (@Sendable (CaptureBuffer) -> Void)? {
        didSet {
            if let sink = levelTapSink {
                _systemSource?.levelTap = { cb in sink(cb) }
                _micSource?.levelTap = { cb in sink(cb) }
            } else {
                _systemSource?.levelTap = nil
                _micSource?.levelTap = nil
            }
        }
    }

    // MARK: - State stream (FR-33, project-design §15.3.1)

    /// Continuation paired with `stateStream`. Buffer policy
    /// `.bufferingNewest(8)` so a slow consumer keeps only the most
    /// recent transitions. Finished from `run()`'s exit so consumer
    /// `Task`s do not leak (R-28).
    private let _stateContinuation: AsyncStream<SessionState>.Continuation

    /// Observable stream of `SessionState` transitions. Live for the
    /// lifetime of the `RecordingSession`. Finished when `run()`
    /// returns (success, throw, or signal-driven stop). UI consumers
    /// should `for await s in session.stateStream { ... }` from a
    /// `@MainActor`-isolated `Task`.
    public let stateStream: AsyncStream<SessionState>

    // MARK: - Permission gate (project-design §15.3.4 / ISSUE-02)

    /// Pluggable permission gate. Tests inject a stub conformer to
    /// bypass the TCC check; production runs use `LivePermissionGate`.
    private let permissionGate: any PermissionGating

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - options: Resolved `RecordingOptions`.
    ///   - logger: Optional pre-built session logger. Defaults to
    ///     `LoggerFactory.make("ntakker-cli.session")`.
    ///   - systemSource: Optional injected system-audio source. When
    ///     `nil`, a `SCKitSystemAudioSource` is built in `run()`.
    ///     Tests pass a `FakeAudioSource` here.
    ///   - micSource: Optional injected microphone source. When
    ///     `nil`, an `AVMicrophoneSource` is built in `run()`.
    ///     Tests pass a `FakeAudioSource` here.
    ///   - permissionGate: Optional `PermissionGating` conformer. When
    ///     `nil`, a live `PermissionGate` is constructed (preserving
    ///     pre-Phase-A CLI behavior). Tests inject a stub conformer
    ///     that always returns `.bothAuthorized` to bypass the TCC
    ///     check. Resolves ISSUE-02.
    public init(
        options: RecordingOptions,
        logger: Logger? = nil,
        systemSource: (any SystemAudioSource)? = nil,
        micSource: (any MicrophoneSource)? = nil,
        permissionGate: (any PermissionGating)? = nil,
        transcriptionProviderFactory: TranscriptionProviderFactoryClosure? = nil
    ) {
        let resolvedLogger = logger ?? LoggerFactory.make("ntakker-cli.session")
        self.options = options
        self.logger = resolvedLogger
        self.pidLogger = LoggerFactory.make("ntakker-cli.pidfile")
        self.injectedSystemSource = systemSource
        self.injectedMicSource = micSource
        self.transcriptionProviderFactory = transcriptionProviderFactory
        // Resolve the permission gate. Default-`nil` preserves
        // pre-Phase-A behavior: the live `PermissionGate` is built and
        // used exactly as before. Test injection paths supply a stub.
        self.permissionGate = permissionGate ?? PermissionGate(logger: resolvedLogger)
        // Wire the state stream. `.bufferingNewest(8)` is the policy
        // locked by project-design §15.3.1; a slow consumer keeps only
        // the most recent eight transitions.
        let pair = AsyncStream.makeStream(
            of: SessionState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        self.stateStream = pair.stream
        self._stateContinuation = pair.continuation
        // Wire the transcription events stream. Bounded at 64 events so
        // a slow UI consumer drops oldest events without backing up the
        // driver (design §LT-6.4 row 4). The stream is created
        // unconditionally; if transcription is disabled it simply
        // finishes when `run()` returns without ever yielding.
        let trPair = AsyncStream.makeStream(
            of: TranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.transcriptEvents = trPair.stream
        self._transcriptEventsContinuation = trPair.continuation
    }

    // MARK: - Public API

    /// Whether the session is currently in the running window
    /// (recorder open, sources started, stop not yet completed).
    public var isRunning: Bool {
        var snapshot = false
        serialQueue.sync { snapshot = _running }
        return snapshot
    }

    /// Aggregate observability snapshot. Reads the aligner's stats
    /// under the aligner's own lock.
    public var stats: Stats {
        var alignerStats: HostClockAligner.Stats?
        serialQueue.sync { alignerStats = _aligner?.stats }
        if let s = alignerStats {
            return Stats(
                framesEmitted: s.framesEmitted,
                systemGapFills: s.systemGapFills,
                micGapFills: s.micGapFills,
                lastDriftSec: s.lastDriftSec
            )
        }
        return Stats(framesEmitted: 0, systemGapFills: 0, micGapFills: 0, lastDriftSec: 0)
    }

    /// Programmatic stop request. Idempotent — repeated calls are
    /// no-ops. Resolves the suspended `run()` with `.programmatic` if
    /// no other resolver has fired yet. Safe to call from any
    /// thread.
    public func requestStop() {
        serialQueue.async { [weak self] in
            self?.resolveRunLoop(reason: .programmatic, errorToCapture: nil)
        }
    }

    /// Run a recording session to completion. See file-level docs
    /// for the algorithm.
    ///
    /// - Throws: `NtakkerError` for any failure that prevents the
    ///   session from starting (permissions, already-recording,
    ///   recorder open) or any terminal recorder error captured
    ///   during the run.
    public func run() async throws {
        // Emit `.starting` immediately. Project-design §15.3.1 maps this
        // emission to "top of run()". A subscriber that misses this
        // transition (because it subscribed late) still observes the
        // subsequent `.recording` thanks to the `.bufferingNewest(8)`
        // policy.
        emitState(.starting)

        // ---- Step 1: bootstrap ~/.tool-agents/ntakker-cli/. (FR-13) ----
        do {
            _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli")
        } catch {
            logger.error("bootstrap failed: \(error.localizedDescription)")
            failAndFinishStream(with: error)
            throw error
        }

        // ---- Step 2: permission gate. (FR-10) ----
        // Uses the injected `permissionGate` (resolved in init).
        // Default `LivePermissionGate` matches pre-Phase-A behavior;
        // tests inject a stub conformer.
        do {
            try await permissionGate.requireBothOrThrow()
        } catch {
            failAndFinishStream(with: error)
            throw error
        }

        // ---- Step 3: detach guard. (FR-28) ----
        // In foreground mode this is a no-op. In detach mode we
        // refuse to start over a live PID file and clean up a stale
        // one.
        if options.runMode == .detached {
            try checkExistingPidFile()
        }

        // ---- Step 4: build sources (real or injected). ----
        let systemSource: any SystemAudioSource = injectedSystemSource ?? SCKitSystemAudioSource(
            sampleRate: options.sampleRate,
            channelCount: 2,
            logger: LoggerFactory.make("ntakker-cli.capture.system")
        )
        // plan-013 (revised) — `AVMicrophoneSource` is the only mic
        // source. The previous plan-013 attempt used `AVAudioEngine`
        // + `setVoiceProcessingEnabled(true)` to get Apple's AEC, but
        // that path's underlying `AUVoiceProcessingIO` audio unit
        // could not coexist with our `SCStream` system-audio capture
        // (HAL conflict: VP IO needs unobstructed access to the system
        // OUTPUT device for its AEC reference; SCStream taps the same
        // mix). Symptom: VP delivered exactly one warm-up buffer and
        // then halted permanently. The current AEC path is a custom
        // software adaptive filter (`SoftwareAECProcessor`) wired
        // downstream of this source — see `SoftwareAECProcessor.swift`
        // and the wiring further down in `run()` — so the mic source
        // itself stays the proven `AVCaptureSession` path.
        let micSource: any MicrophoneSource = injectedMicSource ?? AVMicrophoneSource(
            deviceQuery: options.micDevice,
            targetSampleRate: options.sampleRate,
            targetChannelCount: 2,
            logger: LoggerFactory.make("ntakker-cli.capture.mic")
        )
        if injectedMicSource == nil {
            logger.info("mic source = AVMicrophoneSource (AEC processor=\(options.micAEC ? "on" : "off"))")
        }

        // ---- Step 5: aligner. ----
        let aligner = HostClockAligner(
            targetSampleRate: Double(options.sampleRate),
            targetChannelCount: 2,
            logger: LoggerFactory.make("ntakker-cli.aligner")
        )

        // ---- Step 6: recorder. (factory pre-flight validates path) ----
        let recorder: Recorder
        do {
            recorder = try makeRecorder(
                options: options,
                logger: LoggerFactory.make("ntakker-cli.recorder.\(options.format.rawValue)")
            )
        } catch {
            logger.error("recorder construction failed: \(error.localizedDescription)")
            throw error
        }

        // ---- Step 6b: AEC processor (plan-013 revised). ----
        //
        // When `options.micAEC == true`, build a `SoftwareAECProcessor`
        // that sits between the mic source and the aligner. Its NLMS
        // adaptive filter takes the system-audio buffers as the
        // reference and subtracts the estimated echo from the mic
        // signal. The processor's `onCleanedMic` becomes the new
        // entry point into `aligner.ingest` for the mic side; the
        // system source is teed (still feeds the aligner directly,
        // and additionally feeds the processor's reference).
        let aecProcessor: SoftwareAECProcessor? = options.micAEC ? SoftwareAECProcessor(
            config: SoftwareAECProcessor.Configuration(
                channels: 2,
                sampleRate: Double(options.sampleRate)
            ),
            logger: LoggerFactory.make("ntakker-cli.aec")
        ) : nil

        // Stash so `requestStop` / signal handlers can reach them.
        // The recorder lives behind `_recorderLock` (project-design
        // §15.3.2 / AMB-2) so the aligner-frame callback can read it
        // atomically while `split(nextOutput:)` rotates the reference.
        serialQueue.sync {
            self._aligner = aligner
            self._systemSource = systemSource
            self._micSource = micSource
            self._aecProcessor = aecProcessor
        }
        _recorderLock.withLock { current in
            current = recorder
        }

        // ---- Step 7: wire callbacks. ----
        // Source → aligner (and AEC reference, when enabled).
        if let aec = aecProcessor {
            // AEC's cleaned-mic output feeds the aligner.
            aec.onCleanedMic = { [weak aligner] cb in
                aligner?.ingest(cb)
            }
            // System buffers fan out to BOTH the aligner (recorded as
            // the system track) and the AEC reference. The two paths
            // are independent — the aligner stores the system buffer
            // verbatim while the processor copies the samples into
            // its reference ring.
            systemSource.onSampleBuffer = { [weak aligner, weak aec] cb in
                aligner?.ingest(cb)
                aec?.feedReference(cb)
            }
            // Mic buffers go through the AEC processor instead of
            // directly to the aligner. The processor calls
            // `onCleanedMic` synchronously on the mic capture queue,
            // so end-to-end latency is unchanged.
            micSource.onSampleBuffer = { [weak aec] cb in
                aec?.processMic(cb)
            }
        } else {
            systemSource.onSampleBuffer = { [weak aligner] cb in
                aligner?.ingest(cb)
            }
            micSource.onSampleBuffer = { [weak aligner] cb in
                aligner?.ingest(cb)
            }
        }
        // Source → level meter (optional). The sink is set by
        // `RecordingController` before `run()` is invoked; CLI
        // sessions leave it nil and the closures below short-circuit
        // to no-op. Strong capture of `self.levelTapSink` is safe —
        // sources outlive their callbacks within a single session.
        if let sink = self.levelTapSink {
            systemSource.levelTap = { cb in sink(cb) }
            micSource.levelTap = { cb in sink(cb) }
        }
        // Aligner → recorder. Failures inside `append` are non-fatal
        // per-frame; we capture the most recent error and let the
        // finalize path surface it.
        //
        // Project-design §15.3.2 / §15.3.3: the recorder reference is
        // read through `_recorderLock` on every aligned-frame callback
        // so that `split(nextOutput:)` can swap encoders atomically.
        // The callback DOES NOT capture `recorder` directly — capturing
        // it would pin the post-split callback to the old encoder.
        aligner.onAlignedFrame = { [weak self] frame in
            guard let self else { return }
            let active: Recorder? = self._recorderLock.withLock { $0 }
            guard let active else { return }
            do {
                try active.append(frame)
            } catch {
                self.logger.error(
                    "recorder.append failed: \(error.localizedDescription)"
                )
                self.captureRecorderError(error)
            }
        }

        // ---- Step 7.5: transcription pipeline (plan-003 Phase G). ----
        // Constructed BEFORE `recorder.start()` so any pre-flight
        // failure (missing API key, unknown provider, non-writable
        // sidecar path) surfaces before the recorder ever opens.
        // When transcription is disabled the entire block is a no-op
        // (NFR-17 / AC-LT-2: byte-identical recording path).
        do {
            try await setUpTranscriptionPipelineIfNeeded(aligner: aligner)
        } catch {
            logger.error("transcription pipeline setup failed: \(error.localizedDescription)")
            failAndFinishStream(with: error)
            throw error
        }

        // ---- Step 8/9: start recorder, write PID, start sources. ----
        // (Recorder must be open before any buffer arrives.)
        do {
            try await recorder.start()
        } catch {
            logger.error("recorder.start failed: \(error.localizedDescription)")
            // No PID file written yet, no sources started — nothing
            // to clean up. Tear down the transcription pipeline if it
            // was set up.
            await tearDownTranscriptionPipelineIfNeeded(aligner: aligner)
            failAndFinishStream(with: error)
            throw error
        }

        // Detach-mode PID write: design §14.1 step [6] says
        // "IMMEDIATELY after recorder.start, before first capture
        // buffer flows". We write here, before either source has
        // started — buffers cannot arrive until both `start()`s
        // return.
        if options.runMode == .detached {
            do {
                try PidFile.write(at: options.pidFile)
                pidLogger.info("PID file written at \(options.pidFile.path)")
            } catch {
                logger.error("PID file write failed: \(error.localizedDescription)")
                // We have an open recorder but no PID file. We MUST
                // tear the recorder down before throwing so the
                // file does not stay locked indefinitely. Best-
                // effort finalize with a generous timeout; ignore
                // any further error in favor of the original.
                _ = try? await recorder.finalize(timeout: 5)
                await tearDownTranscriptionPipelineIfNeeded(aligner: aligner)
                failAndFinishStream(with: error)
                throw error
            }
        }

        // Mark as running NOW. Stop requests received before this
        // point are no-ops (the `_runContinuation` is nil). The
        // signal sources installed below would race anyway.
        serialQueue.sync { self._running = true }

        // Start mic first, then system. (No deep reason — both are
        // idempotent. The aligner will gap-fill whichever side is
        // not yet producing frames.)
        do {
            try await micSource.start()
        } catch {
            logger.error("microphone source failed to start: \(error.localizedDescription)")
            await cleanupAfterStartFailure(recorder: recorder, system: nil, mic: nil)
            await tearDownTranscriptionPipelineIfNeeded(aligner: aligner)
            failAndFinishStream(with: error)
            throw error
        }

        do {
            try await systemSource.start()
        } catch {
            logger.error("system audio source failed to start: \(error.localizedDescription)")
            await cleanupAfterStartFailure(recorder: recorder, system: nil, mic: micSource)
            await tearDownTranscriptionPipelineIfNeeded(aligner: aligner)
            failAndFinishStream(with: error)
            throw error
        }

        // FR-33 / project-design §15.3.1: emit `.recording` AFTER both
        // sources have started — the pipeline is now actively producing
        // frames into the recorder. Subscribers observe the transition
        // `.starting` → `.recording`.
        emitState(.recording)

        // ---- Step 10: install signal handlers + max-duration timer. ----
        installSignalSources()
        if let cap = options.maxDuration {
            installMaxDurationTimer(seconds: cap)
        }
        // Poll the sources' `terminalError` getters (Phase I exposes
        // `terminalError: Error?` on both real impls; the fake does
        // not, hence the `Any` reflection lookup so injected fakes
        // can be used without a `terminalError` shim).
        installTerminalErrorPoll(system: systemSource, mic: micSource)

        // ---- Step 11: suspend until a resolver fires. ----
        let stopReason: StopReason = await withCheckedContinuation { (cont: CheckedContinuation<StopReason, Never>) in
            serialQueue.async { [weak self] in
                guard let self = self else {
                    cont.resume(returning: .programmatic)
                    return
                }
                // If a resolver beat us here (e.g. SIGTERM arrived
                // between sources starting and us suspending), there
                // is no stored continuation — but `_stopRequested`
                // is already true. Honor it without suspending.
                if self._stopRequested {
                    cont.resume(returning: .programmatic)
                    return
                }
                self._runContinuation = cont
            }
        }

        logger.info("stop requested (reason: \(stopReason))")

        // ---- Step 12: stop sequence (drain + finalize). ----
        // Cancel timers and signal sources first so they cannot
        // fire again during the drain.
        teardownTimersAndSignals()

        // Stop sources (system first, then mic — opposite of start).
        await systemSource.stop()
        await micSource.stop()

        // Final flush of any complete window the aligner has buffered.
        aligner.flush()

        // Finalize the recorder. We catch any error so the PID file
        // cleanup at the end of `run()` always runs.
        var finalizeError: Error?
        do {
            try await recorder.finalize(timeout: 30)
        } catch {
            logger.error("recorder.finalize failed: \(error.localizedDescription)")
            finalizeError = error
        }

        // Tear the transcription pipeline down AFTER the recorder has
        // finalized — the design (§LT-12) guarantees the recording is
        // the primary artefact. Errors during transcription teardown
        // are logged but never override `finalizeError`. The teardown
        // is bounded with a hard timeout (§LT-12.1, added 2026-04-29):
        // a wedged provider session (e.g. an Apple Speech analyzer
        // whose on-device asset failed to download and is now stuck
        // inside `finalizeAndFinishThroughEndOfInput`) MUST NOT
        // prevent `run()` from reaching `emitState(.stopped)`. If the
        // teardown does not complete within the budget, log a warning
        // and proceed; the leaked provider task will be torn down with
        // the process.
        await withTranscriptionTeardownTimeout(
            seconds: Self.transcriptionTeardownTimeoutSeconds
        ) { [aligner] in
            await self.tearDownTranscriptionPipelineIfNeeded(aligner: aligner)
        }

        // Mark as no-longer-running.
        serialQueue.sync { self._running = false }

        // ---- Step 13: PID file cleanup (detach mode only). ----
        if options.runMode == .detached {
            PidFile.remove(at: options.pidFile, logger: pidLogger)
            pidLogger.info("PID file removed at \(options.pidFile.path)")
        }

        // Drop our reference to the recorder so the lock no longer
        // pins it once finalize has completed.
        _recorderLock.withLock { current in
            current = nil
        }

        // ---- Step 14: surface any captured error. ----
        // Order: finalize error wins (it covers a writer failure
        // that may have been the root cause of any prior append
        // error); then any captured per-frame recorder error;
        // otherwise success.
        if let err = finalizeError {
            failAndFinishStream(with: err)
            throw err
        }
        let captured: Error? = serialQueue.sync { self._recorderError }
        if let err = captured {
            failAndFinishStream(with: err)
            throw err
        }

        // FR-33 / project-design §15.3.1: clean exit. Emit `.stopped`
        // and finish the continuation (R-28: every `for await` consumer
        // sees the stream terminate). Also finish the transcript-events
        // stream so UI consumers' `for await` loops exit cleanly.
        emitState(.stopped)
        _stateContinuation.finish()
        _transcriptEventsContinuation.finish()
    }

    // MARK: - Public API — split (FR-32, project-design §15.3.2)

    /// Rotate the output encoder while keeping the capture pipeline
    /// alive. The new file at `nextOutput` opens, the reference is
    /// swapped atomically through `_recorderLock`, the previous
    /// recorder finalizes asynchronously, and capture continues
    /// uninterrupted. Audible seam is bounded at ~52 ms (m4a) /
    /// ~10 ms (wav, caf) per project-design §15.3.2 — well inside the
    /// AC-UI-7 250 ms ceiling.
    ///
    /// - Parameter nextOutput: writable destination URL for the next
    ///   segment. Must be on the same volume as `options.output`'s
    ///   parent (no validation here — the recorder factory enforces
    ///   path parent-existence and overwrite semantics).
    ///
    /// - Throws: any `NtakkerError` produced by the recorder factory or
    ///   `Recorder.start()` (in which case the previous recorder is
    ///   left untouched and the session continues recording into the
    ///   original file), or any error produced by
    ///   `Recorder.finalize(timeout:)` on the rotated-out recorder.
    public func split(nextOutput: URL) async throws {
        // 1. Emit `.splitting`. Subscribers observe the swap.
        emitState(.splitting)

        // 2. Pre-flight the new recorder OFF the serial queue. If
        // construction or `start()` throws, leave `_recorderLock`
        // untouched and emit `.failed`. The current recorder continues
        // unchanged.
        let newOptions = options.withOutput(nextOutput)
        let newRecorder: Recorder
        do {
            newRecorder = try makeRecorder(
                options: newOptions,
                logger: LoggerFactory.make("ntakker-cli.recorder.\(newOptions.format.rawValue)")
            )
            try await newRecorder.start()
        } catch {
            logger.error("split: pre-flight failed; continuing with original recorder: \(error.localizedDescription)")
            // We do NOT finish the stream — the session keeps going.
            // The error is surfaced to the caller of `split()` only.
            // We do, however, emit `.failed` so observers see the
            // attempted-but-aborted split, then re-emit `.recording`
            // because that is the actual current state.
            emitState(.failed(ntakkerify(error)))
            emitState(.recording)
            throw error
        }

        // 3. Atomic swap on `_recorderLock`. Frame N goes to the old
        // recorder (already passed the lock read on its callback);
        // frame N+1 goes to the new. No frame is dropped.
        let oldRecorder: Recorder? = _recorderLock.withLock { current in
            let prev = current
            current = newRecorder
            return prev
        }

        // 4. Finalize the old recorder OFF the serial queue. m4a
        // finalize writes the moov atom and can take seconds; the
        // 5 s timeout matches the post-pid-write-failure path. Any
        // finalize error is logged but does not roll the swap back —
        // the new recorder is already accepting frames.
        if let oldRecorder {
            do {
                try await oldRecorder.finalize(timeout: 5)
            } catch {
                logger.error("split: old recorder finalize failed: \(error.localizedDescription)")
                // Swallow — the partial file is on disk; the new
                // segment is fine. Surface to caller via throw.
                emitState(.recording)
                throw error
            }
        }

        // 4.5. plan-004 R-LT-5: when transcription is active, rotate
        // the sidecar onto the new audio URL so the in-flight transcript
        // follows the rotated audio file. The dispatcher closes the
        // outgoing writer, opens a fresh one at the derived sibling
        // path, and resets its segment indexing. Failures here are
        // logged but do NOT roll back the audio rotation — the new
        // audio segment is already accepting frames and the partial
        // sidecar is on disk.
        //
        let dispatcherSnapshot: (any TranscriptionDispatcher)? = serialQueue.sync {
            self._transcriptionDispatcher
        }
        if let dispatcher = dispatcherSnapshot {
            let sidecarFormat: TranscriptFormat = options.transcriptionFormat
            do {
                try await dispatcher.rotateSidecar(
                    toAudioURL: nextOutput,
                    format: sidecarFormat
                )
            } catch {
                logger.error(
                    "split: transcription sidecar rotation failed: \(error.localizedDescription)"
                )
            }
        }

        // 5. Emit `.recording` after the swap settles. The state
        // machine is back at the steady state.
        emitState(.recording)
    }

    // MARK: - Private — state-stream helpers

    /// Forward a `SessionState` to the continuation. Drops cleanly if
    /// the stream has already finished (`.bufferingNewest(8)` policy
    /// means any prior overflow loses the oldest entry, never blocks).
    private func emitState(_ state: SessionState) {
        _stateContinuation.yield(state)
    }

    /// Emit `.failed(error)` and finish the stream. Used on every
    /// throwing exit path of `run()` so the consumer sees terminal
    /// failure and the consumer `Task` does not leak (R-28). Also
    /// finishes the transcript-events stream so UI consumers' `for
    /// await` loops exit cleanly.
    private func failAndFinishStream(with error: Error) {
        emitState(.failed(ntakkerify(error)))
        _stateContinuation.finish()
        _transcriptEventsContinuation.finish()
    }

    /// Coerce an arbitrary `Error` into a `NtakkerError` for embedding
    /// in `SessionState.failed`. `NtakkerError` round-trips unchanged;
    /// every other error is wrapped via `.unknown(...)`. Pure
    /// helper — performs no I/O, no logging.
    private func ntakkerify(_ error: Error) -> NtakkerError {
        if let m = error as? NtakkerError { return m }
        return .unknown(error.localizedDescription)
    }

    // MARK: - Private — start-failure cleanup

    /// Best-effort teardown when a source `start()` throws after the
    /// recorder is already open.
    private func cleanupAfterStartFailure(
        recorder: Recorder,
        system: (any SystemAudioSource)?,
        mic: (any MicrophoneSource)?
    ) async {
        if let s = system { await s.stop() }
        if let m = mic { await m.stop() }
        _ = try? await recorder.finalize(timeout: 5)
        if options.runMode == .detached {
            PidFile.remove(at: options.pidFile, logger: pidLogger)
        }
    }

    // MARK: - Private — already-recording detach guard (FR-28)

    /// Inspect the resolved PID file. Throws `alreadyRecording` if
    /// the contained PID is alive; removes a stale or unreadable
    /// file and continues otherwise.
    private func checkExistingPidFile() throws {
        let url = options.pidFile
        let existingPid: Int32?
        do {
            existingPid = try PidFile.read(at: url)
        } catch {
            // Malformed file → treat as stale. Design §14.1 says
            // "log a warning, remove it, continue".
            pidLogger.warning(
                "removing malformed PID file at \(url.path): \(error.localizedDescription)"
            )
            PidFile.remove(at: url, logger: pidLogger)
            return
        }
        guard let pid = existingPid else {
            // File does not exist → safe to start.
            return
        }
        let alive: Bool
        do {
            alive = try PidFile.isAlive(pid: pid)
        } catch {
            // Probing the PID failed. Conservative default per design
            // §14.1: refuse to start (treat as alive). The user can
            // remove the file manually if they truly want to take
            // over.
            pidLogger.warning(
                "kill(\(pid), 0) probe failed; refusing to start (treat as alive): \(error.localizedDescription)"
            )
            throw NtakkerError.alreadyRecording(pid: pid, pidFilePath: url.path)
        }
        if alive {
            throw NtakkerError.alreadyRecording(pid: pid, pidFilePath: url.path)
        }
        // PID is stale.
        pidLogger.warning("removing stale PID file at \(url.path) (PID \(pid) not alive)")
        PidFile.remove(at: url, logger: pidLogger)
    }

    // MARK: - Private — run-loop resolution

    /// Resolve the run-loop with `reason` if not already resolved.
    /// Must be invoked on `serialQueue`. Captures `errorToCapture`
    /// if non-nil and no error has been captured yet.
    private func resolveRunLoop(reason: StopReason, errorToCapture: Error?) {
        if let err = errorToCapture, _recorderError == nil {
            _recorderError = err
        }
        if _stopRequested { return }
        _stopRequested = true
        // FR-33 / project-design §15.3.1: the unified resolution path
        // is the single emission point for `.stopping`. SIGINT/SIGTERM,
        // max-duration timer, terminal recorder error, and
        // `requestStop()` all funnel here, and the listener observes
        // exactly one `.stopping` transition per session.
        emitState(.stopping)
        if let cont = _runContinuation {
            _runContinuation = nil
            cont.resume(returning: reason)
        }
        // If `_runContinuation` is nil, `run()` has not yet reached
        // the suspension point. It will check `_stopRequested` on
        // arrival and resume immediately.
    }

    /// Hop onto `serialQueue` and capture a terminal recorder error.
    /// The error is surfaced after finalize so we always close the
    /// writer.
    private func captureRecorderError(_ error: Error) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            if self._recorderError == nil {
                self._recorderError = error
            }
            // A per-frame append failure indicates the writer is
            // wedged. Resolve the run-loop so the orchestrator
            // tears the pipeline down. If a resolver beat us here,
            // this is a no-op.
            self.resolveRunLoop(reason: .error, errorToCapture: nil)
        }
    }

    // MARK: - Private — signals + timer

    /// Install `DispatchSourceSignal` for SIGINT and SIGTERM. The
    /// handler hops onto `serialQueue` and resolves the run-loop.
    /// Per `docs/research/avassetwriter-aac.md` §1.4, we ignore the
    /// signal at the libc level first so the default action does not
    /// fire concurrently.
    private func installSignalSources() {
        let signals: [Int32] = [SIGINT, SIGTERM]
        for sig in signals {
            // Disable libc default handling for this signal.
            Darwin.signal(sig, SIG_IGN)

            let src = DispatchSource.makeSignalSource(signal: sig, queue: serialQueue)
            src.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.logger.info("received signal \(sig); requesting stop")
                self.resolveRunLoop(reason: .signal(sig), errorToCapture: nil)
            }
            src.resume()
            serialQueue.sync { self._signalSources.append(src) }
        }
    }

    /// Schedule a one-shot `DispatchSourceTimer` that resolves the
    /// run-loop when `seconds` elapse. Cancelled in
    /// `teardownTimersAndSignals`.
    private func installMaxDurationTimer(seconds: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: serialQueue)
        t.schedule(
            deadline: .now() + seconds,
            repeating: .never,
            leeway: .milliseconds(50)
        )
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.logger.info("max-duration cap reached (\(seconds)s); requesting stop")
            self.resolveRunLoop(reason: .maxDuration, errorToCapture: nil)
        }
        serialQueue.sync { self._maxDurationTimer = t }
        t.resume()
    }

    /// Cancel timers and signal sources. Idempotent.
    private func teardownTimersAndSignals() {
        serialQueue.sync {
            for src in _signalSources {
                src.cancel()
            }
            _signalSources.removeAll()
            _maxDurationTimer?.cancel()
            _maxDurationTimer = nil
            _terminalErrorPollTimer?.cancel()
            _terminalErrorPollTimer = nil
        }
    }

    /// Schedule a 1 s repeating timer that polls each source's
    /// `terminalError` (declared on `AudioSource`; default
    /// implementation returns `nil` for sources that have no notion
    /// of an unrecoverable error, e.g. `FakeAudioSource`). On a
    /// non-nil error, captures it and resolves the run loop.
    private func installTerminalErrorPoll(
        system: any SystemAudioSource,
        mic: any MicrophoneSource
    ) {
        let t = DispatchSource.makeTimerSource(queue: serialQueue)
        t.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        // Capture sources weakly so cancellation breaks the cycle.
        t.setEventHandler { [weak self, weak system, weak mic] in
            guard let self = self else { return }
            if let err = system?.terminalError {
                self.logger.error("system source terminal error: \(err.localizedDescription)")
                self.resolveRunLoop(reason: .error, errorToCapture: err)
                return
            }
            if let err = mic?.terminalError {
                self.logger.error("microphone source terminal error: \(err.localizedDescription)")
                self.resolveRunLoop(reason: .error, errorToCapture: err)
                return
            }
        }
        serialQueue.sync { self._terminalErrorPollTimer = t }
        t.resume()
    }

    // MARK: - Private — transcription pipeline (plan-004 Phase G)

    /// Resolve the `TranscriptionProvider` for the current
    /// `RecordingOptions` either via the injected test factory or the
    /// shared production `TranscriptionProviderFactory.build`. Coerces
    /// non-`NtakkerError` thrown values to `NtakkerError.unknown(...)`.
    private func resolveTranscriptionProvider() throws -> any TranscriptionProvider {
        let providerLogger = LoggerFactory.make("ntakker-cli.transcription.provider")
        if let factory = transcriptionProviderFactory {
            do {
                return try factory(options)
            } catch let ntakkerError as NtakkerError {
                throw ntakkerError
            } catch {
                throw NtakkerError.unknown(error.localizedDescription)
            }
        }
        let input = TranscriptionProviderFactoryInput(
            providerId: options.transcriptionProviderId ?? "none",
            apiKey: options.transcriptionApiKey,
            modelId: options.transcriptionModelId,
            languageHints: options.transcriptionLanguageHints,
            logger: providerLogger,
            keyExpiresAt: options.transcriptionKeyExpiresAt,
            // Plan-007 Phase A1 / A2 — Azure OpenAI fields.
            azureOpenAIEndpoint: options.azureOpenAIEndpoint,
            azureOpenAIDeployment: options.azureOpenAIDeployment,
            azureOpenAIApiVersion: options.azureOpenAIApiVersion,
            azureOpenAIApiKeyExpiresAt: options.azureOpenAIApiKeyExpiresAt,
            azureOpenAIRealtimeVADThreshold: options.azureOpenAIRealtimeVADThreshold,
            azureOpenAIRealtimeVADPrefixPaddingMS: options.azureOpenAIRealtimeVADPrefixPaddingMS,
            azureOpenAIRealtimeVADSilenceMS: options.azureOpenAIRealtimeVADSilenceMS,
            azureOpenAIRealtimeNoiseReduction: options.azureOpenAIRealtimeNoiseReduction,
            azureOpenAIRealtimeIncludeLogprobs: options.azureOpenAIRealtimeIncludeLogprobs,
            azureOpenAIRealtimeDeploymentInUrl: options.azureOpenAIRealtimeDeploymentInUrl,
            // Plan-007 Phase B — ElevenLabs fields.
            elevenLabsModelId: options.elevenLabsModelId,
            elevenLabsLanguageCode: options.elevenLabsLanguageCode,
            elevenLabsDiarize: options.elevenLabsDiarize,
            elevenLabsTagAudioEvents: options.elevenLabsTagAudioEvents,
            elevenLabsNumSpeakers: options.elevenLabsNumSpeakers,
            elevenLabsFileFormat: options.elevenLabsFileFormat,
            elevenLabsEntityDetection: options.elevenLabsEntityDetection,
            elevenLabsKeyterms: options.elevenLabsKeyterms,
            elevenLabsApiKeyExpiresAt: options.elevenLabsApiKeyExpiresAt,
            // Plan-012 Phase A5 — Soniox speaker-diarization toggle.
            sonioxDiarize: options.sonioxDiarize,
            // WhisperKit on-device tunables (added 2026-05-02).
            whisperKitModel: options.whisperKitModel,
            whisperKitLanguage: options.whisperKitLanguage,
            whisperKitTask: options.whisperKitTask,
            whisperKitTemperature: options.whisperKitTemperature,
            whisperKitWordTimestamps: options.whisperKitWordTimestamps,
            // Parakeet on-device tunables (plan-012 Phase B3).
            parakeetModel: options.parakeetModel,
            parakeetLanguage: options.parakeetLanguage
        )
        do {
            return try TranscriptionProviderFactory.build(input)
        } catch let ntakkerError as NtakkerError {
            throw ntakkerError
        } catch {
            throw NtakkerError.unknown(error.localizedDescription)
        }
    }

    /// Install the live transcription pipeline if transcription is
    /// enabled. "Enabled" means `options.transcriptionProviderId`
    /// selects a real provider (non-empty / non-`"none"` / non-`"noop"`).
    /// When transcription is disabled this is a no-op and the recording
    /// path is byte-identical to pre-Phase-G behavior (NFR-17 / AC-LT-2).
    ///
    /// On success, populates the three pieces of state:
    ///   * `_transcriptionDispatcher`
    ///   * `_transcriptionTapToken` (installed on `aligner.addLiveTap`)
    ///   * `_transcriptionForwarderTask` (dispatcher events → public stream)
    ///
    /// The sidecar writer lives inside the dispatcher (per-session
    /// writer owned by `TranscriptionManager`); the session does not
    /// retain a separate sidecar reference.
    ///
    /// Throws on missing API key, unknown provider, non-writable
    /// sidecar path, or downsampler init failure. Per the project
    /// "no fallback" rule, any of these errors aborts `run()` and
    /// surfaces back to the CLI / UI caller.
    private func setUpTranscriptionPipelineIfNeeded(
        aligner: HostClockAligner
    ) async throws {
        let dispatcher: (any TranscriptionDispatcher)?
        let trSource: TranscriptionSource
        let summary: String

        // Plan-012 Phase C4 introduces a second branch on top of the
        // legacy single path: when the user picks `--transcribe-source
        // both` we build TWO single-source TranscriptionManagers (one
        // per SourceTag) and wrap them in a
        // SourceSplitTranscriptionManager. Otherwise we fall through
        // to the unchanged single path.
        let providerId = options.transcriptionProviderId ?? "none"
        let normalized = providerId.lowercased()
        guard !normalized.isEmpty, normalized != "none", normalized != "noop" else {
            // Transcription disabled — nothing to do, recording
            // path is unchanged.
            return
        }
        let kind = TranscriptionDispatcherSelector.chooseKind(for: options)
        switch kind {
        case .sourceSplit:
            // Plan-012 Phase C4 — true `--transcribe-source both`
            // routing. Build two parallel managers, each driving
            // its own provider instance, sidecar writer, and
            // metrics struct, then wrap in
            // SourceSplitTranscriptionManager.
            if normalized == "elevenlabs" {
                logger.warning(
                    "ElevenLabs Free/Starter tiers cap concurrent STT requests at 8; --transcribe-source both will run two parallel POSTs and may surface concurrent_limit_exceeded (HTTP 429)."
                )
            }
            let (sysMgr, _, sysSummary) = try await buildSingleModeManager(
                normalizedProviderId: normalized,
                sourceOverride: .system,
                sidecarSourceTag: .system
            )
            let (micMgr, _, micSummary) = try await buildSingleModeManager(
                normalizedProviderId: normalized,
                sourceOverride: .mic,
                sidecarSourceTag: .microphone
            )
            let split = SourceSplitTranscriptionManager(
                systemManager: sysMgr,
                microphoneManager: micMgr,
                logger: LoggerFactory.make("ntakker-cli.transcription.source-split")
            )
            dispatcher = split
            trSource = .both
            summary = "source-split (\(sysSummary) || \(micSummary))"
        case .single, .none:
            // .none was filtered by the guard above. The `.single`
            // arm is the legacy path.
            let (mgr, source, summaryLine) = try await buildSingleModeManager(
                normalizedProviderId: normalized
            )
            dispatcher = mgr
            trSource = source
            summary = summaryLine
        }

        guard let dispatcher else {
            return
        }

        // ----------------------------------------------------------
        // Start the dispatcher and wire the forwarder Task. The
        // dispatcher protocol's `start()` is `async throws` —
        // `TranscriptionManager.start()` is non-throwing (Swift allows
        // the conformance).
        // ----------------------------------------------------------
        let dispatcherEvents: AsyncStream<TranscriptionEvent>
        do {
            dispatcherEvents = try await dispatcher.start()
        } catch let ntakkerError as NtakkerError {
            throw ntakkerError
        } catch {
            throw NtakkerError.unknown(
                "transcription dispatcher start failed: \(error.localizedDescription)"
            )
        }

        let publicContinuation = self._transcriptEventsContinuation
        let forwarderLogger = self.logger
        let forwarder = Task {
            forwarderLogger.info("transcript forwarder: starting drain of dispatcher events stream")
            var seen = 0
            for await event in dispatcherEvents {
                if Task.isCancelled { break }
                seen += 1
                // A7: trace, not info — one line per event otherwise.
                forwarderLogger.trace("transcript forwarder: republishing event #\(seen) \(String(describing: event).prefix(60))")
                publicContinuation.yield(event)
            }
            forwarderLogger.info("transcript forwarder: dispatcher events stream ended after \(seen) events")
            // Dispatcher events finished — the public stream is
            // intentionally NOT finished here. The session's run-loop
            // owns the stream's lifecycle (so a transient provider
            // failure does not exit the UI's `for await` loop early).
        }

        // ----------------------------------------------------------
        // Step 3: install the live tap on the aligner. The closure
        // is mode-agnostic — it routes frames into the dispatcher
        // through the protocol method `ingestFrame(_:from:)`. Both
        // implementations are `async`, so the sync tap closure hands
        // each frame to a `TranscriptionFrameFeeder` lane.
        //
        // `.mixed` deserves the long comment: previously this case
        // fell through to `manager.ingestFrame(frame, from: .system)`,
        // which made `TranscriptionManager.ingestFrame` read
        // `frame.systemBuffer` and DROP `frame.micBuffer` entirely.
        // That made `.mixed` silently equivalent to `.system` for
        // transcription even though the audio file was correctly
        // mixed by `M4ARecorder` via `BufferSummer.sum(...)`. The
        // observable defect was: recording contains both the user's
        // mic and the system audio, but the transcript sidecar only
        // contains the system side (e.g. the other Teams participants
        // but not the user). Fix: sum the two sub-buffers here using
        // the same `BufferSummer` the recorder uses, then synthesise
        // a single-buffer `AlignedFrame` that the dispatcher picks up
        // through its existing `.system` branch. This keeps the
        // dispatcher's API surface unchanged.
        // ----------------------------------------------------------
        // C4 (EVAL 2026-06-12): capture the dispatcher STRONGLY. The
        // session owns the dispatcher's lifetime through `stop()` (the
        // tap is removed and the dispatcher stopped before the
        // reference is dropped); a weak capture here meant the final
        // frames emitted during `aligner.flush()` could observe a
        // nil dispatcher and silently vanish — losing the last
        // ~100–200 ms of every transcript.
        // TR-14 / F1 (EVAL 2026-10-16): the tap hands frames to one
        // bounded, ordered lane per source instead of spawning a Task
        // per frame. Teardown drains the lanes before stopping the
        // dispatcher, so the last frames are never lost.
        let feederSources: [SourceTag] = trSource == .mic
            ? [.microphone]
            : (trSource == .both ? [.system, .microphone] : [.system])
        let feeder = TranscriptionFrameFeeder(dispatcher: dispatcher, sources: feederSources)
        let token = aligner.addLiveTap { frame in
            switch trSource {
            case .system:
                feeder.feed(frame, to: .system)
            case .mic:
                feeder.feed(frame, to: .microphone)
            case .mixed:
                // `BufferSummer.sum(_:_:)` is nil-tolerant: nil+nil
                // returns nil, side+nil returns the side untouched,
                // both-present returns the clamped Float-add. `try?`
                // collapses any DSP-level failure into "fall back to
                // whichever side is available" — the same defensive
                // posture the recorder takes inside `buildMixed`.
                let mixed = (try? BufferSummer.sum(
                    frame.systemBuffer,
                    frame.micBuffer
                )) ?? frame.systemBuffer ?? frame.micBuffer
                guard let mixed else { return }
                let mixedFrame = AlignedFrame(
                    pts: frame.pts,
                    duration: frame.duration,
                    systemBuffer: mixed,
                    micBuffer: nil
                )
                feeder.feed(mixedFrame, to: .system)
            case .both:
                feeder.feed(frame, to: .system)
                feeder.feed(frame, to: .microphone)
            }
        }

        serialQueue.sync {
            self._transcriptionDispatcher = dispatcher
            self._transcriptionForwarderTask = forwarder
            self._transcriptionTapToken = token
            self._transcriptionFeeder = feeder
        }

        logger.info("transcription pipeline ready: \(summary)")
    }

    /// Build a `TranscriptionManager` from the resolved
    /// `RecordingOptions`. Extracted from
    /// `setUpTranscriptionPipelineIfNeeded` so the outer method can
    /// branch cleanly between the legacy single path and the
    /// source-split path without duplicating the long setup.
    ///
    /// Returns the manager (typed as `TranscriptionManager`, the
    /// caller widens to `any TranscriptionDispatcher`), the resolved
    /// transcription source, and a one-line summary string for the
    /// logger.
    private func buildSingleModeManager(
        normalizedProviderId: String,
        sourceOverride: TranscriptionSource? = nil,
        sidecarSourceTag: SourceTag? = nil
    ) async throws -> (TranscriptionManager, TranscriptionSource, String) {
        // Per FR / configuration-guide rule: warn if the API key is in
        // its last 7 days of validity. The manager still runs; this is
        // a heads-up on stderr.
        if let expiresAt = options.transcriptionKeyExpiresAt {
            let interval = expiresAt.timeIntervalSinceNow
            if interval <= 7 * 24 * 3600 && interval > 0 {
                let days = Int(ceil(interval / 86_400))
                logger.warning(
                    "transcription API key for provider '\(normalizedProviderId)' expires in \(days) day(s)"
                )
            }
        }

        // Resolve provider — may throw `transcriptionApiKeyMissing`
        // or `transcriptionConfigConflict` (unknown id). We let those
        // bubble.
        let provider = try resolveTranscriptionProvider()

        // Plan-005 Phase G — speech-permission preflight. Apple's
        // on-device `SpeechAnalyzer` requires Speech Recognition TCC
        // grant; we trigger the prompt (if .notDetermined) and throw
        // `transcriptionPermissionDenied(provider: "apple")` (exit 77)
        // on any non-authorized terminal state. Done BEFORE the
        // manager / sidecar / aligner-tap are wired so a denial leaves
        // no half-built pipeline behind.
        if provider.id == "apple" {
            if #available(macOS 26.0, *) {
                try await SpeechPermission.ensureGranted()
            }
        }

        // Build the downsampler configured for the aligner's output
        // (Float32 / 48 kHz / stereo by default; the constructor
        // refuses anything else and we propagate the error verbatim).
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(options.sampleRate),
            channels: 2,
            interleaved: false
        ) else {
            throw NtakkerError.unknown(
                "failed to construct aligner output format for transcription downsampler"
            )
        }
        let downsampler: AudioDownsampler
        do {
            downsampler = try AudioDownsampler(
                inputFormat: inputFormat,
                logger: LoggerFactory.make("ntakker-cli.transcription.downsampler")
            )
        } catch {
            throw NtakkerError.unknown(
                "transcription downsampler init failed: \(error.localizedDescription)"
            )
        }

        // Resolve the per-recording transcription source. When the
        // caller passes `sourceOverride` (Phase C4 source-split path),
        // it wins so each child manager sees a single-source filter
        // (.system or .mic). Otherwise we forward
        // `options.transcriptionSource` unchanged (the legacy path
        // where TranscriptionManager handles whatever was requested,
        // including .both natively).
        let trSource: TranscriptionSource = sourceOverride ?? options.transcriptionSource

        // Build the sidecar writer. When `sidecarSourceTag` is non-nil
        // (Phase C4), the sidecar URL gets a `.system.` / `.microphone.`
        // infix so two parallel managers don't overwrite the same file.
        // Otherwise we keep the legacy nil sourceTag for byte-equivalent
        // single-source naming.
        let sidecarURL = SidecarPathBuilder.sidecarURL(
            forRecording: options.output,
            format: options.transcriptionFormat,
            partNumber: nil,
            sourceTag: sidecarSourceTag
        )
        // Plan-005 Phase F: derive the sidecar policy from the
        // provider's declared modes. Streaming providers persist only
        // `.segmentFinalized`; batch providers persist
        // `.segmentAppended` + `.segmentUpdated` via id-keyed in-place
        // rewrite. The policy is fixed at writer construction; the
        // streaming pipeline rebuilds the writer with the streaming
        // policy on `rotateSidecar(...)` so this initial choice is the
        // single source of truth for the per-mode dispatch.
        let sidecarPolicy: SidecarPolicy =
            provider.supportedModes.contains(.streaming) ? .streaming : .batch
        let sidecar: TranscriptSidecarWriter
        do {
            sidecar = try TranscriptSidecarWriter(
                outputPath: sidecarURL,
                format: options.transcriptionFormat,
                policy: sidecarPolicy
            )
        } catch let ntakkerError as NtakkerError {
            throw ntakkerError
        } catch {
            // Per project rule "no fallback": surface the path issue
            // as a configuration error so the CLI exits with the
            // standard exit code. Recording does not start when the
            // sidecar cannot be opened.
            throw NtakkerError.ioError(
                "transcription sidecar open failed at \(sidecarURL.path): \(error.localizedDescription)"
            )
        }

        // Build the manager. The `TranscriptionOptions` carries the
        // resolved provider id (`provider.id`) so the manager logs and
        // privacy-disclosure carry the canonical wire form (e.g.
        // `"gemini"` rather than the deprecated `"gemini-live"`).
        let trOptions = TranscriptionOptions(
            providerId: provider.id,
            apiKey: options.transcriptionApiKey,
            modelId: options.transcriptionModelId,
            languageHints: options.transcriptionLanguageHints,
            customSystemInstruction: nil,
            keyExpiresAt: options.transcriptionKeyExpiresAt
        )
        let manager = TranscriptionManager(
            provider: provider,
            source: trSource,
            options: trOptions,
            downsampler: downsampler,
            sidecarWriter: sidecar,
            logger: LoggerFactory.make("ntakker-cli.transcription.manager"),
            // F24: the manager must remember its per-source sidecar
            // infix so `rotateSidecar(...)` after `split()` reproduces
            // the tagged path instead of colliding on the untagged one.
            sidecarSourceTag: sidecarSourceTag
        )

        let summary = "single (provider=\(provider.id), source=\(trSource.rawValue), format=\(options.transcriptionFormat.rawValue), sidecar=\(sidecarURL.lastPathComponent))"
        return (manager, trSource, summary)
    }

    /// Hard upper bound on `tearDownTranscriptionPipelineIfNeeded`.
    /// Provider sessions whose internal `finish()` blocks beyond this
    /// budget are abandoned so the recording-stop sequence can always
    /// reach `emitState(.stopped)`. Five seconds matches
    /// `TranscriptionManager.stopDrainSeconds` for the rest-batch path
    /// — the streaming pipeline previously had no bound at all.
    public static let transcriptionTeardownTimeoutSeconds: Double = 5.0

    /// Run `body` with a hard time budget. If `body` does not return
    /// within `seconds`, this function returns anyway, a warning is
    /// logged, and the abandoned task is **leaked** (it keeps running
    /// in the background until its non-cancellable inner call returns
    /// on its own).
    ///
    /// The earlier `withTaskGroup` implementation was a noop because
    /// `withTaskGroup` waits for every child task to finish before
    /// exiting — even after `cancelAll()`. `Task.cancel()` only sets
    /// a flag; both `analyzer.finalizeAndFinishThroughEndOfInput()`
    /// (Apple Speech) and URLSession's blocking call paths (Gemini
    /// REST under network failure) ignore it. So we need a pattern
    /// that does not await the body task at all once the timer wins.
    ///
    /// `withCheckedContinuation` + two detached tasks racing to
    /// resume the continuation is exactly that pattern: whichever
    /// resumes first unblocks the caller; the loser is no longer
    /// awaited.
    private func withTranscriptionTeardownTimeout(
        seconds: Double,
        _ body: @Sendable @escaping () async -> Void
    ) async {
        let didFinish: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            // Single-shot resume guard — `CheckedContinuation` traps
            // on double-resume.
            nonisolated(unsafe) var resumed = false
            let resume: @Sendable (Bool) -> Void = { value in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            Task.detached {
                await body()
                resume(true)
            }
            Task.detached {
                let nanos = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                resume(false)
            }
        }
        if !didFinish {
            logger.warning(
                "transcription teardown exceeded \(seconds)s budget; abandoning to keep stop sequence responsive"
            )
        }
    }

    /// Tear the live transcription pipeline down. Idempotent — safe to
    /// call from every error/cleanup path. Order:
    ///
    ///   1. Remove the aligner tap (no more frames flow into the
    ///      dispatcher).
    ///   2. Stop the dispatcher (final-drains the per-source buffers,
    ///      waits up to `TranscriptionManager.stopDrainSeconds` for
    ///      outstanding provider calls, closes the sidecar, and
    ///      finishes the events stream).
    ///   3. Await the forwarder task (so the last events make it to
    ///      the public `transcriptEvents` stream).
    private func tearDownTranscriptionPipelineIfNeeded(
        aligner: HostClockAligner
    ) async {
        // Snapshot under serialQueue and clear so subsequent calls
        // are no-ops.
        let dispatcher: (any TranscriptionDispatcher)?
        let token: HostClockAligner.TapToken?
        let forwarder: Task<Void, Never>?
        let feeder: TranscriptionFrameFeeder?
        (dispatcher, token, forwarder, feeder) = serialQueue.sync {
            let d = self._transcriptionDispatcher
            let t = self._transcriptionTapToken
            let f = self._transcriptionForwarderTask
            let q = self._transcriptionFeeder
            self._transcriptionDispatcher = nil
            self._transcriptionTapToken = nil
            self._transcriptionForwarderTask = nil
            self._transcriptionFeeder = nil
            return (d, t, f, q)
        }

        guard dispatcher != nil || token != nil else {
            return
        }

        // 1. Detach the tap so no more frames flow into the dispatcher.
        if let token {
            aligner.removeLiveTap(token)
        }

        // 1b. Let the feeder lanes deliver the frames already queued,
        // in order, before the dispatcher drains (TR-14 / F1).
        if let feeder {
            await feeder.finish()
        }

        // 2. Stop the dispatcher — final-drains buffers, awaits
        // in-flight provider calls (bounded), closes the sidecar,
        // finishes the events stream.
        if let dispatcher {
            await dispatcher.stop()
        }

        // 3. Await the forwarder so the last events reach the public
        // stream subscribers.
        if let forwarder {
            _ = await forwarder.value
        }
    }
}
