// NtakkerCoreTests/NtakkerErrorTranscriptionTests.swift —
// see project-design.md §LT-4 / plan-003 Phase C.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("NtakkerError — live transcription cases")
struct NtakkerErrorTranscriptionTests {

    // MARK: - Exit codes (design §LT-4 — locked, no new codes introduced)

    @Test("transcriptionApiKeyMissing exits 78 (EX_CONFIG)")
    func apiKeyMissingExits78() {
        let e = NtakkerError.transcriptionApiKeyMissing(provider: "gemini-live")
        #expect(e.exitCode == 78)
    }

    @Test("transcriptionProviderUnavailable exits 70 (EX_SOFTWARE)")
    func providerUnavailableExits70() {
        let e = NtakkerError.transcriptionProviderUnavailable(reason: "endpoint refused connection")
        #expect(e.exitCode == 70)
    }

    @Test("transcriptionConfigConflict exits 64 (EX_USAGE)")
    func configConflictExits64() {
        let e = NtakkerError.transcriptionConfigConflict(reason: "--transcribe-source mic requires --mic")
        #expect(e.exitCode == 64)
    }

    @Test("transcriptionKeyExpired exits 78 (EX_CONFIG)")
    func keyExpiredExits78() {
        let e = NtakkerError.transcriptionKeyExpired(
            provider: "gemini-live",
            expiredAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        #expect(e.exitCode == 78)
    }

    // MARK: - Localized descriptions

    @Test("transcriptionApiKeyMissing description names the provider")
    func apiKeyMissingDescription() {
        let e = NtakkerError.transcriptionApiKeyMissing(provider: "gemini-live")
        #expect(!e.description.isEmpty)
        #expect(e.description.contains("gemini-live"))
        #expect(e.errorDescription == e.description)
    }

    @Test("transcriptionProviderUnavailable description echoes the reason")
    func providerUnavailableDescription() {
        let e = NtakkerError.transcriptionProviderUnavailable(reason: "bad endpoint")
        #expect(!e.description.isEmpty)
        #expect(e.description.contains("bad endpoint"))
    }

    @Test("transcriptionConfigConflict description echoes the reason")
    func configConflictDescription() {
        let e = NtakkerError.transcriptionConfigConflict(reason: "--mic disabled but --transcribe-source mic")
        #expect(!e.description.isEmpty)
        #expect(e.description.contains("--mic disabled but --transcribe-source mic"))
    }

    @Test("transcriptionKeyExpired description names the provider and an ISO-8601 timestamp")
    func keyExpiredDescription() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let e = NtakkerError.transcriptionKeyExpired(provider: "gemini-live", expiredAt: date)
        #expect(!e.description.isEmpty)
        #expect(e.description.contains("gemini-live"))
        // The description should include some recognisable ISO-8601 fragment.
        let formatter = ISO8601DateFormatter()
        #expect(e.description.contains(formatter.string(from: date)))
    }

    // MARK: - Remediation

    @Test("All new cases have non-empty remediation strings")
    func nonEmptyRemediation() {
        let cases: [NtakkerError] = [
            .transcriptionApiKeyMissing(provider: "gemini-live"),
            .transcriptionProviderUnavailable(reason: "x"),
            .transcriptionConfigConflict(reason: "x"),
            .transcriptionKeyExpired(provider: "gemini-live", expiredAt: Date()),
        ]
        for e in cases {
            #expect(!e.remediation.isEmpty, "remediation must be non-empty for \(e)")
            #expect(e.recoverySuggestion == e.remediation)
        }
    }

    @Test("transcriptionApiKeyMissing remediation mentions the env-var resolution chain")
    func apiKeyMissingRemediationMentionsEnv() {
        let e = NtakkerError.transcriptionApiKeyMissing(provider: "gemini-live")
        // Remediation should reference at least one of the four resolution
        // tiers (shell / .env / ~/.tool-agents/ntakker-cli/.env) so users can act.
        let r = e.remediation
        let mentionsAtLeastOneTier =
            r.contains("shell") ||
            r.contains(".env") ||
            r.contains(".tool-agents")
        #expect(mentionsAtLeastOneTier, "remediation '\(r)' must point at the env-var chain")
    }
}
