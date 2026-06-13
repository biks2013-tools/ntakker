// NtakkerCore/Transcription/Providers/SpeechAnalyzerAdapter.swift —
// see docs/design/plan-005-apple-speech-streaming.md §"Phase B".
//
// Phase B (plan-005) — thin protocol over Apple's `SpeechAnalyzer +
// SpeechTranscriber` so the higher-level `AppleSpeechTranscriptionProvider`
// (Phase D) can be unit-tested without ever touching `Speech.framework`.
//
// Two conforming types live in the codebase:
//   * `ProductionSpeechAnalyzerAdapter` (this file) — wraps the real
//     `Speech.SpeechAnalyzer + Speech.SpeechTranscriber` and bridges raw
//     `[Float]` 16 kHz mono samples into `AVAudioPCMBuffer` /
//     `AnalyzerInput` values.
//   * `MockSpeechAnalyzer`   (Tests/.../MockSpeechAnalyzer.swift) — a
//     test double that records ingest/finalize calls and lets the test
//     `push(_:)` canned `TranscriptionResult` values into the stream.
//
// API surface — every test in the suite touches THIS protocol, never
// `Speech.framework` directly. The production adapter's internal API
// choices (PCM buffer format, preset, finalize-mode) are private.

import AVFAudio
import CoreMedia
import Foundation
import Logging
import Speech

/// One transcription result emitted by a `SpeechAnalyzerAdapter`.
///
/// `text` is the verbatim transcript for the result so far. `isFinal`
/// distinguishes a stable final from an in-flight volatile partial.
/// `confidence` is provider-supplied (Apple may report `nil` if the
/// `transcriptionConfidence` attribute was not requested). `timeRange`
/// is the wall-clock range the audio underlying this result spans, when
/// the adapter can derive it from the framework's `CMTimeRange`.
public struct TranscriptionResult: Sendable {
    public let text: String
    public let confidence: Float?
    public let isFinal: Bool
    public let timeRange: ClosedRange<Date>?

    public init(text: String, confidence: Float?, isFinal: Bool, timeRange: ClosedRange<Date>?) {
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.timeRange = timeRange
    }
}

/// Test seam between `AppleSpeechTranscriptionProvider` (Phase D) and
/// the real `Speech.framework`. Implementations are `Sendable` and must
/// be safe for concurrent `ingest(_:)` calls from a single producer.
///
/// Lifecycle:
///   1. The owner constructs the adapter (with a `Locale` for the
///      production conformer).
///   2. The owner attaches a consumer task to `results` BEFORE the
///      first `ingest(_:)` so no events are missed.
///   3. The owner calls `ingest(_:)` zero-or-more times.
///   4. The owner calls `finalizeAndFinish()` once, which drains any
///      buffered audio, waits for the last final result, and closes
///      `results`.
public protocol SpeechAnalyzerAdapter: Sendable {
    /// Append samples to the analyzer. 16 kHz mono Float32 in `[-1, 1]`
    /// is the project-wide pre-normalised contract. Fire-and-forget
    /// from the caller's perspective.
    func ingest(_ samples: [Float]) async

    /// Stream of partial + final results emitted by the underlying
    /// transcriber. Closes after `finalizeAndFinish()` drains.
    var results: AsyncStream<TranscriptionResult> { get }

    /// Stop accepting new samples, flush any in-flight buffered audio,
    /// wait for the final result, then close `results`. Idempotent.
    func finalizeAndFinish() async
}

