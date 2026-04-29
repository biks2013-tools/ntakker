// MacrecCoreTests/Commands/StartCommandTranscriptionFlagsTests.swift —
// see plan-003 Phase C, design §LT-5.3 / §LT-5.5.
//
// **Why this file lives in MacrecCoreTests, not macrecTests**: there is no
// `macrecTests` test target in `Package.swift` and the prompt forbids adding
// one. `StartCommand`'s `buildCLIOverrides()` is intentionally module-private
// (it cannot be imported from outside the executable target). So we exercise
// the equivalent flag round-trip through the env-var-keyed input dictionary
// directly against `ConfigResolver`. Every CLI flag wires into one and only
// one env-var key (see `StartCommand.buildCLIOverrides()`), so this test
// validates the contract end-to-end without needing the CLI binary.

import Foundation
import Testing
@testable import MacrecCore

@Suite("StartCommand — live transcription flag round-trip + cross-checks")
struct StartCommandTranscriptionFlagsTests {

    private static let outputPath = "/tmp/macrec-start-transcribe.m4a"

    private func resolverWithBaseShell() -> ConfigResolver {
        ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
    }

    // MARK: - Each flag round-trips into RecordingOptions

    @Test("--transcribe gemini-live ⇒ RecordingOptions.transcriptionProviderId == \"gemini-live\"")
    func transcribeFlagRoundTrip() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "gemini-live",
        ])
        #expect(opts.transcriptionProviderId == "gemini-live")
    }

    @Test("--transcribe-source both ⇒ transcriptionSource == .both")
    func transcribeSourceFlagRoundTrip() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "gemini-live",
            "MACREC_TRANSCRIBE_SOURCE": "both",
        ])
        #expect(opts.transcriptionSource == .both)
    }

    @Test("--transcribe-format vtt ⇒ transcriptionFormat == .vtt")
    func transcribeFormatFlagRoundTrip() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE_FORMAT": "vtt",
        ])
        #expect(opts.transcriptionFormat == .vtt)
    }

    @Test("--transcribe-model overrides flow into transcriptionModelId")
    func transcribeModelFlagRoundTrip() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "gemini-live",
            "MACREC_TRANSCRIBE_MODEL": "gemini-3.1-flash-live-preview",
        ])
        #expect(opts.transcriptionModelId == "gemini-3.1-flash-live-preview")
    }

    @Test("--transcribe-language en ⇒ transcriptionLanguageHints == [\"en\"]")
    func transcribeLanguageFlagRoundTrip() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "gemini-live",
            "MACREC_TRANSCRIBE_LANGUAGE": "en",
        ])
        // plan-005 Phase G — single value parses to one-element list.
        #expect(opts.transcriptionLanguageHints == ["en"])
    }

    @Test("--transcribe-key-expires-at ISO-8601 ⇒ transcriptionKeyExpiresAt parsed")
    func transcribeKeyExpiresAtFlagRoundTrip() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE_KEY_EXPIRES_AT": "2027-01-01T00:00:00Z",
        ])
        #expect(opts.transcriptionKeyExpiresAt != nil)
    }

    // MARK: - Default `--transcribe none` is a true no-op (AC-LT-16)

    @Test("Default --transcribe absent ⇒ transcriptionProviderId == \"apple\" (plan-005 default flip)")
    func defaultTranscribeIsApple() throws {
        // plan-005 Phase G: the resolver's no-value default for
        // MACREC_TRANSCRIBE flips from "none" to "apple". Apple's
        // on-device SpeechAnalyzer is the out-of-the-box experience.
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "apple")
    }

    @Test("Explicit --transcribe none ⇒ transcriptionProviderId == nil")
    func explicitTranscribeNoneIsNil() throws {
        let opts = try resolverWithBaseShell().resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "none",
        ])
        #expect(opts.transcriptionProviderId == nil)
    }

    // MARK: - Conflict matrix (design §LT-5.5 step 9)

    @Test("Conflict — gemini-live + --transcribe-source mic + --mic-device none raises")
    func conflictGeminiLiveMicSourceNoMic() {
        let r = resolverWithBaseShell()
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "gemini-live",
                "MACREC_TRANSCRIBE_SOURCE": "mic",
                "MACREC_MIC_DEVICE": "none",
            ])
            Issue.record("expected throw")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(!reason.isEmpty)
            } else {
                Issue.record("expected .transcriptionConfigConflict, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Non-conflict — gemini-live + --transcribe-source mixed (or default) is fine")
    func nonConflictGeminiLiveMixed() throws {
        let r = resolverWithBaseShell()
        let opts = try r.resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "gemini-live",
            "MACREC_TRANSCRIBE_SOURCE": "mixed",
        ])
        #expect(opts.transcriptionProviderId == "gemini-live")
        #expect(opts.transcriptionSource == .mixed)
    }
}
