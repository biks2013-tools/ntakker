// NtakkerCoreTests/Config/SonioxConfigResolverTests.swift —
// plan-006 Phase B (Unit B). See project-design.md §SX-5 and
// plan-006 §6 Configuration / §11 Phase B Task B.9.
//
// Mirrors the existing Gemini patterns in
// `ConfigResolverTranscriptionTests.swift`, but exercises the new
// `SONIOX_API_KEY`, `NTAKKER_SONIOX_ENDPOINT`, and
// `NTAKKER_SONIOX_KEY_EXPIRES_AT` keys plus the `.soniox` enum case
// added in `RecordingOptions.swift`.
//
// Test scope (from the Unit B brief):
//   1. Resolves SONIOX_API_KEY from shell env.
//   2. Resolves SONIOX_API_KEY from ~/.tool-agents/ntakker-cli/.env.
//   3. Resolves SONIOX_API_KEY from local .env.
//   4. Throws `NtakkerError.transcriptionApiKeyMissing(provider: "soniox")`
//      when no source provides it.
//   5. Resolves NTAKKER_SONIOX_ENDPOINT when set; resolves to nil when
//      unset (vendor default applied at provider layer per design SX-5.3).
//   6. Per-provider expiry beats shared:
//      NTAKKER_SONIOX_KEY_EXPIRES_AT="2026-12-31" +
//      NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT="2026-06-30" → 2026-12-31.
//   7. Shared expiry used when per-provider unset.
//   8. Both unset → expiry returns nil.
//   9. Mirror Gemini test patterns from `ConfigResolverTranscriptionTests`.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("ConfigResolver — Soniox provider (plan-006 Phase B)")
struct SonioxConfigResolverTests {

    // MARK: - Test fixtures (mirrors ConfigResolverTranscriptionTests)

    private static let outputPath = "/tmp/ntakker-cli-resolver-soniox.m4a"

    private func resolverWith(
        shell: [String: String] = [:],
        user: [String: String] = [:],
        local: [String: String] = [:]
    ) -> ConfigResolver {
        ConfigResolver(
            toolName: "ntakker-cli",
            shellEnv: shell,
            userEnv: user,
            localEnv: local
        )
    }

    private func baseShell() -> [String: String] {
        ["OUTPUT_PATH": Self.outputPath]
    }

