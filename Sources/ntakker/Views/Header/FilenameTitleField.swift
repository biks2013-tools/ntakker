// ntakker/Views/Header/FilenameTitleField.swift — plan-008 Unit E.
//
// Big semibold "title" rendition of the filename field that lives at
// the top of the popover header (mockup `header-input` style — see
// docs/design/mockups/popover-redesign.html lines 204..222).
//
// This view does NOT replace `FilenameField.swift` — that view stays
// for back-compat and the test target still pins it. The new
// `FilenameTitleField` reuses the SAME `@AppStorage` slot
// (`com.ntakker-cli.ui.basename`) and the SAME placeholder
// (`FilenameGenerator.default(now:)`), so the user's typed value and
// the engine's fallback semantics are identical.
//
// Visual contract per mockup lines 204..222:
//   * 17pt semibold, slight negative letter-spacing.
//   * Transparent background by default; `.chipBackground` on hover;
//     `.fieldBackground` on focus with a 3pt accent halo.
//   * No border, no rounded outline at rest — the field "is" the title.
//
// SwiftUI compromise: hover/focus visuals are approximated via
// `.background(...)` + a `.background` material swap. The accent halo
// on focus is rendered with an `.overlay(RoundedRectangle.stroke())`
// keyed off `@FocusState` rather than a full glow effect, which is
// adequate for the v1.6 fidelity bar.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Big-title filename field rendered at the top of the popover header.
struct FilenameTitleField: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    @AppStorage("com.ntakker-cli.ui.basename") private var basename: String = ""

    @FocusState private var isFocused: Bool
    @State private var isHovering: Bool = false

    /// Locked while a session is in flight (AC-UI-8).
    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// Deterministic placeholder when `basename` is empty — same source
    /// the engine would use at `start()`.
    private var placeholder: String {
        FilenameGenerator.default(now: Date())
    }

    /// Background color follows the mockup's hover/focus states.
    private var backgroundFill: Color {
        if isFocused { return palette.fieldBackground }
        if isHovering { return palette.chipBackground }
        return Color.clear
    }

    var body: some View {
        TextField(
            String(localized: "Filename"),
            text: $basename,
            prompt: Text(placeholder)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.tertiary)
        )
        .textFieldStyle(.plain)
        .font(.system(size: 17, weight: .semibold))
        .tracking(-0.015 * 17)
        .foregroundStyle(palette.value)
        .focused($isFocused)
        .disabled(isLocked)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(
                    isFocused ? palette.accent.opacity(0.35) : Color.clear,
                    lineWidth: isFocused ? 3 : 0
                )
        )
        .onHover { isHovering = $0 }
        .help(String(localized: "Base filename for the next recording (no extension)."))
    }
}
