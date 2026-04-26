// MacrecCore/RecordingSession.swift — see project-design.md §2.18 / §2.11
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
//   1. Bootstraps `~/.tool-agents/macrec/` (FR-13).
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
//   * `serialQueue` ("macrec.session") owns the mutable state
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

    /// Serial queue protecting all mutable orchestrator state.
    private let serialQueue = DispatchQueue(
        label: "macrec.session.serial",
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
    ///     `LoggerFactory.make("macrec.session")`.
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
        permissionGate: (any PermissionGating)? = nil
    ) {
        let resolvedLogger = logger ?? LoggerFactory.make("macrec.session")
        self.options = options
        self.logger = resolvedLogger
        self.pidLogger = LoggerFactory.make("macrec.pidfile")
        self.injectedSystemSource = systemSource
        self.injectedMicSource = micSource
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
    /// - Throws: `MacrecError` for any failure that prevents the
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

        // ---- Step 1: bootstrap ~/.tool-agents/macrec/. (FR-13) ----
        do {
            _ = try ToolAgentsBootstrap.ensure(toolName: "macrec")
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
            logger: LoggerFactory.make("macrec.capture.system")
        )
        let micSource: any MicrophoneSource = injectedMicSource ?? AVMicrophoneSource(
            deviceQuery: options.micDevice,
            targetSampleRate: options.sampleRate,
            targetChannelCount: 2,
            logger: LoggerFactory.make("macrec.capture.mic")
        )

        // ---- Step 5: aligner. ----
        let aligner = HostClockAligner(
            targetSampleRate: Double(options.sampleRate),
            targetChannelCount: 2,
            logger: LoggerFactory.make("macrec.aligner")
        )

        // ---- Step 6: recorder. (factory pre-flight validates path) ----
        let recorder: Recorder
        do {
            recorder = try makeRecorder(
                options: options,
                logger: LoggerFactory.make("macrec.recorder.\(options.format.rawValue)")
            )
        } catch {
            logger.error("recorder construction failed: \(error.localizedDescription)")
            throw error
        }

        // Stash so `requestStop` / signal handlers can reach them.
        // The recorder lives behind `_recorderLock` (project-design
        // §15.3.2 / AMB-2) so the aligner-frame callback can read it
        // atomically while `split(nextOutput:)` rotates the reference.
        serialQueue.sync {
            self._aligner = aligner
            self._systemSource = systemSource
            self._micSource = micSource
        }
        _recorderLock.withLock { current in
            current = recorder
        }

        // ---- Step 7: wire callbacks. ----
        // Source → aligner.
        systemSource.onSampleBuffer = { [weak aligner] cb in
            aligner?.ingest(cb)
        }
        micSource.onSampleBuffer = { [weak aligner] cb in
            aligner?.ingest(cb)
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

        // ---- Step 8/9: start recorder, write PID, start sources. ----
        // (Recorder must be open before any buffer arrives.)
        do {
            try await recorder.start()
        } catch {
            logger.error("recorder.start failed: \(error.localizedDescription)")
            // No PID file written yet, no sources started — nothing
            // to clean up.
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
            failAndFinishStream(with: error)
            throw error
        }

        do {
            try await systemSource.start()
        } catch {
            logger.error("system audio source failed to start: \(error.localizedDescription)")
            await cleanupAfterStartFailure(recorder: recorder, system: nil, mic: micSource)
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
        // sees the stream terminate).
        emitState(.stopped)
        _stateContinuation.finish()
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
    /// - Throws: any `MacrecError` produced by the recorder factory or
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
                logger: LoggerFactory.make("macrec.recorder.\(newOptions.format.rawValue)")
            )
            try await newRecorder.start()
        } catch {
            logger.error("split: pre-flight failed; continuing with original recorder: \(error.localizedDescription)")
            // We do NOT finish the stream — the session keeps going.
            // The error is surfaced to the caller of `split()` only.
            // We do, however, emit `.failed` so observers see the
            // attempted-but-aborted split, then re-emit `.recording`
            // because that is the actual current state.
            emitState(.failed(macrecify(error)))
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
    /// failure and the consumer `Task` does not leak (R-28).
    private func failAndFinishStream(with error: Error) {
        emitState(.failed(macrecify(error)))
        _stateContinuation.finish()
    }

    /// Coerce an arbitrary `Error` into a `MacrecError` for embedding
    /// in `SessionState.failed`. `MacrecError` round-trips unchanged;
    /// every other error is wrapped via `.unknown(...)`. Pure
    /// helper — performs no I/O, no logging.
    private func macrecify(_ error: Error) -> MacrecError {
        if let m = error as? MacrecError { return m }
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
            throw MacrecError.alreadyRecording(pid: pid, pidFilePath: url.path)
        }
        if alive {
            throw MacrecError.alreadyRecording(pid: pid, pidFilePath: url.path)
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
}
