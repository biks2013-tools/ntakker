---
language: swift
framework: swiftui
package_manager: swift-package-manager
build_command: swift build
test_command: swift test
lint_command: null
entry_points:
  - Sources/macrec-ui/MacrecUIApp.swift
  - Sources/macrec/main.swift
last_scanned_commit: 8230f65438843587a9a10de19f8c7500022d1f4c
scanned_for_request: refined-request-ui-redesign.md
scanned_at: "2026-04-30T20:45:00Z"
---

# Codebase Scan — macrec-ui Popover Redesign + Light/Dark Theming

## 1. Project Overview

`macrec` is a Swift / SwiftUI macOS-only audio-recording toolchain. The package
(`Package.swift`, swift-tools-version 6.2) targets macOS 26 (Tahoe) and declares
four products: the `macrec` CLI executable, the `macrec-ui` menu-bar-accessory
executable, and the `MacrecCore` / `MacrecUIKit` library targets that both
consume. Swift 6 language mode is pinned to `.v5` package-wide to allow
incremental migration. No xcassets, no SwiftLint, no SwiftFormat — the project
uses no automated linting toolchain.

The UI-redesign request touches `Sources/macrec-ui/` (the SwiftUI app shell and
all popover views) and `Sources/MacrecUIKit/RecordingController.swift` (boundary
— read-only from the view layer). All audio-engine and transcription-pipeline
logic (`Sources/MacrecCore/`) is fully out of scope.

---

## 2. Module Map

| Path | Purpose | Representative symbols |
|---|---|---|
| `Sources/macrec-ui/` | SwiftUI menu-bar app executable. `@main` entry, AppDelegate/NSPopover shell, all popover and settings views. | `MacrecUIApp`, `AppDelegate`, `RootView` |
| `Sources/macrec-ui/Views/` | Flat collection of popover sub-views (leaf + composite). | `ControlBar`, `FilenameField`, `LevelMeterView` |
| `Sources/macrec-ui/Views/Transcription/` | All live-transcription UI widgets. | `LiveTranscriptPanel`, `TranscriptionPicker`, `PrivacyDisclosureSheet` |
| `Sources/macrec-ui/Settings/` | SwiftUI `Settings { }` scene root and sidebar navigation. | `SettingsRootView`, `SettingsCategory` |
| `Sources/macrec-ui/Settings/Sections/` | Per-provider settings detail views (cloud API-key management). | `GeminiSettingsView`, `AzureBatchSettingsView`, `ElevenLabsSettingsView` |
| `Sources/MacrecUIKit/` | Domain layer: `@MainActor @Observable` controller, level meter, session coordinator, filename generator. Testable without AppKit. | `RecordingController`, `SessionCoordinator`, `LevelMeterPublisher` |
| `Sources/MacrecCore/` | Recording engine, transcription pipeline, configuration resolution. Out of scope for the redesign. | `RecordingSession`, `TranscriptionManager`, `ConfigResolver` |
| `Sources/macrec/` | CLI entry point (`ArgumentParser`). Out of scope. | `StartCommand`, `StopCommand` |
| `Tests/MacrecUITests/` | Swift Testing tests targeting `MacrecUIKit`. | `RecordingControllerTests`, `LiveTranscriptPanelTests` |
| `Tests/MacrecCoreTests/` | Unit + integration tests for the engine layer. | `RecordingSessionTests`, `SonioxStreamingTranscriptionProviderTests` |

---

## 3. Conventions

- **File header style.** Every source file opens with a structured block comment:
  `// <target>/<file>.swift — see project-design.md §<section>, plan-<N>-*.md §<phase> (<FR-NN>)`.
  Cross-references to design docs and functional requirements are mandatory.
  Observed in `Sources/macrec-ui/Views/ControlBar.swift:1` and every other
  popover view.

- **Import ordering.** Alphabetical, Foundation first, then third-party (`Logging`),
  then internal modules (`MacrecCore`, `MacrecUIKit`), then `SwiftUI` last when
  present. Observed in `Sources/macrec-ui/Views/ControlBar.swift:34-38` and
  `Sources/macrec-ui/Views/PermissionStatusView.swift:1-5`.

