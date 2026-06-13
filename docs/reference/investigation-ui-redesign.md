# Investigation: macrec-ui Popover Redesign + Light/Dark Theming

## Executive Summary

The redesign needs to (a) re-skin the popover to a Tahoe System-Settings look, (b) introduce a Light / Dark / Follow-System appearance switcher persisted across launches, and (c) preserve the existing vertically elastic popover and live transcript stream. Across the four sub-topics evaluated below, the recommended stack is:

1. **Color theming** — a hybrid of SwiftUI built-in semantic colors + `Material` + a thin custom `Palette` Swift struct for the few brand-specific tokens (record-button red gradient, success chip). No xcassets.
2. **Appearance switching** — `.preferredColorScheme(_:)` driven by an `AppearanceMode` enum stored in `@AppStorage`, applied to both the `Settings { }` scene **and** the `NSHostingController` hosting the popover, with `PopoverController` observing `UserDefaults.didChangeNotification` (mirroring the existing `heightObserver`).
3. **Persistence** — `@AppStorage("com.macrec.ui.appearance")` reading from `UserDefaults.standard` (which maps to the `com.local.macrec-ui` bundle domain). This matches every other key in the project and is what the acceptance-criterion `defaults read` invocation expects.
4. **Layout primitives** — `Form { Section { … } }.formStyle(.grouped)` for the two inset-grouped sections; custom row content inside each Section for the chip-style "Save to" control and the multi-line API-key cell. This matches macOS Tahoe System Settings out of the box and coexists cleanly with `ScrollView` + `ResizeHandle`.

Each recommendation is the lowest-risk fit given Exception 002 (macOS 26 deployment target), the no-fallback configuration rule, the requirement to preserve all 15 existing `@AppStorage` keys, and the requirement to preserve the popover's vertical elasticity.

## Context

- **What was investigated** — four discrete UI-architecture questions for the macrec-ui popover redesign (color theming primitives, appearance switching mechanism, persistence layer, layout primitives).
- **Driving requirements** — refined-request §13–§17 (theming + appearance + persistence), §3–§9 (visual layout), §10–§11 (preserve vertical elasticity and live transcript), and acceptance criteria 1–12. Plus the codebase-scan §4e–§4h hard constraints (Settings dialog already exists, popover lives outside the SwiftUI scene tree, all 15 `@AppStorage` keys must be preserved).
- **Refined request** — `docs/design/refined-request-ui-redesign.md`
- **Codebase scan** — `docs/reference/codebase-scan-ui-redesign.md`

---

## Topic 1 — Color theming primitives in SwiftUI on macOS 26

### Option 1.A — System semantic colors + small custom palette

Use SwiftUI built-ins (`Color.primary`, `.secondary`, `Color(nsColor: .controlBackgroundColor)`, `Color(nsColor: .windowBackgroundColor)`, `Color(nsColor: .separatorColor)`, `Color(nsColor: .underPageBackgroundColor)`, `Color.accentColor`, system `Material.regular` / `.thick` / `.bar`) for the bulk of tokens, plus a tiny `Palette` Swift file for the items the system does not provide (record-button red gradient, success-chip green, optionally the chip-bg fill).

- **Strengths**
  - Zero maintenance for system colors — Apple keeps them aligned with each OS revision and all variant/accessibility states (Increase Contrast, accent-color override, etc.).
  - Automatic light/dark response — `Color(nsColor:)` already inverts under `.preferredColorScheme(.dark)`.
  - Composes natively with `Material` backgrounds (the popover will use the standard `MenuBarExtra` vibrancy).
  - Minimal new code; no environment plumbing; no asset catalog to bootstrap.
  - Per-view override is trivial — any view can shadow a token by passing a custom value.
- **Weaknesses**
  - Brand colors must still live somewhere — the `Palette` file is unavoidable.
  - Mockup-token names (e.g. `--group-bg`, `--control-bg`) don't map 1:1 to NSColor identifiers; mapping must be documented in `Palette.swift` so future readers know which CSS token corresponds to which NSColor.
- **Effort/Complexity**: Low
- **Risk**: Low
- **Best suited when** the design philosophy is "match macOS HIG, not the mockup pixel-by-pixel" — i.e. when system-theme variations (Increase Contrast, custom accent color) should propagate naturally.

### Option 1.B — Full custom `Palette` struct injected via `@Environment`

