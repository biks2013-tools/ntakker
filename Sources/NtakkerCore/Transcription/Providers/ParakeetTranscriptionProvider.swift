// NtakkerCore/Transcription/Providers/ParakeetTranscriptionProvider.swift
//
// On-device transcription via FluidAudio's port of NVIDIA's
// Parakeet TDT V3 multilingual model (~25 European languages incl.
// Greek, Turkish, Polish, …). Plan-012 Phase B.
//
// Architectural shape mirrors `WhisperKitTranscriptionProvider`:
//   * `actor`; the loaded manager lives in the process-wide
//     `OnDeviceModelCache` (EVAL-2026-10-16 TR-11).
//   * Batch-only — `openStreamingSession(...)` throws
//     `transcriptionConfigConflict` (matches WhisperKit posture).
//   * Lazy ~600 MB model download on first transcribe call
//     (FluidAudio caches under Application Support).
//
// API surface mapped onto FluidAudio v0.8.2:
//   * Model load:   AsrModels.downloadAndLoad(version: .v3)
//   * Manager init: AsrManager(config: .default) +
//                   asrManager.initialize(models: models)
//   * Transcribe:   asrManager.transcribe(samples, source: AudioSource)
//                   returns ASRResult { .text, .tokenTimings, ... }
//
// Notes:
//   * Parakeet TDT V3 multilingual auto-detects the spoken language
//     per chunk; the project's `NTAKKER_PARAKEET_LANGUAGE` /
//     `--parakeet-language` knob is informational only — logged at
//     init but NOT forwarded into the FluidAudio API (it has no
//     per-call language hint surface in v0.8.x). The user-facing
//     env var is kept so the convention stays consistent with
//     WhisperKit and the resolver chain.
//   * `SourceTag` (CaptureSourceTag) maps 1:1 onto FluidAudio's
//     `AudioSource` (`.system` / `.microphone`), letting Parakeet
//     keep separate decoder state per source.

import Foundation
import Logging
import FluidAudio

