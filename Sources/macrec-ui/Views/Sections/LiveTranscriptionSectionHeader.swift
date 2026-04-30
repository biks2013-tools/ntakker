// macrec-ui/Views/Sections/LiveTranscriptionSectionHeader.swift —
// plan-008 Unit E (project-design §UR-4.10).
//
// Section header for the Live Transcription block. Renders the same
// uppercased small-caps "LIVE TRANSCRIPTION" label as the General
// section's title, plus an `NSSwitch`-style toggle at the trailing
// edge. The toggle binds to
// `@AppStorage("com.macrec.ui.transcriptionEnabled")` (declared in
// Unit I and mirrored in `RootView`); flipping it OFF collapses the
// section body to a one-line "Off — toggle on…" hint without mutating
// the persisted `transcribeProvider` (UR-ADR-7).

import SwiftUI

/// Section header for the Live Transcription block — uppercased title
/// on the leading edge, NSSwitch on the trailing edge.
struct LiveTranscriptionSectionHeader: View {
    @Environment(\.palette) private var palette

    /// Master enable/disable switch — UR-ADR-7. Re-declared here so the
    /// Toggle binds locally and the `RootView` does not have to thread
    /// a Binding through.
    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Text("LIVE TRANSCRIPTION")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.07 * 11)
                .foregroundStyle(palette.secondary)
            Spacer()
            Toggle("", isOn: $transcriptionEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .accessibilityLabel(String(localized: "Live transcription"))
                .accessibilityValue(transcriptionEnabled
                                    ? String(localized: "On")
                                    : String(localized: "Off"))
        }
    }
}
