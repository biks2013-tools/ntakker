// macrec-ui/Views/Footer/RecordButton.swift — plan-008 Unit E
// (project-design §UR-4.12).
//
// Red-gradient "Start Recording" button matching the mockup
// `.record-btn` rule (docs/design/mockups/popover-redesign.html lines
// 448..471). The button is intentionally NOT wired into the footer
// composition — Unit E preserves the existing `ControlBar()` as the
// action surface so the visibility matrix + transcription-gate logic
// stay in one place. This file ships the visual primitive so a future
// unit (or the Phase 9 test builders) can swap it into the footer
// without redrawing the artwork.
//
// Visual contract per mockup lines 448..471:
//   * `palette.recordButtonGradient` (linear top→bottom, two stops).
//   * White foreground, 13.5pt semibold.
//   * 8pt rounded corners; 7/16/7/12pt padding.
//   * Leading "rec glyph" — white circle with a subtle white halo.
//   * Subtle drop shadow.

import SwiftUI

/// Red-gradient record button. Standalone visual primitive — the
/// caller wires its own action.
struct RecordButton: View {
    @Environment(\.palette) private var palette

    let action: () -> Void
    var label: String = String(localized: "Start Recording")

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                recGlyph
                Text(label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.recordButtonGradient)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var recGlyph: some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.4), lineWidth: 1.5)
            )
    }
}