- **`// MARK: -` sections.** Used consistently to separate logical groups within
  a file: `// MARK: - Buttons`, `// MARK: - Visibility`, `// MARK: - Start composition`
  in `ControlBar.swift:103, 155, 193`. All new files should follow this pattern.

- **No `#Preview` blocks.** SwiftUI preview macros are intentionally omitted
  throughout the project because the build pipeline uses `swift build` (CLI
  toolchain), not Xcode. Documented in `Sources/macrec-ui/Views/FilenameField.swift:62-67`.
  New view files must carry the same comment explaining the omission.

- **`String(localized:)` for all user-visible text.** Every label, placeholder,
  help string, and button title is wrapped. Observed in `ControlBar.swift:109`,
  `FilenameField.swift:57`, `PermissionStatusView.swift:61`. The redesign must
  continue this pattern.

- **Error handling.** No `try?` or `catch` on configuration. Missing config
  propagates as `MacrecError` thrown by the engine before the session starts,
  surfaced in `RecordingController.latestError`, rendered by `ErrorBanner`.
  Observed in `ControlBar.swift:277-288` (API-key resolution) and design §15.10.

---

## 4. Integration Points

### 4a. Popover Composition Root — `RootView.swift`

**File:** `Sources/macrec-ui/RootView.swift`
**Role:** Top-level SwiftUI view hosted by `NSHostingController` inside
`PopoverController`. Composes the entire popover surface in a three-band
`VStack` (top pinned, middle scrollable, bottom pinned).

**Current layout (top → bottom):**
```
VStack(spacing: 0):
  Top band:  SettingsLink (gear icon) | ErrorBanner | PermissionStatusView(.onlyWhenIssues)
  Divider
  Middle:    FilenameField
             DisclosureGroup "Recording settings" → HStack[FormatPicker, LayoutPicker] + FolderPicker
             MicrophonePicker
             DisclosureGroup "Live transcription" → TranscriptionPicker + [Source/Format/Language pickers] + SettingsLink
             if showsLiveStats: Divider + LevelMeterView + ElapsedTimeView
  LiveTranscriptPanel  (.frame(maxHeight: .infinity) — the flexible band)
  TranscriptionMetricsView
  Divider
  Bottom:    ControlBar + (if segments) Divider + SavedToDisclosure
  ResizeHandle
```

**`@AppStorage` keys owned by `RootView`:**

| Key | Type | Default | Purpose |
|---|---|---|---|
| `"com.macrec.ui.transcribeProvider"` | `String` | `"apple"` | Mirrors picker; drives privacy gate |
| `PrivacyDisclosureViewModel.userDefaultsKey` | `Bool` | `false` | Legacy Gemini acknowledgement (back-compat) |
| `"com.macrec.ui.transcriptionExpanded"` | `Bool` | `false` | Live transcription group open/closed |
| `"com.macrec.ui.recordingSettingsExpanded"` | `Bool` | `false` | Recording settings group open/closed |
| `"com.macrec.ui.popoverHeight"` (= `RootView.popoverHeightKey`) | `Double` | `600` | Persisted popover height for `ResizeHandle` |

**Redesign action:** This file is the primary composition site. The existing
three-band structure must be rearchitected into the mockup layout (header strip,
two inset-grouped `Form` sections, transcript panel, footer button cluster).
The `DisclosureGroup` containers are replaced by `.formStyle(.grouped)` sections.

---

### 4b. Popover Sub-Views

#### `Views/ErrorBanner.swift`
Self-conditional red banner; returns `EmptyView` when `recordingController.latestError == nil`.
Owns no state. Composites: none. Leaf component.
**Redesign:** Preserve verbatim; the container styling (corner-radius, red fill) is
internal to the view and not affected by the theme system.

#### `Views/PermissionStatusView.swift`
Two-row TCC-state indicator, polls at 2 Hz. Accepts a `Visibility` enum:
`.always` (used in Settings) or `.onlyWhenIssues` (used in popover — collapses
when both permissions are `.authorized`). Leaf with embedded polling task.
**Redesign:** The `.onlyWhenIssues` mode already collapses to nothing when
permissions are clean. The metadata-strip "All permissions granted" pill
(requirement §2) is a new wrapper view; `PermissionStatusView` becomes the
"expanded" form revealed by the pill when issues exist.

