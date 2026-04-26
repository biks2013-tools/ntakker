// macrec/Commands/RootCommand.swift — see project-design.md §2.12, §9.1
// Phase K finalization (plan-001 §K).
//
// Top-level `macrec` command. Owns only the subcommand registry and the
// version constant; no flags live here. The subcommands themselves
// implement all the real behavior:
//
//   * `start`              — begin a recording (FR-1..FR-11, FR-25, FR-29)
//   * `stop`               — stop a detached recording (FR-26)
//   * `list-devices`       — print available input audio devices (AC-3)
//   * `check-permissions`  — print TCC permission state (AC-2)
//
// Note (per the Phase K dispatch): we do NOT use `@main` on
// `RootCommand`. The executable target ships a `main.swift` that calls
// `RootCommand.main()` explicitly. This makes the entrypoint
// dispatching obvious to readers and avoids the SPM @main+main.swift
// edge case where both would conflict.

import ArgumentParser
import Foundation

public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "macrec",
        abstract: "macOS system audio + microphone recording tool.",
        version: "0.1.0",
        subcommands: [
            StartCommand.self,
            StopCommand.self,
            ListDevicesCommand.self,
            CheckPermissionsCommand.self,
        ]
    )

    public init() {}
}
