# Refined Request: macrec-ui Popover Redesign + Light/Dark Theming

## Category
Design + Development (SwiftUI / macOS 26)

## Objective
Re-skin the `macrec-ui` menu-bar popover so its visual layout matches the
proposed mockup in `docs/design/mockups/popover-redesign.html` /
`popover-redesign.png` (an inset-grouped, NSPopUpButton-styled,
two-section settings card with a metadata header strip and a red-gradient
record button). The redesign must be delivered in BOTH a light and a
dark variant that match the two side-by-side mockup variants, must
introduce a user-facing appearance switcher (Follow System / Light /
Dark) whose choice persists across launches, and must preserve two
non-negotiable behaviors of the current implementation: the popover
remains vertically expandable (height adapts to content), and the live
transcript panel continues to stream text inside the popover during
recording.

## Scope

### In scope
- Visual rework of the `macrec-ui` popover compositional root
  (`Sources/macrec-ui/Views/ControlBar.swift` and the views it
  composes — `PermissionStatusView`, `FilenameField`, `FormatPicker`,
  `LayoutPicker`, `FolderPicker`, `MicrophonePicker`,
  `TranscriptionPicker`, `TranscriptionSourcePicker`,
  `TranscriptionFormatPicker`, `TranscriptionLanguagePicker`,
  `SonioxKeyField`, `GeminiKeyField`, `ProviderKeyField`, and the
  start/stop button cluster) so the rendered surface matches the mockup.
- Introduction of two coordinated SwiftUI themes (light, dark) using
  semantic colors / `Material` backgrounds so the same view tree renders
  Variant A (light) and Variant B (dark) of the mockup.
- Addition of an appearance-mode switcher control (Follow System /
  Light / Dark) inside the popover header strip.
- Persistence of the appearance choice via `@AppStorage` under the
  `macrec-ui` UserDefaults suite.
- Application of the chosen appearance to the entire macrec-ui app
  (popover plus any auxiliary windows / sheets such as the existing
  Settings dialog) via `.preferredColorScheme` on the root scene.
- Preservation of the existing `LiveTranscriptPanel` streaming behavior
  inside the (now redesigned) popover.
- Preservation of the popover's vertical elasticity — the popover must
  continue to expand and contract with content; no fixed-height window.
- Test coverage for the new appearance-switch and persistence paths.
- Documentation updates: add a `plan-xxx-ui-redesign-and-theming.md`
  under `docs/design/`, update `docs/design/project-design.md`, and
  update `docs/design/project-functions.md` with the new functional
  requirements.

### Out of scope
- Any changes to the `macrec` CLI tool (`Sources/macrec-cli`) or to
  `MacrecCore` recording / transcription logic.
- Adding new transcription providers, new output formats, or new
  recording features.
- Restructuring `RecordingController` state, `RecordingOptions`, or any
  controller-surface contract — only the UI consumes them differently.
- Replacing the popover with a regular window or with a scene-based
  Settings window beyond what already exists.
- Theming for any other macOS app (only `macrec-ui`).
- Localized translations of new labels beyond English (existing
  `String(localized:)` wrapping must continue to be used so future
  localization remains possible).

## Requirements

### Visual / layout (matches mockup `popover-redesign.html`)
1. **Filename-as-title header.** The recording's working filename is
   rendered as the popover's title (large, primary text). The current
   `FilenameField` editor is preserved but visually integrated into
   this header treatment.
2. **Metadata strip.** Below the title, a single horizontal strip
   contains: a "Save to" folder chip showing the resolved output folder
   (driven by the existing `FolderPicker` value, including the FR-36
   `~/Recordings/` default), a single consolidated "All permissions
   granted" / "Permissions needed" pill (replacing the current
   multi-row `PermissionStatusView` when all permissions are granted —
   detail rows still surface when one or more permissions are missing),
   and the new appearance switcher.
3. **Two inset-grouped sections.** The settings area is rendered as two
   `Form { Section { ... } }`-style inset-grouped cards
   (`.formStyle(.grouped)` or equivalent visual styling):
   - **General** — contains `FormatPicker`, `LayoutPicker`,
     `MicrophonePicker`, and `FolderPicker` rows (the folder row may be
     consolidated into the metadata strip; the section keeps the other
     three pickers).
   - **Live Transcription** — contains `TranscriptionPicker` (engine),
     `TranscriptionSourcePicker`, `TranscriptionFormatPicker`,
     `TranscriptionLanguagePicker`, and the API-key sub-row.
4. **Right-aligned `NSPopUpButton`-style controls.** Each picker row in
   both sections renders its label on the left and its picker on the
   right with the chevron affordance, matching the mockup. Use
   `.menu` `Picker` style (or `.pickerStyle(.menu)`) so the macOS
   chevron is rendered.
