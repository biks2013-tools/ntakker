// Sources/NtakkerCore/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift —
// plan-007 Phase B §B.3.

import Foundation
import Logging

public struct ElevenLabsTranscriptionProvider: TranscriptionProvider {

    public let id = "elevenlabs"
    public let displayName = "ElevenLabs Scribe v2"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    /// 3 GB hard cap per research §9.3. Pre-flight before sending so
    /// the user gets a clear error rather than an opaque HTTP 413.
    public static let maxPayloadBytes: Int = 3 * 1024 * 1024 * 1024

    /// 100 ms minimum per research §9.3 (`audio_too_short`).
    public static let minDurationSeconds: Double = 0.1

    /// 4.5 hour maximum per research §9.3 (`audio_too_long`).
    public static let maxDurationSeconds: Double = 4.5 * 3600

    /// Endpoint URL — fixed; ElevenLabs has no per-region routing today.
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    private let config: ElevenLabsConfig
    private let urlSession: URLSession
    private let logger: Logger

    public init(
        config: ElevenLabsConfig,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "ntakker-cli.transcription.elevenlabs")
    ) {
        self.config = config
        self.urlSession = urlSession
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // 1. Encode 16 kHz mono Int16 WAV (matches `pcm_s16le_16`
        //    fast-path contract per §13 EL-3).
        let wavData = AudioWAVEncoder.encode(samples: samples)

        // 2. Pre-flight (research §9.3).
        guard wavData.count <= Self.maxPayloadBytes else {
            throw ElevenLabsSTTError.fileTooLarge.toNtakkerError()
        }
        let durationSec = Double(samples.count) / 16_000.0
        guard durationSec >= Self.minDurationSeconds else {
            // Sub-100 ms chunk — short-circuit to empty transcript per
            // §B.3 step 2; do not waste a request.
            return ""
        }
        guard durationSec <= Self.maxDurationSeconds else {
            throw ElevenLabsSTTError.audioTooLong.toNtakkerError()
        }

        // 3. Build multipart body (research §3 + §B.3).
        var multipart = MultipartFormDataBuilder()
        multipart.append(field: "model_id", value: config.modelId)
        multipart.append(field: "file_format", value: config.fileFormat)
        multipart.append(
            field: "file",
            fileNamed: "audio.wav",
            mimeType: "audio/wav",
            data: wavData
        )
        // Language-code policy — research note 2026-05 (see
        // `docs/reference/elevenlabs-scribe-multilang-diarization-2026-05.md`):
        //   * ElevenLabs has NO multi-language allow-list — `language_code`
        //     is a single string and acts as a SOFT hint.
        //   * Setting `language_code=el` for bilingual Greek+English audio
        //     biases the model so heavily it sometimes drops the English
        //     turns. Our user wants both.
        //   * The official guidance for code-switching content is to omit
        //     `language_code` and let auto-detect handle it.
        // Therefore:
        //   * Explicit `ELEVENLABS_LANGUAGE_CODE` env override (carried
        //     in `config.languageCode`) ALWAYS wins.
        //   * Otherwise: send `language_code` only when the user picked
        //     EXACTLY ONE language hint; ≥2 hints → omit (auto-detect
        //     code-switching mode).
        if let langConfig = config.languageCode, !langConfig.isEmpty {
            multipart.append(field: "language_code", value: langConfig)
            logger.info("elevenlabs: pinning language_code='\(langConfig)' (explicit env override)")
        } else if options.languageHints.count == 1,
                  let single = options.languageHints.first.flatMap(Self.stripBCP47Region(_:))
        {
            multipart.append(field: "language_code", value: single)
            logger.info("elevenlabs: pinning language_code='\(single)' (single hint)")
        } else if options.languageHints.count >= 2 {
            let stripped = options.languageHints
                .compactMap(Self.stripBCP47Region(_:))
                .joined(separator: ",")
            logger.info("elevenlabs: omitting language_code — \(options.languageHints.count) hints (\(stripped)) → auto-detect code-switching mode (ElevenLabs has no hard language allow-list).")
        }
        if config.diarize {
            multipart.append(field: "diarize", value: "true")
        }
        if let n = config.numSpeakers {
            multipart.append(field: "num_speakers", value: String(n))
        }
        // `keyterms` form-field — bias the model toward target vocabulary
        // (added 2026-01-12 to Scribe v2). Limits per the keyterm-prompting
        // guide: ≤50 entries, each ≤20 chars. `ElevenLabsConfig` already
        // enforces those limits at construction time.
        for term in config.keyterms {
            multipart.append(field: "keyterms", value: term)
        }
        multipart.append(
            field: "tag_audio_events",
            value: config.tagAudioEvents ? "true" : "false"
        )
        if let entityDet = config.entityDetection {
            multipart.append(field: "entity_detection", value: entityDet)
        }
        let (contentType, body) = multipart.build()

        // 4. Build request (research §2 — `xi-api-key` header).
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 120  // batch transcripts can run several minutes

        // 5. POST with retry policy (research §8).
        let (data, http) = try await postWithRetries(request: request, body: body)

        // 6. Diagnostic headers (research §9.1).
        logResponseHeaders(http)

        // 7. Map status → typed error → NtakkerError.
        if !(200..<300).contains(http.statusCode) {
            try throwForStatus(http: http, body: data)
        }

        // 8. Decode response.
        do {
            let decoded = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)
            // When diarization is on AND the response actually carried
            // per-word `speaker_id`s, format the transcript as
            // `[Speaker N] …` turns instead of returning the flat
            // `decoded.text` (which discards the speaker information
            // entirely — the visible "wall of text" bug from
            // 2026-05-01).
            if config.diarize, let words = decoded.words,
               words.contains(where: { $0.speakerId != nil })
            {
                return Self.formatDiarizedTranscript(words: words)
            }
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ElevenLabsSTTError.decodingFailure(underlying: error).toNtakkerError()
        }
    }

    /// Group consecutive `words[]` entries by `speaker_id` and emit a
    /// `[Speaker N] …` line per turn. Re-numbers ElevenLabs' opaque
    /// speaker labels (`speaker_0`, `speaker_1`, …) into 1-based,
    /// human-friendly indices in first-appearance order. Words with
    /// no `speaker_id` (e.g. `audio_event` rows or rare untagged
    /// segments) attach to the most recent speaker rather than
    /// breaking the turn. Spacing rows ("type":"spacing") are
    /// preserved to keep punctuation natural.
    static func formatDiarizedTranscript(words: [ElevenLabsResponse.Word]) -> String {
        struct Turn {
            var speakerLabel: String
            var pieces: [String] = []
        }
        var turns: [Turn] = []
        var labelByRawSpeaker: [String: String] = [:]
        var nextLabelNumber = 1

        // Convert ElevenLabs' opaque `speaker_0` → `Speaker 1`, etc.,
        // in first-appearance order so the user sees consistent
        // numbering across recordings.
        func label(forRaw raw: String?) -> String? {
            guard let raw else { return nil }
            if let existing = labelByRawSpeaker[raw] { return existing }
            let label = "Speaker \(nextLabelNumber)"
            nextLabelNumber += 1
            labelByRawSpeaker[raw] = label
            return label
        }

        for word in words {
            // Drop pure-spacing leading entries that don't have any
            // visible text content yet — they would otherwise create
            // an empty leading turn.
            let resolved = label(forRaw: word.speakerId)
            switch (turns.last, resolved) {
            case (nil, let lbl?):
                turns.append(Turn(speakerLabel: lbl, pieces: [word.text]))
            case (nil, nil):
                // First word has no speaker_id — bucket under
                // "Unknown" so we don't drop it.
                turns.append(Turn(speakerLabel: "Speaker ?", pieces: [word.text]))
            case (.some(var last), let lbl?):
                if last.speakerLabel == lbl {
                    last.pieces.append(word.text)
                    turns[turns.count - 1] = last
                } else {
                    turns.append(Turn(speakerLabel: lbl, pieces: [word.text]))
                }
            case (.some(var last), nil):
                last.pieces.append(word.text)
                turns[turns.count - 1] = last
            }
        }

        let lines = turns.map { turn -> String in
            let body = turn.pieces.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(turn.speakerLabel)] \(body)"
        }
        return lines.joined(separator: "\n")
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw NtakkerError.transcriptionConfigConflict(
            reason: "ElevenLabs provider does not support streaming in v1 (scribe_v2_realtime is deferred to a future plan). Use --transcribe apple for streaming."
        )
    }

    // MARK: - Internals

    static func stripBCP47Region(_ hint: String) -> String? {
        let trimmed = hint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let dash = trimmed.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(trimmed[..<dash]).lowercased()
        }
        return trimmed.lowercased()
    }

    private func throwForStatus(http: HTTPURLResponse, body: Data) throws {
        let envelope = ElevenLabsErrorEnvelope.decode(from: body)
        let status = envelope?.detail.status?.lowercased() ?? ""
        let message = envelope?.detail.message ?? "(no message)"

        switch http.statusCode {
        case 400:
            switch status {
            case "audio_too_short":
                throw ElevenLabsSTTError.audioTooShort.toNtakkerError()
            case "invalid_audio_format", "invalid_file_type":
                throw ElevenLabsSTTError.unsupportedFormat.toNtakkerError()
            default:
                throw ElevenLabsSTTError.invalidParameter(field: status, message: message).toNtakkerError()
            }
        case 401:
            throw ElevenLabsSTTError.invalidApiKey.toNtakkerError()
        case 402:
            throw ElevenLabsSTTError.insufficientCredits.toNtakkerError()
        case 403:
            throw ElevenLabsSTTError.planFeatureGate(feature: status).toNtakkerError()
        case 413:
            throw ElevenLabsSTTError.fileTooLarge.toNtakkerError()
        case 422:
            switch status {
            case "audio_too_long":
                throw ElevenLabsSTTError.audioTooLong.toNtakkerError()
            case "invalid_audio_format":
                throw ElevenLabsSTTError.unsupportedFormat.toNtakkerError()
            default:
                throw ElevenLabsSTTError.invalidParameter(field: status, message: message).toNtakkerError()
            }
        case 429:
            if status == "concurrent_limit_exceeded" {
                throw ElevenLabsSTTError.concurrentLimitExceeded.toNtakkerError()
            }
            throw ElevenLabsSTTError.rateLimited(retryAfterSec: nil).toNtakkerError()
        case 500, 503:
            throw ElevenLabsSTTError.serverError(code: http.statusCode).toNtakkerError()
        default:
            throw ElevenLabsSTTError.invalidParameter(field: status, message: "HTTP \(http.statusCode): \(message)").toNtakkerError()
        }
    }

    /// Plan-007 §B.3 retry policy: 3 attempts max, exponential
    /// backoff with ±20% jitter (1, 2, 4 s). ElevenLabs does NOT
    /// return `Retry-After` headers (research §8 footnote). Retry
    /// only on 429 (`rate_limit_exceeded`, `system_busy`), 500, 503,
    /// and transient `URLError`. **Never** retry
    /// `concurrent_limit_exceeded` — surface immediately.
    private func postWithRetries(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        let maxAttempts = 3

        while true {
            attempt += 1
            var sendRequest = request
            sendRequest.httpBody = body

            do {
                let (data, response) = try await urlSession.data(for: sendRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw ElevenLabsSTTError.networkFailure(
                        underlying: NSError(domain: "ElevenLabs", code: -1)
                    ).toNtakkerError()
                }

                // Concurrent-limit: surface immediately, no retry.
                if http.statusCode == 429 {
                    let envelope = ElevenLabsErrorEnvelope.decode(from: data)
                    if envelope?.detail.status?.lowercased() == "concurrent_limit_exceeded" {
                        return (data, http)
                    }
                }

                let isRetryable = [429, 500, 503].contains(http.statusCode)
                if isRetryable && attempt < maxAttempts {
                    let delay = Self.delayForAttempt(attempt)
                    logger.warning("elevenlabs: HTTP \(http.statusCode); retry \(attempt)/\(maxAttempts) after \(String(format: "%.2f", delay))s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, http)
            } catch let err as URLError {
                let transient: Set<URLError.Code> = [
                    .timedOut,
                    .networkConnectionLost,
                    .notConnectedToInternet,
                    .dnsLookupFailed,
                    .cannotConnectToHost
                ]
                if transient.contains(err.code) && attempt < maxAttempts {
                    let delay = Self.delayForAttempt(attempt)
                    logger.warning("elevenlabs: URLError \(err.code.rawValue); retry \(attempt)/\(maxAttempts) after \(String(format: "%.2f", delay))s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw ElevenLabsSTTError.networkFailure(underlying: err).toNtakkerError()
            }
        }
    }

    private static func delayForAttempt(_ attempt: Int) -> Double {
        let base = pow(2.0, Double(attempt - 1))    // 1, 2, 4
        let factor = Double.random(in: 0.8...1.2)
        return min(base * factor, 32.0)
    }

    private func logResponseHeaders(_ http: HTTPURLResponse) {
        let interesting = [
            "current-concurrent-requests",
            "maximum-concurrent-requests",
            "request-id"
        ]
        var pieces: [String] = []
        for key in interesting {
            if let value = http.value(forHTTPHeaderField: key) {
                pieces.append("\(key)=\(value)")
            }
        }
        if !pieces.isEmpty {
            logger.debug("elevenlabs: response headers \(pieces.joined(separator: " "))")
        }
    }
}
