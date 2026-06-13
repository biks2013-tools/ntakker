// Sources/NtakkerCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift
import Foundation
import Logging

/// REST-batch transcription provider for Google Gemini.
/// One `URLSession` data task per `transcribe` call. Stateless across calls.
public struct GeminiRESTTranscriptionProvider: TranscriptionProvider, Sendable {

    /// Default model id for the REST `generateContent` endpoint.
    ///
    /// Was originally `gemini-3.1-flash-live-preview` per user direction
    /// during the plan-004 brainstorming session (2026-04-28). Empirical
    /// confirmation that same day: that model id returns HTTP 404 on the
    /// REST endpoint — it is the Live (WebSocket) API SKU, not a REST SKU.
    /// PEND-LT-6 was closed on 2026-04-28 by switching the default to
    /// `gemini-3-flash-preview`, the documented Google REST audio model
    /// per <https://ai.google.dev/gemini-api/docs/audio>. Override via
    /// `NTAKKER_TRANSCRIBE_MODEL` if a different model is needed.
    public static let defaultModelId = "gemini-3-flash-preview"

    /// Same value as `defaultModelId` since we already moved to it; kept as
    /// a separate symbol for the error-mapping callsites that historically
    /// printed it as the suggested override target.
    public static let knownGoodFallback = "gemini-3-flash-preview"

    /// Allowed list checked at resolver time. Anything outside is logged
    /// as a warning at start but still sent through (so newer GA models
    /// can be opted into without a code change).
    public static let allowedModelIds: Set<String> = [
        "gemini-3.1-flash-live-preview",
        "gemini-3-flash-preview",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash"
    ]

    public let id = "gemini"
    public let displayName = "Gemini"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    private let apiKey: String
    private let modelId: String
    private let urlSession: URLSession
    private let logger: Logger

    public init(
        apiKey: String,
        modelId: String = Self.defaultModelId,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "ntakker-cli.transcription.gemini")
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.urlSession = urlSession
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        let wav = AudioWAVEncoder.encode(samples: samples)
        let base64 = wav.base64EncodedString()

        var prompt = "You are a verbatim audio transcriber. Output only the spoken text from the audio, with no preamble, no narration, no labels, no timestamps. If the audio contains no speech, output an empty string. Preserve the speaker's wording exactly."
        if let lang = options.languageHints.first, !lang.isEmpty {
            prompt += " Audio language: \(lang)."
        }

        let body = GeminiREST.Request(
            contents: [.init(parts: [
                .text(prompt),
                .inlineAudio(mimeType: "audio/wav", base64Data: base64)
            ])],
            generationConfig: .init(temperature: 0.0, candidateCount: 1)
        )

        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent")
        else {
            // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
            throw NtakkerError.transcriptionProviderUnavailable(reason: "could not build URL for model \(modelId)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // F13 (EVAL 2026-06-12): the API key rides a header instead of
        // the query string — query-string keys leak into proxy logs and
        // the URL-bearing error strings this provider throws.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        // F13: bound each attempt — the URLSession default of 60 s let
        // one stuck request pin an in-flight slot for a minute.
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await postWithRetries(request)

        if !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "(non-utf8 body)"
            let parsed = try? JSONDecoder().decode(GeminiREST.Response.self, from: data)
            let google = parsed?.error.map { e in
                " (\(e.status ?? "UNKNOWN") \(e.code.map(String.init) ?? "-"): \(e.message ?? "no message"))"
            } ?? ""
            // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "HTTP \(http.statusCode)\(google). Body: \(bodyText.prefix(200)). Try setting NTAKKER_TRANSCRIBE_MODEL=\(Self.knownGoodFallback) (per https://ai.google.dev/gemini-api/docs/audio)."
            )
        }

        let parsed: GeminiREST.Response
        do {
            parsed = try JSONDecoder().decode(GeminiREST.Response.self, from: data)
        } catch {
            // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "response decode failed: \(error.localizedDescription)"
            )
        }

        let raw = parsed.candidates?.first?.content?.parts?.first?.text ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Retry (F13, EVAL 2026-06-12)

    /// Statuses worth a retry — mirrors the Azure batch / ElevenLabs
    /// retry policy (consolidating the three copies into a shared
    /// `HTTPRetryPolicy` is tracked as eval finding F31).
    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
    private static let maxAttempts = 3

    /// Transient `URLError` codes worth a retry.
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .dnsLookupFailed, .notConnectedToInternet
    ]

    /// POST with up to `maxAttempts` attempts. Retries transient
    /// `URLError`s and retryable HTTP statuses, honouring `Retry-After`
    /// when present, otherwise 0.5 · 2ⁿ s with ±20 % jitter. Before
    /// F13 a single network blip cost the whole 2.5 s chunk — over a
    /// long session that measurably degraded transcript completeness.
    private func postWithRetries(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 1...Self.maxAttempts {
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
                    throw NtakkerError.transcriptionProviderUnavailable(reason: "non-HTTP response")
                }
                if Self.retryableStatuses.contains(http.statusCode), attempt < Self.maxAttempts {
                    let delay = Self.retryDelay(for: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    logger.warning("gemini: HTTP \(http.statusCode) — retrying in \(String(format: "%.1f", delay))s (attempt \(attempt)/\(Self.maxAttempts))")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, http)
            } catch let urlError as URLError
                where Self.transientURLErrorCodes.contains(urlError.code) && attempt < Self.maxAttempts {
                let delay = Self.retryDelay(for: attempt, retryAfter: nil)
                logger.warning("gemini: transient network error (\(urlError.code.rawValue)) — retrying in \(String(format: "%.1f", delay))s (attempt \(attempt)/\(Self.maxAttempts))")
                lastError = urlError
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch let ntakkerError as NtakkerError {
                throw ntakkerError
            } catch {
                // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
                throw NtakkerError.transcriptionProviderUnavailable(
                    reason: "URLSession error: \(error.localizedDescription). Try setting NTAKKER_TRANSCRIBE_MODEL=\(Self.knownGoodFallback)."
                )
            }
        }
        // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
        throw NtakkerError.transcriptionProviderUnavailable(
            reason: "URLSession error after \(Self.maxAttempts) attempts: \(lastError?.localizedDescription ?? "unknown"). Try setting NTAKKER_TRANSCRIBE_MODEL=\(Self.knownGoodFallback)."
        )
    }

    private static func retryDelay(for attempt: Int, retryAfter: String?) -> Double {
        if let retryAfter, let seconds = Double(retryAfter), seconds >= 0 {
            return min(seconds, 30)
        }
        let base = 0.5 * pow(2.0, Double(attempt - 1))
        return base * Double.random(in: 0.8...1.2)
    }

    /// Gemini REST is a batch-only provider. Plan-005 routes streaming
    /// requests to `--transcribe apple` (Apple Speech). Any attempt to
    /// open a streaming session here surfaces a configuration-conflict
    /// error so the user is told exactly which provider to switch to.
    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw NtakkerError.transcriptionConfigConflict(
            reason: "Gemini REST provider does not support streaming; use --transcribe apple for streaming"
        )
    }
}
