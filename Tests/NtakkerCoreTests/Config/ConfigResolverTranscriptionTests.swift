// NtakkerCoreTests/Config/ConfigResolverTranscriptionTests.swift —
// see project-design.md §LT-5 / plan-003 Phase C.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("ConfigResolver — live transcription resolution")
struct ConfigResolverTranscriptionTests {

    // MARK: - Test fixtures

    private static let outputPath = "/tmp/ntakker-cli-resolver-transcription.m4a"

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

    // MARK: - Defaults — plan-005 Phase G default flip (was AC-LT-16 nil)

    @Test("Default — NTAKKER_TRANSCRIBE absent ⇒ provider id is 'apple' (plan-005 default flip)")
    func defaultProviderIsApple() throws {
        // Plan-005 Phase G flips the resolver's no-value default from
        // `none` to `apple` — Apple's on-device SpeechAnalyzer is the
        // out-of-the-box experience now. To opt out, the user must
        // pass `NTAKKER_TRANSCRIBE=none` explicitly (see the next test).
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "apple")
        #expect(opts.transcriptionSource == .mixed)
        #expect(opts.transcriptionFormat == .jsonl)
        #expect(opts.transcriptionApiKey == nil)
        #expect(opts.transcriptionKeyExpiresAt == nil)
        #expect(opts.transcriptionModelId == nil)
        #expect(opts.transcriptionLanguageHints == [])
    }

    @Test("NTAKKER_TRANSCRIBE=none normalizes provider id to nil")
    func transcribeNoneNormalizesToNil() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: ["NTAKKER_TRANSCRIBE": "none"])
        #expect(opts.transcriptionProviderId == nil)
    }

    @Test("NTAKKER_TRANSCRIBE=apple selects Apple Speech provider")
    func transcribeAppleSelectsApple() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: ["NTAKKER_TRANSCRIBE": "apple"])
        #expect(opts.transcriptionProviderId == "apple")
        // Apple Speech is on-device — no API key is required even when
        // active.
        #expect(opts.transcriptionApiKey == nil)
    }

    // MARK: - Four-tier resolution chain — AC-9 for new keys

    @Test("Shell env supplies transcription keys")
    func shellEnvSupplies() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "gemini",
            "NTAKKER_TRANSCRIBE_SOURCE": "mic",
            "NTAKKER_TRANSCRIBE_FORMAT": "srt",
            "NTAKKER_TRANSCRIBE_MODEL": "gemini-3.1-flash-live-preview",
            "NTAKKER_TRANSCRIBE_LANGUAGE": "en",
            "GOOGLE_API_KEY": "shell-key",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        // plan-004 Phase G.2: canonical wire id is `"gemini"` for the
        // REST batch provider.
        #expect(opts.transcriptionProviderId == "gemini")
        #expect(opts.transcriptionSource == .mic)
        #expect(opts.transcriptionFormat == .srt)
        #expect(opts.transcriptionModelId == "gemini-3.1-flash-live-preview")
        // plan-005 Phase G — `NTAKKER_TRANSCRIBE_LANGUAGE` parses as a
        // comma-split list; a single value yields a one-element array.
        #expect(opts.transcriptionLanguageHints == ["en"])
        #expect(opts.transcriptionApiKey == "shell-key")
    }

    // MARK: - Comma-separated language hints (plan-005 Phase G)

    @Test("NTAKKER_TRANSCRIBE_LANGUAGE=en-US,el-GR ⇒ two hints")
    func languageHintsCommaSplit() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_TRANSCRIBE": "gemini",
            "NTAKKER_TRANSCRIBE_LANGUAGE": "en-US,el-GR",
            "GOOGLE_API_KEY": "shell-key",
        ])
        #expect(opts.transcriptionLanguageHints == ["en-US", "el-GR"])
    }

    @Test("NTAKKER_TRANSCRIBE_LANGUAGE with whitespace is trimmed")
    func languageHintsTrimWhitespace() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_TRANSCRIBE": "gemini",
            "NTAKKER_TRANSCRIBE_LANGUAGE": "en-US , el-GR ",
            "GOOGLE_API_KEY": "shell-key",
        ])
        #expect(opts.transcriptionLanguageHints == ["en-US", "el-GR"])
    }

    @Test("NTAKKER_TRANSCRIBE=gemini-live deprecation alias resolves to 'gemini'")
    func geminiLiveDeprecationAlias() throws {
        // plan-004 Phase G.2: `gemini-live` is accepted as a one-release
        // back-compat alias for `gemini`. The resolver lowers it to
        // `"gemini"` and emits a deprecation notice on stderr (we do NOT
        // assert on the notice here; the resolution semantics are what
        // matters to downstream consumers).
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "gemini-live",
            "GOOGLE_API_KEY": "shell-key",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "gemini")
        #expect(opts.transcriptionApiKey == "shell-key")
    }

    @Test("User .env overrides shell — NTAKKER_TRANSCRIBE_FORMAT")
    func userEnvOverridesShell() throws {
        let r = resolverWith(
            shell: [
                "OUTPUT_PATH": Self.outputPath,
                "NTAKKER_TRANSCRIBE": "gemini-live",
                "NTAKKER_TRANSCRIBE_FORMAT": "vtt",
                "GOOGLE_API_KEY": "shell-key",
            ],
            user: ["NTAKKER_TRANSCRIBE_FORMAT": "txt"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionFormat == .txt)
    }

    @Test("Local .env overrides user .env — NTAKKER_TRANSCRIBE_SOURCE")
    func localEnvOverridesUser() throws {
        let r = resolverWith(
            shell: [
                "OUTPUT_PATH": Self.outputPath,
                "NTAKKER_TRANSCRIBE": "gemini-live",
                "GOOGLE_API_KEY": "shell-key",
            ],
            user: ["NTAKKER_TRANSCRIBE_SOURCE": "system"],
            local: ["NTAKKER_TRANSCRIBE_SOURCE": "both"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionSource == .both)
    }

    @Test("CLI overrides beat every other source — full precedence chain")
    func cliOverridesAll() throws {
        let r = resolverWith(
            shell: [
                "OUTPUT_PATH": Self.outputPath,
                "NTAKKER_TRANSCRIBE": "none",
                "NTAKKER_TRANSCRIBE_FORMAT": "srt",
                "GOOGLE_API_KEY": "shell-key",
            ],
            user: ["NTAKKER_TRANSCRIBE_FORMAT": "vtt"],
            local: ["NTAKKER_TRANSCRIBE_FORMAT": "txt"]
        )
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_TRANSCRIBE": "gemini",
            "NTAKKER_TRANSCRIBE_FORMAT": "jsonl",
        ])
        #expect(opts.transcriptionProviderId == "gemini")
        #expect(opts.transcriptionFormat == .jsonl)
    }

    // MARK: - API key resolution

    @Test("Missing GOOGLE_API_KEY when NTAKKER_TRANSCRIBE=gemini does NOT raise at config-load")
    func missingApiKeyDoesNotRaiseAtConfigLoad() throws {
        // Per project-design §LT-5.4 and the documented exception note on
        // RecordingOptions.transcriptionApiKey, the resolver records the
        // missing-key state but does NOT throw. The provider factory
        // (`TranscriptionProviderFactory.build`) raises
        // `NtakkerError.transcriptionApiKeyMissing` at session start.
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "gemini",
            // intentional: no GOOGLE_API_KEY
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "gemini")
        #expect(opts.transcriptionApiKey == nil)
    }

    @Test("Missing GOOGLE_API_KEY when NTAKKER_TRANSCRIBE=none silently ignored")
    func missingApiKeyWhenProviderNoneIsFine() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "none",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == nil)
        #expect(opts.transcriptionApiKey == nil)
    }

    @Test("Missing GOOGLE_API_KEY when NTAKKER_TRANSCRIBE=apple is fine (on-device)")
    func missingApiKeyWhenProviderAppleIsFine() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "NTAKKER_TRANSCRIBE": "apple",
            // intentional: no GOOGLE_API_KEY — Apple Speech is on-device.
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "apple")
        #expect(opts.transcriptionApiKey == nil)
    }

    // MARK: - Validation — no fallback for invalid values

    @Test("Invalid NTAKKER_TRANSCRIBE_FORMAT raises immediately")
    func invalidFormatRaises() {
        let r = resolverWith(shell: baseShell())
        do {
            _ = try r.resolve(cliOverrides: ["NTAKKER_TRANSCRIBE_FORMAT": "ogg"])
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, value, _) = err {
                #expect(key == "NTAKKER_TRANSCRIBE_FORMAT")
                #expect(value == "ogg")
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Invalid NTAKKER_TRANSCRIBE_SOURCE raises immediately")
    func invalidSourceRaises() {
        let r = resolverWith(shell: baseShell())
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["NTAKKER_TRANSCRIBE_SOURCE": "stereo"])
        }
    }

    @Test("Invalid NTAKKER_TRANSCRIBE provider raises immediately")
    func invalidProviderRaises() {
        let r = resolverWith(shell: baseShell())
        do {
            _ = try r.resolve(cliOverrides: ["NTAKKER_TRANSCRIBE": "openai-realtime"])
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            #expect(err.exitCode == 64)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - ISO-8601 expiry parsing

    @Test("NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT parses YYYY-MM-DD")
    func keyExpiresAtParsesDateOnly() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT": "2026-12-31",
        ])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-12-31T00:00:00Z")
        #expect(opts.transcriptionKeyExpiresAt == expected)
    }

    @Test("NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT parses full ISO-8601")
    func keyExpiresAtParsesFullISO() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT": "2026-12-31T23:59:59Z",
        ])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-12-31T23:59:59Z")
        #expect(opts.transcriptionKeyExpiresAt == expected)
    }

    @Test("Invalid NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT raises invalidConfigValue")
    func keyExpiresAtBogusRaises() {
        let r = resolverWith(shell: baseShell())
        do {
            _ = try r.resolve(cliOverrides: [
                "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT": "tuesday",
            ])
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, _, _) = err {
                #expect(key == "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT")
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Cross-check: --transcribe-source mic with no mic device

    @Test("Conflict: --transcribe gemini-live + source=mic + mic disabled raises transcriptionConfigConflict")
    func conflictMicSourceWithDisabledMic() {
        let r = resolverWith(shell: baseShell())
        do {
            _ = try r.resolve(cliOverrides: [
                "NTAKKER_TRANSCRIBE": "gemini-live",
                "NTAKKER_TRANSCRIBE_SOURCE": "mic",
                "NTAKKER_MIC_DEVICE": "none",
            ])
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(!reason.isEmpty)
                #expect(err.exitCode == 64)
            } else {
                Issue.record("expected .transcriptionConfigConflict, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("No conflict when --transcribe none even with --transcribe-source mic and no mic")
    func noConflictWhenProviderNone() throws {
        let r = resolverWith(shell: baseShell())
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_TRANSCRIBE": "none",
            "NTAKKER_TRANSCRIBE_SOURCE": "mic",
            "NTAKKER_MIC_DEVICE": "none",
        ])
        #expect(opts.transcriptionProviderId == nil)
    }

    // MARK: - Vendor-canonical key name (CLAUDE.md tool-conventions)

    @Test("GOOGLE_API_KEY key constant is vendor-canonical (not NTAKKER_GEMINI_API_KEY)")
    func googleApiKeyIsCanonical() {
        #expect(ConfigResolver.Keys.googleApiKey == "GOOGLE_API_KEY")
    }

    @Test("All new transcription key constants follow NTAKKER_TRANSCRIBE* family")
    func keyNamingFamily() {
        #expect(ConfigResolver.Keys.transcribe == "NTAKKER_TRANSCRIBE")
        #expect(ConfigResolver.Keys.transcribeSource == "NTAKKER_TRANSCRIBE_SOURCE")
        #expect(ConfigResolver.Keys.transcribeFormat == "NTAKKER_TRANSCRIBE_FORMAT")
        #expect(ConfigResolver.Keys.transcribeModel == "NTAKKER_TRANSCRIBE_MODEL")
        #expect(ConfigResolver.Keys.transcribeLanguage == "NTAKKER_TRANSCRIBE_LANGUAGE")
        #expect(ConfigResolver.Keys.transcribeKeyExpiresAt == "NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT")
    }
}
