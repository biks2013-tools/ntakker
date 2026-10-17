// ntakker/Views/Transcription/ApiKeyStatusRow.swift — plan-008 Unit D
//
// Reusable API-key sub-row. Renders the locked-in design from v1.6
// (mockup `docs/design/mockups/popover-redesign.html`, sections
// "Soniox API Key" / "Gemini API Key"):
//
//   <PROVIDER> API KEY                         ● Configured
//   ┌──────────────────────────────────┐ ┌─────────┐
//   │ ••••••••••••••••••••••••••       │ │Replace…│
//   └──────────────────────────────────┘ └─────────┘
//
// When the user clicks `Replace…` the field becomes an editable
// `SecureField` and the trailing button area shows `Save` + `Cancel`.
// After Save the row collapses back to the dotted/Replace state.
//
// Per UR-ADR-8 (frozen) the chip is presence-only in v1.6.

import SwiftUI

/// API-key sub-row for a provider. Renders the locked-in design from
/// v1.6 (mockup popover-redesign.html § "Soniox API Key" / "Gemini API Key").
///
/// Two visual states:
/// - Collapsed (default when a key exists): "•••••••••• [Replace…]"
/// - Editing (after Replace tapped, or when no key exists): editable
///   secure field + Save + Cancel buttons.
public struct ApiKeyStatusRow: View {

    /// Display name for the provider section header (e.g. "Soniox", "Gemini").
    let providerDisplayName: String

    /// Currently stored / resolved API key (nil or empty == "Not configured").
    let resolvedKey: String?

    /// Placeholder text shown while editing (e.g. "Paste SONIOX_API_KEY value").
    let editPlaceholder: String

    /// Called when the user commits a new key (non-empty after trim).
    let onSave: (String) -> Void

    /// Called when the user clears the stored key (Cancel during editing
    /// reverts to collapsed; this callback is for an explicit destructive
    /// action — for v1.6 it can be unused / no-op since "Replace…" is the
    /// only entry to editing. Keep the parameter for future use.)
    let onClear: () -> Void

    public init(
        providerDisplayName: String,
        resolvedKey: String?,
        editPlaceholder: String,
        onSave: @escaping (String) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.providerDisplayName = providerDisplayName
        self.resolvedKey = resolvedKey
        self.editPlaceholder = editPlaceholder
        self.onSave = onSave
        self.onClear = onClear
    }

    @State private var isEditing = false
    @State private var draftKey: String = ""

    /// System colours: the row lives in Settings windows of both apps
    /// (it used ntakker's popover palette before plan-025).
    private enum palette {
        static let secondary = Color.secondary
        static let tertiary = Color(nsColor: .tertiaryLabelColor)
        static let value = Color.primary
        static let fieldBackground = Color(nsColor: .textBackgroundColor)
        static let controlStroke = Color(nsColor: .separatorColor)
    }

    private var isPresent: Bool { (resolvedKey?.isEmpty == false) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(providerDisplayName.uppercased()) API KEY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.06 * 11)
                    .foregroundStyle(palette.secondary)
                Spacer()
                ApiKeyStatusChip(present: isPresent)
            }

            if isEditing {
                editingFieldStack
            } else {
                collapsedFieldStack
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var collapsedFieldStack: some View {
        HStack(spacing: 5) {
            // Mask: show dots if a key is stored, else placeholder italic
            Text(isPresent ? maskedKey : "No key configured")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isPresent ? palette.value : palette.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.fieldBackground, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(palette.controlStroke, lineWidth: 0.5)
                )

            Button(isPresent ? "Replace…" : "Add…") {
                draftKey = ""
                isEditing = true
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var editingFieldStack: some View {
        HStack(spacing: 5) {
            SecureField(editPlaceholder, text: $draftKey)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.fieldBackground, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(palette.controlStroke, lineWidth: 0.5)
                )

            Button("Save") {
                let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onSave(trimmed)
                draftKey = ""
                isEditing = false
            }
            .controlSize(.small)
            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel", role: .cancel) {
                draftKey = ""
                isEditing = false
            }
            .controlSize(.small)
        }
    }

    private var maskedKey: String {
        // Render up to 28 dots so the field doesn't reveal length.
        String(repeating: "•", count: 26)
    }
}

#Preview("Configured") {
    ApiKeyStatusRow(
        providerDisplayName: "Soniox",
        resolvedKey: "fake-real-looking-key-1234567890abcdef",
        editPlaceholder: "Paste SONIOX_API_KEY value",
        onSave: { _ in },
        onClear: { }
    )
    .padding()
    .frame(width: 360)
}

#Preview("Empty") {
    ApiKeyStatusRow(
        providerDisplayName: "Gemini",
        resolvedKey: nil,
        editPlaceholder: "Paste GOOGLE_API_KEY value",
        onSave: { _ in },
        onClear: { }
    )
    .padding()
    .frame(width: 360)
}