#### `Views/FilenameField.swift`
`TextField` bound to `@AppStorage("com.macrec.ui.basename")` (default `""`).
Locked when `state != .idle`. Leaf.
**Redesign:** Visual treatment changes (larger, title-weight per mockup header).
`@AppStorage` key unchanged.

#### `Views/FormatPicker.swift`
`Picker(.menu)` over `m4a / wav / caf`, `@AppStorage("com.macrec.ui.format")`.
Disabled when locked. Leaf.
**Redesign:** Moves into the "General" `Form.Section`. `.pickerStyle(.menu)` preserved.

#### `Views/LayoutPicker.swift`
`Picker(.menu)` over `mixed / split / stereo-split`, `@AppStorage("com.macrec.ui.layout")`.
Leaf. Same locking pattern.
**Redesign:** Moves into "General" section alongside `FormatPicker`.

#### `Views/FolderPicker.swift`
`Button` → modal `NSOpenPanel`. Swaps popover behavior to `.semitransient` during
the panel via `@Environment(\.popoverBehavior)`. `@AppStorage("com.macrec.ui.outputFolder")`.
`DefaultRecordingFolder.resolve()` bootstraps `~/Recordings/` on first launch.
**Redesign:** The folder row is consolidated into the metadata strip as a "Save to"
chip (requirement A-07). `FolderPicker` body is refactored into a chip-style button.
The `.semitransient` popover-swap logic must be preserved.

#### `Views/MicrophonePicker.swift`
`Picker(.menu)` over discovered `AVCaptureDevice` list.
`@AppStorage("com.macrec.ui.micUID")` (default `""`).
**Redesign:** Moves into "General" section.

#### `Views/LevelMeterView.swift`
Two `GeometryReader`-based peak/RMS bars, 30 Hz animated. No `@AppStorage`.
Shown only while `showsLiveStats`. Leaf.
**Redesign:** Visual styling of bars may be updated to use new theme tokens.

#### `Views/ElapsedTimeView.swift`
`TimelineView(.periodic(by: 1))` monospaced clock. No `@AppStorage`. Leaf.
**Redesign:** No structural change; visual font weight may adapt.

#### `Views/SavedToDisclosure.swift`
`DisclosureGroup` listing `completedSegments` URLs. Self-hides when empty.
`@State var expanded: Bool = true`. Leaf.
**Redesign:** Visual styling to match inset-group aesthetic.

#### `Views/ResizeHandle.swift`
12pt hit-area drag strip at the bottom. Binds to `height: Binding<Double>` wired
to `@AppStorage("com.macrec.ui.popoverHeight")` in `RootView`.
`minHeight = 360`, `maxHeight = 1100`. Changes `NSCursor.resizeUpDown` on hover.
**Redesign:** Preserve verbatim. May be styled to match new bottom edge aesthetic.

#### `Views/Transcription/LiveTranscriptPanel.swift`
The streaming transcript surface. Renders `recordingController.transcriptSegments`
with auto-scroll, language-chip (BCP-47 first-two-letters uppercased), settled/partial
italic treatment, "Clear transcript" button, and `TranscriptionStatusBadge` header.
Uses `Color(nsColor: .windowBackgroundColor).opacity(0.5)` as scroll background.
Claims `.frame(maxHeight: .infinity)` from the parent.
**Redesign:** Container restyled to inset-group aesthetic; streaming behavior
preserved verbatim (requirement §11).

#### `Views/Transcription/TranscriptionPicker.swift`
`Picker(.menu)` over 8 provider options + "None". `@AppStorage("com.macrec.ui.transcribeProvider")`.
Exposes `requiredKeyEnvVar(for:)` and `missingKeyTooltip(for:)` as static helpers
(used by tests). Red-dot `missingKey` badge when API key is absent. Leaf.
**Redesign:** Moves into "Live Transcription" section. The NSSwitch toggle
(requirement §6) is a new control that wraps this picker.

#### `Views/Transcription/TranscriptionSourcePicker.swift`
`Picker(.menu)` over `system / mic / mixed / both`. `@AppStorage("com.macrec.ui.transcribeSource")`.
Leaf. Shown when `transcribeProviderRaw != "none"`.
**Redesign:** Moves into "Live Transcription" section.

