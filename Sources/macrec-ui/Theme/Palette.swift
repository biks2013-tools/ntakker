// macrec-ui/Theme/Palette.swift — see project-design.md §UR-3 / §UR-4.2
// and plan-008 §B (Unit B). This file is the single source of truth for
// the SwiftUI reification of the 16 CSS custom properties declared in
// `docs/design/mockups/popover-redesign.html` (`.light` block at lines
// 147..164, `.dark` block at lines 179..196).
//
// CSS-token → Swift-token mapping (mockup is authoritative):
//
//   --label             → label                       (text)
//   --value             → value                       (text)
//   --secondary         → secondary                   (text)
//   --tertiary          → tertiary                    (text)
//   --separator         → separator                   (stroke)
//   --group-bg          → groupBackground             (surface)
//   --group-stroke      → groupStroke                 (stroke)
//   --control-bg        → controlBackground           (surface)
//   --control-stroke    → controlStroke               (stroke)
//   --field-bg          → fieldBackground             (surface)
//   --chip-bg           → chipBackground              (surface)
//   --accent            → accent                      (brand)
//   --success-bg        → successBackground           (chip fill)
//   --success-fg        → successForeground           (chip text)
//   --success-dot       → successDot                  (chip indicator)
//   --record-grad start → recordGradientStart         (button gradient stop 0)
//   --record-grad end   → recordGradientEnd           (button gradient stop 1)
//
// CSS shadow tokens (`--control-shadow`, `--record-shadow`) are NOT
// reified here — they are layout/decoration concerns implemented at
// the call site by the consumer view (Unit E onward).
//
// Per design §UR-8.4 (ADR-5): we deliberately do NOT use xcassets
// color sets — a single Swift struct keeps the CSS-token mapping
// auditable and unit-testable.

import SwiftUI

/// Brand-and-semantic token palette. The 17 stored properties below
/// are the SwiftUI reification of the 16 CSS custom properties from
/// `docs/design/mockups/popover-redesign.html` (the `--record-grad`
/// linear gradient is split across two stops:
/// `recordGradientStart` + `recordGradientEnd`).
///
/// Two static instances exist — `.light` and `.dark` — selected by the
/// current `\.colorScheme` environment value (see
/// `SemanticColors.swift` for the `EnvironmentKey`).
///
/// Conforms to `Equatable` so `XCTAssertEqual` / `#expect(==)` can
/// compare instances in `PaletteTests`. Conforms to `Sendable` so it
/// can flow across actor boundaries (e.g. captured by `@MainActor`
/// view bodies from a non-isolated context).
///
/// **Do NOT** add `.regularMaterial` inside `Form` section backgrounds
/// — the popover host already provides vibrancy; double-frost is wrong.
struct Palette: Equatable, Sendable {
    // Text tokens
    let label: Color            // CSS --label
    let value: Color            // CSS --value
    let secondary: Color        // CSS --secondary
    let tertiary: Color         // CSS --tertiary

    // Stroke / separator
    let separator: Color        // CSS --separator
    let groupStroke: Color      // CSS --group-stroke
    let controlStroke: Color    // CSS --control-stroke

    // Surface fills
    let groupBackground: Color  // CSS --group-bg
    let controlBackground: Color// CSS --control-bg
    let fieldBackground: Color  // CSS --field-bg
    let chipBackground: Color   // CSS --chip-bg

    // Accent
    let accent: Color           // CSS --accent

    // Brand: success chip
    let successBackground: Color // CSS --success-bg
    let successForeground: Color // CSS --success-fg
    let successDot: Color        // CSS --success-dot

    // Brand: record button (CSS --record-grad linear-gradient stops)
    let recordGradientStart: Color  // first stop of --record-grad
    let recordGradientEnd: Color    // last  stop of --record-grad

    // MARK: - Variants (mockup is authoritative)