    private func iso8601(_ s: String) -> Date? {
        // Matches `parseOptionalISO8601Date` in ConfigResolver: prefer
        // full ISO-8601, fall back to YYYY-MM-DD as UTC midnight.
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime]
        if let d = isoFull.date(from: s) { return d }
        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .iso8601)
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: s)
    }

    // MARK: - Provider id resolution (SX-9.1)

    @Test("NTAKKER_TRANSCRIBE=soniox selects Soniox provider")
    func transcribeSonioxSelectsSoniox() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-soniox-key",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "soniox")
        #expect(opts.transcriptionApiKey == "test-soniox-key")
    }

    @Test("NTAKKER_TRANSCRIBE=soniox-streaming (close-but-wrong) is rejected with exit 64 (AC-SX-17)")
    func transcribeSonioxStreamingRejected() {
        // The wire id is `soniox` (not `soniox-streaming`); the resolver
        // MUST reject the close-but-wrong value via `parseEnum` and exit
        // 64 (EX_USAGE) so the user sees a deterministic error rather
        // than a silent fall-through.
        let r = resolverWith(shell: baseShell())
        do {
            _ = try r.resolve(cliOverrides: ["NTAKKER_TRANSCRIBE": "soniox-streaming"])
            Issue.record("expected throw for NTAKKER_TRANSCRIBE=soniox-streaming")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, value, _) = err {
                #expect(key == "NTAKKER_TRANSCRIBE")
                #expect(value == "soniox-streaming")
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - 4-tier resolution chain — SONIOX_API_KEY (FR-SX-3)

    @Test("(1) SONIOX_API_KEY resolved from shell env")
    func apiKeyFromShellEnv() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "shell-soniox-key",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionApiKey == "shell-soniox-key")
    }

    @Test("(2) SONIOX_API_KEY resolved from ~/.tool-agents/ntakker-cli/.env (user env)")
    func apiKeyFromUserEnv() throws {
        // The injected `userEnv` test-only initializer simulates the
        // `~/.tool-agents/ntakker-cli/.env` source verbatim — no filesystem
        // I/O involved, consistent with the existing Gemini test pattern.
        let r = resolverWith(
            shell: ["OUTPUT_PATH": Self.outputPath, "NTAKKER_TRANSCRIBE": "soniox"],
            user: ["SONIOX_API_KEY": "user-env-soniox-key"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionApiKey == "user-env-soniox-key")
    }

    @Test("(3) SONIOX_API_KEY resolved from local ./.env")
    func apiKeyFromLocalEnv() throws {
        let r = resolverWith(
            shell: ["OUTPUT_PATH": Self.outputPath, "NTAKKER_TRANSCRIBE": "soniox"],
            local: ["SONIOX_API_KEY": "local-env-soniox-key"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionApiKey == "local-env-soniox-key")
    }

    @Test("Local .env beats user .env beats shell env (full precedence)")
    func apiKeyPrecedenceChain() throws {
        let r = resolverWith(
            shell: [
                "OUTPUT_PATH": Self.outputPath,
                "NTAKKER_TRANSCRIBE": "soniox",
                "SONIOX_API_KEY": "shell-key",
            ],
            user: ["SONIOX_API_KEY": "user-key"],
            local: ["SONIOX_API_KEY": "local-key"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionApiKey == "local-key")
    }

    // MARK: - Hard fail when key missing (SX-5.2 / SX-8.1 — no fallback)

    @Test("(4) Missing SONIOX_API_KEY when NTAKKER_TRANSCRIBE=soniox throws transcriptionApiKeyMissing (exit 78)")
    func missingKeyThrowsTranscriptionApiKeyMissing() {
        // Per design SX-5.2 / SX-8.1, the resolver hard-fails at
        // config-load time with exit 78 (EX_CONFIG) BEFORE any audio
        // file is created — this is a deliberate divergence from the
        // Gemini pattern (which records `nil` and lets the factory
        // throw later) and is mandated by FR-SX-4 + the project's
        // "no fallback for missing config" rule.
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            // intentional: no SONIOX_API_KEY anywhere
        ])
        do {
            _ = try r.resolve(cliOverrides: [:])
            Issue.record("expected throw for missing SONIOX_API_KEY")
        } catch let err as NtakkerError {
            if case let .transcriptionApiKeyMissing(provider) = err {
                #expect(provider == "soniox")
                #expect(err.exitCode == 78)
            } else {
                Issue.record("expected .transcriptionApiKeyMissing(provider:\"soniox\"), got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Empty-string SONIOX_API_KEY treated as missing (no fallback)")
    func emptyKeyTreatedAsMissing() {
        // The merge helper inside `resolve(cliOverrides:)` already
        // filters empty strings out of every tier; this guards against
        // a `NTAKKER_TRANSCRIBE=soniox` + empty-key config silently
        // succeeding.
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "",
        ])
        do {
            _ = try r.resolve(cliOverrides: [:])
            Issue.record("expected throw for empty-string SONIOX_API_KEY")
        } catch let err as NtakkerError {
            if case .transcriptionApiKeyMissing = err {
                #expect(err.exitCode == 78)
            } else {
                Issue.record("expected .transcriptionApiKeyMissing, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Missing SONIOX_API_KEY does NOT fail when provider is something else (e.g. apple)")
    func missingSonioxKeyIgnoredWhenProviderIsApple() throws {
        // Soniox-key validation must be scoped to `NTAKKER_TRANSCRIBE=soniox`
        // — leaving the env-var unset must not affect the on-device Apple
        // Speech path or any other provider.
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "apple",
            // intentional: no SONIOX_API_KEY
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "apple")
        #expect(opts.transcriptionApiKey == nil)
    }

    // MARK: - NTAKKER_SONIOX_ENDPOINT (FR-SX-7)

    @Test("(5a) NTAKKER_SONIOX_ENDPOINT parsed when set")
    func endpointParsedWhenSet() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_SONIOX_ENDPOINT": "wss://stt-rt.eu.soniox.com/transcribe-websocket",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.sonioxEndpoint?.absoluteString == "wss://stt-rt.eu.soniox.com/transcribe-websocket")
    }

    @Test("(5b) NTAKKER_SONIOX_ENDPOINT defaults to nil when unset (vendor default applied at provider layer)")
    func endpointDefaultsToNilWhenUnset() throws {
        // Per design SX-5.3, the vendor production URL
        // (`wss://stt-rt.soniox.com/transcribe-websocket`) is hard-coded
        // in the **provider** code (Unit D's
        // `SonioxStreamingTranscriptionProvider`), NOT applied here as a
        // fallback. The resolver returns `nil` so the consumer can tell
        // "user did not override" from "user said empty".
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.sonioxEndpoint == nil)
    }

    @Test("Invalid NTAKKER_SONIOX_ENDPOINT URL exits 64 (EX_USAGE)")
    func invalidEndpointRaises() {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_SONIOX_ENDPOINT": "this is not a url",
        ])
        do {
            _ = try r.resolve(cliOverrides: [:])
            Issue.record("expected throw for invalid endpoint URL")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, _, _) = err {
                #expect(key == "NTAKKER_SONIOX_ENDPOINT")
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Non-ws/wss NTAKKER_SONIOX_ENDPOINT scheme exits 64")
    func nonWebSocketSchemeRejected() {
        // `https://` is a valid URL but not a valid WebSocket endpoint —
        // catching this at config-load time saves a confusing runtime
        // failure inside the WebSocketTask handshake.
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_SONIOX_ENDPOINT": "https://stt-rt.soniox.com/transcribe-websocket",
        ])
        do {
            _ = try r.resolve(cliOverrides: [:])
            Issue.record("expected throw for non-ws/wss scheme")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, _, _) = err {
                #expect(key == "NTAKKER_SONIOX_ENDPOINT")
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - NTAKKER_SONIOX_KEY_EXPIRES_AT precedence (D-SX-3 / OQ-SX-12)

    @Test("(6) Per-provider expiry beats shared expiry — NTAKKER_SONIOX_KEY_EXPIRES_AT wins")
    func perProviderExpiryWins() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_SONIOX_KEY_EXPIRES_AT": "2026-12-31",
            "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT": "2026-06-30",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        let expected = iso8601("2026-12-31")
        #expect(opts.sonioxKeyExpiresAt == expected)
        // Shared field is still parsed and stored independently — it
        // remains available for non-Soniox providers / future expiry
        // checks. This assertion guards the resolver against silently
        // overwriting one with the other.
        let sharedExpected = iso8601("2026-06-30")
        #expect(opts.transcriptionKeyExpiresAt == sharedExpected)
    }

    @Test("(7) Shared expiry used when per-provider expiry unset")
    func sharedExpiryFallback() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT": "2026-06-30",
            // intentional: no NTAKKER_SONIOX_KEY_EXPIRES_AT
        ])
        let opts = try r.resolve(cliOverrides: [:])
        let expected = iso8601("2026-06-30")
        #expect(opts.sonioxKeyExpiresAt == expected)
    }

    @Test("(8) Both expiries unset ⇒ sonioxKeyExpiresAt is nil (no warning)")
    func bothExpiriesUnsetReturnsNil() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            // intentional: neither expiry set
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.sonioxKeyExpiresAt == nil)
        #expect(opts.transcriptionKeyExpiresAt == nil)
    }

    @Test("NTAKKER_SONIOX_KEY_EXPIRES_AT parses full ISO-8601 timestamp")
    func perProviderExpiryAcceptsFullISO8601() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_SONIOX_KEY_EXPIRES_AT": "2026-12-31T23:59:59Z",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        let expected = iso8601("2026-12-31T23:59:59Z")
        #expect(opts.sonioxKeyExpiresAt == expected)
    }

    @Test("Invalid NTAKKER_SONIOX_KEY_EXPIRES_AT exits 64")
    func invalidPerProviderExpiryRaises() {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "test-key",
            "NTAKKER_SONIOX_KEY_EXPIRES_AT": "not-a-date",
        ])
        do {
            _ = try r.resolve(cliOverrides: [:])
            Issue.record("expected throw for bogus expiry")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, _, _) = err {
                #expect(key == "NTAKKER_SONIOX_KEY_EXPIRES_AT")
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Vendor-canonical key naming (CLAUDE.md tool-conventions)

    @Test("SONIOX_API_KEY constant is vendor-canonical (no NTAKKER_ prefix)")
    func sonioxApiKeyIsCanonical() {
        // Per CLAUDE.md tool-conventions and design SX-5.1, the Soniox
        // API key uses the vendor-canonical name without the `NTAKKER_`
        // prefix — the same convention as `GOOGLE_API_KEY`.
        #expect(ConfigResolver.Keys.sonioxApiKey == "SONIOX_API_KEY")
    }

    @Test("NTAKKER_SONIOX_ENDPOINT and NTAKKER_SONIOX_KEY_EXPIRES_AT follow the NTAKKER_ prefix convention")
    func ntakkerPrefixedKeysSpelledCorrectly() {
        // Project-internal config knobs use the `NTAKKER_*` family.
        #expect(ConfigResolver.Keys.sonioxEndpoint == "NTAKKER_SONIOX_ENDPOINT")
        #expect(ConfigResolver.Keys.sonioxKeyExpiresAt == "NTAKKER_SONIOX_KEY_EXPIRES_AT")
    }

    // MARK: - Enum surface (SX-9.1)

    @Test("TranscriptionProviderId.soniox raw value is 'soniox'")
    func providerEnumRawValue() {
        #expect(TranscriptionProviderId.soniox.rawValue == "soniox")
    }

    @Test("TranscriptionProviderId.allCases includes .soniox")
    func providerEnumCaseIterable() {
        #expect(TranscriptionProviderId.allCases.contains(.soniox))
    }
}
