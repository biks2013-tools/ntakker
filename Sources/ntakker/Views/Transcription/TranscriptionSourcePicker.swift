// ntakker/Views/Transcription/TranscriptionSourcePicker.swift — see
// project-design.md §LT-8.1 and plan-003 Phase G.
//
// SwiftUI `Picker` over the four `TranscriptionSource` values
// (system | mic | mixed | both). Default `mixed`. Disabled while a
// session is in flight (AC-LT-19) and only rendered when the
// transcription provider is non-`None` (per the popover layout
// §LT-8.1 — disclosure-group child).
//
// Persistence: stored under `com.ntakker-cli.ui.transcribeSource`.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Source-routing picker for live transcription.
struct TranscriptionSourcePicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted source raw value. Default `"mixed"`.
    @AppStorage("com.ntakker-cli.ui.transcribeSource")
    private var sourceRaw: String = TranscriptionSource.mixed.rawValue

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    private var sourceBinding: Binding<TranscriptionSource> {
        Binding(
            get: { TranscriptionSource(rawValue: sourceRaw) ?? .mixed },
            set: { sourceRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker(String(localized: "Source"), selection: sourceBinding) {
            Text("System").tag(TranscriptionSource.system)
            Text("Microphone").tag(TranscriptionSource.mic)
            Text("Mixed").tag(TranscriptionSource.mixed)
            Text("Both").tag(TranscriptionSource.both)
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "Audio source fed into the transcription provider."))
    }
}
