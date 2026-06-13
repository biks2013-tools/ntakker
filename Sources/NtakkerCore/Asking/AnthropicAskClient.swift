// NtakkerCore/Asking/AnthropicAskClient.swift — plan-015 Phase 4.
// Anthropic Messages API streaming client.
//
// Wire shape (https://docs.anthropic.com/en/api/messages-streaming):
//   POST  {endpoint}/messages
//   Headers: x-api-key, anthropic-version, content-type, accept: text/event-stream
//   Body:    { model, max_tokens, system, messages, stream: true }
//
// SSE events of interest:
//   event: content_block_delta
//   data:  { "type":"content_block_delta",
//            "delta":{ "type":"text_delta", "text":"…" } }
//   event: message_stop  → end-of-stream

import Foundation

struct AnthropicAskClient: AskClient {

    let config: AskConfig
    let urlSession: URLSession
    /// Anthropic requires a pinned `anthropic-version` header. Defaults
    /// to the date used by the SDK at time of writing; override via
    /// `ANTHROPIC_VERSION` in the env (resolved here, not in
    /// `AskConfig`, because no other provider needs it).
    let anthropicVersion: String

    init(config: AskConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
        self.anthropicVersion = ProcessInfo.processInfo.environment["ANTHROPIC_VERSION"]
            ?? "2023-06-01"
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
                        var bodyBytes: [UInt8] = []
                        for try await b in bytes {
                            bodyBytes.append(b)
                            if bodyBytes.count > 2048 { break }
                        }
                        let body = String(decoding: bodyBytes, as: UTF8.self)
                        continuation.finish(throwing: NtakkerError.transcriptionProviderUnavailable(
                            reason: "HTTP \(http.statusCode) from Anthropic: \(body)"
                        ))
                        return
                    }

                    for try await line in (AsyncLineIterator(bytes: bytes).lines()) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = String(trimmed.dropFirst("data:".count))
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if let delta = parseDelta(payload) {
                            continuation.yield(delta)
                        }
                        if isStopEvent(payload) {
                            continuation.finish()
                            return
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

    // MARK: - Request

    private func buildRequest(system: String, user: String) throws -> URLRequest {
        let url = config.endpoint.appendingPathComponent("messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if let key = config.apiKey {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        let body = AnthropicRequest(
            model: config.model,
            max_tokens: 1024,
            system: system,
            messages: [.init(role: "user", content: user)],
            stream: true
        )
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    // MARK: - SSE parsing

    private func parseDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(AnthropicEvent.self, from: data) else { return nil }
        guard parsed.type == "content_block_delta", parsed.delta?.type == "text_delta" else { return nil }
        return parsed.delta?.text
    }

    private func isStopEvent(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8) else { return false }
        guard let parsed = try? JSONDecoder().decode(AnthropicEvent.self, from: data) else { return false }
        return parsed.type == "message_stop"
    }
}

// MARK: - Wire types

private struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [AskChatMessage]
    let stream: Bool
}

private struct AnthropicEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    let type: String
    let delta: Delta?
}