#### `Views/Transcription/TranscriptionFormatPicker.swift`
`Picker(.menu)` over `jsonl / srt / vtt / txt`. `@AppStorage("com.macrec.ui.transcriptFormat")`.
Leaf. Shown when provider is non-none.
**Redesign:** Moves into "Live Transcription" section.

#### `Views/Transcription/TranscriptionLanguagePicker.swift`
Primary + secondary BCP-47 language pickers. `@AppStorage("com.macrec.ui.transcribeLanguage")` +
`@AppStorage("com.macrec.ui.transcribeLanguage2")`. Also reads
`@AppStorage("com.macrec.ui.transcribeProvider")` to choose picker label.
Leaf with two slots.
**Redesign:** Moves into "Live Transcription" section.

#### `Views/Transcription/SonioxKeyField.swift` / `GeminiKeyField.swift` / `ProviderKeyField.swift`
Key-entry fields. These were migrated OUT of the popover to the Settings dialog
in the plan-007 follow-up (2026-04-30 commit). They still exist as source files
but their usage in `RootView` was replaced by a `SettingsLink` pointer.
**Redesign:** The API-key chip + `Replace…` button (requirement §7) is a new
inline component; these files supply the underlying `EnvFileStore` persistence
but the popover no longer embeds the full field editors.

#### `Views/Transcription/TranscriptionStatusBadge.swift`
Compact green "Active" / red "Error" pill. Reads
`recordingController.transcriptionStatus`. Leaf, no state.
**Redesign:** Preserve; restyled to match new badge shape if needed.

#### `Views/Transcription/TranscriptionMetricsView.swift`
Footer cost/latency summary (billable seconds, RTT ms, indicative $). Shown when
transcription has produced any state. Leaf.
**Redesign:** Styled to match the inset-group footer area.

#### `Views/Transcription/PrivacyDisclosureSheet.swift`
Modal sheet + `PrivacyDisclosureViewModel` (per-provider acknowledgement flags).
`RootView` presents it via `.sheet(isPresented:)` when user first selects a cloud provider.
**Redesign:** Preserve verbatim (behavior not in scope). Container dimensions fixed at `width: 460`.

---

### 4c. `ControlBar.swift` — Action Layer

**File:** `Sources/macrec-ui/Views/ControlBar.swift`
**Role:** Lifecycle button bar (Start / Pause / Resume / Stop / Split). The
*only* site that assembles `RecordingOptions` from persisted UI state and
forwards to `RecordingController`.

**`@AppStorage` keys read by `ControlBar.startTapped()`** (lines 47–72):

| Key | Type | Default |
|---|---|---|
| `"com.macrec.ui.outputFolder"` | `String` | `""` |
| `"com.macrec.ui.basename"` | `String` | `""` |
| `"com.macrec.ui.format"` | `String` | `"m4a"` |
| `"com.macrec.ui.layout"` | `String` | `"mixed"` |
| `"com.macrec.ui.micUID"` | `String` | `""` |
| `"com.macrec.ui.transcribeProvider"` | `String` | `"apple"` |
| `"com.macrec.ui.transcribeSource"` | `String` | `"mixed"` |
| `"com.macrec.ui.transcriptFormat"` | `String` | `"jsonl"` |
| `"com.macrec.ui.transcribeLanguage"` | `String` | `""` |
| `"com.macrec.ui.transcribeLanguage2"` | `String` | `""` |

**Redesign:** The Start button becomes the red-gradient footer button (requirement
§8). The button cluster (Pause / Stop / Split) moves into the footer slot when
recording is active. The button's visibility matrix (lines 9–18 of the file
header comment, `showsStart` / `showsPause` / `showsResume` / `showsStop` /
`showsSplit`) is preserved exactly. **The ten `@AppStorage` keys above must not
be renamed or removed** (requirement §12 / acceptance criterion 11).

---

### 4d. Settings Dialog — Q-01 Answer

**Q-01 answer: YES, a Settings dialog exists.**

