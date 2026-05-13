// macrec-ui/Views/Sections/PopoverModeSwitcher.swift — plan-015
// Pattern C, FR-IRQ-43 / FR-IRQ-47.
//
// Top-of-popover two-segment toggle: Transcription | Asking. Sits
// immediately under the header row. Default selection: Transcription.
// Persisted across app restarts via `@AppStorage`.
//
// Visual contract: a `.chipBackground`-tinted container with two
// equal-width `Button` segments inside. The selected segment is
// promoted with the `.controlBackground` fill + the standard
// 0.5pt `.controlStroke` hairline + 1pt drop shadow (same shadow
// stack the `.btn` rule uses in the popover baseline).
//
// Keyboard: ⌘1 selects Transcription, ⌘2 selects Asking. The bindings
// are wired here (not at `RootView`) so the shortcut is active whenever
// the popover is key — exactly matching the user's expectation that the
// shortcut is "scoped to the popover".

import SwiftUI

/// Persisted-popover-mode enum. Backed by a plain `String` so the
/// `@AppStorage` slot is stable across future schema changes.
public enum PopoverMode: String, CaseIterable, Sendable {
    case transcription
    case asking

    /// User-visible label used by the segmented control + accessibility.
    var label: String {
        switch self {
        case .transcription: return String(localized: "Transcription")
        case .asking:        return String(localized: "Asking")
        }
    }
}

/// `@AppStorage` key for the persisted mode. Public so other views
/// (`RootView`, `AskingModeView`, future tests) can read the same key
/// without re-deriving the string literal.
public let kPopoverModeStorageKey = "com.macrec.ui.popoverMode"

/// Two-segment switch — Transcription | Asking. Drives `selection`
/// via the supplied binding; `RootView` is the owner of the binding
/// (typically backed by `@AppStorage(kPopoverModeStorageKey)`).
struct PopoverModeSwitcher: View {
    @Environment(\.palette) private var palette
    @Binding var selection: PopoverMode

    var body: some View {
        HStack(spacing: 4) {
            segment(.transcription)
            segment(.asking)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.chipBackground)
        )
        // Keyboard accelerators (FR-IRQ-47).
        .background(
            VStack {
                Button("") { selection = .transcription }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { selection = .asking }
                    .keyboardShortcut("2", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
    }

    @ViewBuilder
    private func segment(_ mode: PopoverMode) -> some View {
        let isSelected = (selection == mode)
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selection = mode
            }
        } label: {
            Text(mode.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? palette.accent : palette.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? palette.controlBackground : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? palette.controlStroke : Color.clear,
                            lineWidth: 0.5
                        )
                )
                .shadow(
                    color: isSelected ? Color.black.opacity(0.06) : .clear,
                    radius: 1,
                    x: 0,
                    y: 1
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(mode.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
