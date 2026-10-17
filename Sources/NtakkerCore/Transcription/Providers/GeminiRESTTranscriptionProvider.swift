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

        // TR-10: an auth failure is a configuration error no retry can
        // fix — map it so the circuit breaker trips permanently.
        if http.statusCode == 401 {
            throw NtakkerError.transcriptionApiKeyMissing(provider: "gemini")
        }
        if http.statusCode == 403 {
            throw NtakkerError.transcriptionPermissionDenied(provider: "gemini")
        }
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

    // MARK: - Retry (F13 / F31)

    /// The shared REST retry policy (F31). Gemini backs off from 0.5 s;
    /// `Retry-After` is honoured up to `HTTPRetryPolicy.maxRetryAfterSeconds`.
    private static let retryPolicy = HTTPRetryPolicy(
        label: "gemini",
        retryableStatuses: [429, 500, 502, 503, 504],
        baseDelay: 0.5
    )

    /// POST with retries. Before F13 a single network blip cost the
    /// whole chunk — over a long session that measurably degraded
    /// transcript completeness.
    private func postWithRetries(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await Self.retryPolicy.send(request, session: urlSession, logger: logger)
        } catch is HTTPRetryPolicy.NonHTTPResponse {
            // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
            throw NtakkerError.transcriptionProviderUnavailable(reason: "non-HTTP response")
        } catch {
            // TODO(plan-004 Phase G): rename to .transcriptionProviderFailed(detail:)
            throw NtakkerError.transcriptionProviderUnavailable(
                reason: "URLSession error: \(error.localizedDescription). Try setting NTAKKER_TRANSCRIBE_MODEL=\(Self.knownGoodFallback)."
            )
        }
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
