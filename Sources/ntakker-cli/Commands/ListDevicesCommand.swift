// ntakker-cli/Commands/ListDevicesCommand.swift — see project-design.md §9.3
// Phase K finalization (AC-3).
//
// Prints one line per available input audio device. The format is
// strictly parseable (single record per line, key=value pairs separated
// by two spaces) so downstream scripting can split on `=` cleanly.

import ArgumentParser
import Foundation
import NtakkerCore

public struct ListDevicesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "Print available audio input devices."
    )

    public init() {}

    public func run() throws {
        // Always bootstrap ~/.tool-agents/ntakker-cli/ on every invocation
        // (FR-13). Failure here is fatal — without the folder we
        // cannot read the user's `.env` reliably.
        do {
            _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli")
        } catch let err as NtakkerError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("ntakker-cli: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        // Bootstrap logging at info level. `list-devices` does not
        // accept `--log-level`; the design's CLI surface keeps this
        // subcommand minimal (§9.3).
        LoggerFactory.bootstrap(level: .info)

        let devices: [AudioInputDevice]
        do {
            devices = try AudioDeviceEnumerator.listInputs()
        } catch let err as NtakkerError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("ntakker-cli: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        // Print one line per device. Format (locked, parseable):
        //
        //   name=<name>  uid=<uid>  channels=<n>  sample-rate-range=<min>..<max>
        //
        // The `..` separator is chosen to match Swift's
        // `ClosedRange.description` so a reader can splat the value
        // straight into a `ClosedRange<Double>` if desired.
        for device in devices {
            let line = "name=\(device.name)  uid=\(device.uid)  channels=\(device.channelCount)  sample-rate-range=\(formatRate(device.sampleRateRange.lowerBound))..\(formatRate(device.sampleRateRange.upperBound))"
            print(line)
        }
    }

    /// Format a sample-rate value without trailing ".0" when it is a
    /// whole number (so 48000.0 prints as `48000`, but 44100.05 prints
    /// as `44100.05`).
    private func formatRate(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(value)
    }
}
