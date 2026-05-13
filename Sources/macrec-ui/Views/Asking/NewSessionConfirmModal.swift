// macrec-ui/Views/Asking/NewSessionConfirmModal.swift — plan-015
// Pattern C, FR-IRQ-55 + FR-IRQ-58.
//
// The three-option confirmation modal shown when the user clicks the
// `New Session` button while the session is stopped. The options are:
//
//   1. Save and start new — runs the Save flow first, then clears.
//   2. Discard and start new — clears immediately, no save.
//   3. Cancel — closes the modal; nothing else happens.
//
// Per FR-IRQ-58, Esc and click-outside both equal Cancel. No keyboard
// accelerator pre-selects a destructive option — the user must click
// one of the three explicitly.

import SwiftUI

struct NewSessionConfirmModal: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Tap on "Save and start new" — owner runs the Save flow first,
    /// then triggers `clearSession()` on the toast.
    let onSaveAndStart: () -> Void
    /// Tap on "Discard and start new" — owner clears immediately.
    let onDiscardAndStart: () -> Void
    /// Tap on Cancel or Esc — owner closes the modal.
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Start a new session?"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.label)
                Text(String(localized: "Choose what to do with the current transcript and Q&A before starting fresh."))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
            }

            VStack(spacing: 8) {
                optionRow(
                    title: String(localized: "Save and start new"),
                    subtitle: String(localized: "Save the current session, then clear the popover for a new recording."),
                    style: .primary,
                    action: onSaveAndStart
                )
                optionRow(
                    title: String(localized: "Discard and start new"),
                    subtitle: String(localized: "Throw away the current transcript and Q&A. This cannot be undone."),
                    style: .destructive,
                    action: onDiscardAndStart
                )
            }

            HStack {
                Spacer()
                Button(action: onCancel) {
                    Text(String(localized: "Cancel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.label)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(palette.controlBackground)
                        )
                        .overlay(
                            Capsule().strokeBorder(palette.controlStroke, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.groupStroke, lineWidth: 0.5)
        )
    }

    private enum OptionStyle { case primary, destructive }

    @ViewBuilder
    private func optionRow(
        title: String,
        subtitle: String,
        style: OptionStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style == .primary ? "tray.and.arrow.down" : "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style == .primary ? palette.accent : Color.red)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.groupStroke, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
