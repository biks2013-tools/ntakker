// Sources/MacrecCore/Transcription/Providers/Azure/AzureOpenAITranscriptionProvider.swift —
// plan-007 Phase A1 §A.3.
//
// `TranscriptionProvider` conformer for Azure OpenAI's REST batch
// `gpt-4o-mini-transcribe` deployment. Built directly on Foundation —
// `URLSession` for transport, `MultipartFormDataBuilder` (Phase 0.5)
// for the body, `AudioWAVEncoder` (already in tree) for the 16 kHz
// mono Int16 WAV the deployment accepts.
//
// `supportedModes = [.batch]`. Streaming attempts throw a
// `transcriptionConfigConflict` pointing the user at
// `--transcribe azure-openai-realtime` (the Phase A2 sibling) or
// `--transcribe apple` for the on-device option.

import Foundation
import Logging

public struct AzureOpenAITranscriptionProvider: TranscriptionProvider {

    public let id = "azure"
    public let displayName = "Azure OpenAI"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    /// 25 MB hard cap per research §5. We pre-flight before sending so
    /// the user gets a clear error instead of an opaque HTTP 413.
    public static let maxPayloadBytes: Int = 25 * 1024 * 1024

    private let config: AzureOpenAIConfig
    private let urlSession: URLSession
    private let logger: Logger

    public init(
        config: AzureOpenAIConfig,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "macrec.transcription.azure")
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
        // 1. Encode audio (16 kHz mono Int16 WAV per `AudioWAVEncoder`).
        let wavData = AudioWAVEncoder.encode(samples: samples)

        // 2. Pre-flight size check (research §5).
        guard wavData.count <= Self.maxPayloadBytes else {
            throw mapError(
                AzureOpenAISTTError.fileTooLarge
            )
        }

        // 3. Build URL: {endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version=...
        guard var components = URLComponents(
            url: config.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw mapError(
                AzureOpenAISTTError.invalidRequest(message: "Invalid endpoint URL: \(config.endpoint.absoluteString)")
            )
        }
        components.path = "/openai/deployments/\(config.deployment)/audio/transcriptions"
        components.queryItems = [
            URLQueryItem(name: "api-version", value: config.apiVersion)
        ]
        guard let url = components.url else {
            throw mapError(
                AzureOpenAISTTError.invalidRequest(message: "Could not build Azure URL from components")
            )
        }

        // 4. Build multipart body (research §3 — `model` field MUST equal
        //    deployment name on Azure).
        var multipart = MultipartFormDataBuilder()
        multipart.append(
            field: "file",
            fileNamed: "audio.wav",
            mimeType: "audio/wav",
            data: wavData
        )
        multipart.append(field: "model", value: config.deployment)
        multipart.append(field: "response_format", value: "json")
        // Plan-007 follow-up (2026-04-30): map the project's
        // `[String]` hint array into Azure's single-string `language`
        // + free-form `prompt` shape. Two hints (e.g. "en,el") fold
        // into a prompt-based code-switching nudge per the OpenAI
        // guide's recommended workaround.
        let resolved = AzureLanguageHints.resolve(
            hints: options.languageHints,
            customInstruction: options.customSystemInstruction
        )
        if let lang = resolved.language {
            multipart.append(field: "language", value: lang)
        }
        if let prompt = resolved.prompt, !prompt.isEmpty {
            multipart.append(field: "prompt", value: prompt)
        }
        let (contentType, body) = multipart.build()

        // 5. Build request.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "api-key")  // raw key, not "Bearer"
        request.timeoutInterval = 60

        // 6. POST with retry (research §9).
        let (data, http) = try await postWithRetries(request: request, body: body)

        // 7. Log diagnostic headers (research §10).
        logResponseHeaders(http)

        // 8. Map status → AzureOpenAISTTError → MacrecError if not 2xx.
        if !(200..<300).contains(http.statusCode) {
            try throwForStatus(http: http, body: data)
        }