public actor ParakeetTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id: String = "parakeet"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.batch]

    /// Default Parakeet model version (multilingual TDT-0.6B v3 —
    /// supports the 25 European languages including Greek). The
    /// project's NTAKKER_PARAKEET_MODEL knob is informational only in
    /// v1 because FluidAudio's loader picks the model from the
    /// `AsrModelVersion` enum, not from a free-form string.
    public nonisolated static let defaultModelName = "parakeet-tdt-0.6b-v3"

    public nonisolated var displayName: String {
        "Parakeet (\(modelName))"
    }

    private nonisolated let modelName: String
    /// Optional language override. Informational only — see file
    /// header for why this is not threaded into FluidAudio's API.
    private nonisolated let configuredLanguage: String?
    private let logger: Logger

    /// The loaded ASR manager and its inference gate, from the
    /// process-wide `OnDeviceModelCache` (TR-11). `nil` until the
    /// first `prepare` / `transcribe` call. Shared with every other
    /// Parakeet provider — `AsrManager` is not re-entrant
    /// (EVAL-2026-10-16 TR-1; see `InferenceGate`), and it keeps a
    /// separate decoder state per `source`, so one manager serves both
    /// sides of `--transcribe-source both` (F29).
    private var loaded: CachedInferenceEngine<AsrManager>?

    private let modelCache: OnDeviceModelCache

    /// FluidAudio picks the model from `AsrModelVersion`, not from
    /// `modelName`, so every Parakeet provider shares the v3 engine.
    private static let cacheKey = "parakeet:v3"

    public init(
        modelName: String = ParakeetTranscriptionProvider.defaultModelName,
        language: String? = nil,
        modelCache: OnDeviceModelCache = .shared,
        logger: Logger = Logger(label: "ntakker-cli.transcription.parakeet")
    ) {
        self.modelCache = modelCache
        self.modelName = modelName
        self.configuredLanguage = language
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // FluidAudio's Parakeet pipeline operates on 16 kHz mono Float
        // samples. Sub-threshold input is treated as silence per the
        // protocol contract ("Returns "" for non-speech input — does
        // NOT throw"). The threshold MUST match FluidAudio's own
        // minimum at AsrTranscription.swift:11 — `audioSamples.count
        // >= 16_000` — otherwise short chunks (typically the first
        // drain after recording start, when the buffer has only ~400
        // ms accumulated) reach FluidAudio and trigger
        // `ASRError.invalidAudioData("Must be at least 1 second of
        // 16kHz audio.")`. Mirroring WhisperKit's 6_400 (~400 ms) here
        // is wrong for Parakeet — WhisperKit accepts shorter input,
        // FluidAudio does not. Use 16_000 (1 second @ 16 kHz).
        guard samples.count >= 16_000 else { return "" }

        let loaded: CachedInferenceEngine<AsrManager>
        do {
            loaded = try await ensureLoaded()
        } catch {
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "Parakeet failed to load model '\(modelName)': \(error.localizedDescription)"
            )
        }

        // FluidAudio's `AudioSource` enum is unspellable here (it
        // collides with AVFoundation's `AudioSource` protocol when
        // unqualified, AND the spelling `FluidAudio.AudioSource` is
        // rejected because the FluidAudio module declares a top-level
        // `struct FluidAudio` that the lookup hits first). The only
        // workable spelling is to let the compiler infer the enum type
        // from `AsrManager.transcribe(_:source:)`'s parameter type at
        // the call site — a tiny if/else avoids the unutterable type.
        await modelCache.touch(Self.cacheKey)
        let manager = loaded.engine
        let inferenceGate = loaded.gate
        await inferenceGate.acquire()
        do {
            let result: ASRResult
            if source == .microphone {
                result = try await manager.transcribe(samples, source: .microphone)
            } else {
                result = try await manager.transcribe(samples, source: .system)
            }
            await inferenceGate.release()
            let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            logger.debug("Parakeet chunk: in=\(samples.count) outLen=\(text.count) source=\(source)")
            return text
        } catch {
            await inferenceGate.release()
            logger.error("Parakeet transcribe failed: \(error.localizedDescription)")
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "Parakeet transcribe error: \(error.localizedDescription)"
            )
        }
    }

    /// Streaming is not supported. Parakeet TDT V3 is batch-oriented
    /// in FluidAudio v0.8.x; the project's streaming-protocol surface
    /// expects volatile partials + stable finals — a shape this
    /// provider does not produce. The factory should never wire
    /// Parakeet through the streaming path; this is the loud-failure
    /// hatch in case it somehow does.
    public nonisolated func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw NtakkerError.transcriptionConfigConflict(
            reason: "Parakeet provider is batch-only; streaming mode is not supported. Use 'apple' or 'soniox' for streaming."
        )
    }

    // MARK: - Internals

    /// Load the model now so the first chunk does not wait for it
    /// (F28). Called when the transcription pipeline starts.
    public func prepare() async throws {
        _ = try await ensureLoaded()
    }

    /// The shared AsrManager, loaded at most once per process (TR-11).
    /// Concurrent first callers share one load; a failed load is not
    /// cached, so the next call retries it (e.g. after a network blip
    /// during the first download).
    private func ensureLoaded() async throws -> CachedInferenceEngine<AsrManager> {
        if let loaded { return loaded }
        let logger = self.logger
        let modelName = self.modelName
        if let lang = configuredLanguage, !lang.isEmpty {
            logger.notice("Parakeet language hint '\(lang)' is informational only — FluidAudio v0.8.x has no per-call language API; the multilingual model auto-detects.")
        }
        let resolved = try await modelCache.engine(for: Self.cacheKey) { () async throws -> AsrManager in
            logger.info("Parakeet loading model '\(modelName)' (first launch may download ~600MB; cached after)")
            let started = Date()
            // Multilingual TDT v3 — 25 European languages incl. Greek.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            logger.info("Parakeet model '\(modelName)' loaded in \(Int(Date().timeIntervalSince(started)))s")
            return manager
        }
        loaded = resolved
        return resolved
    }
}