Build `Palette { background, label, secondaryLabel, separator, groupBackground, controlBackground, accent, recordGradient, successBackground, successForeground, … }`, with `Palette.light` and `Palette.dark` static instances, injected via `EnvironmentKey` and selected based on `@Environment(\.colorScheme)`.

- **Strengths**
  - Pixel-perfect fidelity to the mockup (every value is hex-locked).
  - Single source of truth; tokens are discoverable via Swift autocomplete (`palette.groupBackground`).
  - Easy to snapshot-test — pass `.light` palette and assert; pass `.dark` palette and assert.
- **Weaknesses**
  - Bypasses system Increase-Contrast and custom-accent integration; color overrides set by the user system-wide will not affect macrec-ui.
  - Every view must read `@Environment(\.palette)` — invasive plumbing across 15+ existing files.
  - Drift risk — Apple may evolve Tahoe's separator/control colors; hex-locked values will look stale.
  - Vibrancy/Material composition is awkward — `Material` is a `ShapeStyle`, not a `Color`; the palette would need parallel `ShapeStyle` properties.
- **Effort/Complexity**: Medium
- **Risk**: Medium (drift + accessibility integration)
- **Best suited when** the app must brand-match precisely across all macOS versions and accessibility settings are not a concern.

### Option 1.C — Asset-catalog color sets (Any/Dark Appearance)

Create `Sources/macrec-ui/Resources/Palette.xcassets` with one Color Set per token, each having `Any Appearance` + `Dark Appearance` variants. Reference via `Color("groupBackground", bundle: .module)`.

- **Strengths**
  - Designer-friendly — color values live in a JSON-ish format easy to edit without recompiling logic.
  - System handles light/dark switch automatically.
  - Per-token override per appearance is trivial.
- **Weaknesses**
  - **The project has zero xcassets today** (codebase scan §1 and §4g). Introducing one means new SPM `resources:` declarations in `Package.swift` and a new build-time path, for a single feature.
  - SPM + xcassets requires `Bundle.module` plumbing which adds friction in tests.
  - Bypasses Increase-Contrast just like Option 1.B (asset-catalog colors are absolute, not semantic).
  - Brand gradients (record-button red gradient) cannot be expressed as a Color Set — they need code anyway.
- **Effort/Complexity**: Medium-High (new build-system surface)
- **Risk**: Medium (touches `Package.swift`, `swift test` resource loading)
- **Best suited when** the project already uses xcassets and a designer iterates on colors independently of code.

### Comparison Matrix — Topic 1

| Criterion | 1.A System + small Palette | 1.B Full custom Palette | 1.C xcassets Color Sets |
|---|---|---|---|
| Maintainability | High (system tracks OS) | Medium (drift risk) | Medium (manual editing) |
| Testability | Medium (system colors opaque) | High (deterministic hex) | Low (`Bundle.module` friction) |
| Mockup fidelity | Medium-High | High | High |
| SwiftUI lifecycle integration | Native | Requires `EnvironmentKey` plumbing | Native |
| Per-view override | Trivial | Trivial via env override | Possible via reassigning Color name |
| Material/vibrancy composition | Native | Awkward (parallel ShapeStyle) | Native for colors only |
| New build-system surface | None | None | New `Package.swift` resources |

### Recommendation — Topic 1

**Option 1.A — System semantic colors + small custom `Palette` Swift file.**

The refined request §13 itself prescribes this approach: "Use SwiftUI semantic colors (`Color(nsColor: .controlBackgroundColor)`, `.windowBackgroundColor`, `.separatorColor`, etc.) and `Material` backgrounds where the mockup shows translucency". §14 confirms the brand-color file location: `Sources/macrec-ui/Theme/Palette.swift`. The codebase scan §4g confirms no xcassets exist today and explicitly states "No `*.xcassets` are needed". Option 1.A is the path of least friction, has the lowest risk, integrates with `MaterialBackground` natively, and respects accessibility overrides.

**Acceptance / risk notes**
- The single `Palette.swift` file should expose `Palette.recordButtonGradient(for: ColorScheme) -> LinearGradient`, `Palette.successChipBackground`, `Palette.successChipForeground`, and `Palette.successDot` — that's it. Everything else must reference an `NSColor` semantic or a `Material`.
- Document the CSS-token → SwiftUI-token mapping in a header comment in `Palette.swift` so the mockup remains auditable.
- Risk: vibrancy of the popover is provided by the `MenuBarExtra` host, not by macrec-ui — the inset-grouped sections inside should NOT add their own `Material` because that produces a "double frosted" look against the popover background. Use `Color(nsColor: .controlBackgroundColor)` for section fill, not `.regularMaterial`.

