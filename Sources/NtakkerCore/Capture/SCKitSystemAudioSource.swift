// NtakkerCore/Capture/SCKitSystemAudioSource.swift — see project-design.md §2.8.1
//
// Phase I (plan-001) — real `SCStream`-backed system audio source.
//
// This file implements the audio-only `SCStream` capture pattern verbatim
// from `docs/research/scstream-audio-only.md` §1, §2 (configuration), §3
// and §5 (long-run stability — silent-stop watchdog), §6 (stop / restart
// recipe), and §7 (error handling matrix). The same recipe is mirrored
// in `docs/design/project-design.md` §2.8.1 / §7.1 / §7.2 / §7.3.
//
// Architecture summary:
//   * `SCStream` is built with the locked configuration in §7.1 (audio
//     only — `width=2/height=2`, `minimumFrameInterval` set to a value
//     that effectively suppresses video frames).
//   * Audio buffers arrive on `ntakker-cli.capture.system` (the audio
//     handler queue); we forward each `CMSampleBuffer` through
//     `onSampleBuffer` as a `CaptureBuffer(source: .system, ...)`.
//   * `.screen` buffers are delivered to a separate `ntakker-cli.capture.system.video`
//     queue and immediately discarded — registering the `.screen` output
//     keeps the framework happy and matches every production audio-only
//     SCStream we surveyed (research §1).
//   * A watchdog `DispatchSourceTimer` running on
//     `ntakker-cli.capture.system.watchdog` polls `lastBufferArrival` every
//     5 s; if no audio buffer has arrived in 10 s, it triggers a
//     full-restart of the stream (the `SCStream` instance is replaced —
//     never reused, per research §6 and design §7.3).
//   * Restart attempts are tracked over a 60 s sliding window. If more
//     than `maxRestartsInWindow` (=3) restarts occur within that window,
//     the watchdog gives up and publishes
//     `NtakkerError.scStreamSilentStopExceeded` via `terminalError`. The
//     `RecordingSession` orchestrator polls this property and tears
//     down the session.
//   * `SCStreamDelegate.stream(_:didStopWithError:)` always wraps its
//     work in `Task { ... }` (research §3 / §7) to dodge the
//     `swift_getErrorValue` `EXC_BAD_ACCESS` framework bug, where the
//     `error` argument arrives with invalid memory.
//   * Sleep / wake are observed via `NSWorkspace.willSleepNotification`
//     and `NSWorkspace.didWakeNotification` (R-13 / research §5.6) so the
//     watchdog does not fire spuriously across a sleep window — on
//     `didWake` we reset `lastBufferArrival = Date()` and any pending
//     restart-window history.
//
// Concurrency model:
//   * `_stateQueue` is a serial dispatch queue
//     (`ntakker-cli.capture.system.state`) that owns all mutable lifecycle
//     state (the `SCStream` reference, watchdog timer, restart history,
//     last-buffer arrival, etc).
//   * The audio handler queue (`ntakker-cli.capture.system`) only ever
//     mutates `lastBufferArrival` and the cached format description —
//     reads of those values from elsewhere bounce through `_stateQueue`.
//   * `onSampleBuffer` is invoked synchronously from the audio handler
//     queue. The contract (per `AudioSource` protocol) is that the
//     callback enqueues work and returns promptly.
//
// First-buffer latency: `SCStream.startCapture()` returns before the
// first audio buffer is delivered. Reported latency is 50–300 ms post
// `startCapture()` completion on Apple Silicon (research §5.6). The
// watchdog accounts for this by seeding `lastBufferArrival = Date()`
// at `startCapture()` completion, so a 10 s staleness window from that
// point comfortably covers normal first-buffer latency.

import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import AppKit
import Logging