5. **Hairline dividers.** Rows within a section are separated by
   1pt hairline dividers using the system separator color.
6. **NSSwitch-style on/off toggle in the "Live Transcription" section
   header.** A `Toggle` with `.toggleStyle(.switch)` next to the
   "Live Transcription" section title flips the engine between an
   active provider (whatever the user last chose) and `none`. When
   off, the section's body controls are dimmed / disabled.
7. **API-key sub-row.** When the selected transcription engine
   requires an API key, a sub-row appears that shows: a status chip
   indicating whether the key is present (and, when known, an
   expiration date status — green/amber/red), and a single
   `Replace…` button (replaces the current `Save / Clear` pair). The
   underlying key value is still resolved through `EnvFileStore` /
   `ProcessInfo` (no behavioral change to the resolution chain).
8. **Red-gradient `Start Recording` footer button.** The primary
   action button uses a red gradient fill matching the mockup. The
   button's enable / disable / visibility logic is unchanged from the
   current `ControlBar` (the matrix in
   `ControlBar.swift` lines 9–18 is preserved). When recording is
   active, the same footer slot renders the `Pause`, `Stop`, `Split`
   cluster according to the existing visibility matrix.
9. **Live transcript panel integration.** The existing
   `LiveTranscriptPanel` is preserved verbatim in functionality but
   restyled so its container matches the inset-grouped look of the new
   sections. It appears between the "Live Transcription" section and
   the footer when transcription is active or has produced segments,
   and is hidden when idle and empty (current `shouldShow` behavior is
   preserved).

### Behavioral
10. **Vertical elasticity preserved.** The popover must continue to
    grow and shrink based on content. The `LiveTranscriptPanel`
    continues to claim its `.frame(maxHeight: .infinity)` slot when
    visible, and the popover height continues to reflect the union of
    all visible sections plus the (variable-height) transcript panel.
    Do NOT introduce a fixed-height window.
11. **Live transcript streaming preserved.** The streaming-text panel
    continues to render `recordingController?.transcriptSegments` with
    the same auto-scroll, segment-cap, language-chip, settled/partial
    visual treatment, and "clear transcript" affordance present today.
12. **All current `@AppStorage` keys preserved.** The redesigned views
    must continue to read and write the same `com.macrec.ui.*` keys
    that `ControlBar.startTapped()` reads at start time (output folder,
    basename, format, layout, mic UID, transcription provider, source,
    format, language hints). The redesign is purely a re-composition of
    the existing controls.

### Theming
13. **Light theme matches Variant A** of the mockup. Use SwiftUI
    semantic colors (`Color(nsColor: .controlBackgroundColor)`,
    `.windowBackgroundColor`, `.separatorColor`, etc.) and `Material`
    backgrounds where the mockup shows translucency, so the light
    rendering matches the left half of the mockup without hard-coding
    hex values where a semantic color exists.
14. **Dark theme matches Variant B** of the mockup. The same view tree
    must render the right-half mockup when `.preferredColorScheme(.dark)`
    is applied. Where the mockup uses brand colors that are not part of
    the system semantic palette (e.g. the red gradient on the record
    button), define a small palette in a single Swift file
    (`Sources/macrec-ui/Theme/Palette.swift`) so light/dark variants of
    the brand colors are co-located.
15. **Appearance switcher control.** A control in the popover header
    strip (icon menu or 3-segment control labeled with SF Symbols
    `circle.lefthalf.filled` for system, `sun.max` for light, `moon` for
    dark) lets the user pick Follow System / Light / Dark. The control
    is keyboard-accessible and exposes accessibility labels.
    *Assumed; please confirm:* 3 options (System / Light / Dark)
    — chosen because it matches macOS HIG.
16. **Application scope: full app.** The chosen appearance is applied
    to the popover and any other macrec-ui windows/sheets via
    `.preferredColorScheme(_:)` on the root scene of the macrec-ui
    `App`. *Assumed; please confirm.*
17. **Persistence.** The chosen appearance is stored in `@AppStorage`
    under the key `com.macrec.ui.appearance` with allowed values
    `system`, `light`, `dark` (default `system`). The control reads
    and writes the same key, and the root scene observes it to apply
    `.preferredColorScheme`. *Assumed; please confirm key name.*
18. **Mirror in Settings dialog (if present).** If a Settings dialog
    already exists in macrec-ui, the same appearance switcher is also
    surfaced there so the user can change it from either entry point;
    both controls bind to the same `@AppStorage` key. If no Settings
    dialog exists, this requirement is dropped (do not invent one).

## Constraints

- **Language / framework.** Swift 6, SwiftUI. Per
  `CLAUDE.md` Exception 001 the global TypeScript-only rule does not
  apply to this project. No Node, no React.
