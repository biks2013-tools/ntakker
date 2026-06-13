# Plan 008 — macrec-ui Popover Redesign + Light/Dark/System Theming

> **Phase 4 (Planner) deliverable.**
> Source documents:
> - `docs/design/refined-request-ui-redesign.md` (18 requirements, 12 acceptance criteria, A-01..A-08, Q-01..Q-03)
> - `docs/reference/codebase-scan-ui-redesign.md` (22 popover sub-views, 15 existing `@AppStorage` keys, popover-resize plumbing)
> - `docs/reference/investigation-ui-redesign.md` (recommended approaches for the 4 sub-topics)
> - `docs/reference/research-nshostingcontroller-appearance.md` (confirms `NSHostingController` propagates appearance automatically on macOS 26)
> - `docs/design/mockups/popover-redesign.html` (visual target; CSS variables = design tokens)
> - `docs/design/project-design.md` §macrec-ui section
>
> **Constraints (must obey):**
> - Swift / SwiftUI only (CLAUDE.md Exception 001 — TS-only rule does not apply).
> - macOS 26 deployment target (CLAUDE.md Exception 002).
> - Do **NOT** rename any of the 15 existing `@AppStorage` keys.
> - Preserve the vertical-elasticity popover plumbing (`ResizeHandle` + `PopoverController.heightObserver` + `NSPopover.contentSize`).
> - Preserve the `LiveTranscriptPanel` streaming-text behavior verbatim — visual rehousing only.
> - New `Theme/` files go in `Sources/macrec-ui/Theme/`. New General/Appearance settings tab goes in `Sources/macrec-ui/Settings/Sections/`. Reusable model types (e.g. `AppearanceMode` enum) go in `Sources/MacrecUIKit/` so the test target can reach them — this mirrors the architectural decision already made for `PrivacyDisclosureViewModel`.
> - No fallback values for required configuration. The appearance-mode default (`"system"`) is a documented user-facing UX default, **not** a missing-config fallback (no exception needed; refined-request §Constraints clause).
> - No version-control operations during implementation unless the user explicitly requests them.

---

## Decisions Still Needed Before Implementation Begins

The plan adopts the recommended defaults below. The user reviews this section before phase execution starts.

### Q-02 — Source of API-key expiration date (chip data source)

- **Default chosen for this iteration:** **DEFER.** The first iteration renders only a `Configured` / `Not configured` status chip with **no** expiration text. The mockup shows an expiration badge but plumbing it requires a new persisted field per provider plus an entry surface in the `Replace…` flow — a non-trivial UX addition that deserves its own plan.
- **Tracked as:** Phase X — out of scope, deferred to a follow-up plan (see §Out of Scope below).
- **User confirmation required to proceed with the deferral.** If the user wants the expiration chip in v1.6, the planner must extend Phase 5 (API-key sub-row) with a new `@AppStorage("com.macrec.ui.apiKeyExpiry.<provider>")` key plus a date entry control inside the `Replace…` sheet.

### Q-03 — Engine retention when the "Live Transcription" header switch is toggled OFF

- **Default chosen for this iteration:** **RETAIN the engine selection.** A new `@AppStorage("com.macrec.ui.transcriptionEnabled")` boolean (default `true`) gates the section's body. When the user flips the switch OFF, `transcriptionEnabled = false`, the body rows hide/disable, and the popover behaves as if the engine were `none` (no transcription pipeline starts). The existing `"com.macrec.ui.transcribeProvider"` value is **not** mutated, so re-toggling ON restores the same engine, source, format, and language hints.
- **Behavioral mapping at `ControlBar.startTapped()`:**
  - When `transcriptionEnabled == false`, `ControlBar.startTapped()` composes `RecordingOptions` as if `transcribeProvider == "none"` (transcription pipeline is not constructed).
  - When `transcriptionEnabled == true`, behavior is unchanged from today.