---

## Topic 2 — Appearance switching mechanism (Light / Dark / Follow System)

The trickiest part is the popover. `RootView` is hosted by `PopoverController` via `NSHostingController` and is **not part of the SwiftUI scene tree** (codebase scan §4e). `.preferredColorScheme(_:)` set on a `Scene` does not automatically propagate to a separately-instantiated `NSHostingController`.

### Option 2.A — `.preferredColorScheme(_:)` on the SwiftUI `Scene`

Add `@AppStorage("com.macrec.ui.appearance") private var appearanceRaw: String = "system"` in `MacrecUIApp`, derive `let scheme: ColorScheme? = AppearanceMode(rawValue: appearanceRaw)?.colorScheme`, and apply `.preferredColorScheme(scheme)` to `Settings { SettingsRootView() }`.

- **Strengths**: Native SwiftUI; no AppKit; lets the system handle "Follow System" via `nil`.
- **Weaknesses**: **Does NOT cover the popover** — `RootView` is hosted outside the `Scene`. The Settings window will respect the choice, the popover will not.
- **Effort/Complexity**: Low
- **Risk**: High — fails acceptance criterion 5 ("the popover header strip contains a 3-way switcher … selecting Dark forces dark rendering").
- **Best suited when**: there is no out-of-scene-tree hosting (not our case).

### Option 2.B — Manipulate `NSApp.appearance` via AppKit

On user switch, set `NSApp.appearance = NSAppearance(named: .aqua)` / `.darkAqua` / `nil`.

- **Strengths**: Reaches every AppKit-hosted surface in one shot — the popover, any future utility windows, even system menu items mounted by the app.
- **Weaknesses**: Mixes AppKit state mutation into SwiftUI; doesn't compose with `.preferredColorScheme` (whichever wins is undefined and version-dependent); harder to express in tests because state lives on a global singleton; the `Settings { }` scene's SwiftUI environment may still override `NSApp.appearance` in some versions, leading to subtle mismatch between the Settings window and the popover.
- **Effort/Complexity**: Low-Medium
- **Risk**: Medium — fragile composition with SwiftUI scenes.
- **Best suited when**: pure AppKit app with no SwiftUI scene tree.

### Option 2.C — Hybrid: `.preferredColorScheme` on Scene + propagate to `NSHostingController`

1. `@AppStorage("com.macrec.ui.appearance")` lives in `MacrecUIApp`; the `Settings { }` scene applies `.preferredColorScheme(resolvedScheme)`.
2. `PopoverController` reads the same `@AppStorage` value (or `UserDefaults.standard.string(forKey: "com.macrec.ui.appearance")`), wraps `RootView` in a small adapter view that applies `.preferredColorScheme(resolvedScheme)` before handing it to `NSHostingController(rootView:)`.
3. `PopoverController` adds a `UserDefaults.didChangeNotification` observer (identical pattern to the existing `heightObserver`, codebase scan §4h) that, when the appearance key changes, re-creates the hosted root or calls `hostingController.rootView = newRoot` with the updated modifier.

- **Strengths**: Stays in pure SwiftUI for the color-scheme propagation; no `NSApp.appearance` mutation; reuses an existing observer pattern that the team already understands; covers both the Settings window AND the popover.
- **Weaknesses**: Requires touching `PopoverController.init` and adding a second observer; small risk of flicker on switch if the entire `rootView` is re-assigned (mitigated by binding the appearance value into the SwiftUI view itself so SwiftUI diff updates the modifier in place).
- **Effort/Complexity**: Low-Medium
- **Risk**: Low — `NSHostingController.rootView` re-assignment is a documented, supported API on macOS 26.
- **Best suited when**: hybrid SwiftUI + AppKit hosting is in play (our exact case).

### Comparison Matrix — Topic 2

| Criterion | 2.A Scene-only | 2.B `NSApp.appearance` | 2.C Hybrid |
|---|---|---|---|
| Covers Settings window | Yes | Yes | Yes |
| Covers popover (the hard part) | **No** | Yes | Yes |
| Handles "Follow System" cleanly | Yes (nil) | Yes (nil) | Yes (nil) |
| Mixes AppKit state | No | Yes | Minimal (re-assigns `rootView`) |
| Testability | High (binding-only) | Low (global singleton) | High |
| Composition with SwiftUI scenes | Native | Fragile | Native |
| Risk of flicker on switch | None | None | Low (mitigatable) |

