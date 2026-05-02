// MacrecCoreTests/Config/ConfigResolverDualModeTests.swift —
// see project-design.md §DT-10, plan-010-dual-transcription.md §Phase H
//
// Phase 7 reviewer requested tests — validates that `ConfigResolver`
// correctly handles the `--transcribe dual` short-circuit branch:
//
//   1. `--transcribe dual` + missing `--transcribe-dual-locale-a`
//      → raises `MacrecError.transcriptionConfigConflict` with field
//        `"--transcribe-dual-locale-a"` in the reason string (exit 64).
//
//   2. `--transcribe dual` + all 4 required flags
//      → builds `RecordingOptions.dualTranscription` non-nil with the
//        correct channel A/B locale, source, and format values.
//
//   3. `--transcribe dual` + `--transcribe-language en-US`
//      → mutual-exclusivity error (`transcriptionConfigConflict(reason:)`
//        mentioning `--transcribe-language`).
//
//   4. Single-mode `--transcribe apple` (existing behaviour)
//      → `RecordingOptions.dualTranscription == nil` (no regression).
//
// Tests use the injected-env `ConfigResolver` initialiser (same pattern
// as `ConfigResolverTranscriptionTests.swift`) so they never touch the
// live filesystem or `ProcessInfo`.

import Foundation
import Testing
@testable import MacrecCore

@Suite("ConfigResolver — dual-mode flag handling (plan-010 Phase H / §DT-10)")
struct ConfigResolverDualModeTests {

    // MARK: - Fixture

    private static let outputPath = "/tmp/macrec-resolver-dual.m4a"

    /// Make a resolver with an injected shell env that satisfies the
    /// mandatory `OUTPUT_PATH` requirement so dual-mode tests don't
    /// hit the unrelated "missing OUTPUT_PATH" error first.
    private func resolver(
        cliOverrides: [String: String] = [:]
    ) -> (ConfigResolver, [String: String]) {
        let resolver = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
        return (resolver, cliOverrides)
    }

    // MARK: - Test 1: missing --transcribe-dual-locale-a

