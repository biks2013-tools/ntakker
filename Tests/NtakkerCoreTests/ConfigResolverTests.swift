// NtakkerCoreTests/ConfigResolverTests.swift — see project-design.md §2.4 / §5
// Phase B — Bootstrap + Config (AC-9)

import Foundation
import Testing
@testable import NtakkerCore

@Suite("ConfigResolver")
struct ConfigResolverTests {

    // MARK: - Test fixtures

    private static let outputPath = "/tmp/ntakker-cli-resolver-test.m4a"
    private static let outputURL = URL(fileURLWithPath: "/tmp/ntakker-cli-resolver-test.m4a")

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

    // MARK: - Required value behavior

    @Test("Missing OUTPUT_PATH throws missingRequiredConfig")
    func missingRequiredOutput() {
        let r = resolverWith()
        do {
            _ = try r.resolve(cliOverrides: [:])
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            if case let .missingRequiredConfig(key, sources) = err {
                #expect(key == "OUTPUT_PATH")
                #expect(sources.contains("--output"))
                #expect(sources.contains("./.env"))
                #expect(sources.contains("shell"))
            } else {
                Issue.record("expected .missingRequiredConfig, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Precedence — AC-9

    @Test("Shell-only env supplies OUTPUT_PATH")
    func shellEnvOnly() throws {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.output == Self.outputURL)
    }

    @Test("User .env overrides shell")
    func userEnvOverridesShell() throws {
        let r = resolverWith(
            shell: ["NTAKKER_FORMAT": "wav", "OUTPUT_PATH": Self.outputPath],
            user: ["NTAKKER_FORMAT": "caf"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.format == .caf)
    }

    @Test("Local .env overrides user .env")
    func localEnvOverridesUser() throws {
        let r = resolverWith(
            shell: ["OUTPUT_PATH": Self.outputPath],
            user: ["NTAKKER_FORMAT": "caf"],
            local: ["NTAKKER_FORMAT": "wav"]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.format == .wav)
    }

    @Test("CLI overrides beat every other source — full precedence chain")
    func cliOverridesAll() throws {
        let r = resolverWith(
            shell: ["NTAKKER_FORMAT": "caf", "OUTPUT_PATH": "/tmp/shell.m4a"],
            user: ["NTAKKER_FORMAT": "wav"],
            local: ["NTAKKER_FORMAT": "wav"]
        )
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_FORMAT": "m4a",
            "OUTPUT_PATH": Self.outputPath,
        ])
        #expect(opts.format == .m4a)
        #expect(opts.output == Self.outputURL)
    }

    // MARK: - Type coercion

    @Test("Invalid sample rate (banana) throws invalidConfigValue")
    func invalidSampleRateBanana() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        do {
            _ = try r.resolve(cliOverrides: ["NTAKKER_SAMPLE_RATE": "banana"])
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            if case let .invalidConfigValue(key, value, _) = err {
                #expect(key == "NTAKKER_SAMPLE_RATE")
                #expect(value == "banana")
            } else {
                Issue.record("expected .invalidConfigValue, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Invalid sample rate (numeric out-of-range) throws")
    func invalidSampleRateOutOfRange() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["NTAKKER_SAMPLE_RATE": "96000"])
        }
    }

    @Test("Bitrate accepts kbps form (e.g. 192) and bps form (e.g. 192000)")
    func bitrateAcceptsKbpsAndBps() throws {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])

        let kbps = try r.resolve(cliOverrides: ["NTAKKER_BITRATE": "192"])
        #expect(kbps.bitrate == 192_000)

