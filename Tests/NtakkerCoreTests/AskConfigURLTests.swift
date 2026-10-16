import Foundation
import Testing
@testable import NtakkerCore

/// EVAL-2026-10-16 INF-7: malformed endpoint overrides used to crash the
/// app through `URL(string: …)!`; they must raise `invalidConfigValue`.
@Suite("AskConfig endpoint URLs")
struct AskConfigURLTests {

    private static func invalidKey(_ body: () throws -> AskConfig) -> String? {
        do {
            _ = try body()
            return nil
        } catch let NtakkerError.invalidConfigValue(key, _, _) {
            return key
        } catch {
            return "unexpected: \(error)"
        }
    }

    @Test("malformed base-URL overrides raise invalidConfigValue for their key")
    func malformedOverridesThrow() {
        let cases: [(provider: String, key: String, extra: [String: String])] = [
            ("openai", "OPENAI_BASE_URL", ["OPENAI_API_KEY": "k"]),
            ("anthropic", "ANTHROPIC_BASE_URL", ["ANTHROPIC_API_KEY": "k"]),
            ("google", "GOOGLE_BASE_URL", ["GOOGLE_API_KEY": "k"]),
            ("ollama", "OLLAMA_HOST", ["NTAKKER_ASK_MODEL": "m"]),
        ]
        for c in cases {
            for bad in ["http://[::1", "not a url", "relative/path"] {
                var env = c.extra
                env["NTAKKER_ASK_PROVIDER"] = c.provider
                env[c.key] = bad
                #expect(Self.invalidKey { try AskConfigResolver.resolve(env: env) } == c.key,
                        "\(c.key)=\(bad)")
            }
        }
    }

    @Test("well-formed overrides are used as the endpoint")
    func validOverride() throws {
        let cfg = try AskConfigResolver.resolve(env: [
            "NTAKKER_ASK_PROVIDER": "openai",
            "OPENAI_API_KEY": "k",
            "OPENAI_BASE_URL": "http://127.0.0.1:8080/v1",
        ])
        #expect(cfg.endpoint.absoluteString == "http://127.0.0.1:8080/v1")
    }
}
