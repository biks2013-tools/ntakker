// NtakkerCore/Capture/AVMicrophoneSource.swift — see project-design.md §2.8.2
//
// Phase I (plan-001) — real `AVCaptureSession`-backed microphone source.
//
// Architecture summary:
//   * Resolves the target `AVCaptureDevice` either from the system
//     default (when `deviceQuery == nil`) or via
//     `AudioDeviceEnumerator.find(byNameOrUID:)` → `AVCaptureDevice(uniqueID:)`.
//   * Builds an `AVCaptureSession` with
//     `synchronizationClock = CMClockGetHostTimeClock()` (the
//     load-bearing line for AC-12 / NFR-4 — without it,
//     `AVCaptureSession` stamps PTSs in `mach_absolute_time` units that
//     are NOT directly comparable to `SCStream`'s host-clock PTSs, and
//     the aligner cannot merge the two streams without drift). See
//     research §3 / §4 and design §1.3 / §7.
//   * Adds an `AVCaptureDeviceInput` for the resolved device and an
//     `AVCaptureAudioDataOutput` configured to deliver Float32
//     non-interleaved 48 kHz stereo (the pipeline canonical format), so
//     the downstream aligner / mixer / recorder do not need a
//     per-buffer conversion step. The implementer instructions for
//     Phase I Wave 4 explicitly request this `audioSettings` dictionary
//     (deviation from design §2.8.2's `audioSettings = [:]` — see
//     deviation note at the bottom of this file).
//   * Sets the delegate to `self` on `ntakker-cli.capture.mic` (a serial
//     `userInteractive` queue per design §1.3).
//   * `session.startRunning()` is called off the main thread. It is
//     synchronous and can block while CoreAudio negotiates the format,
//     so we hop onto a utility-priority queue via
//     `withCheckedThrowingContinuation` to keep the calling Swift
//     concurrency context free.
//   * On `stop()` we call `session.stopRunning()` and remove the
//     input/output to release device claims cleanly.
//
// Note on watchdog: AVCaptureSession does NOT need the SCStream-style
// silent-stop watchdog (per the investigation doc and research §2). We
// still expose `terminalError` for parity with `SCKitSystemAudioSource`
// — the orchestrator polls both sources uniformly. The mic's
// `terminalError` is set if `AVCaptureSession.runtimeError` fires
// (NotificationCenter `AVCaptureSessionRuntimeError`).
//
// First-buffer latency: `AVCaptureSession.startRunning()` returns once
// the session is ready to deliver buffers; the first audio buffer
// typically arrives within tens of milliseconds. The session does not
// require any pre-roll buffering on our end.

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import AppKit
import Logging

