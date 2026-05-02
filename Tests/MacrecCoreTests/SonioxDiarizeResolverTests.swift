// Tests/MacrecCoreTests/SonioxDiarizeResolverTests.swift —
// plan-012 Phase A5. See plan-012 §A5 and project-design.md §SX-5.
//
// Three-case four-tier resolution check for the new
// `MACREC_SONIOX_DIARIZE` env var (and matching `--soniox-diarize`
// CLI flag). The resolver must:
//
//   1. Forward `nil` when no source sets it — the
//      `TranscriptionProviderFactory` then falls back to
//      `SonioxConfigBuilder.defaultDiarize` (true) per Phase A2/A3.
//   2. Parse `MACREC_SONIOX_DIARIZE=false` from the shell env into
//      `RecordingOptions.sonioxDiarize == false`.
//   3. Honour CLI-overrides precedence — `--soniox-diarize true`
//      wins over a shell `MACREC_SONIOX_DIARIZE=false`.
//
// The existing Soniox suite (`SonioxConfigResolverTests`) injects
// envs verbatim through `ConfigResolver(toolName:shellEnv:userEnv:
// localEnv:)` so this file follows the same pattern (no
// `resolveForTesting(env:cliOverrides:)` helper exists in the
// codebase as of plan-012 Phase A5).

import Foundation
import Testing
@testable import MacrecCore

@Suite("ConfigResolver MACREC_SONIOX_DIARIZE four-tier resolution (Phase A5)")
struct SonioxDiarizeResolverTests {

    private static let outputPath = "/tmp/macrec-resolver-soniox-diarize.m4a"

    private func resolverWith(
        shell: [String: String] = [:],
        user: [String: String] = [:],
        local: [String: String] = [:]
    ) -> ConfigResolver {
        ConfigResolver(
            toolName: "macrec",
            shellEnv: shell,
            userEnv: user,
            localEnv: local
        )
    }

    @Test("default is nil when no source sets it")
    func defaultNil() throws {
        // Resolver should leave `sonioxDiarize == nil` when no tier
        // sets it; the factory then falls back to
        // `SonioxConfigBuilder.defaultDiarize` (true).
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "MACREC_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "k",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.sonioxDiarize == nil)
    }

    @Test("env false overrides default")
    func envFalse() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "MACREC_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "k",
            "MACREC_SONIOX_DIARIZE": "false",
        ])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.sonioxDiarize == false)
    }

    @Test("CLI flag wins over env")
    func cliWinsOverEnv() throws {
        let r = resolverWith(shell: [
            "OUTPUT_PATH": Self.outputPath,
            "MACREC_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "k",
            "MACREC_SONIOX_DIARIZE": "false",
        ])
        let opts = try r.resolve(
            cliOverrides: [ConfigResolver.Keys.sonioxDiarize: "true"]
        )
        #expect(opts.sonioxDiarize == true)
    }
}
