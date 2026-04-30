// macrec-ui/Theme/AppearanceHostingRoot.swift — see project-design.md
// §UR-4.4 (signature) and §UR-6 (propagation diagram); plan-008 §F
// (Unit F).
//
// SwiftUI wrapper that bridges the persisted `AppearanceMode` choice
// (in `UserDefaults.standard` under `AppearanceMode.userDefaultsKey`)
// into both `.preferredColorScheme(_:)` AND the `\.palette` environment
// value, so every descendant view automatically picks up the active
// theme tokens.
//
// Per `docs/reference/research-nshostingcontroller-appearance.md`,
// `@AppStorage` reactivity propagates through `NSHostingController` on
// macOS 26 — no `NotificationCenter` observer is required for
// "Follow System" to work. The OS appearance flips trigger a SwiftUI
// invalidation through `@Environment(\.colorScheme)`, and the body
// re-evaluates with the new palette automatically.
//
// Used in two host sites:
//   * `PopoverController` — wraps `RootView` inside the popover's
//     `NSHostingController` (so the popover honors the user's choice).
//   * `MacrecUIApp` — wraps `SettingsRootView` inside the `Settings { }`
//     scene (so the Settings window honors the same choice).

import SwiftUI
import MacrecUIKit

/// Bridges the persisted `AppearanceMode` choice into both
/// `.preferredColorScheme(_:)` and the `\.palette` environment value
/// for the wrapped subtree. See file header for design rationale.
///
/// By reading `\.colorScheme` directly we always know which palette to
/// inject, even when `mode == .system`. Without that read, the
/// `\.palette` injection would not update on a system flip — SwiftUI's
/// automatic invalidation on `\.colorScheme` change handles the body
/// re-evaluation; this is the canonical pattern.
struct AppearanceHostingRoot<Content: View>: View {

    @AppStorage(AppearanceMode.userDefaultsKey)
    private var raw: String = AppearanceMode.defaultRawValue

    @Environment(\.colorScheme) private var systemColorScheme

    @ViewBuilder var content: () -> Content

    var body: some View {
        // Unknown raw values collapse to `.system` (documented fallback;
        // see AppearancePersistenceTests `unknownValueFallback`).
        let mode = AppearanceMode(rawValue: raw) ?? .system

        // For `.system`, defer to SwiftUI's `\.colorScheme` which is
        // already tracking the OS / parent's choice.
        let effective: ColorScheme = mode.colorScheme ?? systemColorScheme

        content()
            .preferredColorScheme(mode.colorScheme)
            .environment(\.palette, effective == .dark ? .dark : .light)
    }
}
