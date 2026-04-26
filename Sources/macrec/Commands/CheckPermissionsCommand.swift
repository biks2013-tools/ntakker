// macrec/Commands/CheckPermissionsCommand.swift — see project-design.md §9.4 / §8
// Phase K finalization (AC-2), revised 2026-04-26 to actually trigger TCC
// prompts when state is .notDetermined (was: print-only).
//
// Behavior:
//   - Bootstrap ~/.tool-agents/macrec/.
//   - Read current state of both permissions.
//   - If Microphone is .notDetermined → call requestAccess(for: .audio) and
//     await the user's response. AVFoundation delivers the post-prompt state
//     reliably in-process.
//   - If Screen Recording is .notDetermined → call CGRequestScreenCaptureAccess
//     to trigger the prompt; same-process re-read is unreliable per
//     ScreenRecordingPermission.swift, so we tell the user to relaunch.
//   - Print final status to stderr.
//   - Exit 0 if both authorized, 77 (EX_NOPERM) otherwise.

import ArgumentParser
import Foundation
import MacrecCore

public struct CheckPermissionsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check-permissions",
        abstract: "Print Screen Recording and Microphone permission state, triggering TCC prompts on first run."
    )

    public init() {}

    public func run() async throws {
        // Bootstrap ~/.tool-agents/macrec/ on every invocation (FR-13).
        do {
            _ = try ToolAgentsBootstrap.ensure(toolName: "macrec")
        } catch let err as MacrecError {
            err.printToStderr()
            throw ExitCode(err.exitCode)
        } catch {
            FileHandle.standardError.write(
                Data("macrec: error: \(error.localizedDescription)\n".utf8)
            )
            throw ExitCode(1)
        }

        LoggerFactory.bootstrap(level: .info)
        let logger = LoggerFactory.make("macrec.permissions")

        // SCREEN RECORDING — use SCShareableContent (modern, authoritative).
        // The legacy CGPreflight API caches stale state on macOS 14+ for
        // ad-hoc-signed CLI tools; SCShareableContent.current actually probes
        // the current TCC state and triggers the System Settings flow if the
        // binary is unknown to the OS.
        logger.info("probing Screen Recording via SCShareableContent.current")
        var finalScreen = await ScreenRecordingPermission.currentAsync()

        // If still denied, also call the legacy CGRequest path. This is the
        // only way to surface the *legacy* TCC prompt for binaries that were
        // never registered via SCShareableContent's path. On macOS 14+ ad-hoc
        // builds this is a belt-and-suspenders move.
        var screenPromptTriggered = false
        if finalScreen == .denied {
            logger.info("triggering legacy CGRequestScreenCaptureAccess prompt")
            ScreenRecordingPermission.request()
            screenPromptTriggered = true
            // Re-probe after the request — same-process state is sometimes
            // updated, sometimes not (per the headers).
            finalScreen = await ScreenRecordingPermission.currentAsync()
        }

        // MICROPHONE — the AVFoundation API delivers the post-prompt state
        // reliably in-process.
        let initialMic = MicrophonePermission.current()
        var finalMic = initialMic
        if initialMic == .notDetermined {
            logger.info("triggering Microphone TCC prompt; awaiting user response")
            finalMic = await MicrophonePermission.request()
        }

        // Print final status.
        let gate = PermissionGate(logger: logger)
        let finalSnapshot = PermissionGate.Snapshot(
            screenRecording: finalScreen,
            microphone: finalMic
        )
        await gate.printSnapshot(finalSnapshot,
                                 to: .standardError,
                                 screenPromptWasTriggered: screenPromptTriggered)

        if finalSnapshot.bothAuthorized {
            return
        }
        throw ExitCode(77)
    }
}