**File:** `Sources/macrec-ui/MacrecUIApp.swift` — `Settings { SettingsRootView() }` scene (line 48).
**Root view:** `Sources/macrec-ui/Settings/SettingsRootView.swift` — sidebar-style
`NavigationSplitView` with categories enumerated in `SettingsCategory`.

**Current sidebar categories (in order):**
1. Permissions — `PermissionsSettingsView`
2. Gemini — `GeminiSettingsView`
3. Soniox — `SonioxSettingsView`
4. Azure OpenAI — `AzureBatchSettingsView`
5. Azure OpenAI Realtime — `AzureRealtimeSettingsView`
6. ElevenLabs — `ElevenLabsSettingsView`
7. Privacy — `PrivacySettingsView`
8. About — `AboutSettingsView`

**No existing "General" or "Appearance" tab.** The redesign must add a new
`SettingsCategory.general` (or `.appearance`) case and a corresponding
`GeneralSettingsView` (or `AppearanceSettingsView`) that surfaces the appearance
switcher. The `SettingsRootView.detailView(for:)` switch must grow a new case.

**`@AppStorage` key already used in `SettingsRootView`:**

| Key | Type | Default | Purpose |
|---|---|---|---|
| `"com.macrec.ui.settings.selectedCategory"` | `String` | `"azure"` | Last-selected sidebar item |

**New key required by the redesign:**

| Key | Type | Default | Purpose |
|---|---|---|---|
| `"com.macrec.ui.appearance"` | `String` | `"system"` | Follow System / Light / Dark |

This key does NOT collide with any existing key. Per requirement A-04, allowed
raw values are `"system"` / `"light"` / `"dark"`.

---

### 4e. App Entry / Scene Root — `.preferredColorScheme` Hook

**File:** `Sources/macrec-ui/MacrecUIApp.swift`

```swift
@main
struct MacrecUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}
```

The `Settings` scene is the only SwiftUI scene. `.preferredColorScheme(_:)`
must be applied **on the `Settings { … }` scene** or on the `NSHostingController`
that hosts `RootView`. Because `MacrecUIApp.body` returns a `Scene`, the modifier
chain is:

```swift
Settings {
    SettingsRootView()
}
.preferredColorScheme(resolvedColorScheme)   // applied to the scene
```

However, `RootView` is hosted by `PopoverController`'s `NSHostingController`, which
is NOT part of the SwiftUI `App.body` scene graph. To propagate the chosen scheme
to the popover as well, the resolved `ColorScheme?` value must be stored in a
place `PopoverController` can observe (e.g. `@AppStorage` via
`NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification …)`,
the same mechanism already used for `popoverHeight`) and applied to the hosting
controller's view via `.preferredColorScheme` on the `AnyView` it wraps.

**Redesign action:** Add `@AppStorage("com.macrec.ui.appearance")` to
`MacrecUIApp` and compute a `ColorScheme?` from it (`nil` for `"system"`, `.light`
for `"light"`, `.dark` for `"dark"`). Apply `.preferredColorScheme` to the
`Settings` scene in `MacrecUIApp.body`. In `PopoverController.init`, also apply
it to the `AnyView` before wrapping in `NSHostingController`, and add an
observer (identical to `heightObserver`) to re-apply it when the preference
changes.

---

### 4f. All `@AppStorage` Keys — Complete Inventory

