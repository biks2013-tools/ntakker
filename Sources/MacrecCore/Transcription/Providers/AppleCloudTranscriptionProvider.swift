// MacrecCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift
//
// 2026-05-01 — Apple's CLOUD Speech-to-Text path, exposed to third-party
// developers via `SFSpeechRecognizer` with `requiresOnDeviceRecognition =
// false`. Distinct from `AppleSpeechTranscriptionProvider` which targets
// the macOS 26 on-device-only `SpeechAnalyzer`.
//
// Why a separate provider?
//   * The `SpeechAnalyzer` provider does not expose Greek (`el-GR`) on
//     macOS 26's launch set; assets are not downloadable on most Macs.
//   * `SFSpeechRecognizer` with the cloud path covers ~57 locales
//     including `el-GR` (research note
//     `docs/reference/apple-cloud-stt-investigation-2026-05.md`).
//   * The two surfaces share the same `NSSpeechRecognitionUsageDescription`
//     TCC string but have different capability profiles (the cloud path
//     needs network + has a 1000 req/hr/device quota + a ~1-min per-task
//     audio cap).
//
// Architecture mirrors the other streaming providers (Azure realtime,
// Soniox): a `TranscriptionProvider` factory hands out
// `StreamingTranscriptionSession`s; the session is a Swift `actor` that
// owns its own `SFSpeechRecognitionTask` and rotates the task every
// ~55 seconds to stay safely inside Apple's per-task duration cap.
//
// Audio contract (per `TranscriptionProvider`): caller hands us 16 kHz
// mono Float32 samples in `[-1, 1]`. We wrap each chunk into an
// `AVAudioPCMBuffer` and `append(_:)` it to the active
// `SFSpeechAudioBufferRecognitionRequest`.

import AVFoundation
import Foundation
import Logging
import Speech

public struct AppleCloudTranscriptionProvider: TranscriptionProvider {

    public let id = "apple-cloud"
    public let displayName = "Apple Cloud"
    public let supportedModes: Set<TranscriptionMode> = [.streaming]

    /// Documented per-task audio cap. Apple QA1951 states ~1 minute per
    /// utterance / per request. We rotate the underlying recognition task
    /// at 55 s to leave headroom for the in-flight final to land.
    public static let taskRotationSeconds: Double = 55

    /// Session input format MUST match what `AVAudioPCMBuffer`'s
    /// constructor expects. `SFSpeechAudioBufferRecognitionRequest`
    /// internally reformats; 16 kHz mono Float32 is the format the
    /// rest of the macrec pipeline downsamples to before handing
    /// audio to providers (see `AudioDownsampler`).
    public static let expectedSampleRate: Double = 16_000

    private let logger: Logger

    public init(logger: Logger = Logger(label: "macrec.transcription.apple-cloud")) {
        self.logger = logger
    }

    /// Detect whether the host process was launched from a `.app`
    /// bundle (vs. a raw CLI binary at `.build/.../macrec-ui`). Used
    /// to decide whether it's safe to call
    /// `SFSpeechRecognizer.requestAuthorization(_:)` — that call
    /// SIGABRTs ad-hoc-signed CLIs on macOS 26 but works fine inside
    /// any `.app` bundle (even ad-hoc-signed) because TCC has bundle
    /// metadata to attach the grant to.
    static func isRunningFromAppBundle() -> Bool {
        // `Bundle.main.bundlePath` for a CLI is the directory holding
        // the binary (no `.app` suffix). For a `.app` it's the bundle
        // root, which always ends in `.app`.
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app")
    }

    // MARK: - TranscriptionProvider

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // The cloud path is fundamentally streaming-shaped (Apple does
        // not expose a synchronous one-shot REST endpoint). Consumers
        // who need batch should pick the on-device `apple` path or one
        // of the cloud REST providers (Azure batch, ElevenLabs, Gemini).
        throw MacrecError.transcriptionConfigConflict(
            reason: "Apple Cloud provider does not support batch mode; use --transcribe apple (on-device) for batch or one of the REST cloud providers"
        )
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        // Resolve the locale: first hint wins; empty hints → `Locale.current`.
        // SFSpeechRecognizer is locale-pinned, so we cannot serve
        // multi-language code-switching from a single recognizer
        // instance. Users wanting multi-language cloud STT should
        // pick ElevenLabs (with the multi-language soft-hint logic
        // wired in PLAN-007-DONE-13).
        let resolvedLocale: Locale = {
            if let first = options.languageHints.first?.trimmingCharacters(in: .whitespaces),
               !first.isEmpty
            {
                return Locale(identifier: first)
            }
            return Locale.current
        }()

