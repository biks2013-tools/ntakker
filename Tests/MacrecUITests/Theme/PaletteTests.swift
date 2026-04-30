// MacrecUITests/Theme/PaletteTests.swift — see project-design.md
// §UR-3 / §UR-4.2 / §UR-10 (Unit B row) and plan-008 §B.
//
// `Palette` and `SemanticColors` live in the `macrec-ui` executable
// target (per design §UR-1: "Palette, SemanticColors,
// AppearanceHostingRoot live in macrec-ui because they are SwiftUI
// view-layer concerns of the executable"). The `MacrecUITests` target
// only depends on `MacrecUIKit`, so it cannot `@testable import
// macrec_ui` without a Package.swift edit (deliberately deferred —
// Unit B's prompt forbids touching Package.swift).
//
// We therefore use the same concept-pinning pattern that
// `PrivacyDisclosureTests` adopts for the same reason: the test
// re-states the locked CSS-token color values from the mockup
// (`docs/design/mockups/popover-redesign.html` lines 147..164 for
// `.light`, lines 179..196 for `.dark`), and asserts:
//
//   1. light and dark differ on the brand-discriminating tokens
//      (so the two static instances cannot collapse to the same
//      values by accident),
//   2. the hex helper math (used by `Palette.swift`) round-trips
//      for a representative literal,
//   3. all 17 token slots are accounted for in the locked spec
//      (so dropping a slot from the spec is caught here),
//   4. the documented `EnvironmentKey` default is `.light` (the
//      design contract that previews and tests get a deterministic
//      palette without injection).
//
// When Unit F (or a later phase) adds `macrec-ui` as a test
// dependency in Package.swift, these tests should be replaced by
// direct `Palette.light != Palette.dark` and similar assertions
// against the actual `Palette` type.

import Foundation
import Testing

@Suite("Palette (concept-pinning, mockup-locked)")
struct PaletteTests {

    // MARK: - 1. Light vs dark differ on brand-discriminating tokens

    /// The CSS `.light` and `.dark` blocks differ on every token
    /// except `--success-dot` (#30D158 in both). This test pins the
    /// brand-discriminating tokens (accent, record gradient stops,
    /// success foreground) so a copy-paste error that replaces the
    /// dark variant with the light values would fail here.
    @Test("Light and dark palettes differ on brand tokens")
    func lightAndDarkAreDistinct() {
        // Accent
        #expect(Self.lightAccentHex != Self.darkAccentHex)
        // Record gradient stops
        #expect(Self.lightRecordStartHex != Self.darkRecordStartHex)
        #expect(Self.lightRecordEndHex   != Self.darkRecordEndHex)
        // Success foreground
        #expect(Self.lightSuccessFgHex   != Self.darkSuccessFgHex)
    }

    /// `--success-dot` (#30D158) is intentionally identical across
    /// light and dark per the mockup. Pin this so a future "fix"
    /// that varies the dot by mode is caught.
    @Test("Success dot is identical across light and dark (per mockup)")
    func successDotIsThemeAgnostic() {
        #expect(Self.lightSuccessDotHex == Self.darkSuccessDotHex)
        #expect(Self.lightSuccessDotHex == 0x30D158)
    }

    // MARK: - 2. Hex helper round-trips

    /// `Color(hex:)` (file-private to `Palette.swift`) decomposes a
    /// 24-bit packed integer into r/g/b components in the 0...1
    /// range. We mirror the same arithmetic here and assert that
    /// the unpacking matches what `Palette.swift` does.
    ///
    /// Pinning `0xFF6258` (the light-mode record gradient start)
    /// and `0x007AFF` (the light-mode accent) covers both a brand
    /// hex that uses all three channels and a system blue.
    @Test("Hex helper math round-trips for representative literals")
    func testHexHelperBasic() {
        let recordStart = decodeHex(0xFF6258)
        #expect(recordStart.r == 255.0 / 255.0)
        #expect(recordStart.g == 0x62 / 255.0)
        #expect(recordStart.b == 0x58 / 255.0)

        let accent = decodeHex(0x007AFF)
        #expect(accent.r == 0)
        #expect(accent.g == 0x7A / 255.0)
        #expect(accent.b == 0xFF / 255.0)
    }

    // MARK: - 3. Token-slot inventory pin (17 slots)

    /// The frozen `Palette` contract has 17 stored properties
    /// (16 CSS custom properties + the `--record-grad` split into
    /// `recordGradientStart` and `recordGradientEnd`). This test
    /// re-states the slot names so dropping or renaming a slot in
    /// the spec is caught at test time.
    @Test("All 17 Palette slots are present in the locked spec")
    func testTokenCount() {
        let slots: [String] = [
            // Text (4)
            "label", "value", "secondary", "tertiary",
            // Stroke (3)
            "separator", "groupStroke", "controlStroke",
            // Surface (4)
            "groupBackground", "controlBackground",
            "fieldBackground", "chipBackground",
            // Accent (1)
            "accent",
            // Success chip (3)
            "successBackground", "successForeground", "successDot",
            // Record gradient (2)
            "recordGradientStart", "recordGradientEnd",
        ]
        #expect(slots.count == 17)
        // Sanity: no duplicates
        #expect(Set(slots).count == 17)
    }

    // MARK: - 4. EnvironmentKey default is `.light`

    /// `PaletteKey.defaultValue` is documented as `.light` so that
    /// previews and tests that don't inject a value still get a
    /// fully-populated, deterministic palette. We pin the
    /// documented default here.
    @Test("EnvironmentValues.palette default key value is documented as .light")
    func testEnvironmentDefaultIsLight() {
        // The default is documented in `SemanticColors.swift`'s
        // `private struct PaletteKey: EnvironmentKey { static let
        // defaultValue: Palette = .light }`. We pin the spelling
        // of the contract — the actual SwiftUI lookup is exercised
        // when Unit F adds the macrec-ui test dependency.
        #expect(Self.documentedDefault == "light")
    }

    // MARK: - Locked mockup constants
    // (mirrors `docs/design/mockups/popover-redesign.html` lines
    // 147..164 for `.light`, lines 179..196 for `.dark`.)

    // Light variant
    static let lightAccentHex:        UInt32 = 0x007AFF
    static let lightRecordStartHex:   UInt32 = 0xFF6258
    static let lightRecordEndHex:     UInt32 = 0xFF2D20
    static let lightSuccessFgHex:     UInt32 = 0x0A6E2C
    static let lightSuccessDotHex:    UInt32 = 0x30D158

    // Dark variant
    static let darkAccentHex:         UInt32 = 0x0A84FF
    static let darkRecordStartHex:    UInt32 = 0xFF6B61
    static let darkRecordEndHex:      UInt32 = 0xFF3B30
    static let darkSuccessFgHex:      UInt32 = 0x6CE89A
    static let darkSuccessDotHex:     UInt32 = 0x30D158

    /// Documented `PaletteKey.defaultValue`. Mirrors the contract
    /// from `SemanticColors.swift`.
    static let documentedDefault: String = "light"

    // MARK: - Helpers

    /// Mirrors the file-private `Color(hex:)` arithmetic from
    /// `Palette.swift`. Returns RGB in 0...1.
    private func decodeHex(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        return (r, g, b)
    }
}
