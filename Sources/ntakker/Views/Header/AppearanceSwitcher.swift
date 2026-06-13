// ntakker/Views/Header/AppearanceSwitcher.swift — see plan-008 Unit G
// (project-design §UR-10) and §UR-4.1 / §UR-4.2 for the consumed
// contracts (`AppearanceMode`, `\.palette`).
//
// Compact icon-menu that lives inline with the popover's metadata
// strip (composed by Unit E into `RootView`). Lets the user switch
// between System / Light / Dark themes without leaving the popover.
// Persists via the canonical `AppearanceMode.userDefaultsKey` so the
// choice round-trips with the Settings → General picker (Unit F) and
// the host-level `.preferredColorScheme(_:)` plumbing (Unit C).
//
// Visual goals (mockup is authoritative for surrounding strip — this
// switcher is a new addition not yet in the HTML mockup):
//   * Tiny 16×16 trigger icon — does not dominate the strip.
//   * Same compact font as the strip (`size: 11`, `weight: .semibold`).
//   * Standard macOS popup with checkmark on the active row (the
//     `Picker` inside `Menu` provides this for free with `.inline`).
//   * Themed via `\.palette.secondary` — yes, the "switch the theme"
//     control is itself themed; that's correct so it blends with
//     whichever theme is currently active.
//
// Accessibility:
//   * `accessibilityLabel("Appearance")` + `accessibilityValue(<mode>)`
//     so VoiceOver announces "Appearance, System" (or Light/Dark).
//   * `.help(...)` provides the hover tooltip.
//   * `Menu` is keyboard-focusable: Tab to enter, Space/Return to open.

import SwiftUI
import NtakkerUIKit

/// Compact icon-menu in the popover's metadata strip that lets the
/// user switch between System / Light / Dark themes. Persists via the
/// canonical `AppearanceMode.userDefaultsKey`.
///
/// Composed by `RootView` (Unit E) into the metadata strip alongside
/// the permission pill, folder, and recording state. Owns no state
/// beyond the `@AppStorage` binding — the parent does not need to
/// thread anything through.
struct AppearanceSwitcher: View {

    // MARK: - Persisted preference

    /// Single source of truth for the appearance choice. Mirrors the
    /// `@AppStorage` declarations in `NtakkerUIApp` (Settings scene),
    /// `AppearanceHostingRoot` (popover host), and
    /// `GeneralSettingsView` (Settings picker). All four references
    /// MUST use `AppearanceMode.userDefaultsKey` — never the raw
    /// string literal — so the magic key lives in one place.
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var raw: String = AppearanceMode.defaultRawValue

    // MARK: - Theming

    @Environment(\.palette) private var palette

    // MARK: - Derived

    /// Decode the persisted raw string into a typed mode for the
    /// trigger icon and accessibility value. Falls back to `.system`
    /// if the stored string is unparseable (defensive — the picker
    /// only writes valid raw values, but `@AppStorage` does not
    /// validate on read).
    private var current: AppearanceMode {
        AppearanceMode(rawValue: raw) ?? .system
    }

    // MARK: - View

    var body: some View {
        Menu {
            // Inline Picker inside Menu yields a flat list with a
            // checkmark next to the selected row — exactly the
            // standard macOS appearance-picker affordance.
            Picker("Appearance", selection: $raw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImageName)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: current.systemImageName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: \(current.displayName)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(current.displayName)
    }
}

#Preview("Inline in metadata strip") {
    HStack(spacing: 8) {
        Text("recording-2026-04-30-20-25").font(.headline)
        Spacer()
        AppearanceSwitcher()
    }
    .padding()
    .frame(width: 360)
}