        // 9. Decode { "text": "..." }.
        do {
            let decoded = try JSONDecoder().decode(AzureOpenAIResponse.self, from: data)
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw mapError(
                AzureOpenAISTTError.unexpectedResponse(statusCode: http.statusCode, body: data)
            )
        }
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Azure provider does not support streaming in batch mode (use --transcribe azure-openai-realtime for the realtime WebSocket variant, or --transcribe apple for on-device streaming)"
        )
    }

    // MARK: - Internals

    /// Strip a BCP-47 region tag (`en-US` → `en`) so the form field
    /// matches Azure's ISO-639-1 expectation. Returns `nil` for empty
    /// hints so the call site can skip appending the field entirely.
    /// Retained for back-compat with any direct callers; new code
    /// should use `AzureLanguageHints.resolve(...)` instead.
    static func stripBCP47Region(_ hint: String) -> String? {
        let trimmed = hint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let dash = trimmed.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(trimmed[..<dash]).lowercased()
        }
        return trimmed.lowercased()
    }

    private func mapError(_ azureErr: AzureOpenAISTTError) -> MacrecError {
        azureErr.toMacrecError(
            deployment: config.deployment,
            host: config.endpoint.host ?? "unknown"
        )
    }

    /// Inspect the response, raise the right `AzureOpenAISTTError` (via
    /// `throw mapError(...)`). Throws even on 2xx unexpected bodies via
    /// the call site's catch (decoding) path.
    private func throwForStatus(http: HTTPURLResponse, body: Data) throws {
        let envelope = AzureOpenAIErrorEnvelope.decode(from: body)
        let code = envelope?.code?.lowercased() ?? ""
        let message = envelope?.message ?? "(no message)"

        switch http.statusCode {
        case 400:
            if code == "file_too_large" {
                throw mapError(.fileTooLarge)
            }
            if code == "invalid_audio_format" || code == "unsupported_format" {
                throw mapError(.unsupportedAudioFormat)
            }
            throw mapError(.invalidRequest(message: message))
        case 401:
            throw mapError(.invalidApiKey)
        case 403:
            throw mapError(.permissionDenied)
        case 404:
            throw mapError(.deploymentNotFound)
        case 408:
            throw mapError(.networkTimeout)
        case 413:
            throw mapError(.fileTooLarge)
        case 415:
            throw mapError(.unsupportedAudioFormat)
        case 429:
            let retryAfter = Self.parseRetryAfterSeconds(http)
            throw mapError(.rateLimited(retryAfterSec: retryAfter))
        case 500, 503:
            throw mapError(.serverError(statusCode: http.statusCode))
        default:
            throw mapError(.unexpectedResponse(statusCode: http.statusCode, body: body))
        }
    }

    /// Plan-007 §A.3 / research §9 retry policy. Up to 3 attempts;
    /// honour `Retry-After` on 429; exponential backoff with ±20%
    /// jitter on 408 / 500 / 503 / transient `URLError`s.
    private func postWithRetries(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        let maxAttempts = 3
        var lastDelay: Double = 0.0

        while true {
            attempt += 1
            var sendRequest = request
            sendRequest.httpBody = body

            do {
                let (data, response) = try await urlSession.data(for: sendRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw mapError(.unexpectedResponse(statusCode: -1, body: data))
                }
                let shouldRetry = [408, 429, 500, 503].contains(http.statusCode)
                if shouldRetry && attempt < maxAttempts {
                    let delay = Self.delayForRetry(
                        statusCode: http.statusCode,
                        http: http,
                        previous: lastDelay,
                        attempt: attempt
                    )
                    lastDelay = delay
                    logger.warning("azure: HTTP \(http.statusCode); retry \(attempt)/\(maxAttempts) after \(String(format: "%.2f", delay))s")
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
                    let delay = Self.delayForRetry(
                        statusCode: -1,
                        http: nil,
                        previous: lastDelay,
                        attempt: attempt
                    )
                    lastDelay = delay
                    logger.warning("azure: URLError \(err.code.rawValue); retry \(attempt)/\(maxAttempts) after \(String(format: "%.2f", delay))s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw mapError(.networkError(underlying: err))
            }
        }
    }

    /// Compute the next-attempt delay. 429 honours `Retry-After`;
    /// other retryable cases use exponential backoff (1, 2, 4 s) with
    /// ±20% jitter.
    private static func delayForRetry(
        statusCode: Int,
        http: HTTPURLResponse?,
        previous: Double,
        attempt: Int
    ) -> Double {
        if statusCode == 429, let http, let after = parseRetryAfterSeconds(http) {
            return jitter(after)
        }
        let base = pow(2.0, Double(attempt - 1))    // 1, 2, 4
        return jitter(base)
    }

    private static func parseRetryAfterSeconds(_ http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(raw) else { return nil }
        return seconds
    }

    private static func jitter(_ value: Double) -> Double {
        let factor = Double.random(in: 0.8...1.2)
        return value * factor
    }

    /// Surface the response headers research §10 calls out as
    /// support-correlation values. Logged at debug level so they don't
    /// noise up the default log volume.
    private func logResponseHeaders(_ http: HTTPURLResponse) {
        let interesting = [
            "apim-request-id",
            "x-request-id",
            "x-ms-region",
            "x-ratelimit-remaining-requests",
            "x-ratelimit-remaining-tokens"
        ]
        var pieces: [String] = []
        for key in interesting {
            if let value = http.value(forHTTPHeaderField: key) {
                pieces.append("\(key)=\(value)")
            }
        }
        if !pieces.isEmpty {
            logger.debug("azure: response headers \(pieces.joined(separator: " "))")
        }
    }
}
