// NtakkerCore/Transcription/Providers/WhisperKitTranscriptionProvider.swift
//
// On-device transcription via Argmax's WhisperKit (OpenAI Whisper
// large-v3 multilingual ported to CoreML / Apple Neural Engine).
//
// Why this provider exists alongside Apple Speech:
//   * Apple Speech (`SpeechAnalyzer`) is the on-device default, but
//     its language coverage is gated by the on-device asset shipped
//     by Apple's `AssetInventory`. For some locales — confirmed
//     2026-04-29 with `el-GR` (Greek) — Apple has NOT shipped the
//     downloadable model, so the analyzer fails to start and the
//     pipeline produces nothing. There is no workaround on Apple's
//     side; the asset just isn't available.
//   * Whisper large-v3 is MULTILINGUAL out of the box (~99 languages
//     including Greek, Turkish, Arabic, Hindi, Vietnamese, etc.) and
//     runs entirely on-device once the model is downloaded once.
//   * We retain Apple Speech as the default (lower latency, no
//     download, lighter on RAM) and offer WhisperKit as the
//     "use this when Apple's model isn't available for your
//     language" fallback.
//
// Mode: BATCH ONLY. WhisperKit's pipeline is fundamentally chunk-at-
// a-time (it sees 30-second windows the model was trained on), so
// the streaming surface throws `transcriptionConfigConflict` per the
// same contract `FakeTranscriptionProvider` uses.
//
// Threading: `actor`-isolated so the lazy `load` is naturally
// deduplicated under concurrent first-call contention from
// `TranscriptionManager` (up to 2 parallel calls per source).
//
// First-call cost: the default model is ~620 MB and is downloaded by
// WhisperKit on first use (cached under the user's `Documents/
// huggingface/` per WhisperKit's defaults). Subsequent app runs
// reuse the cached model and load in a few hundred ms.

import Foundation
import Logging
import WhisperKit