### Recommendation — Topic 2

**Option 2.C — Hybrid.**

The codebase scan §4e already prescribes this approach: "Apply `.preferredColorScheme` to the `Settings` scene in `MacrecUIApp.body`. In `PopoverController.init`, also apply it to the `AnyView` before wrapping in `NSHostingController`, and add an observer (identical to `heightObserver`) to re-apply it when the preference changes." This is the only option that actually fulfills acceptance criterion 5 for the popover.

**Implementation guidance (the load-bearing part)**

The cleanest pattern is to wrap `RootView` in a tiny container view that itself reads `@AppStorage("com.macrec.ui.appearance")` and applies `.preferredColorScheme`, e.g.:

```swift
struct AppearanceHostingRoot: View {
    @AppStorage("com.macrec.ui.appearance") private var raw: String = "system"
    var body: some View {
        RootView()
            .preferredColorScheme(AppearanceMode(rawValue: raw)?.colorScheme)
    }
}
```

Then `PopoverController` hands `NSHostingController(rootView: AppearanceHostingRoot())` and **no observer is needed at all** for the appearance key — SwiftUI's own `@AppStorage` reactivity handles the redraw because the wrapper view is part of the SwiftUI graph rooted at the hosting controller. The `heightObserver` is still needed because that one drives `NSPopover.contentSize` (an AppKit property), but the appearance value drives a SwiftUI modifier and stays inside the SwiftUI graph.

**Acceptance / risk notes**
- Verify on macOS 26 that `.preferredColorScheme(nil)` on a `NSHostingController`-hosted view actually does follow the system appearance live (it should, but this is one of the subtler corners of the API — see the Technical Research Guidance section below).
- The Settings window also needs the same modifier on its scene root; without it, the Settings window will not switch when the popover does (acceptance criterion 5 implies the choice is global per A-03).

---

## Topic 3 — Persistence layer

### Option 3.A — `@AppStorage("com.macrec.ui.appearance")` on `UserDefaults.standard`

`@AppStorage("com.macrec.ui.appearance") private var raw: String = "system"`, backed by an `AppearanceMode: String, CaseIterable { case system = "system"; case light = "light"; case dark = "dark" }` enum with a `var colorScheme: ColorScheme? { … }` computed property.

- **Strengths**: Matches the convention of all 15 existing keys (codebase scan §4f); zero new infrastructure; SwiftUI reactivity for free; works in tests via `UserDefaults(suiteName:).set(_:forKey:)` overrides; the `defaults read com.local.macrec-ui com.macrec.ui.appearance` invocation in acceptance criterion 6 works directly because `UserDefaults.standard` for an executable maps to the bundle-id domain (codebase scan §4j).
- **Weaknesses**: None material.
- **Effort/Complexity**: Low
- **Risk**: Low
- **Best suited when**: the value is a single primitive UI preference — exactly this case.

### Option 3.B — `@AppStorage` with explicit suite name

`@AppStorage("com.macrec.ui.appearance", store: UserDefaults(suiteName: "com.local.macrec-ui"))`.

- **Strengths**: Explicit about the storage domain.
- **Weaknesses**: Inconsistent with the other 15 keys, all of which use `UserDefaults.standard` (codebase scan §4j). A `defaults read com.local.macrec-ui …` works for both — there's no functional gain.
- **Effort/Complexity**: Low
- **Risk**: Low (but introduces a divergent convention).
- **Best suited when**: the app needs to share defaults across multiple bundles (App Group). Not our case.

### Option 3.C — Custom `ObservableObject` wrapping `UserDefaults`

`final class AppearanceStore: ObservableObject { @Published var mode: AppearanceMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "com.macrec.ui.appearance") } } init() { … } }`.

- **Strengths**: Combine pipelines can subscribe; centralized validation/migration if the value format ever changes.
- **Weaknesses**: Heavy machinery for a single string preference; loses `@AppStorage`'s automatic SwiftUI redraw guarantees unless paired with `@StateObject`/`@ObservedObject` everywhere; inconsistent with project convention; harder to test (must inject the store).
- **Effort/Complexity**: Medium
- **Risk**: Low
- **Best suited when**: there are cross-cutting reactions that need Combine streams (e.g., logging, analytics). Not our case.