        let bps = try r.resolve(cliOverrides: ["NTAKKER_BITRATE": "192000"])
        #expect(bps.bitrate == 192_000)
    }

    @Test("Bitrate out-of-range rejected")
    func bitrateOutOfRange() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["NTAKKER_BITRATE": "999"])
        }
    }

    @Test("Invalid format enum value throws")
    func invalidFormat() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["NTAKKER_FORMAT": "ogg"])
        }
    }

    @Test("OUTPUT_PATH = '-' is rejected (stdout streaming not supported in v1)")
    func dashOutputRejected() {
        let r = resolverWith()
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["OUTPUT_PATH": "-"])
        }
    }

    // MARK: - Boolean parsing

    @Test("Boolean truthy values for NTAKKER_OVERWRITE / NTAKKER_DETACH")
    func booleanTruthy() throws {
        for raw in ["1", "true", "TRUE", "yes", "Yes", "YES"] {
            let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
            let opts = try r.resolve(cliOverrides: [
                "NTAKKER_OVERWRITE": raw,
                "NTAKKER_DETACH": raw,
            ])
            #expect(opts.overwrite == true)
            #expect(opts.runMode == .detached)
        }
    }

    @Test("Boolean falsy values for NTAKKER_OVERWRITE / NTAKKER_DETACH")
    func booleanFalsy() throws {
        for raw in ["0", "false", "FALSE", "no", "No"] {
            let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
            let opts = try r.resolve(cliOverrides: [
                "NTAKKER_OVERWRITE": raw,
                "NTAKKER_DETACH": raw,
            ])
            #expect(opts.overwrite == false)
            #expect(opts.runMode == .foreground)
        }
    }

    @Test("Bogus boolean throws invalidConfigValue")
    func booleanBogus() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["NTAKKER_OVERWRITE": "maybe"])
        }
        #expect(throws: NtakkerError.self) {
            _ = try r.resolve(cliOverrides: ["NTAKKER_DETACH": "soonish"])
        }
    }

    // MARK: - Detach-mode keys (FR-25, FR-26, FR-29)

    @Test("NTAKKER_PID_FILE / NTAKKER_LOG_FILE / NTAKKER_STOP_TIMEOUT propagate")
    func detachKeysPropagate() throws {
        let r = resolverWith(
            shell: ["OUTPUT_PATH": Self.outputPath],
            user: [:],
            local: [
                "NTAKKER_PID_FILE": "/tmp/ntakker-cli-test.pid",
                "NTAKKER_LOG_FILE": "/tmp/ntakker-cli-test.log",
                "NTAKKER_STOP_TIMEOUT": "10",
            ]
        )
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.pidFile.path == "/tmp/ntakker-cli-test.pid")
        #expect(opts.logFile.path == "/tmp/ntakker-cli-test.log")
        #expect(opts.stopTimeout == 10)
    }

    @Test("Detach defaults are applied when no override is provided")
    func detachDefaults() throws {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        let opts = try r.resolve(cliOverrides: [:])
        #expect(opts.runMode == .foreground)
        #expect(opts.stopTimeout == 35)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(opts.pidFile.path == "\(home)/.tool-agents/ntakker-cli/ntakker-cli.pid")
        #expect(opts.logFile.path == "\(home)/.tool-agents/ntakker-cli/ntakker-cli.log")
    }

    @Test("NTAKKER_STOP_TIMEOUT rejects non-numeric, zero, negative, and out-of-bounds")
    func stopTimeoutValidation() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        for bad in ["banana", "0", "-5", "601"] {
            #expect(throws: NtakkerError.self) {
                _ = try r.resolve(cliOverrides: ["NTAKKER_STOP_TIMEOUT": bad])
            }
        }
    }

    @Test("Tilde expansion in NTAKKER_PID_FILE / NTAKKER_LOG_FILE")
    func tildeExpansionForDetachPaths() throws {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        let opts = try r.resolve(cliOverrides: [
            "NTAKKER_PID_FILE": "~/ntakker-cli.pid",
            "NTAKKER_LOG_FILE": "~/ntakker-cli.log",
        ])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(opts.pidFile.path == "\(home)/ntakker-cli.pid")
        #expect(opts.logFile.path == "\(home)/ntakker-cli.log")
    }

    // MARK: - Tilde expansion / max-duration

    @Test("Tilde expansion in OUTPUT_PATH")
    func tildeExpansionInOutput() throws {
        let r = resolverWith()
        let opts = try r.resolve(cliOverrides: ["OUTPUT_PATH": "~/ntakker-cli-output.m4a"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(opts.output.path == "\(home)/ntakker-cli-output.m4a")
    }

    @Test("NTAKKER_MAX_DURATION must be positive")
    func maxDurationMustBePositive() {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        for bad in ["banana", "0", "-3"] {
            #expect(throws: NtakkerError.self) {
                _ = try r.resolve(cliOverrides: ["NTAKKER_MAX_DURATION": bad])
            }
        }
    }

    @Test("NTAKKER_MAX_DURATION accepts a positive double")
    func maxDurationAccepted() throws {
        let r = resolverWith(shell: ["OUTPUT_PATH": Self.outputPath])
        let opts = try r.resolve(cliOverrides: ["NTAKKER_MAX_DURATION": "120"])
        #expect(opts.maxDuration == 120)
    }
}