/// `TranscriptionProvider` backed by WhisperKit (multilingual, on-
/// device). Public `displayName` includes the model id so the UI can
/// surface which exact variant is in use without an extra accessor.
public actor WhisperKitTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "whisperkit"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.batch]

    /// Default model name. `large-v3` is the multilingual flagship
    /// (~99 languages); the date-stamped suffix matches the canonical
    /// CoreML export Argmax ships in their HuggingFace model repo.
    /// Mirrors what the sibling `notch` project uses in production.
    public static let defaultModelName = "openai_whisper-large-v3-v20240930_626MB"

    public nonisolated var displayName: String {
        // Strip the long date-stamp+size suffix for a friendlier
        // surface label. `openai_whisper-large-v3-v20240930_626MB`
        // → `openai_whisper-large-v3`.
        if let underscoreV = modelName.range(of: "-v2024") {
            return "WhisperKit (\(modelName[..<underscoreV.lowerBound]))"
        }
        return "WhisperKit (\(modelName))"
    }

    private nonisolated let modelName: String
    /// Optional language override (bare ISO-639-1, e.g. `en`, `el`).
    /// `nil` → Whisper auto-detects per chunk.
    private nonisolated let configuredLanguage: String?
    /// Optional task override — `transcribe` (default) or `translate`.
    /// `nil` → `transcribe`. Validated by the resolver before reaching
    /// here, so any non-nil value is one of the two known strings.
    private nonisolated let configuredTask: String?
    /// Optional decoding temperature `0.0...1.0`. `nil` → 0 (verbatim).
    private nonisolated let configuredTemperature: Float?
    /// Word-timestamp toggle. `nil` → false.
    private nonisolated let configuredWordTimestamps: Bool?
    private let logger: Logger

    /// The loaded pipeline. `nil` until the first `transcribe` call
    /// completes its lazy load.
    private var pipe: WhisperKit?

    /// In-flight load task. Multiple concurrent first-callers all
    /// `await` the same task so we never run two `WhisperKit(config)`
    /// initialisers in parallel (which would double-download the
    /// model on a fresh machine).
    private var loadTask: Task<WhisperKit, Error>?

    /// Serialises engine calls — `WhisperKit` is not re-entrant
    /// (EVAL-2026-10-16 TR-1; see `InferenceGate`).
    private let inferenceGate = InferenceGate()

    public init(
        // `actor` types can't reference `Self` in default-argument
        // expressions (Swift covariant-Self limitation), hence the
        // explicit type name here.
        modelName: String = WhisperKitTranscriptionProvider.defaultModelName,
        language: String? = nil,
        task: String? = nil,
        temperature: Float? = nil,
        wordTimestamps: Bool? = nil,
        logger: Logger = Logger(label: "ntakker-cli.transcription.whisperkit")
    ) {
        self.modelName = modelName
        self.configuredLanguage = language
        self.configuredTask = task
        self.configuredTemperature = temperature
        self.configuredWordTimestamps = wordTimestamps
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // WhisperKit needs at least ~400 ms of 16 kHz audio (6_400
        // samples) to produce anything meaningful. Below that the
        // model just returns empty / hallucinated tokens. Treat
        // sub-threshold input as silence per the protocol contract
        // ("Returns "" for non-speech input — does NOT throw").
        guard samples.count >= 6_400 else { return "" }

        let pipe: WhisperKit
        do {
            pipe = try await ensureLoaded()
        } catch {
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "WhisperKit failed to load model '\(modelName)': \(error.localizedDescription)"
            )
        }

        let decode = decodingOptions(from: options)
        await inferenceGate.acquire()
        do {
            let results = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: decode
            )
            await inferenceGate.release()
            let combined = results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug(
                "WhisperKit chunk: in=\(samples.count) results=\(results.count) outLen=\(combined.count)"
            )
            return combined
        } catch {
            await inferenceGate.release()
            logger.error("WhisperKit transcribe failed: \(error.localizedDescription)")
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "WhisperKit transcribe error: \(error.localizedDescription)"
            )
        }
    }

    /// Streaming is not supported. The WhisperKit pipeline is
    /// chunk-at-a-time and the protocol's streaming surface expects
    /// volatile partials + stable finals — a shape WhisperKit does
    /// not produce. The factory should never wire WhisperKit through
    /// the streaming path; this is the loud-failure hatch in case it
    /// somehow does.
    public nonisolated func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw NtakkerError.transcriptionConfigConflict(
            reason: "WhisperKit provider is batch-only; streaming mode is not supported. Use 'apple' for streaming on macOS 26+."
        )
    }

    // MARK: - Internals

    /// Lazy, deduplicated WhisperKit pipeline construction. The
    /// first caller spawns the load task; subsequent concurrent
    /// callers `await` the same task. Once the load completes the
    /// task slot is cleared and the resolved pipeline is cached.
    private func ensureLoaded() async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }

        let logger = self.logger
        let modelName = self.modelName
        logger.info("WhisperKit loading model '\(modelName)' (first launch may download ~620MB; cached after)")
        let task = Task { () throws -> WhisperKit in
            let started = Date()
            let config = WhisperKitConfig(model: modelName)
            let pipe = try await WhisperKit(config)
            let elapsed = Int(Date().timeIntervalSince(started))
            logger.info("WhisperKit model '\(modelName)' loaded in \(elapsed)s")
            return pipe
        }
        loadTask = task
        do {
            let resolved = try await task.value
            pipe = resolved
            loadTask = nil
            return resolved
        } catch {
            // Clear the task slot so a future caller can retry the
            // load (e.g. after the user fixes a network blip during
            // the initial download).
            loadTask = nil
            throw error
        }
    }

    /// Map the project's `TranscriptionOptions` onto WhisperKit's
    /// `DecodingOptions`.
    ///
    /// Resolution precedence (highest first):
    ///   * `configuredLanguage` (`NTAKKER_WHISPERKIT_LANGUAGE` —
    ///     persisted in the WhisperKit Settings panel) wins. Bare
    ///     ISO-639-1 (e.g. `el`).
    ///   * Else the first BCP-47 entry in `opts.languageHints` is
    ///     truncated to its bare language part (`"el-GR"` → `"el"`).
    ///   * Else WhisperKit auto-detects per chunk.
    ///
    /// Other configured knobs (`task`, `temperature`,
    /// `wordTimestamps`) override the WhisperKit defaults whenever the
    /// user has set them. Temperature defaults to `0` (verbatim,
    /// lowest hallucination — the recorder's downstream coalescer
    /// relies on repeatable text across chunks).
    private nonisolated func decodingOptions(
        from opts: TranscriptionOptions
    ) -> DecodingOptions {
        var d = DecodingOptions()
        d.temperature = configuredTemperature ?? 0

        if let lang = configuredLanguage, !lang.isEmpty {
            d.language = lang
        } else if let primary = opts.languageHints.first,
                  let langPart = primary.split(separator: "-").first,
                  !langPart.isEmpty {
            d.language = String(langPart).lowercased()
        }

        // `task` is an enum on WhisperKit's `DecodingOptions`. We map
        // the validated string from the resolver into the enum here
        // so the provider stays the single source of truth on the
        // mapping. `transcribe` is the WhisperKit default; we still
        // assign explicitly so the value is observable in logs.
        switch configuredTask?.lowercased() {
        case "translate":
            d.task = .translate
        case "transcribe", nil:
            d.task = .transcribe
        default:
            // Defensive — the resolver already validated this; treat
            // an unknown value as `transcribe` so a stale .env entry
            // can't break recording at runtime.
            d.task = .transcribe
        }

        if let wt = configuredWordTimestamps {
            d.wordTimestamps = wt
        }

        return d
    }
}
