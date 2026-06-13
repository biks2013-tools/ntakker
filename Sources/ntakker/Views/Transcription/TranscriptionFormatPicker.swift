// ntakker/Views/Transcription/TranscriptionFormatPicker.swift — see
// project-design.md §LT-8.1 and plan-003 Phase G.
//
// SwiftUI `Picker` over the four `TranscriptFormat` values
// (jsonl | srt | vtt | txt). Default `jsonl`. Disabled while a
// session is in flight (AC-LT-19) and only rendered when the
// transcription provider is non-`None` (popover layout §LT-8.1).
//
// Persistence: stored under `com.ntakker-cli.ui.transcriptFormat`.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Format picker for the sidecar transcript file.
struct TranscriptionFormatPicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted format raw value. Default `"jsonl"`.
    @AppStorage("com.ntakker-cli.ui.transcriptFormat")
    private var formatRaw: String = TranscriptFormat.jsonl.rawValue

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    private var formatBinding: Binding<TranscriptFormat> {
        Binding(
            get: { TranscriptFormat(rawValue: formatRaw) ?? .jsonl },
            set: { formatRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker(String(localized: "Transcript format"), selection: formatBinding) {
            Text("jsonl").tag(TranscriptFormat.jsonl)
            Text("srt").tag(TranscriptFormat.srt)
            Text("vtt").tag(TranscriptFormat.vtt)
            Text("txt").tag(TranscriptFormat.txt)
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "File format for the transcript sidecar."))
    }
}
