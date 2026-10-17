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
// Threading: `actor`-isolated. The loaded pipeline lives in the
// process-wide `OnDeviceModelCache` (EVAL-2026-10-16 TR-11), which
// deduplicates concurrent loads and shares one engine — and its
// inference gate — between recordings and between the two managers of
// `--transcribe-source both`.
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

    /// TR-2: 10–14 s chunks cut at a pause instead of ~2.5 s fixed
    /// cuts, which the model padded to its full encoder window.
    public nonisolated var chunkPolicy: ChunkPolicy { .onDevice }

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

    /// The loaded pipeline and its inference gate, from the
    /// process-wide `OnDeviceModelCache` (TR-11). `nil` until the
    /// first `prepare` / `transcribe` call. Every provider for the
    /// same model shares the engine and the gate — `WhisperKit` is not
    /// re-entrant (EVAL-2026-10-16 TR-1; see `InferenceGate`).
    private var loaded: CachedInferenceEngine<WhisperKit>?

    private let modelCache: OnDeviceModelCache

    private nonisolated var cacheKey: String { "whisperkit:\(modelName)" }

    public init(
        // `actor` types can't reference `Self` in default-argument
        // expressions (Swift covariant-Self limitation), hence the
        // explicit type name here.
        modelName: String = WhisperKitTranscriptionProvider.defaultModelName,
        language: String? = nil,
        task: String? = nil,
        temperature: Float? = nil,
        wordTimestamps: Bool? = nil,
        modelCache: OnDeviceModelCache = .shared,
        logger: Logger = Logger(label: "ntakker-cli.transcription.whisperkit")
    ) {
        self.modelCache = modelCache
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

        let loaded: CachedInferenceEngine<WhisperKit>
        do {
            loaded = try await ensureLoaded()
        } catch {
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "WhisperKit failed to load model '\(modelName)': \(error.localizedDescription)"
            )
        }
        await modelCache.touch(cacheKey)

        let decode = decodingOptions(from: options)
        let inferenceGate = loaded.gate
        await inferenceGate.acquire()
        do {
            let results = try await loaded.engine.transcribe(
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

    /// Load the model now so the first chunk does not wait for it
    /// (F28). Called when the transcription pipeline starts.
    public func prepare() async throws {
        _ = try await ensureLoaded()
    }

    /// The shared WhisperKit pipeline for `modelName`, loaded at most
    /// once per process (TR-11). Concurrent first callers — two
    /// in-flight chunks, or both managers in source-split mode — share
    /// one load, so the model is never downloaded or compiled twice.
    /// A failed load is not cached; the next call retries it.
    private func ensureLoaded() async throws -> CachedInferenceEngine<WhisperKit> {
        if let loaded { return loaded }
        let logger = self.logger
        let modelName = self.modelName
        let resolved = try await modelCache.engine(for: cacheKey) { () async throws -> WhisperKit in
            logger.info("WhisperKit loading model '\(modelName)' (first launch may download ~620MB; cached after)")
            let started = Date()
            let pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
            logger.info("WhisperKit model '\(modelName)' loaded in \(Int(Date().timeIntervalSince(started)))s")
            return pipe
        }
        loaded = resolved
        return resolved
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