    @Test("--transcribe dual with missing --transcribe-dual-locale-a raises transcriptionConfigConflict(field: '--transcribe-dual-locale-a')")
    func dualModeMissingLocaleA() {
        let (r, _) = resolver()
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                // INTENTIONAL: MACREC_TRANSCRIBE_DUAL_LOCALE_A is absent
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": "el-GR",
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mixed",
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "jsonl",
            ])
            Issue.record("Expected throw for missing MACREC_TRANSCRIBE_DUAL_LOCALE_A")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64, "Expected EX_USAGE (64); got: \(err.exitCode)")
                #expect(reason.contains("--transcribe-dual-locale-a"),
                        "Reason must name the missing field; got: '\(reason)'")
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 2: missing --transcribe-dual-locale-b

    @Test("--transcribe dual with missing --transcribe-dual-locale-b raises transcriptionConfigConflict(field: '--transcribe-dual-locale-b')")
    func dualModeMissingLocaleB() {
        let (r, _) = resolver()
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": "en-US",
                // INTENTIONAL: MACREC_TRANSCRIBE_DUAL_LOCALE_B is absent
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mixed",
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "jsonl",
            ])
            Issue.record("Expected throw for missing MACREC_TRANSCRIBE_DUAL_LOCALE_B")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64)
                #expect(reason.contains("--transcribe-dual-locale-b"),
                        "Reason must name the missing field; got: '\(reason)'")
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 3: missing --transcribe-dual-source

    @Test("--transcribe dual with missing --transcribe-dual-source raises transcriptionConfigConflict(field: '--transcribe-dual-source')")
    func dualModeMissingSource() {
        let (r, _) = resolver()
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": "en-US",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": "el-GR",
                // INTENTIONAL: MACREC_TRANSCRIBE_DUAL_SOURCE is absent
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "jsonl",
            ])
            Issue.record("Expected throw for missing MACREC_TRANSCRIBE_DUAL_SOURCE")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64)
                #expect(reason.contains("--transcribe-dual-source"),
                        "Reason must name the missing field; got: '\(reason)'")
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 4: missing --transcribe-dual-format

    @Test("--transcribe dual with missing --transcribe-dual-format raises transcriptionConfigConflict(field: '--transcribe-dual-format')")
    func dualModeMissingFormat() {
        let (r, _) = resolver()
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": "en-US",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": "el-GR",
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mixed",
                // INTENTIONAL: MACREC_TRANSCRIBE_DUAL_FORMAT is absent
            ])
            Issue.record("Expected throw for missing MACREC_TRANSCRIBE_DUAL_FORMAT")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64)
                #expect(reason.contains("--transcribe-dual-format"),
                        "Reason must name the missing field; got: '\(reason)'")
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 5: all 4 flags present → dualTranscription non-nil

    @Test("--transcribe dual + all 4 required flags → RecordingOptions.dualTranscription is non-nil with correct values")
    func dualModeAllFlagsProducesDualTranscriptionConfig() throws {
        let r = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )

        // Resolve locales dynamically from the actual locale sets so the
        // test passes regardless of which Speech language data is installed.
        // `DualLocaleSets.channelASupportedLocales` returns `Locale.identifier`
        // format (underscores: `en_US`) on macOS.
        let channelALocales = DualLocaleSets.channelASupportedLocales
        let channelBLocales = DualLocaleSets.channelBSupportedLocales

        guard let localeAId = channelALocales.first?.identifier else {
            Issue.record("channelASupportedLocales is empty on this host — test requires Speech language data")
            return
        }
        // Pick a Channel B locale that differs from Channel A to avoid Guard 5.
        guard let localeBId = channelBLocales.first(where: { $0.identifier != localeAId })?.identifier
                           ?? channelBLocales.first?.identifier else {
            Issue.record("channelBSupportedLocales is empty on this host — test requires Speech language data")
            return
        }

        // This resolve() calls DualTranscriptionConfig.init which validates
        // locale membership. Using dynamically-resolved locales ensures the
        // validation passes on this host.
        let opts: RecordingOptions
        do {
            opts = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": localeAId,
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": localeBId,
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mic",
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "srt",
            ])
        } catch let err as MacrecError {
            Issue.record("resolve() threw unexpectedly with dynamically-resolved valid locales: \(err)")
            return
        }

        guard let dualConfig = opts.dualTranscription else {
            Issue.record("RecordingOptions.dualTranscription must be non-nil in dual mode")
            return
        }

        // Channel A (apple on-device — provider hardwired by ConfigResolver)
        #expect(dualConfig.channelA.providerId == "apple",
                "Channel A providerId must be 'apple'; got: '\(dualConfig.channelA.providerId)'")
        // Locale round-trips through the resolver unchanged.
        #expect(dualConfig.channelA.locale == localeAId,
                "Channel A locale must round-trip to '\(localeAId)'; got: '\(dualConfig.channelA.locale)'")

        // Channel B (apple-cloud — provider hardwired by ConfigResolver)
        #expect(dualConfig.channelB.providerId == "apple-cloud",
                "Channel B providerId must be 'apple-cloud'; got: '\(dualConfig.channelB.providerId)'")
        #expect(dualConfig.channelB.locale == localeBId,
                "Channel B locale must round-trip to '\(localeBId)'; got: '\(dualConfig.channelB.locale)'")

        // Source and format
        #expect(dualConfig.source == .mic,
                "Dual source must be .mic; got: \(dualConfig.source)")
        #expect(dualConfig.sidecarFormat == .srt,
                "Dual sidecar format must be .srt; got: \(dualConfig.sidecarFormat)")

        // In dual mode the single-mode providerId must be nil (the dual
        // config replaces it, not supplements it).
        #expect(opts.transcriptionProviderId == nil,
                "In dual mode transcriptionProviderId (single-mode) must be nil; got: \(String(describing: opts.transcriptionProviderId))")
    }

    // MARK: - Test 6: --transcribe dual + --transcribe-language → mutual exclusivity error

    @Test("--transcribe dual + --transcribe-language → mutual-exclusivity error mentioning --transcribe-language")
    func dualModePlusTranscribeLanguageMutualExclusivity() {
        let r = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_LANGUAGE": "en_US",   // FORBIDDEN in dual mode (single-mode only)
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": "en_US",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": "el_GR",
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mixed",
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "jsonl",
            ])
            Issue.record("Expected mutual-exclusivity error for --transcribe-language in dual mode")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64)
                #expect(
                    reason.contains("--transcribe-language") || reason.contains("MACREC_TRANSCRIBE_LANGUAGE"),
                    "Reason must mention the conflicting flag '--transcribe-language'; got: '\(reason)'"
                )
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 7: --transcribe dual + --transcribe-source → mutual exclusivity error

    @Test("--transcribe dual + --transcribe-source → mutual-exclusivity error (single-mode source flag forbidden in dual mode)")
    func dualModePlusTranscribeSourceMutualExclusivity() {
        let r = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_SOURCE": "mic",        // FORBIDDEN in dual mode (single-mode only)
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": "en_US",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": "el_GR",
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mixed",
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "jsonl",
            ])
            Issue.record("Expected mutual-exclusivity error for --transcribe-source in dual mode")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64)
                #expect(
                    reason.contains("--transcribe-source") || reason.contains("MACREC_TRANSCRIBE_SOURCE"),
                    "Reason must mention the conflicting flag '--transcribe-source'; got: '\(reason)'"
                )
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 8: --transcribe dual + --transcribe-format → mutual exclusivity error

    @Test("--transcribe dual + --transcribe-format → mutual-exclusivity error (single-mode format flag forbidden in dual mode)")
    func dualModePlusTranscribeFormatMutualExclusivity() {
        let r = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
        do {
            _ = try r.resolve(cliOverrides: [
                "MACREC_TRANSCRIBE": "dual",
                "MACREC_TRANSCRIBE_FORMAT": "vtt",        // FORBIDDEN in dual mode (single-mode only)
                "MACREC_TRANSCRIBE_DUAL_LOCALE_A": "en_US",
                "MACREC_TRANSCRIBE_DUAL_LOCALE_B": "el_GR",
                "MACREC_TRANSCRIBE_DUAL_SOURCE": "mixed",
                "MACREC_TRANSCRIBE_DUAL_FORMAT": "jsonl",
            ])
            Issue.record("Expected mutual-exclusivity error for --transcribe-format in dual mode")
        } catch let err as MacrecError {
            if case let .transcriptionConfigConflict(reason) = err {
                #expect(err.exitCode == 64)
                #expect(
                    reason.contains("--transcribe-format") || reason.contains("MACREC_TRANSCRIBE_FORMAT"),
                    "Reason must mention the conflicting flag '--transcribe-format'; got: '\(reason)'"
                )
            } else {
                Issue.record("Expected .transcriptionConfigConflict, got: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test 9: single-mode apple → dualTranscription == nil

    @Test("Single-mode --transcribe apple → RecordingOptions.dualTranscription == nil (no regression)")
    func singleModeAppleProducesNilDualConfig() throws {
        let r = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
        let opts = try r.resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "apple",
        ])
        #expect(opts.dualTranscription == nil,
                "Single-mode apple must produce nil dualTranscription; got non-nil value")
        #expect(opts.transcriptionProviderId == "apple",
                "Single-mode apple must set transcriptionProviderId to 'apple'")
    }

    // MARK: - Test 10: single-mode none → dualTranscription == nil

    @Test("Single-mode --transcribe none → RecordingOptions.dualTranscription == nil")
    func singleModeNoneProducesNilDualConfig() throws {
        let r = ConfigResolver(
            toolName: "macrec",
            shellEnv: ["OUTPUT_PATH": Self.outputPath],
            userEnv: [:],
            localEnv: [:]
        )
        let opts = try r.resolve(cliOverrides: [
            "MACREC_TRANSCRIBE": "none",
        ])
        #expect(opts.dualTranscription == nil,
                "No-transcription mode must produce nil dualTranscription")
        #expect(opts.transcriptionProviderId == nil)
    }

    // MARK: - Test 11: dual-mode key constants are well-named

    @Test("ConfigResolver.Keys dual-mode constants follow MACREC_TRANSCRIBE_DUAL_* naming convention")
    func dualModeKeyNamingConvention() {
        #expect(ConfigResolver.Keys.transcribeDualLocaleA == "MACREC_TRANSCRIBE_DUAL_LOCALE_A")
        #expect(ConfigResolver.Keys.transcribeDualLocaleB == "MACREC_TRANSCRIBE_DUAL_LOCALE_B")
        #expect(ConfigResolver.Keys.transcribeDualSource  == "MACREC_TRANSCRIBE_DUAL_SOURCE")
        #expect(ConfigResolver.Keys.transcribeDualFormat  == "MACREC_TRANSCRIBE_DUAL_FORMAT")
    }
}