### Comparison Matrix — Topic 3

| Criterion | 3.A `@AppStorage` standard | 3.B `@AppStorage` suite | 3.C `ObservableObject` |
|---|---|---|---|
| Matches project convention | Yes (15 of 15 keys) | No | No |
| `defaults read com.local.macrec-ui` works | Yes | Yes | Yes |
| SwiftUI auto-redraw | Yes | Yes | Manual |
| Testability | High | High | Medium |
| Required code | ~3 lines | ~3 lines + suite plumbing | New class + injection |

### Recommendation — Topic 3

**Option 3.A — `@AppStorage("com.macrec.ui.appearance")` on `UserDefaults.standard`.**

This is the project convention (every existing UI preference uses this pattern, codebase scan §4f); it satisfies acceptance criterion 6 directly; and the codebase scan §4l explicitly lists this as the new artifact to add. The `AppearanceMode` enum should live in `Sources/macrec-ui/Theme/AppearanceMode.swift` as a `public enum String` so the test target can `@testable import macrec_ui` and round-trip the rawValue.

**Acceptance / risk notes**
- Honor the no-fallback rule: the `@AppStorage` default `"system"` is an explicit, documented UX default (refined-request §17 and the Constraints clause); not a silent substitution for missing config. This is allowed.
- Add a `static func resolve(_ raw: String) throws -> AppearanceMode` if defensive parsing is ever needed elsewhere — but for `@AppStorage` the default-on-read pattern is fine.
- Test pattern: write three rawValues to a fresh `UserDefaults(suiteName: "test")`, instantiate `AppearanceMode(rawValue:)`, assert `colorScheme` resolves to `nil` / `.light` / `.dark`. (Acceptance criterion 8 sub-bullet 1.)

---

## Topic 4 — Layout primitives for inset-grouped sections + popup-button rows

### Option 4.A — `Form { Section(header:) { … } }.formStyle(.grouped)`

Native SwiftUI Form with grouped style produces the macOS 26 System-Settings inset-card look automatically — rounded section backgrounds, hairline row dividers, label-on-left/control-on-right `LabeledContent` rows, and grouped scroll behavior.

- **Strengths**: Out-of-the-box visual parity with macOS Tahoe System Settings (the mockup target); zero custom drawing; row dividers are system-managed; `LabeledContent { ... } label: { Text("…") }` produces the right-aligned-control row idiom; `.pickerStyle(.menu)` inside a grouped Form renders the chevron `NSPopUpButton` look correctly.
- **Weaknesses**: Custom row content (the "Save to" folder chip, the multi-line API-key cell with status pill + Replace button) requires putting non-`LabeledContent` views inside `Section` — supported, but slight visual nudge to keep them aligned with neighboring rows.
- **Effort/Complexity**: Low
- **Risk**: Low
- **Best suited when**: the design intentionally mirrors System Settings — exactly our case (refined-request §3, "match macOS Tahoe System Settings").

### Option 4.B — Hand-rolled `VStack` + custom rounded backgrounds + `Divider()`

`VStack { ForEach(rows) { row; Divider().padding(.leading, 16) } }.background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))`.

