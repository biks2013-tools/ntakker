// ntakker/Views/Sections/LiveTranscriptionSection.swift —
// plan-008 Unit E (project-design §UR-5).
//
// Body of the Live Transcription section. The `transcriptionEnabled`
// master switch lives on the section header (UR-ADR-7); when OFF the
// section body collapses to a single hint line so the persisted
// engine + key state survives without consuming popover height.
//
// When ON, the section renders `SingleTranscriptionControls()` — the
// four-row block (Transcribe / Source / Transcript format / Language)
// plus the per-provider API-key row.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Body of the Live Transcription section. Wrapped in a `Section` so it
/// composes cleanly inside the parent `Form` (UR-ADR-1).
struct LiveTranscriptionSection: View {
    @Environment(\.palette) private var palette

    @AppStorage("com.ntakker-cli.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    var body: some View {
        Section {
            if transcriptionEnabled {
                SingleTranscriptionControls()
            } else {
                Text("Off — toggle on to enable live transcription")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiary)
                    .padding(.vertical, 2)
            }
        }
    }
}