/// Production conformer for `SpeechAnalyzerAdapter` backed by Apple's
/// `Speech.SpeechAnalyzer + Speech.SpeechTranscriber`. Available only
/// on macOS 26.0+.
///
/// Implementation notes (verified against the macOS 26 SDK
/// `Speech.framework` swiftinterface, 2026-04-27):
///
///   * `SpeechAnalyzer` is an `actor`; we drive it via a single
///     `AsyncStream<AnalyzerInput>` that is started immediately in
///     `init` via `start(inputSequence:)`.
///   * The plan's sketch named `Preset.progressiveLiveTranscription`,
///     which does NOT exist in the live SDK. The real preset names are
///     `.transcription`, `.transcriptionWithAlternatives`,
///     `.timeIndexedTranscriptionWithAlternatives`,
///     `.progressiveTranscription`,
///     `.timeIndexedProgressiveTranscription`. We use
///     `.progressiveTranscription` (the closest match — emits volatile
///     partials followed by stable finals, which is exactly what the
///     streaming pipeline wants).
///   * `SpeechTranscriber.Result.text` is `Foundation.AttributedString`
///     and `String(result.text.characters)` is the documented way to
///     extract the plain text.
///   * Confidence is exposed only when the `Result` is built with the
///     `.transcriptionConfidence` `ResultAttributeOption` — which is
///     NOT in the `progressiveTranscription` preset's default option
///     set, so we report `nil` for now. (Phase D may opt into a custom
///     option set if confidence becomes load-bearing for the UI.)
///   * `result.isFinal` comes from the `SpeechModuleResult` extension.
///   * `CMTimeRange` → `ClosedRange<Date>` mapping is intentionally
///     left as `nil`: the framework's range is relative to the start
///     of the analyzer's audio timeline, not wall-clock. The streaming
///     pipeline (Phase E) is responsible for grafting wall-clock
///     timestamps from `RecordingSession` onto each final.
///   * `ingest(_:)` wraps the incoming `[Float]` into a
///     non-interleaved mono `AVAudioPCMBuffer` at 16 kHz Float32 and
///     yields it through an `AnalyzerInput` (no `bufferStartTime` —
///     the analyzer manages monotonically advancing time itself).
///   * `finalizeAndFinish()` finishes the input continuation (so the
///     analyzer's input sequence terminates) and then awaits
///     `finalizeAndFinishThroughEndOfInput()` which drains the trailing
///     audio and closes the result stream.
@available(macOS 26.0, *)
public final class ProductionSpeechAnalyzerAdapter: SpeechAnalyzerAdapter, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    public let results: AsyncStream<TranscriptionResult>
    private let resultsContinuation: AsyncStream<TranscriptionResult>.Continuation
    private let pcmFormat: AVAudioFormat
    private let logger: Logger
    private let localeId: String

    /// Whether the async setup task succeeded in calling
    /// `analyzer.start(inputSequence:)`. Guards `finalizeAndFinish()`:
    /// calling `analyzer.finalizeAndFinishThroughEndOfInput()` on an
    /// analyzer that never started can hang forever (observed on
    /// 2026-04-28 with locales whose on-device speech model is not
    /// downloadable, e.g. `el-GR`). A failed-to-start adapter must
    /// finish its streams synchronously instead.
    private let startedLock = NSLock()
    private var _analyzerStarted: Bool = false
    private func setAnalyzerStarted(_ value: Bool) {
        startedLock.lock(); defer { startedLock.unlock() }
        _analyzerStarted = value
    }
    private func analyzerStarted() -> Bool {
        startedLock.lock(); defer { startedLock.unlock() }
        return _analyzerStarted
    }

    /// Preset used by the production adapter. `progressiveTranscription`
    /// emits volatile partials followed by stable finals — the exact
    /// shape `StreamingTranscriptionPipeline` (Phase E) wants.
    public static let preset: SpeechTranscriber.Preset = .progressiveTranscription

    /// Sample rate the project standardises on for transcription input
    /// (matches `AudioDownsampler` / Gemini REST). `SpeechTranscriber`
    /// will resample internally if it prefers a different rate.
    public static let sampleRate: Double = 16_000

    public init(
        locale: Locale,
        logger: Logger = Logger(label: "ntakker-cli.transcription.apple.adapter")
    ) throws {
        self.logger = logger
        self.localeId = locale.identifier
        let transcriber = SpeechTranscriber(locale: locale, preset: Self.preset)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let (resStream, resCont) = AsyncStream<TranscriptionResult>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )

        // SpeechAnalyzer requires Int16 PCM samples — the macOS 26
        // framework throws "Failed precondition: Audio sample data must
        // be 16-bit signed integers" if Float32 buffers are yielded.
        // (Empirical finding from the plan-005 Phase I e2e debug
        // session, 2026-04-28.) The adapter still accepts Float32 input
        // from upstream (the project-wide pre-normalised contract) and
        // converts to Int16 inside `ingest(_:)`.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "ProductionSpeechAnalyzerAdapter: failed to construct 16kHz mono Int16 AVAudioFormat"
            )
        }
        self.pcmFormat = format

        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = inputCont
        self.results = resStream
        self.resultsContinuation = resCont

        // Ensure the on-device language pack is installed for this
        // locale, then hand the analyzer the input stream and start it.
        // First-run downloads the model (~tens of MB per locale); cached
        // on subsequent launches. Errors are surfaced as terminal results
        // so the upstream pipeline sees the failure.
        let analyzerRef = analyzer
        let transcriberForAssets = transcriber
        let setupLogger = logger
        let setupLocaleId = localeId
        Task {
            do {
                let status = await AssetInventory.status(forModules: [transcriberForAssets])
                setupLogger.info("Apple Speech: locale=\(setupLocaleId) asset status=\(status)")
                if status != .installed {
                    setupLogger.info("Apple Speech: locale=\(setupLocaleId) requesting asset install (this may take a while on first run)")
                    if let req = try await AssetInventory.assetInstallationRequest(
                        supporting: [transcriberForAssets]
                    ) {
                        try await req.downloadAndInstall()
                        setupLogger.info("Apple Speech: locale=\(setupLocaleId) asset install completed")
                    } else {
                        setupLogger.warning("Apple Speech: locale=\(setupLocaleId) assetInstallationRequest returned nil — model may not be downloadable for this locale")
                    }
                }
                try await analyzerRef.start(inputSequence: inputStream)
                setupLogger.info("Apple Speech: locale=\(setupLocaleId) analyzer started")
                self.setAnalyzerStarted(true)
            } catch {
                setupLogger.error("Apple Speech: locale=\(setupLocaleId) setup failed: \(error.localizedDescription) (\(String(reflecting: error)))")
                // Close BOTH streams. Closing the input continuation
                // here is critical: a later `finalizeAndFinish()` would
                // otherwise block on `finalizeAndFinishThroughEndOfInput`
                // for an analyzer that never started, which hangs the
                // entire recording-stop sequence.
                inputCont.finish()
                resCont.finish()
            }
        }

        // Forward `SpeechTranscriber` results onto our public
        // `AsyncStream<TranscriptionResult>`.
        let transcriberRef = transcriber
        let resultsLogger = logger
        let resultsLocaleId = localeId
        Task {
            do {
                for try await result in transcriberRef.results {
                    let text = String(result.text.characters)
                    let mapped = TranscriptionResult(
                        text: text,
                        confidence: nil,            // see class doc-comment
                        isFinal: result.isFinal,
                        timeRange: nil              // see class doc-comment
                    )
                    resCont.yield(mapped)
                }
                resultsLogger.debug("Apple Speech: locale=\(resultsLocaleId) results stream ended cleanly")
                resCont.finish()
            } catch {
                resultsLogger.error("Apple Speech: locale=\(resultsLocaleId) results loop failed: \(error.localizedDescription) (\(String(reflecting: error)))")
                resCont.finish()
            }
        }
    }

    public func ingest(_ samples: [Float]) async {
        guard !samples.isEmpty,
              let buffer = Self.makePCMBuffer(samples: samples, format: pcmFormat)
        else { return }
        let input = AnalyzerInput(buffer: buffer)
        inputContinuation.yield(input)
    }

    public func finalizeAndFinish() async {
        inputContinuation.finish()
        // If the async setup task never reached `analyzer.start(...)`
        // (asset download failed, locale unsupported, etc.) then
        // `finalizeAndFinishThroughEndOfInput()` can hang forever — it
        // is waiting for an analysis session that never began. Close
        // the result stream synchronously and bail out instead.
        guard analyzerStarted() else {
            logger.warning(
                "Apple Speech: locale=\(localeId) finalize skipped — analyzer never started (likely a setup failure earlier in the session)"
            )
            resultsContinuation.finish()
            return
        }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // The result-forwarding task will close `results` on its
            // own once the transcriber's results stream terminates.
        }
    }

    /// Convenience factory that returns the existential `any
    /// SpeechAnalyzerAdapter` so production wiring (Phase D) can hand
    /// the value to `AppleSpeechTranscriptionProvider` without naming
    /// the concrete class.
    public static func make(
        _ locale: Locale,
        logger: Logger = Logger(label: "ntakker-cli.transcription.apple.adapter")
    ) throws -> any SpeechAnalyzerAdapter {
        try ProductionSpeechAnalyzerAdapter(locale: locale, logger: logger)
    }

    /// Wraps a `[Float]` of 16 kHz mono samples into a freshly-allocated
    /// `AVAudioPCMBuffer` of the analyzer's required Int16 mono format.
    /// Each Float sample is clamped to `[-1, 1]` and quantised to the
    /// full Int16 range. Returns `nil` only if allocation fails.
    private static func makePCMBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.int16ChannelData
        else { return nil }
        buffer.frameLength = frameCount
        // F32 (EVAL 2026-06-12): vDSP-vectorised via the shared
        // PCMConvert (same symmetric 32 767 convention this loop used).
        let ints = PCMConvert.floatToInt16(samples)
        ints.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: ints.count)
        }
        return buffer
    }
}