- **User confirmation required.** The alternative (reset `transcribeProvider` to `"none"` on OFF and lose the user's last-engine selection) is simpler but less user-friendly.

---

## Out of Scope (deferred to follow-up plans)

- API-key **expiration date** plumbing for the new chip (Q-02). The chip will surface presence-only state in v1.6.
- Repurposing the now-orphaned `@AppStorage("com.macrec.ui.transcriptionExpanded")` and `"com.macrec.ui.recordingSettingsExpanded"` keys. They remain readable/writable in `UserDefaults` for back-compat (a downgrade re-reads them safely) but are no longer consumed by any view after Phase 4. Documented in Phase 11.
- Any change to `MacrecCore`, `RecordingSession`, the transcription pipeline, the env-var resolution chain, or `RecordingOptions` composition.
- Localization of new labels beyond English (existing `String(localized:)` wrappers must continue to be used so future localization is unblocked).

---

## Architecture Summary (one-page recap)

The redesign decomposes into **4 architectural pieces** that compose into the new popover:

1. **`AppearanceMode` enum** in `Sources/MacrecUIKit/Theme/AppearanceMode.swift` — `public enum String { case system, light, dark }` with a `var colorScheme: ColorScheme?` computed property (`nil` for `.system`, `.light`, `.dark`). Lives in `MacrecUIKit` so the test target can reach it without `@testable import` of the executable. Mirrors `PrivacyDisclosureViewModel`.
2. **`Palette` + `SemanticColors`** in `Sources/macrec-ui/Theme/` — a small Swift file holding the brand-only tokens (record-button red gradient, success-chip fill/foreground/dot) and a documented mapping from CSS custom-properties in the mockup to `Color(nsColor:)` semantic colors and `Material` values. **No xcassets.** **No `.regularMaterial` inside section backgrounds** (the popover host already provides vibrancy — double-frost is wrong).
3. **`AppearanceHostingRoot`** in `Sources/macrec-ui/Theme/AppearanceHostingRoot.swift` — a 6-line SwiftUI wrapper that reads `@AppStorage("com.macrec.ui.appearance")` and applies `.preferredColorScheme(AppearanceMode(rawValue:)?.colorScheme)` to its child. Used by `PopoverController` to wrap `RootView` before handing it to `NSHostingController`. Because `@AppStorage` is KVO-backed and the wrapper sits inside the SwiftUI graph rooted at the hosting controller, **no `NotificationCenter` observer is needed** for appearance — the existing `heightObserver` in `PopoverController` is unchanged.
4. **`Form { Section { … } }.formStyle(.grouped)`** is the layout primitive for the two inset-grouped sections in the popover middle band. Paired with `.fixedSize(horizontal: false, vertical: true)` so the Form takes intrinsic height and the existing `LiveTranscriptPanel.frame(maxHeight: .infinity)` keeps consuming the residual vertical space — the three-band structure (pinned top / flexible middle / pinned bottom + `ResizeHandle`) is preserved.

The persistence story is a single new `@AppStorage("com.macrec.ui.appearance")` key (default `"system"`) plus a single new `@AppStorage("com.macrec.ui.transcriptionEnabled")` key (default `true`). Both live on `UserDefaults.standard` (matches every other key — see codebase-scan §4f). The `defaults read com.local.macrec-ui com.macrec.ui.appearance` invocation in acceptance criterion 6 works directly because `UserDefaults.standard` for an executable maps to the bundle-id domain.

---

## Phase Dependency Graph

```
                    ┌──────────────────────────────────────────────────┐
                    │ P1 Foundation (AppearanceMode, Palette,          │
                    │    AppearanceHostingRoot, Settings scene wiring) │
                    └──┬───────────────────────────────────────┬───────┘
                       │                                       │
            ┌──────────┴──────┐                       ┌────────┴──────┐
            │ P2 Settings     │                       │ P8 Popover    │
            │    General tab  │                       │    appearance │
            │    (parallel)   │                       │    plumbing   │
            └─────────────────┘                       └───────┬───────┘
                                                              │
                                                              │
            ┌──────────────────────────────────────┐          │
            │ P3 Popover header redesign           │          │
            │    (parallel after P1)               │◄─────────┤
            └──┬───────────────────────────────────┘          │
               │                                              │
            ┌──┴───────────────────────────────────┐          │
            │ P4 Popover sections refactor (Form)  │          │
            │    [BIG MERGE — NOT parallel-safe]   │          │
            └──┬───────────────────────────────────┘          │
               │                                              │
       ┌───────┼──────────────┬──────────────┐                │
       ▼       ▼              ▼              ▼                ▼
   ┌─────┐ ┌─────┐        ┌─────┐        ┌─────┐         ┌────────┐
   │ P5  │ │ P6  │        │ P7  │        │ P9  │         │  (P8   │
   │ Key │ │ Sw. │        │Foot │        │Live │         │ already│
   │ Sub │ │     │        │+REC │        │Pnl. │         │ done)  │
   └──┬──┘ └──┬──┘        └──┬──┘        └──┬──┘         └────────┘
      │      │              │              │
      └──────┴──────┬───────┴──────────────┘
                    ▼
              ┌──────────────────────────────────────┐
              │ P10 Tests (parallel test-builders,   │
              │     mapped to P1/P2/P5/P6/P8/P9)     │
              └──┬───────────────────────────────────┘
                 ▼
              ┌──────────────────────────────────────┐
              │ P11 Documentation (project-design,   │
              │     project-functions, Issues,       │
              │     macrec-ui.md Theming subsection) │
              └──────────────────────────────────────┘
```

**Parallelization hot path:** P1 → (P2 + P3 + P8 in parallel) → P4 → (P5 + P6 + P7 + P9 in parallel) → P10 → P11.

---

## Phase Reference Tables

### Acceptance-criteria coverage by phase

| AC# | Description | Covered by phase(s) |
|---|---|---|
| 1 | Visual parity (light) | P3, P4, P5, P6, P7, P9 |
| 2 | Visual parity (dark) | P1, P3, P4, P5, P6, P7, P9 |
| 3 | Vertical elasticity preserved | P4, P9 |
| 4 | Live transcript streaming preserved | P9 |
| 5 | Appearance switcher present and functional | P1, P2, P3, P8 |
| 6 | Appearance choice persists | P1, P8, P10 |
| 7 | All existing tests pass | P10 (regression) |
| 8 | New tests added (round-trip + scheme + writer) | P10 |
| 9 | Builds cleanly | every phase ends with `swift build -c debug` + `swift build -c release` |
| 10 | Docs updated | P11 |
| 11 | No regressions to existing `@AppStorage` keys | P4 (preservation), P10 (regression) |
| 12 | No regression to env-var resolution | P5 (chip is display-only) |

### `@AppStorage` key inventory after this plan

| Key | Owner | Status |
|---|---|---|
| `"com.macrec.ui.outputFolder"` | `ControlBar`, `FolderPicker` | unchanged |
| `"com.macrec.ui.basename"` | `ControlBar`, `FilenameField` | unchanged |
| `"com.macrec.ui.format"` | `ControlBar`, `FormatPicker` | unchanged |
| `"com.macrec.ui.layout"` | `ControlBar`, `LayoutPicker` | unchanged |
| `"com.macrec.ui.micUID"` | `ControlBar`, `MicrophonePicker` | unchanged |
| `"com.macrec.ui.transcribeProvider"` | `ControlBar`, `TranscriptionPicker`, `RootView`, `TranscriptionLanguagePicker` | unchanged |
| `"com.macrec.ui.transcribeSource"` | `ControlBar`, `TranscriptionSourcePicker` | unchanged |
| `"com.macrec.ui.transcriptFormat"` | `ControlBar`, `TranscriptionFormatPicker` | unchanged |
| `"com.macrec.ui.transcribeLanguage"` | `ControlBar`, `TranscriptionLanguagePicker` | unchanged |
| `"com.macrec.ui.transcribeLanguage2"` | `ControlBar`, `TranscriptionLanguagePicker` | unchanged |
| `"com.macrec.ui.transcriptionExpanded"` | (was `RootView`) | **orphaned** — keep defined in UserDefaults for back-compat; no view reads/writes after P4 |
| `"com.macrec.ui.recordingSettingsExpanded"` | (was `RootView`) | **orphaned** — same disposition |
| `"com.macrec.ui.popoverHeight"` (= `RootView.popoverHeightKey`) | `RootView`, `PopoverController` | unchanged |
| `"com.macrec.ui.settings.selectedCategory"` | `SettingsRootView` | unchanged |
| `PrivacyDisclosureViewModel.userDefaultsKey` | `RootView` | unchanged |
| **`"com.macrec.ui.appearance"` (NEW)** | `MacrecUIApp`, `AppearanceHostingRoot`, `GeneralSettingsView` | added in P1 |
| **`"com.macrec.ui.transcriptionEnabled"` (NEW)** | `RootView` (Live Transcription Section header), `ControlBar.startTapped()` | added in P6 |

---

## Phase 1 — Foundation (theme tokens, appearance enum, hosting wrapper, scene plumbing)

**parallel_safe: false** — every other phase depends on the artifacts produced here.

### Goal
Land the core theming primitives — the `AppearanceMode` enum, the `Palette` brand-color file, the `SemanticColors` documentation/mapping file, the `AppearanceHostingRoot` wrapper, and the `.preferredColorScheme(_:)` modifier on the `Settings { }` scene. After P1 the app builds and the Settings window can be flipped between System/Light/Dark via direct `UserDefaults.standard.set(_:forKey: "com.macrec.ui.appearance")` writes (verified via `defaults write` from the shell). The popover does not yet honor the choice — that is P8.

### Files to create

| Path | Purpose |
|---|---|
| `Sources/MacrecUIKit/Theme/AppearanceMode.swift` | `public enum AppearanceMode: String, CaseIterable { case system = "system", light = "light", dark = "dark"; public var colorScheme: ColorScheme? { … }; public static let userDefaultsKey = "com.macrec.ui.appearance"; public static let defaultRawValue = "system" }`. The `colorScheme` computed property returns `nil` for `.system`, `.light` for `.light`, `.dark` for `.dark`. The `userDefaultsKey` and `defaultRawValue` constants are referenced by the views and by tests so the magic strings live in exactly one place. |
| `Sources/macrec-ui/Theme/Palette.swift` | Brand-only tokens. Exposes `Palette.recordButtonGradient(for: ColorScheme) -> LinearGradient`, `Palette.successChipBackground: Color`, `Palette.successChipForeground: Color`, `Palette.successDot: Color`. **Header comment** maps each CSS custom-property in `popover-redesign.html` (e.g. `--accent`, `--separator`, `--group-bg`, `--control-bg`) to either a `Color(nsColor:)` semantic, a `Material` value, or a `Palette.*` brand token, so future readers can audit the mockup-to-Swift mapping. |
| `Sources/macrec-ui/Theme/SemanticColors.swift` | Convenience namespace re-exporting `Color(nsColor: .controlBackgroundColor)`, `.windowBackgroundColor`, `.separatorColor`, `.underPageBackgroundColor`, etc., as `static let` properties (`SemanticColors.groupBackground`, `SemanticColors.separator`, `SemanticColors.windowBackground`). Keeps call sites readable and avoids `Color(nsColor: …)` clutter. |
| `Sources/macrec-ui/Theme/AppearanceHostingRoot.swift` | `struct AppearanceHostingRoot<Content: View>: View { @AppStorage(AppearanceMode.userDefaultsKey) private var raw: String = AppearanceMode.defaultRawValue; let content: Content; init(@ViewBuilder content: () -> Content) { self.content = content() }; var body: some View { content.preferredColorScheme(AppearanceMode(rawValue: raw)?.colorScheme) } }`. Generic over `Content` so it can wrap `RootView` (popover, P8) and the Settings scene root (P1). |

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/MacrecUIApp.swift` | Add `@AppStorage(AppearanceMode.userDefaultsKey) private var appearanceRaw: String = AppearanceMode.defaultRawValue` to the `App` struct. Compute `private var resolvedScheme: ColorScheme? { AppearanceMode(rawValue: appearanceRaw)?.colorScheme }`. Apply `.preferredColorScheme(resolvedScheme)` to `Settings { SettingsRootView() }`. **Do NOT** wrap `Settings { }` in `AppearanceHostingRoot` — the Settings scene needs the modifier on the scene itself, not inside the content, for the title bar to switch. |
| `Package.swift` | (verify only — no edit expected) Confirm the new `Sources/MacrecUIKit/Theme/` subfolder is picked up by `swift build` (SPM globs `Sources/<target>/**/*.swift` by default). If not, add `path:` and `sources:` overrides. |

### Acceptance criteria covered
- AC #5 (partial): the persistence binding round-trips; the Settings window honors the choice. Popover side is P8.
- AC #6 (partial): persistence happens; the `defaults read com.local.macrec-ui com.macrec.ui.appearance` returns the written value.
- AC #9: builds cleanly.

### Verification commands
```bash
swift build -c debug 2>&1 | tee /tmp/p1-build.log
swift test --filter AppearanceModeTests   # P10 lands the test; in P1, only build is verified
defaults delete com.local.macrec-ui com.macrec.ui.appearance 2>/dev/null
defaults write com.local.macrec-ui com.macrec.ui.appearance dark
# Manual: launch macrec-ui, open Settings — should render in dark even if system is light.
defaults write com.local.macrec-ui com.macrec.ui.appearance light
# Manual: re-launch macrec-ui, open Settings — should render in light even if system is dark.
defaults delete com.local.macrec-ui com.macrec.ui.appearance
# Manual: re-launch — Settings follows system.
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `AppearanceMode` placed in `macrec-ui` (executable) instead of `MacrecUIKit` blocks the test target | Medium | Plan explicitly puts the enum in `MacrecUIKit` (mirrors `PrivacyDisclosureViewModel`'s pattern fix). |
| `Palette.swift` accidentally adds `.regularMaterial` inside section backgrounds → double-frost | Medium | Header comment of `Palette.swift` documents "do not add Material inside Form sections; the popover host already provides vibrancy". P4 reviewer enforces. |
| `SemanticColors` shadowing causes ambiguity errors at call sites | Low | Use a `enum SemanticColors { … }` (uninstantiable namespace) so call sites are `SemanticColors.groupBackground`, not free-standing identifiers. |
| `Settings { }` scene's `.preferredColorScheme` does not affect a child sheet presented from Settings | Low | Out of scope for v1 — Settings sub-sheets inherit unless they explicitly override. |
| `Package.swift` does not auto-pick up `Sources/MacrecUIKit/Theme/` | Low | SPM globs by default; verify with `swift build -v 2>&1 | grep AppearanceMode.swift`. |

### Dependencies
None (foundation phase).

---

## Phase 2 — Settings General tab + appearance picker

**parallel_safe: true** (after P1 lands `AppearanceMode`).

### Goal
Add a new "General" sidebar entry to the Settings dialog hosting an Appearance picker (System / Light / Dark) wired to the new `@AppStorage("com.macrec.ui.appearance")` key. Verifies the persistence and the round-trip through SwiftUI's binding before the popover-side switcher (P3) consumes the same key.

### Files to create

| Path | Purpose |
|---|---|
| `Sources/macrec-ui/Settings/Sections/GeneralSettingsView.swift` | A `Form { Section("Appearance") { Picker("Appearance", selection: $appearanceRaw) { Label("System", systemImage: "circle.lefthalf.filled").tag("system"); Label("Light", systemImage: "sun.max").tag("light"); Label("Dark", systemImage: "moon").tag("dark") }.pickerStyle(.inline) } }`. Reads/writes `@AppStorage(AppearanceMode.userDefaultsKey) private var appearanceRaw: String = AppearanceMode.defaultRawValue`. Exposes `.accessibilityLabel(String(localized: "Appearance mode"))` on the picker. |

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/Settings/SettingsRootView.swift` | Add `case general` as the **first** item of the `SettingsCategory` enum (so it appears at the top of the sidebar above Permissions). Update `displayName` and `systemImage` for the new case (`"General"`, `"gearshape"`). Extend the `detailView(for:)` switch with `case .general: GeneralSettingsView()`. |

### Acceptance criteria covered
- AC #5 (partial): a switcher control is present and functional in Settings.
- AC #6 (partial): selecting an option writes `com.macrec.ui.appearance`; the choice persists across launches.
- AC #10 (partial): the new tab is one of the things `project-design.md` documents in P11.

### Verification commands
```bash
swift build -c debug
# Manual: launch macrec-ui → Settings → General tab → flip the picker → verify Settings window
# repaints; verify defaults read returns the chosen rawValue; relaunch to confirm persistence.
defaults read com.local.macrec-ui com.macrec.ui.appearance
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Sidebar ordering puts "General" below provider-specific categories, looking alphabetic | Low | Plan explicitly inserts `case general` first in the `SettingsCategory` enum; sidebar renders in declaration order. |
| `@AppStorage("com.macrec.ui.settings.selectedCategory")` default is `"azure"` — users who already used the app land on Azure on first launch even though General now exists | Low | Out of scope — not changing the default. The user can navigate to General manually; future preference reset would update this. |
| `Picker(.inline)` style does not render correctly in a Settings Form on macOS 26 | Low | Fallback to `.pickerStyle(.segmented)` or `.pickerStyle(.menu)`. Visual difference is acceptable. |

### Dependencies
P1 (`AppearanceMode` enum + `userDefaultsKey` constant).

---

## Phase 3 — Popover header redesign (filename title + permission pill + metadata strip + appearance switcher)

**parallel_safe: true** (after P1; the new header is a self-contained replacement of `RootView`'s top band — does NOT yet touch the `DisclosureGroup`s in the middle band).

### Goal
Replace `RootView`'s pinned-top band with the new mockup-driven header: a large filename-as-title (driven by the existing `FilenameField` value, restyled), a horizontal metadata strip below it containing the consolidated permissions pill, the "Save to" folder chip, and the appearance switcher control. The middle and bottom bands of `RootView` are unchanged in P3 — the legacy `DisclosureGroup`s remain functional. P4 will then refactor the middle band into Form sections.

### Files to create

| Path | Purpose |
|---|---|
| `Sources/macrec-ui/Views/Header/PopoverHeaderView.swift` | Top-level header view. `VStack(alignment: .leading, spacing: 8) { FilenameTitleField(); MetadataStrip() }`. Hosts the new structure. |
| `Sources/macrec-ui/Views/Header/FilenameTitleField.swift` | Restyled `FilenameField`: `TextField` with `.font(.title2).fontWeight(.semibold)`, no border, placeholder `String(localized: "Untitled recording")`, locked when `state != .idle`. Reuses `@AppStorage("com.macrec.ui.basename")`. |
| `Sources/macrec-ui/Views/Header/MetadataStrip.swift` | `HStack(spacing: 12) { PermissionsPill(); SaveToChip(); Spacer(); AppearanceSwitcher() }`. |
| `Sources/macrec-ui/Views/Header/PermissionsPill.swift` | Consolidating wrapper around `PermissionStatusView`. When all permissions are `.authorized`, renders a single "All permissions granted" pill (green dot + check icon). When one or more are missing, renders a "Permissions needed" affordance that, when tapped, expands the existing `PermissionStatusView` (with its per-permission CTAs) below the header. Owns a `@State private var expanded: Bool` for the missing-permission expansion. Polls TCC at 2 Hz via the existing `PermissionStatusView` task or a shared `PermissionPoller`. |
| `Sources/macrec-ui/Views/Header/SaveToChip.swift` | Chip-style button driven by `@AppStorage("com.macrec.ui.outputFolder")` and `DefaultRecordingFolder.resolve()`. Shows a folder icon + truncated path (e.g. `~/Recordings`). Tap opens `NSOpenPanel` (preserves `FolderPicker`'s `.semitransient` `popoverBehavior` swap). The existing `FolderPicker` body is refactored into `SaveToChip` so the modal/semitransient logic is preserved exactly. |
| `Sources/macrec-ui/Views/Header/AppearanceSwitcher.swift` | A 3-segment Picker labeled with SF Symbols `circle.lefthalf.filled` / `sun.max` / `moon`, bound to `@AppStorage(AppearanceMode.userDefaultsKey)`. `.pickerStyle(.segmented)`. Each segment carries `.accessibilityLabel(String(localized: …))` (System / Light / Dark). The segment height is matched to the chip height in the strip. |

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/RootView.swift` | Replace the existing top band (`SettingsLink` + `ErrorBanner` + `PermissionStatusView(.onlyWhenIssues)` + standalone `FilenameField`) with `PopoverHeaderView()`. The `SettingsLink` (gear icon) is moved into `MetadataStrip` as a small icon button next to the appearance switcher (preserves Settings access). `ErrorBanner` stays where it is — directly below the new header, above the (still-`DisclosureGroup`) middle band. The `Divider()` between top and middle is preserved. |
| `Sources/macrec-ui/Views/PermissionStatusView.swift` | **No structural change** — the file remains as-is. `PermissionsPill` reuses it for the expanded view. The `Visibility` enum is unchanged. |
| `Sources/macrec-ui/Views/FilenameField.swift` | **Kept verbatim for back-compat** but no longer composed by `RootView`. Considered a candidate for removal in a future cleanup plan. Marked with a deprecation comment in P11. |
| `Sources/macrec-ui/Views/FolderPicker.swift` | Same — kept verbatim, no longer composed by `RootView`. The `.semitransient` `popoverBehavior` logic is now inside `SaveToChip`. Deprecation comment in P11. |

### Acceptance criteria covered
- AC #1 (partial): filename-as-title + Save to chip + consolidated permissions pill + appearance switcher all visible in the new header.
- AC #2 (partial): same in dark.
- AC #5 (partial): the popover header strip contains the 3-way switcher; it writes the same `@AppStorage` key as the Settings tab.
- AC #11: existing `@AppStorage` keys are not renamed (the header is purely a re-composition).

### Verification commands
```bash
swift build -c debug
# Manual:
# - Click the menu-bar icon to open the popover.
# - Verify filename-as-title is the first prominent element.
# - Verify the metadata strip shows the permissions pill, Save to chip, and the 3-segment appearance switcher.
# - Click the Save to chip → NSOpenPanel opens; popover stays open in semitransient mode.
# - Flip the appearance switcher → popover repaints (P8 closes this loop; until P8 lands, only the
#   Settings window honors the change).
# - With one permission revoked (e.g. revoke microphone via System Settings → Privacy & Security),
#   verify the pill becomes "Permissions needed" and tapping it reveals the existing per-permission
#   detail rows.
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `SaveToChip`'s `.semitransient` swap regresses (popover closes when NSOpenPanel opens) | Medium | Carefully port the existing `FolderPicker.swift` `@Environment(\.popoverBehavior)` swap logic into `SaveToChip`. P10 includes a manual verification step. |
| `PermissionsPill` polling races against `PermissionStatusView`'s polling | Low | Use a single shared `PermissionPoller` actor or have `PermissionsPill` consume `PermissionStatusView`'s existing `@State` directly. Recommended: refactor `PermissionStatusView` to expose a `permissionState: PermissionState` `@State` that `PermissionsPill` reads. |
| `AppearanceSwitcher`'s `.pickerStyle(.segmented)` looks visually heavy in the header strip | Low | Fall back to `Menu { Button("System") … } label: { Image(systemName: …) }` (icon menu) if segmented is too tall. Mockup specifies the segmented look. |
| `SettingsLink` icon moved into the metadata strip becomes hard to discover | Low | Add `.help(String(localized: "Open Settings"))` for the tooltip. |
| Header height changes break the `popoverHeight` `@AppStorage` default of `600` | Low | The popover is vertically elastic; the height key is a persisted user preference and re-clamps on next display. No action required. |

### Dependencies
P1 (`AppearanceMode`, `Palette`, `SemanticColors`).

---

## Phase 4 — Popover sections refactor (Form { Section { … } }.formStyle(.grouped))

**parallel_safe: false** — this is the big middle-band rewrite. P5, P6, P7, P9 all assume P4's Form skeleton exists.

### Goal
Replace `RootView`'s middle band (the two `DisclosureGroup` containers + their inline pickers) with two `Form { Section { … } }.formStyle(.grouped)` inset-grouped cards: **General** (Format, Layout, Microphone) and **Live Transcription** (engine, source, format, language hints, API-key sub-row placeholder). The Folder picker is consolidated into the metadata strip in P3 (assumption A-07) — it does not appear in General. The `LiveTranscriptPanel` and the bottom band (`ControlBar`, `SavedToDisclosure`, `ResizeHandle`) are NOT changed in P4 — that is P7 (footer) and P9 (transcript).

### Files to create

| Path | Purpose |
|---|---|
| `Sources/macrec-ui/Views/Sections/GeneralSection.swift` | `Section { … } header: { Text("General") }` containing one `LabeledContent("Format") { FormatPicker() }` row, one `LabeledContent("Layout") { LayoutPicker() }` row, one `LabeledContent("Microphone") { MicrophonePicker() }` row. |
| `Sources/macrec-ui/Views/Sections/LiveTranscriptionSection.swift` | `Section { … } header: { LiveTranscriptionSectionHeader() }` containing the engine picker, the source picker, the format picker, the language pickers, and a placeholder slot for the API-key sub-row (filled in by P5). The header is a custom view (P6 lands the NSSwitch). For now (P4) the header is a plain `Text("Live Transcription")`. |
| `Sources/macrec-ui/Views/Sections/PopoverSettingsForm.swift` | `Form { GeneralSection(); LiveTranscriptionSection() }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)`. The `.fixedSize(horizontal: false, vertical: true)` is **critical** — it tells SwiftUI to give the Form its intrinsic content height, leaving residual vertical space to `LiveTranscriptPanel.frame(maxHeight: .infinity)` below it. Without this, the Form takes infinite height and squashes the transcript panel. |

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/RootView.swift` | Replace the middle band (the two `DisclosureGroup` containers and the inline `MicrophonePicker`) with `PopoverSettingsForm()`. The three-band `VStack(spacing: 0)` structure is preserved: pinned `PopoverHeaderView()`, then `ErrorBanner`, then `PopoverSettingsForm()`, then `LiveTranscriptPanel` (`.frame(maxHeight: .infinity)`), then `TranscriptionMetricsView`, then `ControlBar` (P7 swaps this), then `SavedToDisclosure`, then `ResizeHandle`. |
| `Sources/macrec-ui/Views/FormatPicker.swift` | **No structural change** — `Picker(.menu)` is preserved. Wrapped in `LabeledContent` by `GeneralSection`. |
| `Sources/macrec-ui/Views/LayoutPicker.swift` | Same. |
| `Sources/macrec-ui/Views/MicrophonePicker.swift` | Same. |
| `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift` | Same — moved into `LiveTranscriptionSection`. The `missingKey` red dot styling is preserved. |
| `Sources/macrec-ui/Views/Transcription/TranscriptionSourcePicker.swift` | Same. |
| `Sources/macrec-ui/Views/Transcription/TranscriptionFormatPicker.swift` | Same. |
| `Sources/macrec-ui/Views/Transcription/TranscriptionLanguagePicker.swift` | Same. |

### Acceptance criteria covered
- AC #1 (partial): two inset-grouped sections labeled "General" and "Live Transcription"; right-aligned `NSPopUpButton`-style pickers with chevrons; hairline row dividers (provided by `formStyle(.grouped)`).
- AC #2 (partial): same in dark.
- AC #3 (partial): vertical elasticity preserved — verified by `.fixedSize(horizontal: false, vertical: true)` on the Form; `LiveTranscriptPanel.frame(maxHeight: .infinity)` continues to consume residual height.
- AC #11: zero `@AppStorage` key renames; the pickers continue to read/write the same keys.

### Verification commands
```bash
swift build -c debug
# Manual:
# - Open the popover.
# - Verify two inset-grouped sections with rounded backgrounds and hairline row dividers.
# - Verify each picker row has its label on the left and a chevron `NSPopUpButton`-style picker on the right.
# - Verify the popover height grows when the Live Transcription section reveals more rows
#   (e.g. select a streaming engine that exposes the secondary-language picker).
# - Verify `defaults read com.local.macrec-ui com.macrec.ui.format` etc. round-trip.
swift test --filter ControlBarStartTappedKeysRegression  # P10 lands this
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `Form.formStyle(.grouped)` adds its own internal `ScrollView` causing double-scroll with the existing layout | High | `.fixedSize(horizontal: false, vertical: true)` on the Form. Verified pattern in investigation §Topic 4. |
| `LabeledContent` does not honor `.pickerStyle(.menu)` correctly inside grouped Form on macOS 26 | Low | Fallback: render `HStack { Text("Format"); Spacer(); FormatPicker() }` manually inside the Section. |
| Two now-orphaned keys (`transcriptionExpanded`, `recordingSettingsExpanded`) trigger lint or test warnings | Low | They are not referenced after P4. P11 documents them as orphaned-but-retained for back-compat. |
| Form section header text styling does not match the mockup's bold weight | Low | Override with `Section { … } header: { Text("General").font(.headline) }` if needed. |
| The `LiveTranscriptionSection` reveals/hides rows based on the selected engine — Form animates the height change too aggressively, making the popover jiggle | Low | Wrap conditional rows in `if-else` (SwiftUI uses fade transition by default, not vertical slide). If jiggle is observed, add `.animation(nil, value: …)`. |
| `TranscriptionMetricsView` and `SavedToDisclosure` are below the Form but above `ControlBar` — they need to stay outside the Form so they don't get grouped chrome | Low | The plan keeps them as direct children of `RootView`'s `VStack`; only the two new sections are inside the Form. |

### Dependencies
P1 (palette + semantic colors), P3 (header is in place so `RootView`'s top band is already restructured).

---

## Phase 5 — API-key sub-row (status chip + Replace… pattern)

**parallel_safe: true** (after P4; sub-row lives inside `LiveTranscriptionSection`).

### Goal
Replace the legacy `SonioxKeyField` / `GeminiKeyField` / `ProviderKeyField` inline `Save / Clear` button pair with a new mockup-style sub-row: a status chip ("Configured" / "Not configured") plus a single `Replace…` button. The chip is **display-only** (per requirement §7 and AC #12). Tapping `Replace…` opens a sheet that hosts the existing key-entry UI (one of the per-provider Settings sub-views, e.g. `GeminiSettingsView`'s entry surface, presented modally over the popover). The `EnvFileStore` / `ProcessInfo` resolution chain is unchanged.

**Q-02 deferral applies**: the chip renders only `Configured` or `Not configured`. The expiration-date badge from the mockup is not implemented in this iteration.

### Files to create

| Path | Purpose |
|---|---|
| `Sources/macrec-ui/Views/Transcription/ApiKeyStatusRow.swift` | The new sub-row. Reads the resolved key value via `ControlBar.resolvedEnvValue(_:)` (extract this helper into `MacrecUIKit` if it is currently `private` — see Risk below). Renders `HStack { ApiKeyStatusChip(present: keyPresent); Spacer(); Button("Replace…") { showSheet = true } }`. The sheet hosts the appropriate per-provider entry view based on the currently-selected `transcribeProvider`. |
| `Sources/macrec-ui/Views/Transcription/ApiKeyStatusChip.swift` | Pill-style chip. `present == true` → green fill (uses `Palette.successChipBackground`/`Palette.successChipForeground`/`Palette.successDot`) + "Configured" label. `present == false` → red fill (system `.red.opacity(0.2)`) + "Not configured" label. **No expiration text** in this iteration (Q-02 deferred). |
| `Sources/macrec-ui/Views/Transcription/ApiKeyReplaceSheet.swift` | Modal sheet container. Switches on `transcribeProvider` and presents the matching per-provider Settings sub-view's key-entry surface (extracted from `GeminiSettingsView`, `SonioxSettingsView`, etc. — already exist in `Sources/macrec-ui/Settings/Sections/`). The sheet has a `Done` button that dismisses without saving (the per-provider view's own save/clear semantics are reused). |

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/Views/Sections/LiveTranscriptionSection.swift` | Wire `ApiKeyStatusRow` into the section as the last row, conditionally visible only when the selected `transcribeProvider` requires an API key (use `TranscriptionPicker.requiredKeyEnvVar(for:)` to decide). |
| `Sources/macrec-ui/Views/Transcription/SonioxKeyField.swift` | Marked deprecated in a header comment; not removed (keeps existing `EnvFileStore` write/clear methods callable by the new sheet). P11 records this. |
| `Sources/macrec-ui/Views/Transcription/GeminiKeyField.swift` | Same. |
| `Sources/macrec-ui/Views/Transcription/ProviderKeyField.swift` | Same. |
| `Sources/macrec-ui/Views/ControlBar.swift` | Extract `resolvedEnvValue(_:)` from `private` to internal/file-private accessibility so `ApiKeyStatusRow` can call it. If extraction is heavy, instead duplicate the 3-line read into `ApiKeyStatusRow` (it is just `EnvFileStore.read(toolName: "macrec-ui", key: …) ?? ProcessInfo.processInfo.environment[…]`). |

### Acceptance criteria covered
- AC #1 / AC #2 (partial): API-key sub-row matches the mockup (chip + Replace, no Save/Clear pair).
- AC #12: env-var resolution chain is untouched; the chip only displays state.

### Verification commands
```bash
swift build -c debug
# Manual:
# - Select a cloud provider (e.g. Soniox) in the Live Transcription section.
# - Verify the API-key sub-row appears below.
# - With no key set: chip shows "Not configured" in red.
# - Tap "Replace…" → sheet opens with the per-provider key-entry surface.
# - Save a key → sheet dismisses → chip switches to "Configured" in green.
# - Switch provider to Apple/On-device → sub-row disappears.
swift test --filter ApiKeyStatusRowTests  # P10
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `resolvedEnvValue(_:)` is `private` and extracting it changes `ControlBar`'s shape | Medium | Duplicate the 3-line read into `ApiKeyStatusRow` instead — `EnvFileStore` is already `public`. |
| Per-provider Settings sub-views are tightly coupled to the Settings sidebar layout and don't render cleanly in a sheet | Medium | `ApiKeyReplaceSheet` is allowed to render only the key-entry portion of each Settings view, not the whole detail surface. Refactor the existing `*SettingsView` files to expose a `var keyEntryFragment: some View` if needed. |
| The chip's "Configured" check is a one-shot read, not reactive — if the user opens the sheet and saves a new key, the chip stale-reads | Medium | Use `@State private var keyPresentTrigger = UUID()` and increment after the sheet dismisses; or have `ApiKeyStatusRow` re-read inside an `.onChange(of: showSheet)` when the sheet closes. |
| Q-02 chip-expiration deferral is forgotten in P11 docs | Low | Plan-008 §"Out of Scope" + project-functions.md follow-up FR (P11) explicitly track it. |

### Dependencies
P4 (`LiveTranscriptionSection` exists and exposes a slot for the row).

---

## Phase 6 — Section header NSSwitch (transcriptionEnabled toggle + off-state visibility)

**parallel_safe: true** (after P4; the NSSwitch attaches to the Live Transcription section header).

### Goal
Add a `Toggle("", isOn: $transcriptionEnabled).toggleStyle(.switch).labelsHidden()` next to the "Live Transcription" section header (per requirement §6). The toggle is bound to the new `@AppStorage("com.macrec.ui.transcriptionEnabled")` boolean (default `true`). When OFF: the section's body rows hide/disable, and `ControlBar.startTapped()` composes `RecordingOptions` as if `transcribeProvider == "none"`. The `transcribeProvider` `@AppStorage` value is **not mutated** (Q-03 retention default).

### Files to create

None.

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/Views/Sections/LiveTranscriptionSection.swift` | Replace the plain `Text("Live Transcription")` header (P4 placeholder) with a `LiveTranscriptionSectionHeader` HStack: `HStack { Text("Live Transcription"); Spacer(); Toggle("", isOn: $transcriptionEnabled).toggleStyle(.switch).labelsHidden().accessibilityLabel(String(localized: "Enable live transcription")) }`. The toggle reads/writes `@AppStorage("com.macrec.ui.transcriptionEnabled") private var transcriptionEnabled: Bool = true`. When `transcriptionEnabled == false`, the section's body rows are wrapped in `.disabled(true).opacity(0.4)` (preferred — keeps layout stable) or hidden via `if transcriptionEnabled { … }` (alternative — collapses the section). **Recommended: dim/disable, don't collapse**, so the user can still see what they will get when re-enabling. The Form's `.fixedSize(horizontal: false, vertical: true)` keeps the popover height consistent. |
| `Sources/macrec-ui/Views/ControlBar.swift` | At `startTapped()`: read `@AppStorage("com.macrec.ui.transcriptionEnabled")`. If `false`, override the `transcribeProvider` argument to `RecordingOptions` to `"none"` regardless of the persisted `transcribeProvider` value. The persisted value is unchanged. Add a `// MARK: - Transcription gate` section comment. |
| `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift` | (only if needed) Audit whether the picker also gates on `transcriptionEnabled`. The simplest path: `TranscriptionPicker` is unchanged; the gate lives in `ControlBar.startTapped()`. The picker still allows selection even when the section is disabled — the gate is the toggle. |

### Acceptance criteria covered
- AC #1 / AC #2 (partial): NSSwitch toggle in the Live Transcription section header.
- AC #11: existing `@AppStorage` keys preserved; the new `transcriptionEnabled` key is additive.
- Q-03 honored: the engine selection persists across toggle flips.

### Verification commands
```bash
swift build -c debug
# Manual:
# - Open the popover, select Soniox as the engine.
# - Toggle the section header switch OFF → engine picker (and other Live Transcription rows) dim.
# - Start a recording → no transcription pipeline runs (verify by absence of partials).
# - Stop the recording.
# - Toggle the switch ON → section rows light up, engine still says "Soniox".
# - Start a recording → transcription works as before.
defaults read com.local.macrec-ui com.macrec.ui.transcribeProvider  # should still be "soniox"
defaults read com.local.macrec-ui com.macrec.ui.transcriptionEnabled  # should reflect the toggle
swift test --filter LiveTranscriptionSectionHeaderToggleTests  # P10
swift test --filter ControlBarStartTappedTranscriptionGateTests  # P10
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| The disabled-but-visible rows confuse users (they can still click pickers) | Medium | `.disabled(true)` blocks interaction; `.opacity(0.4)` makes the visual disabled state obvious. Alternative: add a one-line explainer "Transcription off — toggle on to enable" inside the dimmed section. |
| `ControlBar.startTapped()` forgets the gate and the transcription pipeline runs even when toggle is OFF | Medium | Test `ControlBarStartTappedTranscriptionGateTests` verifies `transcribeProvider` resolved to `"none"` when `transcriptionEnabled == false`. |
| The new `transcriptionEnabled` key is `Bool` and must not collide with any existing `Bool` key | Low | `transcriptionEnabled` is a new key name; no collision in the inventory (codebase-scan §4f). |
| Default `true` for `transcriptionEnabled` changes existing behavior — users who never explicitly enabled transcription suddenly start a transcription pipeline at next launch | High **if `transcribeProvider != "none"` was set** | The default of `transcribeProvider` is `"apple"` (codebase-scan §4f), which is a network-free engine. Combined with `transcriptionEnabled = true` default, behavior is the same as today (apple-on-device transcription runs by default). **No regression** for existing users whose `transcribeProvider` is unchanged. |

### Dependencies
P4 (`LiveTranscriptionSection` exists).

---

## Phase 7 — Footer + Record button (red gradient + "Ready" pill)

**parallel_safe: true** (after P4; replaces only the bottom band of `RootView`).

### Goal
Replace `RootView`'s pinned-bottom band (the existing `ControlBar` button row + `SavedToDisclosure`) with the new mockup-style footer: a red-gradient `Start Recording` button on the left, a `● Ready` status pill on the right, and (when recording is active) the existing `Pause`/`Stop`/`Split` cluster swapped in via the existing visibility matrix. `SavedToDisclosure` and `ResizeHandle` remain below the footer (per the existing structure).

### Files to create

| Path | Purpose |
|---|---|
| `Sources/macrec-ui/Views/Footer/RecordButton.swift` | Red-gradient primary button. Uses `Palette.recordButtonGradient(for: colorScheme)`. Calls `ControlBar`'s existing `start()` action. Accessibility label `String(localized: "Start recording")`. Disabled when permissions are missing or recording is in progress (mirrors `ControlBar.showsStart`). |
| `Sources/macrec-ui/Views/Footer/StatusPill.swift` | "● Ready" / "● Recording" / "● Paused" / "● Stopping" pill driven by `recordingController.state`. Color of the dot adapts: gray for `.idle`, red pulsing for `.recording`, amber for `.paused`. |
| `Sources/macrec-ui/Views/Footer/PopoverFooter.swift` | `HStack { RecordButton(); Spacer(); StatusPill() }` when `state == .idle`. When `state != .idle`, swap `RecordButton` for the existing `ControlBar` button cluster (Pause/Stop/Split) per the visibility matrix. Reuses the existing `ControlBar.showsStart` / `showsPause` / `showsResume` / `showsStop` / `showsSplit` properties. |

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/RootView.swift` | Replace `ControlBar()` with `PopoverFooter()` in the bottom band. `SavedToDisclosure` and `ResizeHandle` remain below. |
| `Sources/macrec-ui/Views/ControlBar.swift` | **Behavior preserved verbatim** — `startTapped()`, `pauseTapped()`, `resumeTapped()`, `stopTapped()`, `splitTapped()`, and the visibility matrix are all retained. The existing `ControlBar` view is repurposed: `PopoverFooter` calls into the same `ControlBar` action methods (extract the action methods into a `ControlBarActions` view-model if needed for cleanliness, but a simpler refactor is to just keep `ControlBar` as the action surface and have `PopoverFooter` compose `ControlBar`'s buttons differently). |

### Acceptance criteria covered
- AC #1 / AC #2 (partial): red-gradient `Start Recording` button + status pill in the footer.
- AC #11: `ControlBar`'s `@AppStorage` reads at `startTapped()` are unchanged.

### Verification commands
```bash
swift build -c debug
# Manual:
# - Open the popover in idle state. Verify red-gradient Start Recording button + "● Ready" pill.
# - Click Start → button cluster swaps to Pause/Stop/Split per visibility matrix; pill becomes "● Recording" with pulsing red dot.
# - Click Pause → pill becomes "● Paused" with amber dot; Resume button visible.
# - Click Stop → cluster returns to idle; pill returns to "● Ready".
# - Verify the gradient looks correct in both light and dark modes.
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Refactoring `ControlBar` to expose its actions to `PopoverFooter` introduces a regression in the visibility matrix | Medium | Keep `ControlBar` as-is; have `PopoverFooter` import `ControlBar`'s action methods via a shared view-model, OR simply have `PopoverFooter` instantiate `ControlBar()` and let `ControlBar` render the buttons (only the idle state uses the new `RecordButton`). |
| Red gradient looks different in dark mode | Low | `Palette.recordButtonGradient(for:)` accepts the `ColorScheme` and returns a tuned gradient per scheme. |
| Pulsing red dot animation drains battery | Low | Use `.symbolEffect(.pulse)` (system-throttled) or a 1-Hz `TimelineView`. |
| `StatusPill` reads `recordingController.state` but `PopoverFooter` doesn't have access | Low | `PopoverFooter` reads `@Environment(RecordingController.self)` like every other view in the popover. |

### Dependencies
P1 (`Palette.recordButtonGradient(for:)`), P4 (footer is below the new Form).

---

## Phase 8 — Popover appearance plumbing (`AppearanceHostingRoot` wraps `RootView`)

**parallel_safe: true** (after P1; can land before P3/P4 because it only modifies `PopoverController`).

### Goal
Wrap `RootView` in `AppearanceHostingRoot` before handing it to `NSHostingController` in `PopoverController`. Verifies acceptance criterion 5 for the popover side (the Settings side was verified in P1). Per the research in `research-nshostingcontroller-appearance.md`, **no new `NotificationCenter` observer is needed** — `@AppStorage` reactivity inside the SwiftUI graph rooted at the `NSHostingController` handles the redraw natively on macOS 26.

### Files to create

None.

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/PopoverController.swift` | Change `hostingController = NSHostingController(rootView: RootView())` to `hostingController = NSHostingController(rootView: AppearanceHostingRoot { RootView() })`. **Audit:** verify `popover.appearance` is **never set** anywhere in `PopoverController` (a `grep -n "\.appearance" PopoverController.swift` should return zero hits). If a hit exists, remove it — setting `popover.appearance` overrides `.preferredColorScheme` and breaks Follow-System. The existing `heightObserver` is unchanged. |

### Acceptance criteria covered
- AC #5: selecting Light forces light rendering; selecting Dark forces dark rendering; selecting Follow System matches the system appearance and updates **live** when the system appearance changes.
- AC #6: appearance choice persists across launches (the persistence side was already verified in P1; P8 makes the popover honor it).

### Verification commands
```bash
swift build -c debug
grep -n "\.appearance" Sources/macrec-ui/PopoverController.swift  # should return zero hits
# Manual:
# - With appearance set to System and macOS in Light mode → popover renders light. Flip system to Dark via System Settings → popover repaints dark live (no popover-close-and-reopen needed).
# - Set appearance to Light → popover stays light even when system is Dark.
# - Set appearance to Dark → popover stays dark even when system is Light.
# - Set back to System → popover follows system live (this is the macOS 14 `preferredColorScheme(nil)` revert bug — verified fixed in macOS 15+ per research doc).
swift test --filter AppearanceHostingRootTests  # P10
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `.preferredColorScheme(nil)` revert bug not actually fixed on macOS 26 | LOW (research §risks: medium-high confidence in the fix) | Escape hatch: add a KVO observer on `NSApp.observe(\.effectiveAppearance)` in `PopoverController` that forces `hostingController.rootView = AppearanceHostingRoot { RootView() }` on every system flip. Documented in research doc. |
| `popover.appearance` set elsewhere in the codebase | LOW | Audit step in verification commands above. |
| `.regularMaterial` accidentally added to inner Form sections, causing double-frost when popover is dark | MEDIUM | `Palette.swift` header comment + P1 risk note + P4 reviewer enforce. |
| Settings window does not propagate the appearance switch (because it lives in `Settings { }` scene, not `PopoverController`) | None — covered by P1's `.preferredColorScheme(resolvedScheme)` on the Settings scene | — |

### Dependencies
P1 (`AppearanceHostingRoot` exists).

---

## Phase 9 — `LiveTranscriptPanel` preservation (visual rehousing only)

**parallel_safe: true** (after P4; the panel sits between the Form and the footer in the new layout).

### Goal
Verify that the `LiveTranscriptPanel`'s streaming-text behavior, auto-scroll, segment-cap, language-chip, settled/partial italic treatment, "Clear transcript" button, and `TranscriptionStatusBadge` header are all preserved verbatim in the new layout. The container styling is updated to match the inset-grouped aesthetic of the new sections, but the streaming logic is untouched.

### Files to create

None.

### Files to modify

| Path | Change |
|---|---|
| `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift` | **Streaming logic unchanged.** Container styling updated: replace `Color(nsColor: .windowBackgroundColor).opacity(0.5)` with `SemanticColors.groupBackground` (matches the Form sections). Add a rounded-rectangle border using `SemanticColors.separator` to match the inset-grouped look. Preserve `.frame(maxHeight: .infinity)` (critical for vertical elasticity). Preserve the `shouldShow` computed property (panel hides when idle and empty). |
| `Sources/macrec-ui/Views/Transcription/TranscriptionStatusBadge.swift` | (only if needed) Visual restyle to match the new chip aesthetic. No behavior change. |
| `Sources/macrec-ui/Views/Transcription/TranscriptionMetricsView.swift` | (only if needed) Footer placement preserved (between transcript panel and bottom band). Visual restyle to match the inset-grouped aesthetic. |

### Acceptance criteria covered
- AC #3: vertical elasticity preserved — the panel still claims `.frame(maxHeight: .infinity)`.
- AC #4: live transcript streaming preserved verbatim.
- AC #11: `recordingController.transcriptSegments` reads are unchanged.

### Verification commands
```bash
swift build -c debug
# Manual:
# - Start a recording with transcription enabled (Apple on-device or Soniox).
# - Verify partials stream in italic, settled segments render upright.
# - Verify language chip (BCP-47 first-two letters uppercased) renders next to each segment.
# - Verify auto-scroll keeps the latest segment visible.
# - Verify "Clear transcript" button empties the panel.
# - Stop the recording. Verify the panel collapses when idle and empty.
# - Resize the popover via `ResizeHandle` — the panel grows/shrinks to fill residual space.
swift test --filter LiveTranscriptPanelTests  # existing tests must still pass (gitstatus marks file as modified)
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Container restyle breaks an existing `LiveTranscriptPanelTests` snapshot | Medium | Run the existing tests early in P9; if snapshots break, regenerate (the visual rehousing is intentional). |
| `.frame(maxHeight: .infinity)` interaction with the new Form's `.fixedSize(horizontal: false, vertical: true)` is wrong | Medium | This is the exact composition recommended in investigation §Topic 4 and confirmed by codebase-scan §4h — Form takes intrinsic height, panel takes residual. Verified pattern. |
| `shouldShow` computed property is bypassed by the new layout (panel shows even when idle and empty) | Low | Wrap `LiveTranscriptPanel()` in `if liveTranscriptPanel.shouldShow { ... }` at the `RootView` level. |
| `TranscriptionMetricsView` placement changes break the cost/latency display | Low | Keep it in the same slot (between panel and footer). |

### Dependencies
P4 (Form sections exist; the panel slot is `RootView`'s flexible middle band).

---

## Phase 10 — Tests (parallel test-builders, mapped to source phases)

**parallel_safe: true within the phase** (multiple test files can be authored in parallel by separate test-builders; each maps to a single source phase).

### Goal
Land the new test coverage required by acceptance criterion 8, plus regression tests for the changes made in P4 (key preservation), P6 (transcription gate), and P9 (existing `LiveTranscriptPanelTests` still pass). All tests live under `Tests/MacrecUITests/`.

### Files to create

| Path | Maps to | Purpose |
|---|---|---|
| `Tests/MacrecUITests/Theme/AppearanceModeTests.swift` | P1 | Round-trip `AppearanceMode("system")`, `AppearanceMode("light")`, `AppearanceMode("dark")` rawValues; verify `colorScheme` resolves to `nil` / `.light` / `.dark`. Verify `AppearanceMode.userDefaultsKey == "com.macrec.ui.appearance"` and `AppearanceMode.defaultRawValue == "system"`. |
| `Tests/MacrecUITests/Theme/AppearanceHostingRootTests.swift` | P1, P8 | Verify the wrapper applies `.preferredColorScheme(_:)` matching the persisted `@AppStorage` value. Use a `UserDefaults(suiteName: "test")` override to write each rawValue and assert the wrapper's resolved `ColorScheme?`. |
| `Tests/MacrecUITests/Settings/GeneralSettingsViewTests.swift` | P2 | Verify the picker writes the expected rawValue when each option is selected (acceptance criterion 8 sub-bullet 3). Use a `UserDefaults(suiteName: "test")` injection. |
| `Tests/MacrecUITests/Views/Header/AppearanceSwitcherTests.swift` | P3 | Verify the popover header switcher writes the same `@AppStorage` key as the Settings picker. Verify `.accessibilityLabel(_:)` is set on each segment. |
| `Tests/MacrecUITests/Views/Sections/PopoverSettingsFormTests.swift` | P4 | Verify the Form composes both `GeneralSection` and `LiveTranscriptionSection`. Verify `.fixedSize(horizontal: false, vertical: true)` is applied. |
| `Tests/MacrecUITests/Views/Sections/AppStorageKeyRegressionTests.swift` | P4 | **Regression**: instantiate each picker in isolation (`FormatPicker()`, `LayoutPicker()`, `MicrophonePicker()`, `TranscriptionPicker()`, `TranscriptionSourcePicker()`, `TranscriptionFormatPicker()`, `TranscriptionLanguagePicker()`) and verify the `@AppStorage` key string each one binds to (mirror `Tests/MacrecUITests/Transcription/TranscriptionPickerTests.swift`'s static-helper-test pattern). Documents the ten preserved keys. |
| `Tests/MacrecUITests/Views/Sections/LiveTranscriptionSectionHeaderToggleTests.swift` | P6 | Verify the `transcriptionEnabled` toggle reads/writes `"com.macrec.ui.transcriptionEnabled"`. Verify default is `true`. Verify toggling does NOT mutate `"com.macrec.ui.transcribeProvider"` (Q-03). |
| `Tests/MacrecUITests/ControlBar/ControlBarStartTappedTranscriptionGateTests.swift` | P6 | Verify `ControlBar.startTapped()` composes `RecordingOptions` with `transcribeProvider == .none` when `transcriptionEnabled == false`, even though the persisted `transcribeProvider` is e.g. `"soniox"`. |
| `Tests/MacrecUITests/Views/Transcription/ApiKeyStatusRowTests.swift` | P5 | Verify the chip's "Configured" state when `EnvFileStore.read(toolName:key:)` returns a non-nil value, and "Not configured" when it returns nil. Verify the chip is hidden when `transcribeProvider` is one that does not require a key (Apple, on-device). |
| `Tests/MacrecUITests/Theme/PaletteTests.swift` | P1 | Verify `Palette.recordButtonGradient(for: .light)` and `Palette.recordButtonGradient(for: .dark)` return distinct (non-equal) gradients. Verify `Palette.successChipBackground`, `Palette.successChipForeground`, and `Palette.successDot` are non-nil. |

### Files to modify

| Path | Change |
|---|---|
| `Tests/MacrecUITests/Transcription/LiveTranscriptPanelTests.swift` | (already modified per git status) Update assertions if container restyle changes any test's expected color value. **Streaming-behavior tests must remain unchanged.** Verify the file still compiles after P9. |

### Acceptance criteria covered
- AC #6: persistence — verified by `AppearanceModeTests` round-trip + `defaults read` manual check.
- AC #7: all existing tests pass — regression coverage for `LiveTranscriptPanelTests`, `TranscriptionPickerTests`, `RecordingControllerTests`, etc.
- AC #8: new tests added — exactly the three required by the spec (round-trip, scheme-resolution, switcher-write) plus additional coverage.
- AC #11: `AppStorageKeyRegressionTests` documents the ten preserved keys.

### Verification commands
```bash
swift test 2>&1 | tee /tmp/p10-test.log
# Should show all tests green. If any existing test fails, that's a P9/P4 regression to fix.
swift test --filter AppearanceModeTests
swift test --filter AppearanceHostingRootTests
swift test --filter GeneralSettingsViewTests
swift test --filter AppearanceSwitcherTests
swift test --filter PopoverSettingsFormTests
swift test --filter AppStorageKeyRegressionTests
swift test --filter LiveTranscriptionSectionHeaderToggleTests
swift test --filter ControlBarStartTappedTranscriptionGateTests
swift test --filter ApiKeyStatusRowTests
swift test --filter PaletteTests
swift test --filter LiveTranscriptPanelTests   # existing — must stay green
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `@AppStorage` is hard to test outside SwiftUI body evaluation | Medium | Tests use `UserDefaults(suiteName: "test-uniqueid")` and either (a) `@StateObject` test harness that wraps the view, or (b) extract the rawValue→`ColorScheme?` conversion into `AppearanceMode.colorScheme` and test the enum directly without the SwiftUI binding. The latter is much simpler and is what the AppearanceModeTests file does. |
| `AppStorageKeyRegressionTests` is brittle (any view-internal refactor breaks it) | Low | Test only the `@AppStorage` key string; if a picker is renamed but its key is unchanged, the test still passes. |
| `LiveTranscriptPanelTests` modifications conflict with P9's container restyle | Medium | Land P9 first, then update the modified tests to match. |
| `ControlBarStartTappedTranscriptionGateTests` requires `RecordingController` mocking | Medium | Use the existing `RecordingControllerTests` mock pattern (a fake `RecordingController` that records its `start()` argument). |
| `PaletteTests` needs `LinearGradient` equality | Low | Compare the gradient's `stops` array, not the `LinearGradient` itself. |

### Dependencies
P1, P2, P3, P4, P5, P6, P8, P9 must all be at least scaffolded. Test-builders can run in parallel **after** their respective source phase has landed.

---

## Phase 11 — Documentation (project-design, project-functions, Issues, macrec-ui.md)

**parallel_safe: false** — runs last; documents what was actually built.

### Goal
Update all four required project-level documents to reflect the new theming and redesign. The user-facing `docs/tools/macrec-ui.md` gains a "Theming" subsection; `project-design.md` gains a section on the popover composition and theming architecture; `project-functions.md` gains the new "UI Appearance Mode" functional requirement; `Issues - Pending Items.md` records the orphaned-but-retained `@AppStorage` keys and the deferred Q-02 chip-expiration plumbing.

### Files to create

None.

### Files to modify

| Path | Change |
|---|---|
| `docs/design/project-design.md` | Add a new section under the macrec-ui chapter describing: (a) the new `Theme/` folder layout (`Palette.swift`, `SemanticColors.swift`, `AppearanceHostingRoot.swift`); (b) the `AppearanceMode` enum's location in `MacrecUIKit/Theme/`; (c) the new `Form { Section { … } }.formStyle(.grouped)` popover composition; (d) the persistence story (`@AppStorage("com.macrec.ui.appearance")`, `@AppStorage("com.macrec.ui.transcriptionEnabled")`); (e) the `AppearanceHostingRoot` wrapper used by `PopoverController`; (f) the `.preferredColorScheme(_:)` modifier on the `Settings { }` scene. |
| `docs/design/project-functions.md` | Append two new functional requirements under §1 (functional requirements): **FR-UI-APPEARANCE** (UI Appearance Mode) and **FR-UI-TRANSCRIPTION-GATE** (Live Transcription header toggle). Append the Q-02 deferral to §3 (open questions) and to §4 (deferred features) as "API-key expiration chip data source — deferred to a follow-up plan". The exact text is appended by the standalone task documented at the bottom of this plan. |
| `Issues - Pending Items.md` | Add to the **Pending** section (top): "API-key expiration chip data source plumbing (Q-02 deferred from plan-008) — track expiration date per provider, surface in the chip with red/amber/green status." Add to the **Pending** section: "`@AppStorage` keys `com.macrec.ui.transcriptionExpanded` and `com.macrec.ui.recordingSettingsExpanded` are orphaned after plan-008 P4 — retained in `UserDefaults` for back-compat. Decide whether to remove them in a future cleanup or repurpose for Form section open/closed state." Add to the **Pending** section: "Legacy view files `FilenameField.swift`, `FolderPicker.swift`, `SonioxKeyField.swift`, `GeminiKeyField.swift`, `ProviderKeyField.swift` are no longer composed by `RootView` after plan-008 — kept as deprecated source files. Remove in a future cleanup." |
| `docs/tools/macrec-ui.md` | Add a new "Theming" subsection describing: (a) the appearance switcher control in the popover header strip (3 segments: System / Light / Dark); (b) the same switcher mirrored in Settings → General → Appearance; (c) persistence via `@AppStorage("com.macrec.ui.appearance")` (raw values `"system"` / `"light"` / `"dark"`, default `"system"`); (d) verification command `defaults read com.local.macrec-ui com.macrec.ui.appearance`. |

### Acceptance criteria covered
- AC #10: docs updated.

### Verification commands
```bash
# Verify the new files exist and the new sections are present:
grep -n "FR-UI-APPEARANCE" docs/design/project-functions.md
grep -n "Theming" docs/tools/macrec-ui.md
grep -n "AppearanceHostingRoot" docs/design/project-design.md
grep -n "Q-02 deferred from plan-008" "Issues - Pending Items.md"
```

### Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Documentation drifts from implementation | Medium | P11 is the last phase; all changes are documented after they ship. The plan's "Architecture Summary" also serves as a starting point for the project-design.md section. |
| Issues file misses the orphaned keys | Low | Explicit list above. |

### Dependencies
All other phases (P1–P10) must be complete.

---

## Standalone task (Phase 4 Planner — to be performed alongside this plan)

Append a new "UI Appearance Mode" functional requirement to `docs/design/project-functions.md`. The exact text:

```markdown
### Added by plan-008 — UI redesign + light/dark/system theming

#### FR-UI-APPEARANCE — Appearance mode picker
**Status:** PLANNED.
The macrec-ui menu-bar app MUST surface a 3-options appearance picker
(System / Light / Dark) in two locations: the popover header metadata
strip and the Settings dialog under a new "General" tab. Both controls
bind to the same persisted preference. The selected appearance MUST be
applied to the entire macrec-ui app (popover + Settings window + any
auxiliary windows/sheets) via `.preferredColorScheme(_:)` on the root
SwiftUI scene, and additionally via an `AppearanceHostingRoot` wrapper
that wraps the popover's `RootView` before it is mounted in
`NSHostingController` (because the popover is hosted outside the
SwiftUI scene tree on macOS 26).

The preference MUST persist across app launches via
`@AppStorage("com.macrec.ui.appearance")` on `UserDefaults.standard`,
with raw values `"system"` / `"light"` / `"dark"` and default `"system"`.
The persisted value MUST be readable via
`defaults read com.local.macrec-ui com.macrec.ui.appearance`.

The default value `"system"` is a documented user-facing UX default (not
a silent substitution for missing required configuration), and is
therefore allowed under the project's no-fallback-configuration rule.

#### FR-UI-TRANSCRIPTION-GATE — Live Transcription section header toggle
**Status:** PLANNED.
The "Live Transcription" section in the popover MUST expose a
`Toggle.toggleStyle(.switch)` in its section header that gates whether
the transcription pipeline runs at recording start. The toggle persists
via `@AppStorage("com.macrec.ui.transcriptionEnabled")` (Bool, default
`true`). When OFF, `ControlBar.startTapped()` composes
`RecordingOptions` as if `transcribeProvider == "none"` regardless of
the persisted `transcribeProvider` value (which is preserved unchanged
so re-enabling the toggle restores the user's last engine selection).
```

This text is appended **at the end of §1.1** of `project-functions.md`, between the existing `### Added by plan-007` block and the start of `## 2. Non-functional requirements`. The Q-02 deferral note is added at the end of `## 4. Deferred (v2) features` as a new bullet under a new heading `### Added by plan-008 — UI redesign v2 candidates`.

---

## Cross-Phase Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The redesign accidentally changes one of the ten existing `@AppStorage` keys read by `ControlBar.startTapped()` | Medium | `AppStorageKeyRegressionTests` (P10) verifies all ten keys remain the source of truth. Code review (Phase 7 of team workflow) audits the diff for any string-literal change matching `"com.macrec.ui.*"`. |
| The vertical elasticity regresses (popover stops resizing or hits a fixed-height ceiling) | Medium | `.fixedSize(horizontal: false, vertical: true)` on the Form is the critical pattern. Manual verification step in P4 explicitly tests resize. |
| The `LiveTranscriptPanel` regresses (streaming text disappears, auto-scroll breaks, language chip stops rendering) | Medium | `LiveTranscriptPanelTests` (existing, modified per git status) must stay green in P10. P9 verification step manually exercises the streaming path. |
| Two new `@AppStorage` keys (`appearance`, `transcriptionEnabled`) collide with future keys | Low | Names are namespaced under `com.macrec.ui.*` and verified non-colliding against the codebase-scan §4f inventory. |
| The Q-02 deferred chip-expiration plumbing is forgotten | Low | Recorded in `Issues - Pending Items.md` (P11) and in `project-functions.md` §4 deferred features (P11). |
| macOS 26 beta regression in `preferredColorScheme(nil)` system-following behavior | Low (research §risks) | Escape hatch documented: KVO observer on `NSApp.observe(\.effectiveAppearance)` in `PopoverController` that re-assigns `hostingController.rootView`. Add only if the manual verification in P8 reveals a regression. |
| The Form's `.formStyle(.grouped)` consumes drag gestures intended for `ResizeHandle` | Low | Verified in investigation §Topic 4 — separate hit areas. Manual verification in P4 confirms. |
| Double-frost (Material inside Form sections on top of popover vibrancy) | Medium | `Palette.swift` header comment + P1, P4, P8 risk notes all enforce. Use `Color(nsColor: .controlBackgroundColor)` for section fill, never `.regularMaterial`. |

---

## Phase Execution Order Summary

**Recommended execution sequence** (Phase 6 of team workflow):

1. **Pass 1 (foundation):** P1 only.
2. **Pass 2 (parallel-safe after P1):** P2, P3, P8 in parallel.
3. **Pass 3 (big merge):** P4 only.
4. **Pass 4 (parallel-safe after P4):** P5, P6, P7, P9 in parallel.
5. **Pass 5 (tests):** P10 — multiple test-builders in parallel, each scoped to one source phase.
6. **Pass 6 (docs):** P11 only.

Total estimated coder-passes: 6. Pass 2 and Pass 4 each contain 3-4 parallel work units. Pass 5 contains up to 10 parallel test-builders. Pass 1, Pass 3, and Pass 6 are single-coder serial work.

---

## Plan Sign-Off Checklist (before Phase 6 starts)

- [ ] User confirmed Q-02 deferral (chip shows only "Configured" / "Not configured" in v1.6).
- [ ] User confirmed Q-03 retention default (engine selection preserved when toggle is OFF; new `transcriptionEnabled` Bool gates).
- [ ] User confirmed the orphaned-but-retained disposition for `transcriptionExpanded` and `recordingSettingsExpanded` keys.
- [ ] User confirmed the deferred-cleanup disposition for `FilenameField.swift`, `FolderPicker.swift`, `SonioxKeyField.swift`, `GeminiKeyField.swift`, `ProviderKeyField.swift` (kept as deprecated source files).
- [ ] User confirmed the new sidebar entry in Settings is labeled "General" (not "Appearance") and appears at the top of the sidebar.
- [ ] User confirmed the appearance switcher in the popover header uses a 3-segment Picker (not an icon menu).
- [ ] User confirmed that on macOS 26 the `.preferredColorScheme(nil)` revert behavior works as documented (no escape-hatch KVO observer needed).