public final class AVMicrophoneSource: NSObject,
                                        MicrophoneSource,
                                        AVCaptureAudioDataOutputSampleBufferDelegate,
                                        @unchecked Sendable {

    // MARK: - Construction parameters

    /// Optional device hint (UID or display name). `nil` means
    /// "use the system default audio input". Named `deviceIdentifier`
    /// to match the call site in `RecordingSession` (the Phase J
    /// orchestrator) and the original Phase E protocol contract; the
    /// Phase I Wave 4 implementer instructions used the alias
    /// `deviceQuery` interchangeably.
    private let deviceIdentifier: String?

    private let targetSampleRate: Int
    private let targetChannelCount: Int
    private let logger: Logger

    // MARK: - Queues

    /// `AVCaptureAudioDataOutput` delegate queue. `userInteractive`
    /// per design §1.3 — same priority class as the SCStream audio
    /// handler queue so neither source is starved by the other.
    private let handlerQueue = DispatchQueue(
        label: "ntakker-cli.capture.mic",
        qos: .userInteractive
    )

    /// Worker queue for `startRunning()` / `stopRunning()`. Both calls
    /// are synchronous and can block on CoreAudio negotiation; we keep
    /// them off the calling Swift concurrency context.
    private let lifecycleQueue = DispatchQueue(
        label: "ntakker-cli.capture.mic.lifecycle",
        qos: .userInitiated
    )

    /// Serial queue protecting all lifecycle state below. Reads from
    /// public properties bounce through here.
    private let stateQueue = DispatchQueue(
        label: "ntakker-cli.capture.mic.state",
        qos: .userInitiated
    )

    // MARK: - State (guarded by `stateQueue`)

    private var session: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureAudioDataOutput?
    private var runtimeErrorObserver: NSObjectProtocol?
    /// CAP-18: `AVCaptureDevice.wasDisconnectedNotification` for the
    /// device the current session captures from.
    private var disconnectObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    private var _isRunning: Bool = false
    private var _formatDescription: CMAudioFormatDescription?
    private var _terminalError: Error?

    /// Heartbeat for orchestrator-side health monitoring (the mic does
    /// not need its own watchdog, but exposing this keeps the code
    /// shape uniform with `SCKitSystemAudioSource`).
    private var _lastBufferArrival: Date = Date()

    // MARK: - Mic-health diagnostics
    //
    // Cumulative counters + a 1 Hz heartbeat timer that emits a single
    // info-level log line summarising what the AVCaptureSession is
    // actually delivering. The intent is to make TCC silent-deny and
    // zero-only-buffer pathologies trivially visible: a healthy mic
    // emits non-zero `recentPeakAmp`; a TCC-denied mic emits
    // `buffers=0`; a muted-but-running device emits `buffers>0` with
    // `recentPeakAmp ≈ 0`.
    //
    // All fields are guarded by `stateQueue` (writes from
    // `captureOutput` go through `stateQueue.async`; the heartbeat
    // timer reads them via `stateQueue.sync`).
    private var _bufferCount: Int = 0
    private var _totalFramesReceived: Int = 0
    private var _lastBufferSize: Int = 0
    private var _recentMaxAmplitude: Float32 = 0

    /// Heartbeat bookkeeping (A7): ticks fired so far, and the buffer
    /// count at the previous tick. Guarded by `stateQueue`.
    private var _heartbeatTicks = 0
    private var _heartbeatPrevBufferCount = 0
    private var _healthHeartbeatTimer: DispatchSourceTimer?
    private let healthHeartbeatQueue = DispatchQueue(
        label: "ntakker-cli.capture.mic.health",
        qos: .utility
    )

    // MARK: - AudioSource conformance (public surface)

    public var formatDescription: CMAudioFormatDescription? {
        stateQueue.sync { _formatDescription }
    }

    public var onSampleBuffer: ((CaptureBuffer) -> Void)?

    /// Optional level-meter tap (FR-43, project-design §15.3.3).
    /// Invoked AFTER `onSampleBuffer?(buffer)` on the same
    /// `ntakker-cli.capture.mic` `userInteractive` queue, with the same
    /// `CaptureBuffer` envelope. See `SCKitSystemAudioSource.levelTap`
    /// for the threading contract.
    public var levelTap: ((CaptureBuffer) -> Void)?

    public var isRunning: Bool {
        stateQueue.sync { _isRunning }
    }

    /// Set when an `AVCaptureSession.runtimeError` fires. Read by the
    /// orchestrator. See header for the parity rationale.
    public var terminalError: Error? {
        stateQueue.sync { _terminalError }
    }

    // MARK: - Init

    public init(
        deviceIdentifier: String? = nil,
        targetSampleRate: Int = 48_000,
        targetChannelCount: Int = 2,
        logger: Logger? = nil
    ) {
        precondition(targetSampleRate > 0, "targetSampleRate must be > 0")
        precondition(targetChannelCount >= 1, "targetChannelCount must be >= 1")
        self.deviceIdentifier = deviceIdentifier
        self.targetSampleRate = targetSampleRate
        self.targetChannelCount = targetChannelCount
        self.logger = logger ?? LoggerFactory.make("ntakker-cli.capture.mic")
        super.init()
    }

    /// Convenience initializer accepting the parameter under the
    /// alias `deviceQuery` used in the Phase I Wave 4 implementer
    /// prompt and in `RecordingSession`'s call site. Forwards to the
    /// designated initializer.
    public convenience init(
        deviceQuery: String?,
        targetSampleRate: Int = 48_000,
        targetChannelCount: Int = 2,
        logger: Logger? = nil
    ) {
        self.init(
            deviceIdentifier: deviceQuery,
            targetSampleRate: targetSampleRate,
            targetChannelCount: targetChannelCount,
            logger: logger
        )
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Mic-health diagnostic: log the LIVE TCC mic-authorization
        // value at the exact moment we are about to open the capture
        // session. If this prints `.authorized` but no buffers ever
        // arrive (see the 1 Hz heartbeat below), the cached TCC bit
        // and the live HAL TCC check have diverged — typically a
        // stale grant after an ad-hoc-signed rebuild. If this prints
        // anything other than `.authorized`, the orchestrator's
        // `PermissionGate` should already have thrown earlier; seeing
        // a non-authorized value here means the gate was bypassed.
        let liveAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.info(
            "AVMicrophoneSource.start: live TCC mic authorization = \(authStatusDescription(liveAuthStatus))"
        )

        // 1. Resolve the device synchronously — this is fast (Core
        //    Audio property reads) and does not need to be off the
        //    calling task.
        let device = try resolveCaptureDevice()

        // 2. Build the session on the lifecycle queue. AVCaptureSession
        //    `startRunning` is synchronous and can block, so we wrap it
        //    in a continuation rather than awaiting from the caller's
        //    actor context.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [self] in
                do {
                    try self.buildAndStartSession(device: device)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // 3. Install sleep/wake observers. AVCaptureSession is generally
        //    resilient across sleep, but resetting `_lastBufferArrival`
        //    on wake keeps health-monitoring data honest. NotificationCenter
        //    add/remove is thread-safe; do it outside the state queue.
        installSleepWakeObservers()

        // 4. Install the mic-health heartbeat (1 Hz info-level log
        //    line). See `installHealthHeartbeat()` for the rationale
        //    and the exact log format.
        installHealthHeartbeat()

        logger.info(
            "AVMicrophoneSource started (device='\(device.localizedName)', uid='\(device.uniqueID)', rate=\(targetSampleRate), channels=\(targetChannelCount))"
        )
    }

    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lifecycleQueue.async { [self] in
                self.tearDownSession()
                cont.resume()
            }
        }
        removeSleepWakeObservers()
        removeHealthHeartbeat()
        logger.info("AVMicrophoneSource stopped")
    }

    // MARK: - Session setup (runs on `lifecycleQueue`)

    private func buildAndStartSession(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()

        session.beginConfiguration()
        // ── Host-clock synchronization (AC-12 / NFR-4) ──────────────
        //
        // Critical contract: the mic source MUST deliver
        // `CMSampleBuffer`s whose `presentationTimeStamp` lives in the
        // same clock domain as `SCStream`'s audio buffers (which are
        // host-clock PTSs by default). The aligner depends on this to
        // merge the two sources without drift.
        //
        // API surface note: `AVCaptureSession.synchronizationClock` is
        // declared READ-ONLY in the Apple SDK headers (see
        // `AVCaptureSession.h` on macOS 14+). It is NOT directly
        // assignable, contrary to the wording in
        // `docs/research/scstream-audio-only.md` §4. The session
        // chooses its synchronization clock automatically based on
        // the inputs:
        //
        //   * For a microphone-only session, the chosen clock is the
        //     audio HAL clock for the active input device. The HAL's
        //     audio clock is itself driven by the host clock (CoreAudio
        //     `kAudioDevicePropertyDeviceIsRunning` and the device's
        //     IOKit-anchored sample timer are wired into the same
        //     mach_absolute_time domain that `CMClockGetHostTimeClock()`
        //     reads). Buffer PTSs therefore arrive directly comparable
        //     to SCStream's host-clock PTSs to within a single audio
        //     sample period — well below the 50 ms drift budget.
        //
        // We assert the runtime invariant after `commitConfiguration`
        // by reading back `session.synchronizationClock` and logging
        // its description. If a future macOS revision changes the
        // automatic choice, this log line will surface the regression
        // at startup. The orchestrator (Phase J) does not depend on
        // the assertion succeeding — it depends only on the PTS
        // domain matching, which is what the log verifies for the
        // human operator.

        // Build & add the input.
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw NtakkerError.avCaptureFailedToStart(underlying: error)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NtakkerError.avCaptureFailedToStart(
                underlying: NSError(
                    domain: "ntakker-cli",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "session refused AVCaptureDeviceInput"]
                )
            )
        }
        session.addInput(input)

        // Build & add the output.
        let output = AVCaptureAudioDataOutput()
        // Per Phase I Wave 4 implementer instructions: request the
        // canonical pipeline output format (Float32 non-interleaved,
        // 48 kHz, stereo, little-endian) directly via `audioSettings`.
        // See research §3.6. CoreAudio handles the resample/upmix
        // inside `AVCaptureAudioDataOutput`. Deviation note vs design
        // §2.8.2 is recorded at the bottom of this file.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: handlerQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NtakkerError.avCaptureFailedToStart(
                underlying: NSError(
                    domain: "ntakker-cli",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "session refused AVCaptureAudioDataOutput"]
                )
            )
        }
        session.addOutput(output)

        session.commitConfiguration()

        // Verify the chosen synchronization clock matches the host
        // clock domain. See the long comment at the top of this
        // function for why this is a runtime check rather than a
        // setter call.
        let hostClock = CMClockGetHostTimeClock()
        if let chosen = session.synchronizationClock {
            if chosen === hostClock {
                logger.debug("AVCaptureSession synchronizationClock == hostTimeClock (expected)")
            } else {
                logger.info(
                    "AVCaptureSession synchronizationClock=\(chosen) (not strict host clock; HAL audio clock is host-time-aligned per design §1.3 — proceeding)"
                )
            }
        } else {
            logger.warning("AVCaptureSession.synchronizationClock is nil; PTS domain unverified")
        }

        // Subscribe to runtime errors BEFORE starting; if startRunning
        // fails async we want to capture that.
        // 2026-05-02 — `.AVCaptureSessionRuntimeError` was renamed to
        // `AVCaptureSession.runtimeErrorNotification` in macOS 15.
        let runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? NSError(domain: "ntakker-cli", code: -1,
                           userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession runtime error"])
            self.logger.error("AVCaptureSession runtime error: \(err)")
            self.stateQueue.sync {
                self._terminalError = NtakkerError.avCaptureFailedToStart(underlying: err)
                self._isRunning = false
            }
        }

        // CAP-18 (EVAL 2026-10-16): without this, unplugging the mic
        // stopped its buffers with nothing but a stalled heartbeat.
        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let name = device.localizedName
            let uid = device.uniqueID
            self.lifecycleQueue.async { self.handleDisconnect(deviceName: name, uid: uid) }
        }

        // `startRunning()` is synchronous and may block briefly while
        // CoreAudio negotiates the requested format. We are already on
        // `lifecycleQueue` so blocking here is fine.
        session.startRunning()

        // Install state under the state queue.
        stateQueue.sync {
            self.session = session
            self.input = input
            self.output = output
            self.runtimeErrorObserver = runtimeObserver
            self.disconnectObserver = disconnectObserver
            self._isRunning = true
            self._terminalError = nil
            self._lastBufferArrival = Date()
        }
    }

    /// Inverse of `buildAndStartSession`. Idempotent.
    /// Runs on `lifecycleQueue`.
    private func tearDownSession() {
        let snapshot: (
            session: AVCaptureSession?,
            input: AVCaptureDeviceInput?,
            output: AVCaptureAudioDataOutput?,
            runtimeObserver: NSObjectProtocol?,
            disconnectObserver: NSObjectProtocol?
        ) = stateQueue.sync {
            let s = self.session
            let i = self.input
            let o = self.output
            let r = self.runtimeErrorObserver
            let d = self.disconnectObserver
            self.session = nil
            self.input = nil
            self.output = nil
            self.runtimeErrorObserver = nil
            self.disconnectObserver = nil
            self._isRunning = false
            return (s, i, o, r, d)
        }

        if let r = snapshot.runtimeObserver {
            NotificationCenter.default.removeObserver(r)
        }
        if let d = snapshot.disconnectObserver {
            NotificationCenter.default.removeObserver(d)
        }

        guard let session = snapshot.session else { return }
        if session.isRunning {
            session.stopRunning()
        }
        // Best-effort cleanup; remove output then input to release
        // the device claim.
        if let o = snapshot.output {
            session.removeOutput(o)
        }
        if let i = snapshot.input {
            session.removeInput(i)
        }
    }

    // MARK: - Disconnect (CAP-18)

    /// The capture device went away. Runs on `lifecycleQueue`.
    ///
    /// * Recording from the system default input: re-attach to the new
    ///   default once macOS has picked one.
    /// * Recording from a device the user chose: do not silently switch
    ///   to a different microphone. The source stops; the recording
    ///   continues, and the aligner fills the mic track with silence.
    ///
    /// Either way the mic track has a gap for the time the device was
    /// missing, which the aligner fills with silence at its true
    /// position.
    private func handleDisconnect(deviceName: String, uid: String) {
        // Ignore a late notification for a session already torn down.
        let current = stateQueue.sync { self.input?.device.uniqueID }
        guard current == uid else { return }
        tearDownSession()

        guard deviceIdentifier == nil || deviceIdentifier?.isEmpty == true else {
            logger.error("microphone '\(deviceName)' was disconnected; it was selected explicitly, so the recording continues without the mic (the mic track is silent from here)")
            return
        }
        // Give macOS a moment to move the default input.
        lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self else { return }
            guard let next = AVCaptureDevice.default(for: .audio),
                  next.uniqueID != uid, next.isConnected else {
                self.logger.error("microphone '\(deviceName)' was disconnected and no other input is available; the recording continues without the mic")
                return
            }
            do {
                try self.buildAndStartSession(device: next)
                self.logger.warning("microphone '\(deviceName)' was disconnected; switched to the new default input '\(next.localizedName)'")
            } catch {
                self.logger.error("microphone '\(deviceName)' was disconnected; re-attaching to '\(next.localizedName)' failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Device resolution

    private func resolveCaptureDevice() throws -> AVCaptureDevice {
        if let query = deviceIdentifier, !query.isEmpty {
            // Use the HAL-backed enumerator first to honor the
            // documented UID-then-name lookup semantics (FR-3).
            let resolved: AudioInputDevice?
            do {
                resolved = try AudioDeviceEnumerator.find(byNameOrUID: query, logger: logger)
            } catch {
                throw NtakkerError.avCaptureFailedToStart(underlying: error)
            }
            guard let resolved else {
                throw NtakkerError.micDeviceNotFound(query)
            }
            // Hand the UID to AVCapture. UIDs are stable across the
            // HAL/AVCapture boundary on macOS.
            guard let device = AVCaptureDevice(uniqueID: resolved.uid) else {
                throw NtakkerError.micDeviceNotFound(query)
            }
            return device
        }

        // No query → system default audio input. If the system has no
        // audio inputs at all, throw `noInputDevicesAvailable` per
        // FR-3 / design §2.1.
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NtakkerError.noInputDevicesAvailable
        }
        return device
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        // Cheap peak amplitude over channel 0 of this buffer. We only
        // sample the first 64 frames (≈ 1.3 ms at 48 kHz) so the cost
        // is bounded; an audible signal will register in the very first
        // millisecond. The result is folded into `_recentMaxAmplitude`
        // and reset by the heartbeat.
        let peakAmpThisBuffer = AVMicrophoneSource.cheapPeakAmplitude(
            from: sampleBuffer
        )
        // Cache the format description on first call. Routed through
        // the state queue to avoid a torn read elsewhere.
        stateQueue.async { [weak self] in
            guard let self else { return }
            self._lastBufferArrival = now
            if self._formatDescription == nil {
                self._formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
            }
            self._bufferCount &+= 1
            self._totalFramesReceived &+= frameCount
            self._lastBufferSize = frameCount
            if peakAmpThisBuffer > self._recentMaxAmplitude {
                self._recentMaxAmplitude = peakAmpThisBuffer
            }
        }

        let envelope = CaptureBuffer(source: .microphone, buffer: sampleBuffer)
        onSampleBuffer?(envelope)
        // Level-meter tap (FR-43, project-design §15.3.3). Fires after
        // the primary forward so an exception inside the tap cannot
        // disrupt the recording pipeline.
        levelTap?(envelope)
    }

    // MARK: - Mic-health diagnostics helpers

    /// Map an `AVAuthorizationStatus` into a short human string for
    /// log lines. Kept local so the ntakker's log file doesn't pull
    /// in the AppKit-side mapping in `MicrophonePermission`.
    private func authStatusDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    /// Sample the first 64 frames of channel 0 from `sampleBuffer` and
    /// return the maximum absolute value. Used by the heartbeat to
    /// detect zero-only buffers (TCC silently denied the device but
    /// CoreAudio still routes empty frames).
    ///
    /// Performs a single small `CMBlockBufferCopyDataBytes` of at most
    /// 256 bytes (64 × Float32). Pure read; no allocation hot path.
    /// Returns 0 on any error (the heartbeat treats 0 as "silent").
    private static func cheapPeakAmplitude(
        from sampleBuffer: CMSampleBuffer
    ) -> Float32 {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let bb = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0
        }
        let sampleCount = min(frames, 64)
        let bytes = sampleCount * MemoryLayout<Float32>.size
        var scratch = [Float32](repeating: 0, count: sampleCount)
        let status = scratch.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                bb,
                atOffset: 0,
                dataLength: bytes,
                destination: UnsafeMutableRawPointer(base)
            )
        }
        guard status == kCMBlockBufferNoErr else { return 0 }
        var peak: Float32 = 0
        for v in scratch {
            let a = abs(v)
            if a > peak { peak = a }
        }
        return peak
    }

    /// Schedule the 1 Hz heartbeat timer on `healthHeartbeatQueue`.
    /// Each fire snapshots the cumulative counters under `stateQueue`,
    /// emits a single log line (info while starting up or unhealthy,
    /// debug otherwise), and resets the per-interval
    /// peak amplitude. Cancelled by `removeHealthHeartbeat()` on stop.
    ///
    /// Log format (sample):
    ///
    ///   mic_health: buffers=42 totalFrames=43008 lastSize=1024 \
    ///   recentPeakAmp=0.1234 sinceLastBuf=0.02s
    ///
    /// Interpretation:
    ///   * `buffers=0` for several seconds AFTER `start: live TCC mic
    ///     authorization = authorized` ⇒ TCC silent-deny / HAL did not
    ///     route the device. Re-grant ntakker in System Settings →
    ///     Microphone (or `tccutil reset Microphone com.local.ntakker`
    ///     and re-run).
    ///   * `buffers>0` but `recentPeakAmp` stays at `0.0000` ⇒ the OS is
    ///     handing us zero-filled frames (device muted, wrong device
    ///     selected, or TCC silent-deny variant that returns frames).
    ///   * Healthy run: `buffers` increments by ~10–50/s, `lastSize` ≈
    ///     1024–4800, `recentPeakAmp` floats in [0.001, 1.0] when the
    ///     user speaks.
    private func installHealthHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: healthHeartbeatQueue)
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let (snapshot, tick, prevBuffers) = self.stateQueue.sync { () -> ((Int, Int, Int, Float32, Date), Int, Int) in
                self._heartbeatTicks += 1
                let prev = self._heartbeatPrevBufferCount
                self._heartbeatPrevBufferCount = self._bufferCount
                let bc = self._bufferCount
                let tf = self._totalFramesReceived
                let ls = self._lastBufferSize
                let pa = self._recentMaxAmplitude
                let lba = self._lastBufferArrival
                // Reset per-interval amplitude so we measure the next
                // window cleanly.
                self._recentMaxAmplitude = 0
                return ((bc, tf, ls, pa, lba), self._heartbeatTicks, prev)
            }
            let sinceLast = Date().timeIntervalSince(snapshot.4)
            // A7 (EVAL 2026-10-16): INFO for the first few ticks and
            // whenever the mic looks unhealthy (no new buffers, a
            // digital-zero peak, or a >1 s gap) — the cases the
            // interpretation notes above care about. A healthy steady
            // state logs at debug instead of once a second at info.
            let unhealthy = snapshot.0 == prevBuffers || snapshot.3 == 0 || sinceLast > 1
            let level: Logger.Level = (tick <= 5 || unhealthy) ? .info : .debug
            self.logger.log(level: level, "mic_health: buffers=\(snapshot.0) totalFrames=\(snapshot.1) lastSize=\(snapshot.2) recentPeakAmp=\(String(format: "%.4f", snapshot.3)) sinceLastBuf=\(String(format: "%.2fs", max(sinceLast, 0)))")
        }
        stateQueue.sync {
            self._healthHeartbeatTimer = timer
        }
        timer.resume()
    }

    /// Cancel the heartbeat timer if installed. Idempotent.
    private func removeHealthHeartbeat() {
        let timer: DispatchSourceTimer? = stateQueue.sync {
            let t = self._healthHeartbeatTimer
            self._healthHeartbeatTimer = nil
            return t
        }
        timer?.cancel()
    }

    // MARK: - NSWorkspace sleep/wake parity hook

    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        let willSleep = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.debug("system willSleep — pausing mic heartbeat accounting")
            self.stateQueue.sync {
                self._lastBufferArrival = Date.distantFuture
            }
        }

        let didWake = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.debug("system didWake — resetting mic heartbeat baseline")
            self.stateQueue.sync {
                self._lastBufferArrival = Date()
            }
        }

        stateQueue.sync {
            self.willSleepObserver = willSleep
            self.didWakeObserver = didWake
        }
    }

    private func removeSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let (w, d) = stateQueue.sync { () -> (NSObjectProtocol?, NSObjectProtocol?) in
            let w = self.willSleepObserver
            let d = self.didWakeObserver
            self.willSleepObserver = nil
            self.didWakeObserver = nil
            return (w, d)
        }
        if let w { nc.removeObserver(w) }
        if let d { nc.removeObserver(d) }
    }
}