- **Deployment target.** macOS 26 (Tahoe) — `Package.swift`
  `platforms: [.macOS(.v26)]` per Exception 002. Modern SwiftUI APIs
  (`@AppStorage`, `.preferredColorScheme`, `.formStyle(.grouped)`,
  `Material`) are available.
- **No fallback configuration values.** Per the project rule, missing
  configuration must raise an error — not be substituted with a
  default. The appearance setting is a UI preference (not a
  configuration setting) and DOES have a documented default
  (`system`); this is allowed because the default is part of the
  product's specified UX, not a silent substitution for a missing
  required configuration.
- **No changes to the env-var resolution chain.** The four-tier
  precedence chain (`shell env → ~/.tool-agents/macrec-ui/.env →
  local .env → CLI flags`) and `EnvFileStore.read(toolName:key:)`
  semantics are unchanged. The API-key chip surfaces resolved state
  but does not change resolution.
- **No version-control operations** during implementation unless the
  user explicitly asks.
- **Test conventions.** New tests live under `Tests/MacrecUITests/`
  and any ad-hoc verification scripts under `test_scripts/`.
- **Plan, design, and functional-requirement docs** must be updated
  per the project's Structure & Conventions:
  - new plan file at
    `docs/design/plan-xxx-ui-redesign-and-theming.md`
    (next sequential `xxx`);
  - `docs/design/project-design.md` updated with a new section
    describing the redesigned popover composition, the theming
    architecture, and the appearance-switcher persistence;
  - `docs/design/project-functions.md` updated with the new
    functional requirements introduced here (appearance switcher,
    persistence, theme variants).
- **Tools entry.** `macrec-ui` already has a Tools entry in
  `CLAUDE.md` and a doc at `docs/tools/macrec-ui.md`. Update that doc
  with one paragraph describing the new appearance switcher.

## Acceptance Criteria

A reviewer verifies the work by checking that **all** of the following
are true:

1. **Visual parity (light).** Side-by-side comparison of the running
   popover in light mode against `popover-redesign.html` Variant A
   shows: filename-as-title header, "Save to" folder chip in the
   metadata strip, single consolidated permissions pill, two
   inset-grouped sections labeled "General" and "Live Transcription",
   right-aligned `NSPopUpButton`-style pickers with chevrons, hairline
   row dividers, NSSwitch-style toggle in the "Live Transcription"
   section header, API-key chip + `Replace…` button (no `Save` /
   `Clear` pair), and red-gradient `Start Recording` button in the
   footer.
2. **Visual parity (dark).** Same comparison against Variant B with
   the appearance switcher set to Dark.
3. **Vertical elasticity preserved.** Adding rows to the "Live
   Transcription" section (e.g. opening the language picker reveals
   the secondary-language slot) and starting / stopping a recording
   that toggles the live transcript panel produces a popover whose
   height grows and shrinks; it does not stay at a fixed height and
   does not produce empty padding (the `LiveTranscriptPanel` already
   solved this; the redesign must not regress it).
4. **Live transcript streaming preserved.** Starting a recording with
   transcription enabled produces streaming text in the panel with
   the same auto-scroll, language-chip, partial/settled italic
   treatment, segment-cap, and clear-transcript button as today.
5. **Appearance switcher present and functional.** The popover header
   strip contains a 3-way switcher (Follow System / Light / Dark).
   Selecting Light forces light rendering even if the system is in
   dark; selecting Dark forces dark rendering; selecting Follow
   System matches the system appearance and updates live when the
   system appearance changes.
6. **Appearance choice persists.** Quitting macrec-ui and relaunching
   it restores the user's last appearance choice. The choice is
   readable via `defaults read com.local.macrec-ui
   com.macrec.ui.appearance`.
7. **All existing tests pass.** `swift test` runs green for
   `MacrecCoreTests`, `MacrecUIKitTests`, and `MacrecUITests`,
   including the existing `LiveTranscriptPanelTests`.
8. **New tests added** under `Tests/MacrecUITests/`:
   - a test that verifies the `@AppStorage("com.macrec.ui.appearance")`
     binding round-trips `system` / `light` / `dark`;
   - a test that verifies the root scene's `.preferredColorScheme`
     reflects the persisted value (using a helper that reads the
     resolved `ColorScheme?` for each stored value);
   - a test that verifies the appearance switcher control writes the
     expected raw value when each option is selected.
9. **Builds cleanly.** `swift build -c debug` and
   `swift build -c release` complete with zero errors and no NEW
   warnings under the Swift 6 / macOS 26 toolchain.
