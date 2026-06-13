// ntakker-cli/Commands/CheckPermissionsCommand.swift — see project-design.md §9.4 / §8
// Phase K finalization (AC-2), revised 2026-04-26 to actually trigger TCC
// prompts when state is .notDetermined (was: print-only).
//
// Plan-005 Phase G adds an Apple Speech Recognition row alongside the
// existing Microphone and Screen Recording rows. The Speech grant is
// required when the (now default) Apple Speech transcription provider is
// active; we surface and prompt for it here so users can pre-approve
// every TCC capability via a single `ntakker-cli check-permissions` invocation.
//
// Behavior:
//   - Bootstrap ~/.tool-agents/ntakker-cli/.
//   - Read current state of all three permissions.
//   - If Microphone is .notDetermined → call requestAccess(for: .audio) and
//     await the user's response. AVFoundation delivers the post-prompt state
//     reliably in-process.
//   - If Screen Recording is .notDetermined → call CGRequestScreenCaptureAccess
//     to trigger the prompt; same-process re-read is unreliable per
//     ScreenRecordingPermission.swift, so we tell the user to relaunch.
//   - If Speech Recognition is .notDetermined → call
//     SFSpeechRecognizer.requestAuthorization and await the post-prompt
//     state (delivered reliably in-process, like AVFoundation).
//   - Print final status to stderr (mic + screen via PermissionGate;
//     speech as a free-standing line because PermissionGate.Snapshot is
//     locked by project-design.md §2.1 / §8 to the original two-field
//     shape).
//   - Exit 0 if mic + screen are both authorized, 77 (EX_NOPERM) otherwise.
//     Speech Recognition is informational here — it is enforced at
//     `RecordingSession` start time, not at `check-permissions` time, so
//     a user without a Speech grant can still record audio and use the
//     `NTAKKER_TRANSCRIBE=none` opt-out.

import ArgumentParser
import Foundation
import NtakkerCore

public struct CheckPermissionsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check-permissions",
        abstract: "Print Screen Recording and Microphone permission state, triggering TCC prompts on first run."
    )

    public init() {}

    public func run() async throws {
        // Bootstrap ~/.tool-agents/ntakker-cli/ on every invocation (FR-13).
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

        LoggerFactory.bootstrap(level: .info)
        let logger = LoggerFactory.make("ntakker-cli.permissions")

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

        // SPEECH RECOGNITION — required by the Apple on-device transcription
        // provider (plan-005 Phase G; default provider as of plan-005).
        // Same shape as the mic flow: read, prompt on .notDetermined, await.
        // Reported as a free-standing stderr line below (PermissionGate's
        // snapshot type is locked to the original two-field schema by
        // project-design.md §2.1 / §8).
        var finalSpeech: SpeechPermission.State?
        if #available(macOS 26.0, *) {
            let initialSpeech = SpeechPermission.current()
            if initialSpeech == .notDetermined {
                logger.info("triggering Speech Recognition TCC prompt; awaiting user response")
                finalSpeech = await SpeechPermission.request()
            } else {
                finalSpeech = initialSpeech
            }
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

        if let speech = finalSpeech {
            let label: String = {
                switch speech {
                case .authorized:    return "authorized"
                case .denied:        return "denied"
                case .restricted:    return "restricted"
                case .notDetermined: return "not determined"
                }
            }()
            FileHandle.standardError.write(
                Data("Speech Recognition: \(label)\n".utf8)
            )
            if speech == .denied {
                FileHandle.standardError.write(Data(
                    "  hint: Open System Settings > Privacy & Security > Speech Recognition and enable ntakker-cli, or set NTAKKER_TRANSCRIBE=none to disable transcription.\n".utf8
                ))
            } else if speech == .restricted {
                FileHandle.standardError.write(Data(
                    "  hint: Speech Recognition is restricted on this Mac (managed device); set NTAKKER_TRANSCRIBE=none to disable transcription.\n".utf8
                ))
            }
        }

        if finalSnapshot.bothAuthorized {
            return
        }
        throw ExitCode(77)
    }
}