    /// Light variant. Mirrors the `.light` block (lines 147..164) of
    /// `docs/design/mockups/popover-redesign.html`.
    static let light: Palette = Palette(
        // Text
        label:               Color(red: 0,   green: 0,   blue: 0,   opacity: 0.86),
        value:               Color(red: 0,   green: 0,   blue: 0,   opacity: 0.92),
        secondary:           Color(red: 0,   green: 0,   blue: 0,   opacity: 0.55),
        tertiary:            Color(red: 0,   green: 0,   blue: 0,   opacity: 0.40),
        // Stroke
        separator:           Color(red: 0,   green: 0,   blue: 0,   opacity: 0.08),
        groupStroke:         Color(red: 0,   green: 0,   blue: 0,   opacity: 0.06),
        controlStroke:       Color(red: 0,   green: 0,   blue: 0,   opacity: 0.12),
        // Surface
        groupBackground:     Color(red: 1,   green: 1,   blue: 1,   opacity: 0.55),
        controlBackground:   Color(hex: 0xFFFFFF),
        fieldBackground:     Color(hex: 0xFFFFFF),
        chipBackground:      Color(red: 0,   green: 0,   blue: 0,   opacity: 0.05),
        // Accent
        accent:              Color(hex: 0x007AFF),
        // Success chip
        successBackground:   Color(red: 48.0/255.0, green: 209.0/255.0, blue: 88.0/255.0, opacity: 0.18),
        successForeground:   Color(hex: 0x0A6E2C),
        successDot:          Color(hex: 0x30D158),
        // Record gradient stops
        recordGradientStart: Color(hex: 0xFF6258),
        recordGradientEnd:   Color(hex: 0xFF2D20)
    )

    /// Dark variant. Mirrors the `.dark` block (lines 179..196) of
    /// `docs/design/mockups/popover-redesign.html`.
    static let dark: Palette = Palette(
        // Text
        label:               Color(red: 1,   green: 1,   blue: 1,   opacity: 0.92),
        value:               Color(red: 1,   green: 1,   blue: 1,   opacity: 0.96),
        secondary:           Color(red: 1,   green: 1,   blue: 1,   opacity: 0.55),
        tertiary:            Color(red: 1,   green: 1,   blue: 1,   opacity: 0.38),
        // Stroke
        separator:           Color(red: 1,   green: 1,   blue: 1,   opacity: 0.09),
        groupStroke:         Color(red: 1,   green: 1,   blue: 1,   opacity: 0.08),
        controlStroke:       Color(red: 1,   green: 1,   blue: 1,   opacity: 0.14),
        // Surface
        groupBackground:     Color(red: 1,   green: 1,   blue: 1,   opacity: 0.06),
        controlBackground:   Color(red: 1,   green: 1,   blue: 1,   opacity: 0.12),
        fieldBackground:     Color(red: 0,   green: 0,   blue: 0,   opacity: 0.28),
        chipBackground:      Color(red: 1,   green: 1,   blue: 1,   opacity: 0.08),
        // Accent
        accent:              Color(hex: 0x0A84FF),
        // Success chip
        successBackground:   Color(red: 48.0/255.0, green: 209.0/255.0, blue: 88.0/255.0, opacity: 0.22),
        successForeground:   Color(hex: 0x6CE89A),
        successDot:          Color(hex: 0x30D158),
        // Record gradient stops
        recordGradientStart: Color(hex: 0xFF6B61),
        recordGradientEnd:   Color(hex: 0xFF3B30)
    )

    // MARK: - Convenience

    /// Linear gradient for the record button — composed from the
    /// `--record-grad` stops above. Top → bottom (matches the CSS
    /// `linear-gradient(180deg, … 0%, … 100%)`).
    var recordButtonGradient: LinearGradient {
        LinearGradient(
            colors: [recordGradientStart, recordGradientEnd],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Hex helper (file-private)

extension Color {
    /// Build a SwiftUI `Color` from a 24-bit packed RGB integer (e.g.
    /// `0x007AFF`). The optional `opacity` defaults to `1`.
    ///
    /// Intentionally `internal` (and lives in this file) so that the
    /// `Palette` constants above stay readable. Not part of the public
    /// API — Unit E and onward should write `palette.<token>`, never
    /// reach for `Color(hex:)` directly.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}
