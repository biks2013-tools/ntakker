// macrec-ui/Views/Sections/GeneralSection.swift — plan-008 Unit E
// (project-design §UR-5).
//
// Body of the General section: Format, Layout, and Microphone rows.
// Folder is intentionally NOT here — UR-ADR-9 consolidates the folder
// control into the metadata strip's `SaveToChip`, and the legacy
// `FolderPicker` row is left orphan-but-retained for back-compat.
//
// Per UR-ADR-1 the rows live inside a `Form { Section { ... } }
// .formStyle(.grouped)` which gives us the inset-grouped HIG look + the
// system-managed hairline dividers between rows. We pin the Form's
// vertical axis with `.fixedSize(horizontal: false, vertical: true)`
// at the call site (PopoverSettingsForm / RootView) so the elasticity
// contract from §UR-5 is preserved (the LiveTranscriptPanel is the
// only sibling with `.frame(maxHeight: .infinity)`).
//
// The reused pickers (`FormatPicker`, `LayoutPicker`,
// `MicrophonePicker`) already paint their own label + control via
// `Picker(_:selection:)`; under `.formStyle(.grouped)` they render as
// `LabeledContent`-style rows automatically — we don't need to wrap
// them in a custom HStack.

import SwiftUI

/// General section body — composes the existing Format / Layout /
/// Microphone pickers into a `Form` `Section`.
struct GeneralSection: View {
    var body: some View {
        Section {
            FormatPicker()
            LayoutPicker()
            MicrophonePicker()
        }
    }
}
