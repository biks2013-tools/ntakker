// Sources/MacrecCore/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift —
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
        logger: Logger = Logger(label: "macrec.transcription.elevenlabs")
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
            throw ElevenLabsSTTError.fileTooLarge.toMacrecError()
        }
        let durationSec = Double(samples.count) / 16_000.0
        guard durationSec >= Self.minDurationSeconds else {
            // Sub-100 ms chunk — short-circuit to empty transcript per
            // §B.3 step 2; do not waste a request.
            return ""
        }
        guard durationSec <= Self.maxDurationSeconds else {
            throw ElevenLabsSTTError.audioTooLong.toMacrecError()
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
        if let langConfig = config.languageCode, !langConfig.isEmpty {
            multipart.append(field: "language_code", value: langConfig)
        } else if let hint = options.languageHints.first.flatMap(Self.stripBCP47Region(_:)) {
            multipart.append(field: "language_code", value: hint)
        }
        if config.diarize {
            multipart.append(field: "diarize", value: "true")
        }
        if let n = config.numSpeakers {
            multipart.append(field: "num_speakers", value: String(n))
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

        // 7. Map status → typed error → MacrecError.
        if !(200..<300).contains(http.statusCode) {
            try throwForStatus(http: http, body: data)
        }

        // 8. Decode response.
        do {
            let decoded = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ElevenLabsSTTError.decodingFailure(underlying: error).toMacrecError()
        }
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
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
                throw ElevenLabsSTTError.audioTooShort.toMacrecError()
            case "invalid_audio_format", "invalid_file_type":
                throw ElevenLabsSTTError.unsupportedFormat.toMacrecError()
            default:
                throw ElevenLabsSTTError.invalidParameter(field: status, message: message).toMacrecError()
            }
        case 401:
            throw ElevenLabsSTTError.invalidApiKey.toMacrecError()
        case 402:
            throw ElevenLabsSTTError.insufficientCredits.toMacrecError()
        case 403:
            throw ElevenLabsSTTError.planFeatureGate(feature: status).toMacrecError()
        case 413:
            throw ElevenLabsSTTError.fileTooLarge.toMacrecError()
        case 422:
            switch status {
            case "audio_too_long":
                throw ElevenLabsSTTError.audioTooLong.toMacrecError()
            case "invalid_audio_format":
                throw ElevenLabsSTTError.unsupportedFormat.toMacrecError()
            default:
                throw ElevenLabsSTTError.invalidParameter(field: status, message: message).toMacrecError()
            }
        case 429:
            if status == "concurrent_limit_exceeded" {
                throw ElevenLabsSTTError.concurrentLimitExceeded.toMacrecError()
            }
            throw ElevenLabsSTTError.rateLimited(retryAfterSec: nil).toMacrecError()
        case 500, 503:
            throw ElevenLabsSTTError.serverError(code: http.statusCode).toMacrecError()
        default:
            throw ElevenLabsSTTError.invalidParameter(field: status, message: "HTTP \(http.statusCode): \(message)").toMacrecError()
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
                    ).toMacrecError()
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
                throw ElevenLabsSTTError.networkFailure(underlying: err).toMacrecError()
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