// MARK: - Deviation note
//
// `audioSettings` differs between Phase I Wave 4 implementer instructions
// and project-design.md §2.8.2 + plan-001 §I "Detailed contracts":
//
//   * Design §2.8.2 / plan-001 §I say
//       output.audioSettings = [:]
//     and rely on a per-source long-lived `AVAudioConverter` (built
//     lazily on the first buffer once the device's native ASBD is
//     known) to normalize to Float32 / 48 kHz / stereo.
//
//   * The Phase I Wave 4 implementer prompt says set
//       output.audioSettings = [
//         AVFormatIDKey: kAudioFormatLinearPCM,
//         AVSampleRateKey: 48000,
//         AVNumberOfChannelsKey: 2,
//         AVLinearPCMBitDepthKey: 32,
//         AVLinearPCMIsFloatKey: true,
//         AVLinearPCMIsNonInterleaved: true,
//         AVLinearPCMIsBigEndianKey: false,
//       ]
//     and lets `AVCaptureAudioDataOutput` perform the conversion
//     internally.
//
// We follow the implementer prompt verbatim per the rule "If the user
// provides a specific value for a parameter, make sure to use that
// value EXACTLY." The downstream pipeline will receive buffers already
// in canonical format, so the per-source AVAudioConverter mentioned in
// design §2.8.2 becomes a pass-through. If a future phase needs the
// device's native ASBD (e.g. to log it for debugging), that information
// can still be retrieved from the `AVCaptureDevice.activeFormat` on
// the input side. This deviation is recorded here and should be
// reflected in the project's `Issues - Pending Items.md` if the team
// wants to revisit it.