        // Validate the locale against the runtime supported set. The
        // cloud path serves a superset of the on-device set, so a
        // locale that fails this check will not work on either path.
        let supportedSet = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier })
        guard supportedSet.contains(resolvedLocale.identifier) else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "Apple Speech does not support locale '\(resolvedLocale.identifier)'. Pick one of the locales SFSpeechRecognizer.supportedLocales() reports."
            )
        }

        // Authorisation. The original
        // `SpeechPermission.ensureGranted()` long-comment notes that
        // `SFSpeechRecognizer.requestAuthorization(_:)` SIGABRTs
        // ad-hoc-signed *CLI binaries* on macOS 26 because TCC has no
        // bundle metadata to attach the grant to. Inside a `.app`
        // bundle (even ad-hoc-signed — the dist/macrec-ui.app from
        // 2026-04-29 has worked for Microphone + Screen Recording
        // grants), TCC accepts the request and shows the system
        // prompt normally. So we branch on `Bundle.main.bundlePath`:
        //   * Path ends with `.app`  → safe to prompt; trigger the
        //                              system Speech Recognition dialog.
        //   * Otherwise (raw CLI)    → surface a precise actionable
        //                              error with no in-process prompt.
        let authState = SpeechPermission.current()
        switch authState {
        case .authorized:
            break
        case .denied, .restricted:
            throw MacrecError.transcriptionPermissionDenied(provider: "apple-cloud")
        case .notDetermined:
            if Self.isRunningFromAppBundle() {
                logger.info("apple-cloud: TCC status notDetermined and running from .app bundle — triggering system Speech Recognition prompt")
                let postPromptState = await SpeechPermission.request()
                guard postPromptState == .authorized else {
                    throw MacrecError.transcriptionPermissionDenied(provider: "apple-cloud")
                }
            } else {
                // Tell the user precisely what to do; do NOT trigger
                // the crash-prone request flow.
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Apple Speech Recognition has not been authorised yet AND macrec-ui is running as a raw CLI binary (not from a .app bundle). Repackage as macrec-ui.app first (the in-process Speech Recognition prompt SIGABRTs ad-hoc-signed CLI binaries on macOS 26). Run `bash scripts/package-macrec-ui-app.sh && open dist/macrec-ui.app` and try again."
                )
            }
        }

        guard let recognizer = SFSpeechRecognizer(locale: resolvedLocale) else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "SFSpeechRecognizer(locale: '\(resolvedLocale.identifier)') returned nil — the locale is not installed."
            )
        }
        guard recognizer.isAvailable else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "SFSpeechRecognizer reports the recognizer for locale '\(resolvedLocale.identifier)' is currently unavailable. Common cause: no network connectivity for the cloud path."
            )
        }

        logger.info(
            "apple-cloud: opening streaming session source=\(source) locale=\(resolvedLocale.identifier)"
        )

        let session = AppleCloudStreamingSession(
            recognizer: recognizer,
            locale: resolvedLocale,
            logger: logger
        )
        await session.open()
        return session
    }
}

// MARK: - Streaming session

