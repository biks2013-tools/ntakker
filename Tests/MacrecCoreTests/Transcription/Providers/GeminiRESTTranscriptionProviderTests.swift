import Foundation
import Testing
@testable import MacrecCore

@Suite("GeminiRESTTranscriptionProvider", .serialized)
struct GeminiRESTTranscriptionProviderTests {

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil)!
    }

    private func makeProvider(model: String = GeminiRESTTranscriptionProvider.defaultModelId) -> GeminiRESTTranscriptionProvider {
        GeminiRESTStubProtocol.reset()
        return GeminiRESTTranscriptionProvider(
            apiKey: "test-key",
            modelId: model,
            urlSession: GeminiRESTStubProtocol.makeURLSession()
        )
    }

    /// Build a TranscriptionOptions for tests using the existing initializer
    /// in `Sources/MacrecCore/Transcription/TranscriptionOptions.swift`.
    private func makeOptions() -> TranscriptionOptions {
        TranscriptionOptions(
            providerId: "gemini",
            apiKey: "test-key",
            modelId: GeminiRESTTranscriptionProvider.defaultModelId,
            languageHints: [],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
    }

    @Test("happy path returns trimmed text")
    func happyPath() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            let body = #"{"candidates":[{"content":{"parts":[{"text":"  hello world  "}]}}]}"#
            return (self.httpResponse(200), Data(body.utf8))
        }
        let p = makeProvider()
        let out = try await p.transcribe(
            samples: Array(repeating: Float(0.1), count: 16_000),
            source: .microphone, options: makeOptions())
        #expect(out == "hello world")
    }

    @Test("empty candidates returns empty string")
    func emptyCandidates() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            return (self.httpResponse(200), Data("{}".utf8))
        }
        let p = makeProvider()
        let out = try await p.transcribe(
            samples: [0.1], source: .microphone, options: makeOptions())
        #expect(out == "")
    }

    @Test("HTTP 400 throws transcriptionProviderUnavailable mentioning fallback model")
    func http400() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            let body = #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Model does not support generateContent"}}"#
            return (self.httpResponse(400), Data(body.utf8))
        }
        let p = makeProvider()
        do {
            _ = try await p.transcribe(samples: [0.1], source: .microphone, options: makeOptions())
            Issue.record("expected throw")
        } catch let e as MacrecError {
            // TODO(plan-004 Phase G): assert against .transcriptionProviderFailed
            if case .transcriptionProviderUnavailable(let reason) = e {
                #expect(reason.contains("HTTP 400"))
                #expect(reason.contains("gemini-3-flash-preview"))
            } else {
                Issue.record("wrong MacrecError case: \(e)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("request body contains audio/wav inline data")
    func requestBodyShape() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            (self.httpResponse(200), Data(#"{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}"#.utf8))
        }
        let p = makeProvider()
        _ = try await p.transcribe(
            samples: Array(repeating: Float(0.1), count: 16_000),
            source: .microphone, options: makeOptions())
        let body = GeminiRESTStubProtocol.capturedBody ?? Data()
        let s = String(data: body, encoding: .utf8) ?? ""
        #expect(s.contains("\"mimeType\":\"audio/wav\""))
        #expect(s.contains("\"temperature\":0"))
    }

    @Test("URL contains the configured model id and key")
    func requestURL() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            (self.httpResponse(200), Data(#"{"candidates":[]}"#.utf8))
        }
        let p = makeProvider(model: "gemini-3-flash-preview")
        _ = try await p.transcribe(samples: [0.1], source: .microphone, options: makeOptions())
        let url = GeminiRESTStubProtocol.capturedRequest?.url?.absoluteString ?? ""
        #expect(url.contains("/models/gemini-3-flash-preview:generateContent"))
        #expect(url.contains("key=test-key"))
    }
}