10. **Docs updated.** A new `docs/design/plan-xxx-ui-redesign-and-theming.md`
    exists; `docs/design/project-design.md` has a new section covering
    the redesign and the theming/persistence architecture;
    `docs/design/project-functions.md` lists the new appearance-switch
    functional requirement and the persisted key; `docs/tools/macrec-ui.md`
    mentions the appearance switcher.
11. **No regressions to current `@AppStorage` keys.** Output folder,
    basename, format, layout, mic UID, transcription provider /
    source / format / language hints are still read by
    `ControlBar.startTapped()` (or its successor) at Start time and
    composed into `RecordingOptions` as today (the keys named in
    `ControlBar.swift` lines 47–72 are unchanged).
12. **No regression to env-var resolution.** API-key resolution still
    flows through `EnvFileStore` / `ProcessInfo` per the documented
    four-tier precedence chain; the redesigned API-key sub-row only
    *displays* state (present / absent / expiry) and triggers the
    `Replace…` flow.

## Assumptions

The following decisions were made during refinement without explicit
user confirmation. They are flagged here so they can be challenged
before implementation begins.

- **A-01 — Three appearance options.** The switcher offers Follow
  System / Light / Dark (three options), matching macOS HIG. *Basis:*
  standard macOS appearance UX; user prompt suggested this as the
  default.
- **A-02 — Switcher placement.** The switcher lives in the popover
  header metadata strip (compact icon menu or 3-segment control), and
  is also mirrored in the existing Settings dialog if one exists.
  *Basis:* user prompt's stated default.
- **A-03 — Application scope.** The chosen appearance applies to the
  entire macrec-ui app via `.preferredColorScheme` on the root scene
  (not just the popover). *Basis:* user prompt's stated default and
  consistency with macOS app conventions.
- **A-04 — Persistence key.** `com.macrec.ui.appearance` with raw
  values `system` / `light` / `dark`, stored in the macrec-ui
  UserDefaults suite via `@AppStorage`. Default value `system`.
  *Basis:* user prompt's stated default and consistency with the
  existing `com.macrec.ui.*` key namespace used by other persisted UI
  state.
- **A-05 — Transcription panel placement.** The live transcript panel
  remains *inside* the popover, expanding it vertically as today (not
  a separate window). *Basis:* user prompt's stated default and
  current behavior.
- **A-06 — Brand-color file location.** Non-semantic brand colors
  (e.g. the record-button red gradient) live in
  `Sources/macrec-ui/Theme/Palette.swift`. *Basis:* convention; keeps
  the palette discoverable in one place.
- **A-07 — Folder row consolidation.** The folder picker is surfaced
  as the "Save to" chip in the metadata strip and is therefore removed
  from the "General" section body to avoid duplication. *Basis:*
  mockup shows the folder only in the metadata strip.
- **A-08 — Permissions pill collapse rule.** The single
  "All permissions granted" pill is shown when every required
  permission is granted; if one or more are missing, the pill becomes
  a "Permissions needed" affordance that expands the existing
  per-permission detail rows. *Basis:* the mockup shows only the
  collapsed form; the expanded form is needed because the current
  `PermissionStatusView` exposes per-permission CTAs.

## Open Questions

These could not be resolved during refinement and downstream work
should surface them at the start of planning:

- **Q-01.** Does a Settings dialog currently exist in macrec-ui? If
  yes, does it already have a section where the appearance switcher
  should be mirrored, or should a new "Appearance" section be added
  there?
- **Q-02.** Should the API-key expiration-date chip read its date from
  a new persisted field per provider (e.g.
  `com.macrec.ui.apiKeyExpiry.<provider>`), and if so, how is that
  date entered — at the same time the user types/pastes the key in
  the `Replace…` flow? The mockup shows the chip but the data source
  is not specified.
- **Q-03.** When the "Live Transcription" header NSSwitch is toggled
  off, should the engine selection be retained (so re-toggling on
  restores the last engine) or reset to `none`? Default behavior must
  be chosen at planning time.

## Original Request

```
Align the UI of the macrec-ui SwiftUI menu-bar app to the proposed design captured in:
- /Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/design/mockups/popover-redesign.html
- /Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/design/mockups/popover-redesign.png

Constraints from the user (must be preserved from current implementation):
1. Keep the vertically expandable popover approach from the current implementation (the popover currently grows / shrinks based on content; this elasticity must remain — don't switch to a fixed-height window).
2. Keep the transcription area where the live transcript text streams in during transcription (the "live transcript panel" feature must remain functional and visible during recording).

New requirements:
3. Implement BOTH light and dark themes that match the two variants in the mockup (popover-redesign.html shows them side by side).
4. Add a UI control that lets the user switch between Light / Dark (and ideally also "Follow System") appearance modes.
5. Persist the user's last appearance choice across app launches (likely via UserDefaults / @AppStorage in the macrec-ui bundle).
```