| Key | Type | Default | Owner | Redesign |
|---|---|---|---|---|
| `"com.macrec.ui.outputFolder"` | `String` | `""` | `ControlBar`, `FolderPicker` | Unchanged |
| `"com.macrec.ui.basename"` | `String` | `""` | `ControlBar`, `FilenameField` | Unchanged |
| `"com.macrec.ui.format"` | `String` | `"m4a"` | `ControlBar`, `FormatPicker` | Unchanged |
| `"com.macrec.ui.layout"` | `String` | `"mixed"` | `ControlBar`, `LayoutPicker` | Unchanged |
| `"com.macrec.ui.micUID"` | `String` | `""` | `ControlBar`, `MicrophonePicker` | Unchanged |
| `"com.macrec.ui.transcribeProvider"` | `String` | `"apple"` | `ControlBar`, `TranscriptionPicker`, `RootView`, `TranscriptionLanguagePicker` | Unchanged |
| `"com.macrec.ui.transcribeSource"` | `String` | `"mixed"` | `ControlBar`, `TranscriptionSourcePicker` | Unchanged |
| `"com.macrec.ui.transcriptFormat"` | `String` | `"jsonl"` | `ControlBar`, `TranscriptionFormatPicker` | Unchanged |
| `"com.macrec.ui.transcribeLanguage"` | `String` | `""` | `ControlBar`, `TranscriptionLanguagePicker` | Unchanged |
| `"com.macrec.ui.transcribeLanguage2"` | `String` | `""` | `ControlBar`, `TranscriptionLanguagePicker` | Unchanged |
| `"com.macrec.ui.transcriptionExpanded"` | `Bool` | `false` | `RootView` | Unchanged or adapted to Form-section open state |
| `"com.macrec.ui.recordingSettingsExpanded"` | `Bool` | `false` | `RootView` | Unchanged or adapted |
| `RootView.popoverHeightKey` = `"com.macrec.ui.popoverHeight"` | `Double` | `600` | `RootView`, `PopoverController` | Unchanged |
| `"com.macrec.ui.settings.selectedCategory"` | `String` | `"azure"` | `SettingsRootView` | Unchanged |
| `PrivacyDisclosureViewModel.userDefaultsKey` = `"com.local.macrec-ui.transcription.privacyDisclosureAcknowledged"` | `Bool` | `false` | `RootView` (legacy back-compat) | Unchanged |
| **`"com.macrec.ui.appearance"` (NEW)** | `String` | `"system"` | `MacrecUIApp`, appearance switcher control | **Added by redesign** |

No existing key must be renamed. The new key `"com.macrec.ui.appearance"` has no
collision.

---

### 4g. Color / Theme Utilities — Existing State

**No project-level color tokens, `Color` extensions, custom palettes, or `.xcassets`
exist in `Sources/macrec-ui/`.** All color references in the current codebase are
raw SwiftUI system references:

- `Color.red.opacity(0.92)` — `ErrorBanner.swift:109`
- `Color.secondary.opacity(0.18)` — `LevelMeterView.swift:58`
- `Color.accentColor.opacity(0.7)` — `LevelMeterView.swift:62`
- `Color(nsColor: .windowBackgroundColor).opacity(0.5)` — `LiveTranscriptPanel.swift:112`
- `Color.secondary.opacity(0.35)` — `ResizeHandle.swift:44-45`

**What must be created for the redesign:**

The spec calls for a new file `Sources/macrec-ui/Theme/Palette.swift` (requirement A-06)
containing:

1. **Brand colors** — the record-button red gradient (light and dark variants, as
   `ShapeStyle` or `LinearGradient` values).
2. **Semantic tokens** — equivalents for the CSS custom properties in the mockup
   (`--accent`, `--separator`, `--group-bg`, etc.) expressed as computed `Color`
   properties or static `ShapeStyle` values that adapt automatically when
   `.preferredColorScheme` is applied (prefer `Color(nsColor: .controlBackgroundColor)`
   and system `Material` values rather than hard-coded hex, per requirement §13).

**No `*.xcassets` are needed** for this scope — `Color(nsColor:)` and system
`Material` values adapt to light/dark automatically without asset catalogs.

---

### 4h. Resizable Popover Plumbing

**Vertical elasticity is achieved through three cooperating mechanisms:**

1. **`RootView.swift` — `@AppStorage` + `.frame(height:)`** (lines 84-85, 311-314):
   ```swift
   @AppStorage(RootView.popoverHeightKey) private var popoverHeight: Double = 600
   …
   .frame(
       height: min(max(popoverHeight, ResizeHandle.minHeight), ResizeHandle.maxHeight),
       alignment: .top
   )
   ```
   The outer `.frame` pins the SwiftUI layout to the persisted height. `alignment: .top`
   prevents SwiftUI from centering content inside the frame when content is shorter.

2. **`ResizeHandle.swift`** — `DragGesture` updates the `height` binding on drag.
   `minHeight = 360`, `maxHeight = 1100`. Writes flow into `@AppStorage` via the binding.