@available(macOS 14.0, *)
public final class SCKitSystemAudioSource: NSObject,
                                           SystemAudioSource,
                                           SCStreamDelegate,
                                           SCStreamOutput,
                                           @unchecked Sendable {

    // MARK: - Configuration constants (design §7.3)

    /// How often the watchdog polls `lastBufferArrival`. Design §7.3.
    private static let watchdogPollInterval: TimeInterval = 5.0

    /// If `Date().timeIntervalSince(lastBufferArrival) > stalenessThreshold`
    /// when the watchdog ticks, restart the stream. Design §7.3.
    private static let stalenessThreshold: TimeInterval = 10.0

    /// Sliding window over which restart attempts are counted. Design §7.3.
    private static let restartWindow: TimeInterval = 60.0

    /// More than this many restarts within `restartWindow` ⇒ fatal. Design §7.3.
    private static let maxRestartsInWindow: Int = 3

    // MARK: - Construction parameters

    private let sampleRate: Int
    private let channelCount: Int
    private let logger: Logger
    private let clock: CMClock

    // MARK: - State queues

    /// Audio buffer delivery queue. `userInteractive` per design §1.3.
    private let audioHandlerQueue = DispatchQueue(
        label: "ntakker-cli.capture.system",
        qos: .userInteractive
    )

    /// `.screen` buffers land here and are immediately discarded.
    /// `utility` per design §1.3.
    private let videoDiscardQueue = DispatchQueue(
        label: "ntakker-cli.capture.system.video",
        qos: .utility
    )

    /// Owns the watchdog timer source. Separate queue per design §1.3.
    private let watchdogQueue = DispatchQueue(
        label: "ntakker-cli.capture.system.watchdog",
        qos: .utility
    )

    /// Serial queue protecting all lifecycle state below.
    private let stateQueue = DispatchQueue(
        label: "ntakker-cli.capture.system.state",
        qos: .userInitiated
    )

    // MARK: - State (guarded by `stateQueue` unless noted otherwise)

    /// The live SCStream — replaced on every restart, never reused.
    private var stream: SCStream?

    /// The watchdog poll timer (DispatchSourceTimer running on
    /// `watchdogQueue`). Cancelled on `stop()` and during restart.
    private var watchdogTimer: DispatchSourceTimer?

    /// True once `start()` has succeeded (or the watchdog is restarting).
    /// Read only from inside `stateQueue`.
    private var _isRunning: Bool = false

    /// True once the user has invoked `stop()` — informs the delegate
    /// callback that the next `didStopWithError` is expected.
    private var _userStopped: Bool = false

    /// Heartbeat timestamp of the most recently delivered audio buffer.
    /// Written from the audio handler queue, read from the watchdog
    /// queue — both via `stateQueue` for serialization.
    private var lastBufferArrival: Date = Date()

    /// History of restart timestamps. Pruned on every push to drop
    /// entries older than `restartWindow`.
    private var restartTimestamps: [Date] = []

    /// Cached format description from the very first audio buffer. Once
    /// set, it does not change for the lifetime of the source.
    private var _formatDescription: CMAudioFormatDescription?

    /// Set when the watchdog gives up (>3 restarts in 60 s) or when a
    /// fatal stream error occurs. Surfaced via `terminalError` for the
    /// orchestrator to poll.
    private var _terminalError: Error?

    /// Sleep/wake observers from `NSWorkspace`. Removed on `stop()`.
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    // MARK: - AudioSource conformance (public surface)

    public var formatDescription: CMAudioFormatDescription? {
        stateQueue.sync { _formatDescription }
    }

    public var onSampleBuffer: ((CaptureBuffer) -> Void)?

    /// Optional level-meter tap (FR-43, project-design §15.3.3).
    /// Invoked AFTER `onSampleBuffer?(buffer)` on the same
    /// `ntakker-cli.capture.system` `userInteractive` queue, with the same
    /// `CaptureBuffer` envelope. Consumers (typically the UI's
    /// `LevelMeterTap`) MUST NOT touch SwiftUI state directly — route
    /// through an `AsyncStream` whose consumer is `@MainActor`.
    public var levelTap: ((CaptureBuffer) -> Void)?

    public var isRunning: Bool {
        stateQueue.sync { _isRunning }
    }

    /// Surfaced for the `RecordingSession` orchestrator to poll — when
    /// the watchdog gives up after exceeding the restart cap, or when
    /// a non-recoverable stream error occurs, the orchestrator can
    /// observe the resulting `NtakkerError` here without us having to
    /// invent a new callback on the `AudioSource` protocol. Design
    /// note: a strictly cleaner approach would be a `Combine`
    /// publisher or an `AsyncStream` of events, but per the
    /// implementer instructions we expose a plain getter.
    public var terminalError: Error? {
        stateQueue.sync { _terminalError }
    }

    // MARK: - Init

    public init(
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        logger: Logger? = nil,
        clock: CMClock = CMClockGetHostTimeClock()
    ) {
        precondition(sampleRate > 0, "sampleRate must be > 0")
        precondition(channelCount >= 1, "channelCount must be >= 1")
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.logger = logger ?? LoggerFactory.make("ntakker-cli.capture.system")
        self.clock = clock
        super.init()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Build the filter and configuration up front — both are async
        // boundaries because `SCShareableContent` is async, so we do it
        // outside the state queue then hop in to install state.
        let filter = try await Self.makeSystemAudioFilter()
        let cfg = Self.makeAudioOnlyConfiguration(
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        // Build a fresh `SCStream`. Errors from `addStreamOutput` /
        // `startCapture` are surfaced as `scStreamFailedToStart` after
        // tearing down any partial state.
        let newStream = SCStream(filter: filter, configuration: cfg, delegate: self)

        do {
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: videoDiscardQueue
            )
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: audioHandlerQueue
            )
        } catch {
            logger.error("addStreamOutput failed: \(error)")
            throw NtakkerError.scStreamFailedToStart(underlying: error)
        }

        do {
            try await newStream.startCapture()
        } catch {
            logger.error("SCStream.startCapture failed: \(error)")
            // Best-effort teardown of the partially-built stream.
            try? await newStream.stopCapture()
            throw NtakkerError.scStreamFailedToStart(underlying: error)
        }

        // Install state under `stateQueue` and arm the watchdog.
        stateQueue.sync {
            // If `start()` is invoked twice (idempotency contract on
            // `AudioSource`), tear down the previous stream first.
            if let existing = self.stream {
                logger.warning("start() called while a stream exists; tearing down previous one")
                Task { try? await existing.stopCapture() }
            }
            self.stream = newStream
            self._isRunning = true
            self._userStopped = false
            self.lastBufferArrival = Date()
            self._terminalError = nil
            self.installWatchdogLocked()
        }

        // Subscribe to NSWorkspace sleep/wake outside the state queue
        // (NotificationCenter add/remove is thread-safe).
        installSleepWakeObservers()

        logger.info("SCKitSystemAudioSource started (rate=\(sampleRate), channels=\(channelCount))")
    }

    public func stop() async {
        // Mark user-stop FIRST so the delegate callback can short-circuit.
        // Tear down sleep/wake observers, the watchdog, and the stream.
        var streamToStop: SCStream?
        stateQueue.sync {
            self._userStopped = true
            self._isRunning = false
            self.cancelWatchdogLocked()
            streamToStop = self.stream
            self.stream = nil
        }

        removeSleepWakeObservers()

        if let s = streamToStop {
            do {
                try await s.stopCapture()
            } catch {
                // Per research §6: stopCapture errors at this point are
                // benign (often `attemptToStopStreamState`, code -3808).
                logger.debug("stopCapture during user stop returned: \(error)")
            }
            // `removeStreamOutput` is not required (research §6); skip.
        }

        logger.info("SCKitSystemAudioSource stopped")
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .audio:
            handleAudioBuffer(sampleBuffer)
        default:
            // `.screen` (and any `.microphone` accidentally registered
            // on macOS 15+) — discard. We don't capture mic via SCStream.
            return
        }
    }

    private func handleAudioBuffer(_ sb: CMSampleBuffer) {
        // The audio handler queue is serial; we can update last-arrival
        // and the cached format description without locking — but we
        // route writes through `stateQueue` to keep the read-side from
        // having to synchronize against the audio queue specifically.
        let now = Date()
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.lastBufferArrival = now
            if self._formatDescription == nil {
                self._formatDescription = CMSampleBufferGetFormatDescription(sb)
            }
        }

        // Forward the buffer. The contract on `AudioSource.onSampleBuffer`
        // is that the callback runs on the source's delivery queue.
        let envelope = CaptureBuffer(source: .system, buffer: sb)
        onSampleBuffer?(envelope)
        // Level-meter tap (FR-43, project-design §15.3.3). Fires after
        // the primary forward so that an exception in the tap cannot
        // disrupt the recording pipeline. The tap is `nil` for the CLI
        // and for `RecordingSession` consumers that do not opt in.
        levelTap?(envelope)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Wrap in Task to dodge the `swift_getErrorValue` EXC_BAD_ACCESS
        // bug: introspecting `error` synchronously on the framework's
        // callback thread sometimes accesses dangling memory. Hopping
        // off via Task forces a heap allocation that breaks the dangling
        // reference. Per research §3, §7.
        Task { [weak self] in
            await self?.handleDelegateStop(error: error)
        }
    }

    private func handleDelegateStop(error: Error) async {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code

        // userStopped (-3817): expected when WE called stopCapture, OR
        // when the user clicked the system stop UI. Either way, do not
        // restart.
        let isUserStopped = (
            domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" &&
            code == -3817
        )
        // attemptToStopStreamState (-3808): redundant stop; ignore.
        let isAttemptToStop = (
            domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" &&
            code == -3808
        )

        let userInitiated = stateQueue.sync { _userStopped }

        if isUserStopped || isAttemptToStop || userInitiated {
            logger.info("SCStream stopped (domain=\(domain) code=\(code), userStopped=\(userInitiated))")
            stateQueue.sync {
                self._isRunning = false
            }
            return
        }

        logger.warning("SCStream stopped unexpectedly (domain=\(domain) code=\(code)); attempting restart")
        await restartStream(reason: "delegate-error")
    }

    // MARK: - Watchdog

    /// Must be called inside `stateQueue.sync`.
    private func installWatchdogLocked() {
        // Cancel any previous timer first.
        watchdogTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
        let interval = Self.watchdogPollInterval
        t.schedule(
            deadline: .now() + .seconds(Int(interval)),
            repeating: .seconds(Int(interval)),
            leeway: .milliseconds(500)
        )
        t.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdogTimer = t
        t.resume()
    }

    /// Must be called inside `stateQueue.sync`.
    private func cancelWatchdogLocked() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        // Snapshot state under the lock.
        let (running, stale, userStopped) = stateQueue.sync { () -> (Bool, Bool, Bool) in
            let s = Date().timeIntervalSince(self.lastBufferArrival) > Self.stalenessThreshold
            return (self._isRunning, s, self._userStopped)
        }
        guard running, !userStopped else { return }
        guard stale else { return }

        logger.warning("SCStream audio stall detected (no buffer in >\(Self.stalenessThreshold)s); restarting")
        Task { [weak self] in
            await self?.restartStream(reason: "watchdog-stall")
        }
    }

    // MARK: - Restart

    private func restartStream(reason: String) async {
        // Record the restart attempt and check the cap before doing
        // anything expensive.
        let exceeded: Bool = stateQueue.sync {
            let now = Date()
            self.restartTimestamps.append(now)
            // Prune entries older than `restartWindow`.
            let cutoff = now.addingTimeInterval(-Self.restartWindow)
            self.restartTimestamps.removeAll { $0 < cutoff }
            return self.restartTimestamps.count > Self.maxRestartsInWindow
        }

        if exceeded {
            let count = stateQueue.sync { self.restartTimestamps.count }
            logger.error("SCStream restart cap exceeded (\(count) restarts in \(Int(Self.restartWindow))s); aborting")
            stateQueue.sync {
                self._terminalError = NtakkerError.scStreamSilentStopExceeded(
                    restartCount: count
                )
                self._isRunning = false
                self.cancelWatchdogLocked()
            }
            // Best-effort: stop the current stream so we don't leak it.
            let toStop: SCStream? = stateQueue.sync {
                let s = self.stream
                self.stream = nil
                return s
            }
            if let s = toStop {
                try? await s.stopCapture()
            }
            return
        }

        logger.info("SCStream restart (\(reason)); building fresh stream instance")

        // 1. Tear down the existing stream.
        let oldStream: SCStream? = stateQueue.sync {
            let s = self.stream
            self.stream = nil
            return s
        }
        if let s = oldStream {
            try? await s.stopCapture()
        }

        // 2. Re-fetch SCShareableContent (display list may have changed)
        //    and rebuild the configuration.
        let filter: SCContentFilter
        do {
            filter = try await Self.makeSystemAudioFilter()
        } catch {
            logger.error("restart: failed to fetch SCShareableContent: \(error)")
            stateQueue.sync {
                self._terminalError = NtakkerError.scStreamFailedToStart(underlying: error)
                self._isRunning = false
                self.cancelWatchdogLocked()
            }
            return
        }
        let cfg = Self.makeAudioOnlyConfiguration(
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        // 3. New SCStream — never reuse a stopped instance (research §6).
        let newStream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: videoDiscardQueue
            )
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: audioHandlerQueue
            )
            try await newStream.startCapture()
        } catch {
            logger.error("restart: failed to start fresh SCStream: \(error)")
            stateQueue.sync {
                self._terminalError = NtakkerError.scStreamFailedToStart(underlying: error)
                self._isRunning = false
                self.cancelWatchdogLocked()
            }
            return
        }

        // 4. Install the new stream and reset the heartbeat.
        stateQueue.sync {
            self.stream = newStream
            self.lastBufferArrival = Date()
            // Watchdog timer keeps running across restarts; nothing to
            // re-install. The restart history is intentionally retained
            // so the cap is enforced across consecutive failures.
        }
        logger.info("SCStream restart complete (\(reason))")
    }

    // MARK: - NSWorkspace sleep/wake (R-13 / research §5.6)

    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        // Reset the heartbeat baseline on willSleep so the watchdog
        // doesn't accumulate "stale" time during sleep.
        let willSleep = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.debug("system willSleep — pausing watchdog accounting")
            self.stateQueue.sync {
                self.lastBufferArrival = Date.distantFuture
            }
        }

        // On wake, reset baselines so the watchdog evaluates from a
        // clean slate. SCStream may have stalled during sleep — give it
        // one full poll interval before triggering a restart.
        let didWake = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.debug("system didWake — resetting watchdog baseline")
            self.stateQueue.sync {
                self.lastBufferArrival = Date()
            }
        }

        stateQueue.sync {
            self.willSleepObserver = willSleep
            self.didWakeObserver = didWake
        }
    }

    private func removeSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let (willSleep, didWake) = stateQueue.sync { () -> (NSObjectProtocol?, NSObjectProtocol?) in
            let w = self.willSleepObserver
            let d = self.didWakeObserver
            self.willSleepObserver = nil
            self.didWakeObserver = nil
            return (w, d)
        }
        if let w = willSleep { nc.removeObserver(w) }
        if let d = didWake { nc.removeObserver(d) }
    }

    // MARK: - Configuration builders (design §7.1, §7.2; research §1, §2)

    /// Build the locked `SCStreamConfiguration` literal from design §7.1
    /// (which is itself verbatim from research §1 / §2). All knobs are
    /// pinned by the design doc; do not deviate without first updating
    /// `docs/design/project-design.md` §7.1 and the research doc.
    private static func makeAudioOnlyConfiguration(
        sampleRate: Int,
        channelCount: Int
    ) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()

        // Audio knobs.
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = sampleRate
        cfg.channelCount = channelCount

        // Video suppression — values per research §2.1 / design §7.1.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
        cfg.width = 2
        cfg.height = 2
        cfg.queueDepth = 5
        cfg.showsCursor = false
        // pixelFormat: leave at default (kCVPixelFormatType_32BGRA);
        // explicit values cost extra compositor work for no benefit
        // when frames are discarded (research §2 table).

        // Do NOT set `captureMicrophone` or `microphoneCaptureDeviceID`
        // (macOS 15+ only; we capture the mic via AVCaptureSession).
        return cfg
    }

    /// Build the audio-capture `SCContentFilter`. We anchor on the
    /// first display from `SCShareableContent.excludingDesktopWindows`
    /// (design §7.2) and pass an empty `excludingApplications` array,
    /// which captures the entire system audio submix. The display
    /// choice is irrelevant for audio (research §2.5 — audio is filtered
    /// at the application level), but a display IS required to
    /// construct an `SCContentFilter`.
    private static func makeSystemAudioFilter() async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw NtakkerError.scStreamFailedToStart(underlying: error)
        }
        guard let display = content.displays.first else {
            throw NtakkerError.scStreamFailedToStart(
                underlying: NSError(
                    domain: "ntakker-cli",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "no SCDisplay available"]
                )
            )
        }
        return SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
    }
}