- **Strengths**: Total visual control; arbitrary row content has no constraint.
- **Weaknesses**: Re-implements what `formStyle(.grouped)` does for free; divider insets and padding need to match Tahoe's exact spec which Apple may shift between revisions; loses keyboard-traversal / accessibility behavior baked into `Form`; more code to maintain.
- **Effort/Complexity**: Medium
- **Risk**: Medium (drift from Apple's evolving Tahoe metrics)
- **Best suited when**: the layout deliberately diverges from Form, or contains highly bespoke rows.

### Option 4.C — Hybrid: `Form` outer + custom row content for chips/multi-line cells

Use `Form.formStyle(.grouped)` for the two sections, but render the "Save to" chip as a free-form view inside the metadata strip (above the Form), and the API-key cell as a custom multi-line `VStack` inside its `Section` row.

- **Strengths**: Best of both — system-managed section/divider chrome, full freedom for the irregular cells; matches the mockup's actual structure (chip in the metadata strip is *outside* both Form sections, not inside General).
- **Weaknesses**: Two layout idioms in the same view file — readers must understand both. Mitigated by the strict file-header convention and `// MARK: -` separation already enforced.
- **Effort/Complexity**: Low-Medium
- **Risk**: Low
- **Best suited when**: most of the surface is regular settings rows but a small minority needs bespoke chrome (our exact case — chip and API-key cell are the only outliers).

### Coexistence with `ScrollView` + `ResizeHandle`

The current `RootView` (codebase scan §4h) is a `VStack(spacing: 0)` with a pinned top band, a flexible middle band, and a pinned bottom band. The middle band must contain the two `Form` sections + the `LiveTranscriptPanel` (which claims `.frame(maxHeight: .infinity)`).

`Form.formStyle(.grouped)` on macOS produces its own internal `ScrollView`. Nesting it inside an outer `ScrollView` creates double-scroll, which is wrong. The recommended composition is:

```
VStack(spacing: 0) {
    HeaderStrip(…)                          // pinned top
    Form {
        Section("General")        { … }
        Section("Live Transcription") { … }
    }
    .formStyle(.grouped)
    .fixedSize(horizontal: false, vertical: true)   // critical: lets Form take intrinsic height
    LiveTranscriptPanel(…)
        .frame(maxHeight: .infinity)         // flexible
    Footer(…)                                // pinned bottom
    ResizeHandle(height: $popoverHeight)
}
.frame(height: clampedPopoverHeight, alignment: .top)
```

`fixedSize(horizontal: false, vertical: true)` on the Form is the critical piece — it tells SwiftUI to give the Form its intrinsic content height, leaving the leftover vertical space to `LiveTranscriptPanel.frame(maxHeight: .infinity)`. This mirrors the pattern documented in codebase-scan §4h point 4 ("controls band uses `.fixedSize(horizontal: false, vertical: true)`") and is exactly how the existing layout already works.

### Comparison Matrix — Topic 4

| Criterion | 4.A Pure Form | 4.B Hand-rolled VStack | 4.C Hybrid |
|---|---|---|---|
| Tahoe System-Settings look | Free | Manual (drift risk) | Free |
| Custom chip / multi-line cells | Workable | Trivial | Trivial |
| Hairline row dividers | System | Manual | System |
| Keyboard/accessibility | Built-in | Re-implement | Built-in |
| Coexists with ResizeHandle / vertical elasticity | Yes (with `.fixedSize`) | Yes | Yes (with `.fixedSize`) |
| LOC | Lowest | Highest | Low |

### Recommendation — Topic 4

**Option 4.C — Hybrid: `Form { Section { … } }.formStyle(.grouped)` for the two sections, custom views for the metadata-strip "Save to" chip (outside the Form) and the multi-line API-key cell (inside its Section as a free-form row).**

This matches the mockup's actual structure (chip lives in the metadata strip, not in General), gets the System-Settings chrome for free, and uses `.fixedSize(horizontal: false, vertical: true)` to coexist with `LiveTranscriptPanel`'s `.frame(maxHeight: .infinity)` and the existing `ResizeHandle`-driven height.

**Acceptance / risk notes**
- The "Live Transcription" section header NSSwitch toggle (refined-request §6) goes in the Section's header parameter: `Section { … } header: { HStack { Text("Live Transcription"); Spacer(); Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden() } }`. Confirmed supported by `Form.formStyle(.grouped)` on macOS 26.
- API-key sub-row is rendered as a `VStack(alignment: .leading)` inside its Section row; the pill + `Replace…` button form an `HStack` at the top, optional expiry sub-text underneath.
- Risk: `Form.formStyle(.grouped)` adds its own outer scroll behavior. Use `.fixedSize(horizontal: false, vertical: true)` on the Form to make it report its intrinsic height. Verify the Form does not consume drag gestures intended for `ResizeHandle` (separate hit areas, so it should not).
- Existing `@AppStorage("com.macrec.ui.transcriptionExpanded")` and `"com.macrec.ui.recordingSettingsExpanded"` are owned by the current `DisclosureGroup`s. With Form sections always visible, those two keys become unused (codebase scan §5 flags this). Recommendation: keep the keys defined for back-compat (so a downgrade re-reads them safely), but stop reading/writing them. Document the deprecation in the plan.

---

## Cross-Topic: Open-Question Resolution

The investigation answers the following from `refined-request-ui-redesign.md`:

- **Q-01** — Already answered by codebase scan §4d: a Settings dialog **does** exist (`SettingsRootView` in a `Settings { }` scene), and there is **no** existing General/Appearance category. The redesign must add a `SettingsCategory.general` (or `.appearance`) case + a new `GeneralSettingsView` / `AppearanceSettingsView` mirroring the popover's appearance switcher (refined-request §18). This is design-time agreed.
- **Q-02 (API-key expiration date)** — Out of scope for this investigation. The data-source decision (new persisted field per provider, entered during the `Replace…` flow) is a planning-phase decision; the chip's *rendering* contract is unaffected by where the date comes from.
- **Q-03 (NSSwitch off behavior)** — Out of scope for this investigation. Recommend at planning time: retain the last engine selection in `@AppStorage("com.macrec.ui.transcribeProvider")` and treat the NSSwitch as a *visibility/active* gate that maps off→`"none"` and on→last-non-none-value held in a new `@AppStorage("com.macrec.ui.transcribeProviderLast")`. But this is a planning decision, not an investigation one.

The other refined-request assumptions (A-01 through A-08) are all consistent with the recommended approaches above and require no further investigation.

---

## Recommendation Summary

| Topic | Recommendation |
|---|---|
| 1. Color theming | System semantic colors + `Material` + tiny `Sources/macrec-ui/Theme/Palette.swift` for record-button gradient and success chip |
| 2. Appearance switching | `.preferredColorScheme(_:)` driven by `AppearanceMode` enum, applied to **both** the Settings scene and a small `AppearanceHostingRoot` SwiftUI wrapper inside `PopoverController`'s `NSHostingController`. No `NSApp.appearance` mutation. No explicit observer needed for appearance (SwiftUI handles redraw inside the hosted graph) — the existing `heightObserver` for `NSPopover.contentSize` is unchanged. |
| 3. Persistence | `@AppStorage("com.macrec.ui.appearance")` on `UserDefaults.standard`, raw values `"system"` / `"light"` / `"dark"`, default `"system"`, `AppearanceMode: String, CaseIterable` enum in `Sources/macrec-ui/Theme/AppearanceMode.swift` (declared `public` for `@testable import` from `MacrecUITests`) |
| 4. Layout primitives | `Form { Section { … } }.formStyle(.grouped)` for the two sections, with `.fixedSize(horizontal: false, vertical: true)` so the Form coexists with `LiveTranscriptPanel.frame(maxHeight: .infinity)` and the existing `ResizeHandle`. Custom views for the metadata-strip chip and the API-key sub-row. |

These four pieces compose into a single coherent architecture: `MacrecUIApp` and `PopoverController` both read the same `@AppStorage` key; SwiftUI's `.preferredColorScheme` handles the visual switch; the `Palette` file supplies the brand colors; the `Form { Section { … } }` produces the visual shell; the existing `ResizeHandle` + `popoverHeight` plumbing is unchanged.

---

## Technical Research Guidance

**Research needed**: Yes — but only one item.

### Topic — `NSHostingController` + `.preferredColorScheme(nil)` "Follow System" live-update on macOS 26

- **Why**: Acceptance criterion 5 requires "selecting Follow System matches the system appearance and updates **live** when the system appearance changes." For a SwiftUI scene, `.preferredColorScheme(nil)` is documented to inherit from the system and update live. For a SwiftUI view tree wrapped in `NSHostingController` and mounted on an `NSPopover`, the live-update behavior on macOS 26 is not as well documented and is the kind of subtle hosting-boundary corner that has shifted between OS versions in the past. It is worth confirming with the latest API docs / a small spike before assuming it works.
- **Focus**: (a) does `NSHostingController` propagate `NSApplication.effectiveAppearance` changes into the SwiftUI environment automatically on macOS 26; (b) if not, what's the recommended escape hatch — observe `NSApplication.didChangeScreenParametersNotification`, observe `effectiveAppearance` via KVO, or set `hostingController.view.appearance` manually; (c) does setting `.preferredColorScheme(nil)` actually opt back in to system tracking after a previous explicit value, or does the hosting view need to be re-created.
- **Depth**: Intermediate (one short documentation read + a 30-line Swift spike).
- **Relevance**: Directly affects the implementation of `AppearanceHostingRoot` recommended in Topic 2. If `NSHostingController` doesn't track the system appearance live, an explicit KVO observer on `NSApp.effectiveAppearance` becomes part of `PopoverController` (small, but needs to be designed in).

All other topics (Form usage, `@AppStorage` semantics, `Color(nsColor:)` / Material composition, `NSPopover.contentSize` driven by `UserDefaults.didChangeNotification`) are well-documented and the existing codebase already exercises every relevant pattern. No further research needed.

---

## Implementation Considerations

- **File additions needed** (codebase scan §4l):
  - `Sources/macrec-ui/Theme/AppearanceMode.swift` — `public enum AppearanceMode: String, CaseIterable { case system, light, dark; var colorScheme: ColorScheme? { … } }`
  - `Sources/macrec-ui/Theme/Palette.swift` — record-button red gradient, success chip tokens
  - `Sources/macrec-ui/Settings/Sections/AppearanceSettingsView.swift` (or `GeneralSettingsView.swift`)
  - new test file `Tests/MacrecUITests/AppearanceModeTests.swift`
- **File edits needed**:
  - `Sources/macrec-ui/MacrecUIApp.swift` — add `@AppStorage("com.macrec.ui.appearance")`, apply `.preferredColorScheme` on the `Settings` scene
  - `Sources/macrec-ui/PopoverController.swift` — wrap `RootView` in `AppearanceHostingRoot` (a 6-line wrapper that reads `@AppStorage` and applies `.preferredColorScheme`); the existing `heightObserver` is unchanged and no new observer is needed
  - `Sources/macrec-ui/RootView.swift` — major restructure: header strip + two `Form` sections + transcript panel + footer + resize handle (compositional only — no behavior change)
  - `Sources/macrec-ui/Settings/SettingsRootView.swift` — add `SettingsCategory.general` (or `.appearance`) case + branch in `detailView(for:)`
- **Decisions still to be made**:
  - Q-02 (API-key expiry data source) — defer to planning
  - Q-03 (NSSwitch off-behavior — retain or reset engine selection) — defer to planning
  - Whether to remove or repurpose `"com.macrec.ui.transcriptionExpanded"` and `"com.macrec.ui.recordingSettingsExpanded"` — recommend keep-but-stop-writing for back-compat
- **Pitfalls to watch**:
  - Do NOT add `.regularMaterial` to inner Form sections — the popover's host already provides vibrancy; double-vibrancy looks wrong.
  - `Form.formStyle(.grouped)` injects its own scroll; pair with `.fixedSize(horizontal: false, vertical: true)` so the elastic transcript panel below it gets the residual height.
  - `NSHostingController` appearance live-update under "Follow System" — verify per Technical Research Guidance.
- **Suggested first steps**:
  1. Land the `AppearanceMode` enum + `Palette.swift` skeleton + `AppearanceSettingsView`.
  2. Wire `@AppStorage("com.macrec.ui.appearance")` into `MacrecUIApp` and `PopoverController` via `AppearanceHostingRoot`. Verify acceptance criterion 5 + 6 manually before refactoring `RootView`.
  3. Refactor `RootView` into header / two Form sections / transcript / footer.
  4. Migrate sub-views (`FormatPicker`, etc.) into Form rows.
  5. Add the new tests.

---

## References

| # | Source | URL | What was learned |
|---|---|---|---|
| 1 | Refined request | `docs/design/refined-request-ui-redesign.md` | Full requirements list, assumptions A-01–A-08, open questions Q-01–Q-03, acceptance criteria 1–12 |
| 2 | Codebase scan | `docs/reference/codebase-scan-ui-redesign.md` | All existing `@AppStorage` keys, `PopoverController`/`NSHostingController` hosting model, `ResizeHandle` plumbing, Settings dialog inventory, color-utility absence (no xcassets), bundle-id mapping for `defaults read` |
| 3 | Project conventions | `Sources/macrec-ui/CLAUDE.md` (project root) | Swift exception 001, macOS 26 exception 002, no-fallback-config rule, file-header convention, `String(localized:)` requirement |
| 4 | Mockup spec | `docs/design/mockups/popover-redesign.html` (referenced by refined request) | CSS custom-property names that the new `Palette` must cover |

---

## Original Request

See `docs/design/refined-request-ui-redesign.md` (preserved verbatim there). The request asks to (1) re-skin the macrec-ui popover to match `popover-redesign.html` / `.png`, (2) implement coordinated light + dark themes, (3) add a Follow-System / Light / Dark switcher persisted in `@AppStorage`, while preserving the popover's vertical elasticity and the live-transcript streaming behavior.
