// ntakker-studio/NtakkerStudioApp.swift — plan-024 T9.
//
// The recordings explorer that sits next to ntakker: browse the library,
// study transcripts against the audio, cut, ask, write minutes,
// re-transcribe. A normal Dock app (bundle id com.giorgosmarinos.ntakker-studio).
//
// At launch it loads `~/.tool-agents/ntakker/.env` into the process, so
// Ask / minutes and re-transcription use the same settings as ntakker.

import AppKit
import Logging
import NtakkerCore
import SwiftUI

/// The app; started by `StudioMain` (StudioCommandLine.swift) when no
/// command is given.
struct NtakkerStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()

    var body: some Scene {
        WindowGroup("ntakker studio", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 1180, minHeight: 680)
                .task { await library.rescan() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Library Folder…") { library.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Library") { Task { await library.rescan() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                StudioAppearancePicker()
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { library.workspace?.player.togglePlay() }
                    .keyboardShortcut(.space, modifiers: .option)
                Button("Back 5 Seconds") { library.workspace?.player.skip(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Forward 5 Seconds") { library.workspace?.player.skip(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
            }
        }

        Settings {
            StudioSettingsView()
                .environment(library)
        }
    }
}

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(label: "ntakker-studio.app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window opens, so a dark choice never flashes light.
        StudioAppearance.apply(StudioAppearance.current.rawValue)
        do {
            let loaded = try EnvFileStore.loadIntoProcess(toolName: "ntakker")
            logger.info("loaded \(loaded.count) settings from ~/.tool-agents/ntakker/.env")
        } catch {
            logger.error("could not load ~/.tool-agents/ntakker/.env: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        PlaybackKeys.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Space plays / pauses and ←/→ skip 5 s, unless a text field has focus.
@MainActor
enum PlaybackKeys {
    static var player: (() -> PlayerController?)?
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  let p = player?() else { return event }
            switch event.keyCode {
            case 49: p.togglePlay(); return nil          // space
            case 123: p.skip(by: -5); return nil         // ←
            case 124: p.skip(by: 5); return nil          // →
            default: return event
            }
        }
    }
}
