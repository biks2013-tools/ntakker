// MacrecCore/Asking/GoogleGeminiAskClient.swift — plan-015 Phase 4.
// Gemini streamGenerateContent SSE client.
//
// Wire shape (https://ai.google.dev/api/generate-content#method:-models.streamgeneratecontent):
//   POST  {endpoint}/models/<model>:streamGenerateContent?alt=sse&key=<apikey>
//   Body: { systemInstruction: {parts:[{text:…}]},
//           contents: [{ role:"user", parts:[{text:…}] }] }
//
// SSE events: `data: {json}\n\n` where `json.candidates[0].content.parts[*].text`
// carries the token deltas. End-of-stream is signalled by closing the
// connection (no explicit `[DONE]`).

import Foundation

struct GoogleGeminiAskClient: AskClient {

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
                        var bodyBytes: [UInt8] = []
                        for try await b in bytes {
                            bodyBytes.append(b)
                            if bodyBytes.count > 2048 { break }
                        }
                        let body = String(decoding: bodyBytes, as: UTF8.self)
                        continuation.finish(throwing: MacrecError.transcriptionProviderUnavailable(
                            reason: "HTTP \(http.statusCode) from Gemini: \(body)"
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
        guard let key = config.apiKey else {
            throw MacrecError.missingRequiredConfig(
                key: "GOOGLE_API_KEY",
                sourcesChecked: AskConfigResolver.canonicalSources
            )
        }
        var comps = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + "/models/" + percentEncode(config.model) + ":streamGenerateContent"
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "alt",  value: "sse"))
        items.append(URLQueryItem(name: "key",  value: key))
        comps.queryItems = items
        guard let url = comps.url else {
            throw MacrecError.invalidConfigValue(
                key: "GOOGLE_BASE_URL",
                value: config.endpoint.absoluteString,
                expected: "absolute URL"
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = GeminiRequest(
            systemInstruction: .init(parts: [.init(text: system)]),
            contents: [.init(role: "user", parts: [.init(text: user)])]
        )
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func parseDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(GeminiStreamChunk.self, from: data) else { return nil }
        guard let cand = parsed.candidates?.first else { return nil }
        let parts = cand.content?.parts ?? []
        let text = parts.compactMap { $0.text }.joined()
        return text.isEmpty ? nil : text
    }

    private func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

// MARK: - Wire types

private struct GeminiRequest: Encodable {
    struct Part: Encodable { let text: String }
    struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }
    struct SystemInstruction: Encodable { let parts: [Part] }
    let systemInstruction: SystemInstruction
    let contents: [Content]
}

private struct GeminiStreamChunk: Decodable {
    struct Part: Decodable { let text: String? }
    struct Content: Decodable { let parts: [Part]? }
    struct Candidate: Decodable { let content: Content? }
    let candidates: [Candidate]?
}