/// Actor-isolated `StreamingTranscriptionSession` driving an
/// `SFSpeechRecognitionTask` against the cloud path. Rotates the
/// task every ~55 s to stay inside Apple's per-task audio cap
/// (QA1951). Surfaces partials as `.partial`, finals as `.final`,
/// and any non-fatal recognition errors as `.error`.
public actor AppleCloudStreamingSession: StreamingTranscriptionSession {

    public let events: AsyncStream<StreamingTranscriptionEvent>
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    private let recognizer: SFSpeechRecognizer
    private let locale: Locale
    private let logger: Logger

    /// Audio format matching the macrec pipeline's downsampler output.
    /// Constructed lazily because `AVAudioFormat?` initialiser can
    /// return nil for invalid permutations.
    private let inputFormat: AVAudioFormat

    /// In-flight request being fed via `append(_:)`. Replaced when the
    /// task rotates.
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?

    /// In-flight recognition task. Cancelled and replaced on rotation.
    private var currentTask: SFSpeechRecognitionTask?

    /// One UUID per "open utterance window" so partial → final flips
    /// for the same window keep a stable id (caller's TranscriptionManager
    /// keys on this).
    private var currentUtteranceId: UUID = UUID()

    /// Whether the user has called `finish()`. Stops the rotation timer
    /// and prevents new requests from being created mid-drain.
    private var isFinished: Bool = false

    /// Rotation timer task — cancels the running request before the
    /// 60 s Apple cap and starts a fresh one. Re-armed on every
    /// rotation.
    private var rotationTask: Task<Void, Never>?

    private var metrics = StreamingProviderMetrics()

    public init(
        recognizer: SFSpeechRecognizer,
        locale: Locale,
        logger: Logger
    ) {
        self.recognizer = recognizer
        self.locale = locale
        self.logger = logger

        // 16 kHz mono Float32 — the format every macrec provider
        // receives from the shared downsampler (see
        // `RecordingSession.setUpTranscriptionPipelineIfNeeded`).
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppleCloudTranscriptionProvider.expectedSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            // The init can't throw, so we fall back to a format that's
            // guaranteed to construct. Caller will receive a wire-side
            // failure when ingest tries to copy mismatched samples; the
            // factory's pre-flight makes this branch unreachable.
            self.inputFormat = AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1
            )!
            var continuationHandle: AsyncStream<StreamingTranscriptionEvent>.Continuation!
            self.events = AsyncStream { continuationHandle = $0 }
            self.eventsContinuation = continuationHandle
            return
        }
        self.inputFormat = format

        var continuationHandle: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream { continuationHandle = $0 }
        self.eventsContinuation = continuationHandle
    }

    // MARK: - StreamingTranscriptionSession

    public func ingest(_ samples: [Float]) async {
        guard !isFinished else { return }
        guard !samples.isEmpty else { return }
        guard let request = currentRequest else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ) else {
            logger.warning("apple-cloud: failed to allocate AVAudioPCMBuffer for \(samples.count) frames")
            return
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        request.append(buffer)
    }

    public func finish() async {
        guard !isFinished else { return }
        isFinished = true
        rotationTask?.cancel()
        rotationTask = nil

        currentRequest?.endAudio()
        // Note: do NOT cancel the task here — let the in-flight
        // final result land on the result handler so the caller
        // sees the last utterance. We finish the events stream from
        // inside the result handler when the task naturally ends.
        // Belt-and-braces: emit a final-metrics snapshot now so the
        // UI's metrics overlay updates immediately on user-driven stop.
        eventsContinuation.yield(.metrics(metrics))

        // If the task never produced a result (e.g. user hit Stop
        // immediately after Start with no audio), give the runtime a
        // brief window to drain, then finish the stream regardless.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s
            await self?.forceFinishIfStillOpen()
        }
    }

    /// Opens the first request + task. Called by the provider after
    /// construction.
    public func open() async {
        startNewRecognitionTask()
        scheduleRotation()
    }

    // MARK: - Internals

    private func startNewRecognitionTask() {
        guard !isFinished else { return }

        // Mint a fresh utterance id for the new window so the caller's
        // `TranscriptionManager` treats it as a new utterance instead
        // of revising the previous one across the rotation seam.
        currentUtteranceId = UUID()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Force the cloud path — the on-device path is already exposed
        // as the separate `apple` provider, and on the user's Mac the
        // el-GR on-device asset is unavailable.
        request.requiresOnDeviceRecognition = false
        // Bias toward dictation usage (continuous speech) so Apple's
        // server doesn't apply the short-form / Siri-command formatter.
        if #available(macOS 13.0, *) {
            request.taskHint = .dictation
        }

        currentRequest = request

        let openedAt = Date()
        let utteranceId = currentUtteranceId
        currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The result/error callback fires on an internal queue;
            // hop back into the actor to mutate state.
            Task { [weak self] in
                await self?.handleResult(
                    result: result,
                    error: error,
                    utteranceId: utteranceId,
                    openedAt: openedAt
                )
            }
        }

        logger.info("apple-cloud: opened recognition task locale=\(locale.identifier) utterance=\(utteranceId.uuidString.prefix(8))")
    }

    private func handleResult(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        utteranceId: UUID,
        openedAt: Date
    ) async {
        if let error = error as NSError? {
            // Some "errors" are just the natural end-of-task signal
            // when `endAudio()` was called and there was no audio
            // left to recognise — surface as info, not error.
            //
            // Apple's framework returns:
            //   * `kAFAssistantErrorDomain code 1110` → "no speech
            //     detected" — informational, common on short silences.
            //   * `kAFAssistantErrorDomain code 1101` → unauthorized
            //     (TCC denied mid-session) — fatal.
            //   * `NSURLErrorDomain` codes → network failures —
            //     fatal for that task; we close the events stream.
            //   * On normal `endAudio()` + drain we can also get
            //     code 216 ("session ended") — informational.
            let code = error.code
            let domain = error.domain
            let isInformational = (code == 1110 || code == 216)
            if isInformational {
                logger.info("apple-cloud: task ended (\(domain) code=\(code))")
            } else {
                metrics.errorCount += 1
                logger.error("apple-cloud: recognition error \(domain) code=\(code): \(error.localizedDescription)")
                eventsContinuation.yield(.error(detail: "Apple Cloud: \(error.localizedDescription) (\(domain) #\(code))"))
            }
            // Whether informational or fatal, the active task is done.
            // If the session is still alive AND we haven't hit a
            // hard auth failure, start a fresh task so the next ingest
            // continues to flow.
            currentTask = nil
            currentRequest = nil
            if isFinished {
                eventsContinuation.yield(.metrics(metrics))
                eventsContinuation.finish()
            } else if !isInformational, code == 1101 {
                // Auth revoked mid-session — do not retry.
                eventsContinuation.yield(.metrics(metrics))
                eventsContinuation.finish()
                isFinished = true
            } else {
                startNewRecognitionTask()
            }
            return
        }

        guard let result else { return }

        let text = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            metrics.finalsEmitted += 1
            metrics.lastFinalLatencyMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            let now = Date()
            eventsContinuation.yield(
                .final(
                    utteranceId: utteranceId,
                    text: text,
                    confidence: nil,
                    range: openedAt...now,
                    language: locale.identifier
                )
            )
            // Apple's task closes itself after a final; clear our
            // refs and start a fresh one (or finish if user stopped).
            currentTask = nil
            currentRequest = nil
            if isFinished {
                eventsContinuation.yield(.metrics(metrics))
                eventsContinuation.finish()
            } else {
                startNewRecognitionTask()
            }
        } else {
            metrics.partialsEmitted += 1
            metrics.lastPartialLatencyMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            eventsContinuation.yield(
                .partial(
                    utteranceId: utteranceId,
                    text: text,
                    confidence: nil
                )
            )
        }
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            let nanos = UInt64(AppleCloudTranscriptionProvider.taskRotationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.rotateTask()
        }
    }

    private func rotateTask() async {
        guard !isFinished else { return }
        logger.info("apple-cloud: rotating recognition task at \(AppleCloudTranscriptionProvider.taskRotationSeconds)s to stay under Apple's per-task audio cap")
        // Politely close the current request — the result handler will
        // fire one final result for the closing window, then start a
        // fresh task via the same handler.
        currentRequest?.endAudio()
        // Do NOT call `currentTask?.cancel()` — that drops the in-flight
        // final on the floor. `endAudio()` triggers the natural drain.
        // Re-arm the rotation timer for the next window.
        scheduleRotation()
    }

    /// Belt-and-braces finalisation in case the recognition task never
    /// produced a result (very short recordings, immediate auth denial,
    /// etc.). Runs from the post-`finish()` deferred Task.
    private func forceFinishIfStillOpen() {
        guard isFinished else { return }
        // If the result handler already finished the stream this is a
        // no-op (AsyncStream.Continuation.finish() is idempotent).
        eventsContinuation.yield(.metrics(metrics))
        eventsContinuation.finish()
    }
}
