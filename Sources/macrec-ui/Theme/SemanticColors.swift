// macrec-ui/Theme/SemanticColors.swift — see project-design.md §UR-4.3
// and plan-008 §B (Unit B).
//
// Two responsibilities live in this file:
//
//   1. `SemanticColors` — an uninstantiable namespace re-exporting
//      `Color(nsColor:)` system-semantic colors as readable `static let`
//      properties. Keeps call sites short:
//        SemanticColors.label
//      instead of:
//        Color(nsColor: .labelColor)
//
//      `Palette` (in `Palette.swift`) deliberately bakes the literal
//      CSS rgba/hex values from the mockup; `SemanticColors` is here
//      for view code that needs a plain AppKit semantic color (e.g.
//      window background) outside the design-token surface.
//
//   2. `EnvironmentValues.palette` — the SwiftUI `EnvironmentKey` that
//      propagates the active `Palette` down the view tree.
//      `AppearanceHostingRoot` (Unit F) writes the key based on
//      `\.colorScheme`; downstream views read via
//      `@Environment(\.palette) private var palette`.
//
// The `EnvironmentKey` default is `.light` so that previews and tests
// that don't inject a value get a deterministic palette.

import AppKit
import SwiftUI

/// Uninstantiable namespace exposing AppKit's semantic colors as
/// SwiftUI `Color` values. Unit E and onward should prefer
/// `\.palette.<token>` for design-token surfaces; reach for
/// `SemanticColors.<x>` only for non-token system surfaces.
enum SemanticColors {
    static let label: Color = Color(nsColor: .labelColor)
    static let secondaryLabel: Color = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel: Color = Color(nsColor: .tertiaryLabelColor)
    static let separator: Color = Color(nsColor: .separatorColor)
    static let windowBackground: Color = Color(nsColor: .windowBackgroundColor)
    static let underPageBackground: Color = Color(nsColor: .underPageBackgroundColor)
    static let controlBackground: Color = Color(nsColor: .controlBackgroundColor)
    static let controlAccent: Color = Color(nsColor: .controlAccentColor)
}

// MARK: - EnvironmentKey for the active Palette

/// Private key — call sites must go through `EnvironmentValues.palette`
/// (or `@Environment(\.palette)`); the key itself is an implementation
/// detail.
private struct PaletteKey: EnvironmentKey {
    /// Default is `.light` so previews / tests that don't inject a
    /// value still get a deterministic, fully-populated palette
    /// (avoids surprise white-on-white when developing a view
    /// outside the popover host).
    static let defaultValue: Palette = .light
}

extension EnvironmentValues {
    /// Resolved theme palette for the current view subtree. Selected
    /// upstream by `AppearanceHostingRoot` (Unit F) based on the
    /// effective `\.colorScheme`; downstream views read via
    /// `@Environment(\.palette)`. Default value is `Palette.light`.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
