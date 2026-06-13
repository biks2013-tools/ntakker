// NtakkerCore/Asking/OpenAICompatibleAskClient.swift — plan-015 Phase 4.
// Single client that drives the six providers whose chat-completions
// wire format matches OpenAI's:
//   * `openai`             — POST {base}/chat/completions  (Bearer)
//   * `azure-openai` (v1)  — POST {base}/openai/v1/chat/completions  (api-key header)
//   * `azure-openai` (leg) — POST {base}/openai/deployments/<d>/chat/completions?api-version=…
//   * `azure-ai-inference` — POST {base}/chat/completions?api-version=…   (api-key header)
//   * `ollama`             — POST {base}/v1/chat/completions   (no auth)
//   * `litellm`            — POST {base}/chat/completions    (optional Bearer)
//   * `mlx`                — POST {base}/chat/completions   (no auth)
//
// All six accept the same `{ model, messages, stream }` request body
// and emit the same `data: {json}\n` SSE format (terminated by
// `data: [DONE]`).
//
// FR-IRQ-8: streamed token-by-token via SSE — the UI's typing indicator
// reacts to each yielded delta.

import Foundation

struct OpenAICompatibleAskClient: AskClient {

    let config: AskConfig
    let urlSession: URLSession

    init(config: AskConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    func streamChat(
        system: String,
        user: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(system: system, user: user)
                    let (bytes, response) = try await urlSession.bytes(for: request)

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Try to capture the error body for surfacing in
                        // the inline-error pane.
                        var bodyBytes: [UInt8] = []
                        for try await b in bytes {
                            bodyBytes.append(b)
                            if bodyBytes.count > 2048 { break }
                        }
                        let body = String(decoding: bodyBytes, as: UTF8.self)
                        continuation.finish(throwing: NtakkerError.transcriptionProviderUnavailable(
                            reason: "HTTP \(http.statusCode) from \(config.provider.displayName): \(body)"
                        ))
                        return
                    }

                    for try await line in (AsyncLineIterator(bytes: bytes).lines()) {
                        guard let payload = sseDataPayload(line) else { continue }
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        if let delta = parseDelta(payload) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request construction

    private func buildRequest(system: String, user: String) throws -> URLRequest {
        let url = try chatCompletionsURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthHeaders(to: &req)

        let body = OpenAIChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user",   content: user),
            ],
            stream: true
        )
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func chatCompletionsURL() throws -> URL {
        switch config.provider {
        case .openai:
            // base already ends with /v1 by default.
            return config.endpoint.appendingPathComponent("chat/completions")

        case .azureOpenAI:
            // Two URL shapes (legacy deployment-based vs. v1 GA path).
            var comps = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)
                ?? URLComponents()
            if comps.scheme == nil { comps.scheme = "https" }
            if comps.host == nil, let host = config.endpoint.host {
                comps.host = host
            }
            if let apiVersion = config.azureAPIVersion {
                // Legacy: /openai/deployments/<deployment>/chat/completions?api-version=…
                let path = trimTrailingSlash(comps.path)
                    + "/openai/deployments/\(percentEncode(config.model))/chat/completions"
                comps.path = path
                comps.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
            } else {
                // v1 GA: /openai/v1/chat/completions  (no api-version).
                let path = trimTrailingSlash(comps.path) + "/openai/v1/chat/completions"
                comps.path = path
            }
            guard let url = comps.url else {
                throw NtakkerError.invalidConfigValue(
                    key: "AZURE_OPENAI_ENDPOINT",
                    value: config.endpoint.absoluteString,
                    expected: "absolute URL"
                )
            }
            return url

        case .azureAIInference:
            // Foundry inference endpoint: <base>/chat/completions?api-version=…
            var comps = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)
                ?? URLComponents()
            let path = trimTrailingSlash(comps.path) + "/chat/completions"
            comps.path = path
            if let v = config.azureAPIVersion {
                comps.queryItems = [URLQueryItem(name: "api-version", value: v)]
            }
            guard let url = comps.url else {
                throw NtakkerError.invalidConfigValue(
                    key: "AZURE_AI_INFERENCE_ENDPOINT",
                    value: config.endpoint.absoluteString,
                    expected: "absolute URL"
                )
            }
            return url

        case .ollama:
            // Ollama exposes the OpenAI-compat surface at /v1/chat/completions.
            return config.endpoint.appendingPathComponent("v1/chat/completions")

        case .litellm, .mlx:
            // Both sit behind an OpenAI-compatible reverse proxy.
            return config.endpoint.appendingPathComponent("chat/completions")

        case .anthropic, .google:
            preconditionFailure("OpenAICompatibleAskClient called for non-OpenAI provider \(config.provider.rawValue)")
        }
    }

    private func applyAuthHeaders(to req: inout URLRequest) {
        switch config.provider {
        case .azureOpenAI, .azureAIInference:
            if let key = config.apiKey { req.setValue(key, forHTTPHeaderField: "api-key") }
        case .openai, .litellm:
            if let key = config.apiKey {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .ollama, .mlx:
            // No auth header by convention.
            break
        case .anthropic, .google:
            break
        }
    }

    // MARK: - SSE parsing

    /// Extract the payload portion of a `data: …` SSE line. Returns
    /// `nil` for non-`data` lines (comments, `event:` lines, blank).
    private func sseDataPayload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Parse one OpenAI streaming chunk JSON into a token delta string.
    /// Returns `nil` when the chunk carries no text (e.g. role-only
    /// preamble, function-call deltas).
    private func parseDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else { return nil }
        guard let first = parsed.choices.first else { return nil }
        return first.delta.content
    }

    private func trimTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

// MARK: - Wire types

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [AskChatMessage]
    let stream: Bool
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}