3. **`PopoverController.swift`** — `NotificationCenter` observer on
   `UserDefaults.didChangeNotification` reads the new height and pushes it onto
   `NSPopover.contentSize` (lines 137-151). This is the AppKit bridge — SwiftUI's
   `@AppStorage` write fires the notification → the observer fires → `NSPopover`
   gets the new frame size.

4. **`LiveTranscriptPanel.swift` + `RootView.swift`** — The transcript panel carries
   `.frame(maxHeight: .infinity)` (applied by `RootView` at line 272). The controls
   band above it uses `.fixedSize(horizontal: false, vertical: true)` (line 260) to
   take only intrinsic height, leaving all remaining vertical space to the transcript.

**Redesign must preserve:** the `RootView.popoverHeightKey` constant, the `ResizeHandle`
binding contract, and `PopoverController`'s `heightObserver`. The three-band structure
(pinned top / flexible middle / pinned bottom) must be preserved — only the content
within each band changes.

---

### 4i. Test Layout

**Test runner:** `swift test`

**UI-relevant test target:** `MacrecUITests` (path `Tests/MacrecUITests/`), which
imports `MacrecUIKit` only — NOT `Sources/macrec-ui/` (the executable target is
untestable via SPM by design; logic is factored into the `MacrecUIKit` library).

**Existing UI test files:**

| File | Content |
|---|---|
| `Tests/MacrecUITests/Transcription/LiveTranscriptPanelTests.swift` | Panel auto-scroll, segment-cap, isSettled behavior — git status marks this file as modified |
| `Tests/MacrecUITests/Transcription/TranscriptionPickerTests.swift` | `requiredKeyEnvVar(for:)` + `missingKeyTooltip(for:)` static helpers |
| `Tests/MacrecUITests/Transcription/PrivacyDisclosureTests.swift` | `PrivacyDisclosureViewModel` round-trip, per-provider acknowledgement |
| `Tests/MacrecUITests/UIErrorPresenterTests.swift` | Error message formatting |
| `Tests/MacrecUITests/RecordingControllerTests.swift` | `RecordingController` state transitions |
| `Tests/MacrecUITests/SessionCoordinatorTests.swift` | Coordinator event forwarding |
| `Tests/MacrecUITests/SegmentNamerTests.swift` | Segment naming logic |
| `Tests/MacrecUITests/FilenameGeneratorTests.swift` | Filename generation |

**New tests for the redesign** (per acceptance criteria 8) must be placed under
`Tests/MacrecUITests/` and test `MacrecUIKit`-layer logic. The appearance
`@AppStorage` key round-trip and `ColorScheme?` resolution helper should be
implemented in a testable form in `MacrecUIKit` or as a pure-Swift helper
(`AppearanceMode` enum) importable from the test target.

**Note:** The `PrivacyDisclosureViewModel` (in `PrivacyDisclosureSheet.swift`) is
already structured as a `public final class` in the `macrec-ui` executable — it is
NOT in `MacrecUIKit`, which is why its tests reference it via `@testable import`
patterns. The appearance enum should follow the same pattern if it lives in
`macrec-ui`, or be moved to `MacrecUIKit` for cleaner test access.

---

### 4j. Bundle / Target Metadata

From `Package.swift`:

- `macrec-ui` bundle identifier: **`com.local.macrec-ui`** (embedded via
  `Resources/MacrecUI-Info.plist` linker flag). Confirmed: `LSUIElement = true`,
  no Dock icon.
- `macrec` CLI bundle identifier: **`com.local.macrec`** (separate plist — TCC
  grants do not collide per R-23).
- **No explicit `UserDefaults` suite name is configured.** All `@AppStorage` writes
  go to `UserDefaults.standard`, which for the executable is keyed to the bundle
  identifier `com.local.macrec-ui`. The `defaults read com.local.macrec-ui
  com.macrec.ui.appearance` command in acceptance criterion 6 will work correctly
  because `UserDefaults.standard` maps to the bundle-id domain for executables.
- Swift language mode: `.v5` (package-wide), allowing gradual migration to Swift 6.

---

### 4k. Out-of-Scope Modules

The following modules are explicitly NOT touched by the UI-redesign:

- **`Sources/MacrecCore/`** — recording engine, transcription pipeline, `RecordingOptions`,
  `ConfigResolver`, `EnvFileStore`. The API-key chip in the redesign only *reads*
  state from `RecordingController` and invokes the existing `ControlBar.resolvedEnvValue(_:)`
  helper; `EnvFileStore` internals are unchanged.
- **`Sources/macrec/`** — CLI entry point; zero overlap.
- **`Tests/MacrecCoreTests/`** — engine tests; must remain green but are not modified.
- **`Sources/MacrecUIKit/RecordingController.swift`** — boundary contract. The redesign
  reads these published properties but does not modify them:
  - `state: SessionState` — drives button-cluster visibility
  - `transcriptSegments: [TranscriptSegment]` — drives `LiveTranscriptPanel`
  - `transcriptionStatus: TranscriptionUIState` — drives `TranscriptionStatusBadge`
  - `transcriptionMissingKey: Bool` — drives API-key chip
  - `transcriptionMetrics: TranscriptionMetrics` — drives `TranscriptionMetricsView`
  - `latestError: MacrecError?` — drives `ErrorBanner`
  - `latestLevels: MergedLevelSample?` — drives `LevelMeterView`
  - `segmentElapsed: TimeInterval` — drives `ElapsedTimeView`
  - `completedSegments: [URL]` — drives `SavedToDisclosure`

### 4l. New Integration Points (not present today)

| Artifact | Landing location | Notes |
|---|---|---|
| `AppearanceMode` enum (`.system`, `.light`, `.dark`) | `Sources/macrec-ui/Theme/AppearanceMode.swift` or embedded in `Palette.swift` | Needs `rawValue: String` for `@AppStorage` round-trip |
| `Sources/macrec-ui/Theme/Palette.swift` | New file; `Theme/` subdirectory must be created | Brand colors + semantic tokens |
| Appearance switcher control | Embedded in the new header-strip view | 3-way `Picker` or segmented control using SF Symbols |
| `GeneralSettingsView` (or `AppearanceSettingsView`) | `Sources/macrec-ui/Settings/Sections/` | New file; mirrors appearance switcher |
| `SettingsCategory.general` case | `Sources/macrec-ui/Settings/SettingsRootView.swift` | New enum case + `detailView(for:)` branch |
| `@AppStorage("com.macrec.ui.appearance")` in `MacrecUIApp` | `Sources/macrec-ui/MacrecUIApp.swift` | Drives `.preferredColorScheme` on both the Settings scene and the `NSHostingController` |
| Appearance observer in `PopoverController` | `Sources/macrec-ui/PopoverController.swift` | Same `UserDefaults.didChangeNotification` pattern as `heightObserver` |
| New tests | `Tests/MacrecUITests/AppearanceModeTests.swift` | Round-trip, `ColorScheme?` resolution |

---

## 5. Notes

- **`LiveTranscriptPanelTests.swift` is modified** (per git status). Review before
  adding new tests to avoid conflicts. The file is the highest-risk existing test
  because the panel is directly in scope of the redesign's "preserve verbatim"
  requirement.

- **No lint toolchain.** There is no `.swiftlint.yml` or `.swiftformat` in the
  project root (only in `.build/` dependency checkouts). Code style must be
  enforced manually: the convention is exactly what is observed in the existing
  sources (no semicolons, 4-space indentation implied by the existing files,
  `// MARK: -` sections, alphabetical imports, `String(localized:)` everywhere).

- **`PrivacyDisclosureViewModel` lives in the executable target** (`macrec-ui`), not
  in `MacrecUIKit`. If the `AppearanceMode` enum needs test coverage and follows
  the same pattern, it must be declared `public` and the test target must use
  `@testable import` — or the enum should be relocated to `MacrecUIKit`.

- **The `DisclosureGroup` containers in `RootView`** drive two `@AppStorage` keys
  (`transcriptionExpanded`, `recordingSettingsExpanded`). If the redesign replaces
  `DisclosureGroup` with `Form.Section`, those keys either become unused or must
  be repurposed. The spec says "all current `@AppStorage` keys preserved" (requirement
  §12), which applies to the keys read at `start()` time; the two disclosure-state
  keys are UI-only. Clarify before implementation whether they should be removed,
  repurposed for the `Form` section state, or left as-is for back-compat.
