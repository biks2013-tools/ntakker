// macrec-ui/Views/FormatPicker.swift — see project-design.md §15.4
// (RecordingController inputs) and plan-002-toolbar-ui.md §3 Phase E
// (FR-38, AC-UI-8).
//
// SwiftUI `Picker` over the three locked `OutputFormat` values
// (`m4a`, `wav`, `caf`). Disabled while a session is in flight so the
// user cannot mid-session change the encoder format that has already
// been baked into the active `RecordingSession` (AC-UI-8).
//
// Persistence: the chosen format is stored under the canonical
// `com.macrec.ui.format` UserDefaults key (per project-functions FR-38).
// This is UI state, not engine configuration — the "no fallback config"
// rule does not apply (explicitly carved out by plan-002 §3 Phase E
// gate criteria).

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Format picker with three options (`m4a`, `wav`, `caf`).
struct FormatPicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted format raw value (one of `"m4a"`, `"wav"`, `"caf"`).
    /// Default `.m4a` per FR-1 (AAC is the project's primary codec).
    @AppStorage("com.macrec.ui.format") private var formatRaw: String = OutputFormat.m4a.rawValue

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// Bind the picker to a typed `OutputFormat` derived from the raw
    /// `@AppStorage` string. Falls back to `.m4a` only when the stored
    /// value cannot be decoded — UI defaulting, not engine defaulting.
    private var formatBinding: Binding<OutputFormat> {
        Binding(
            get: { OutputFormat(rawValue: formatRaw) ?? .m4a },
            set: { formatRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker(String(localized: "Format"), selection: formatBinding) {
            Text("m4a").tag(OutputFormat.m4a)
            Text("wav").tag(OutputFormat.wav)
            Text("caf").tag(OutputFormat.caf)
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "Container format for the next recording."))
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
