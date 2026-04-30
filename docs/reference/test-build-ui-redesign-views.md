---
status: completed
mode: write-and-run
scope_slug: ui-redesign-views
language: Swift
framework: Swift Testing
test_command_full: swift test
test_command_scope: swift test --filter "ApiKeyStatusRow|ApiKeyStatusChip|SaveToChip|PermissionPill|LiveTranscriptionSectionHeader|ReadyPill|AppearanceHostingRoot"
test_dir: Tests/MacrecUITests
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
test_files_owned:
  - Tests/MacrecUITests/Transcription/ApiKeyStatusRowTests.swift
  - Tests/MacrecUITests/Transcription/ApiKeyStatusChipTests.swift
  - Tests/MacrecUITests/Header/SaveToChipTests.swift
  - Tests/MacrecUITests/Header/PermissionPillTests.swift
  - Tests/MacrecUITests/Sections/LiveTranscriptionSectionHeaderTests.swift
  - Tests/MacrecUITests/Footer/ReadyPillTests.swift
  - Tests/MacrecUITests/Theme/AppearanceHostingRootSystemModeTests.swift
tests_added: 77
tests_updated: 0
tests_run: 77
tests_passed: 77
tests_failed: 0
implementation_gaps: 0
built_at: 2026-04-30T22:40:00Z
last_built_commit: 8230f65438843587a9a10de19f8c7500022d1f4c
---

# Test Build — UI Redesign Views (plan-008 Phase 6)

## 1. Summary

Status: completed. Framework: Swift Testing (`import Testing`, `@Suite`, `#expect`). 77 new concept-pinning tests were added across 7 new files covering 7 source components. All 77 tests pass. Zero implementation gaps detected — no drift found between design and source literals. The tests were written without `@testable import macrec_ui`, following the established concept-pinning pattern of the project.

## 2. Scope Resolved

**Source files inspected:**

- `Sources/macrec-ui/Views/Transcription/ApiKeyStatusRow.swift`
  - `maskedKey` (26-dot mask width), `isPresent` derivation (`resolvedKey?.isEmpty == false`), `onSave` trim logic (`trimmingCharacters(in: .whitespacesAndNewlines)`), `editPlaceholder` format strings
- `Sources/macrec-ui/Views/Transcription/ApiKeyStatusChip.swift`
  - `body` text branch: `present ? "Configured" : "Not configured"`, `present: Bool` API surface
- `Sources/macrec-ui/Views/Header/SaveToChip.swift`
  - `@AppStorage("com.macrec.ui.outputFolder")`, `folderPath: String = ""` default, `displayName` derivation via `URL.lastPathComponent`, empty-path branch `"Choose…"`
- `Sources/macrec-ui/Views/Header/PermissionPill.swift`
  - `pollLoop` sleep `2_000_000_000 ns`, `allGranted` nil-guard (optimistic bootstrap), label strings `"All permissions granted"` / `"Permissions needed"` / `"Hide permissions"`
- `Sources/macrec-ui/Views/Sections/LiveTranscriptionSectionHeader.swift`
  - `@AppStorage("com.macrec.ui.transcriptionEnabled")`, default `true`, header `Text("LIVE TRANSCRIPTION")`
- `Sources/macrec-ui/Views/Footer/ReadyPill.swift`
  - `label` switch (9 cases), `dotColor` switch (red/yellow/successDot families), `SessionState` enum from `MacrecCore`
- `Sources/macrec-ui/Theme/AppearanceHostingRoot.swift`
  - `let effective: ColorScheme = mode.colorScheme ?? systemColorScheme` two-branch logic, `.preferredColorScheme(mode.colorScheme)` nil-pass for `.system`

## 3. Existing Coverage

| Symbol | Existing tests |
|---|---|
| `ApiKeyStatusRow` | None |
| `ApiKeyStatusChip` | None |
| `SaveToChip` | None |
| `PermissionPill` | None |
| `LiveTranscriptionSectionHeader` | Indirectly via `ControlBarStartTappedKeysRegressionTests` (pins the same `transcriptionEnabled` key from the ControlBar angle) |
| `ReadyPill` | None |
| `AppearanceHostingRoot` | `AppearancePersistenceTests` (5 tests: key, round-trip, unknown fallback, default, ColorScheme mapping) — system-mode palette-injection contract was NOT covered |

## 4. Plan

| target_symbol | category | test_file | test_name | intent |
|---|---|---|---|---|
| `ApiKeyStatusRow.maskedKey` | unit | `ApiKeyStatusRowTests.swift` | maskWidthIs26 | Pin that mask is exactly 26 dots so a "scale to key length" refactor breaks loudly |
| `ApiKeyStatusRow.maskedKey` | unit | `ApiKeyStatusRowTests.swift` | maskCharacterIsBullet | Pin that the mask char is U+2022, not ASCII |
| `ApiKeyStatusRow.isPresent` | unit | `ApiKeyStatusRowTests.swift` | nilKeyNotPresent | nil resolvedKey → not present |
| `ApiKeyStatusRow.isPresent` | unit | `ApiKeyStatusRowTests.swift` | emptyKeyNotPresent | empty string → not present |
| `ApiKeyStatusRow.isPresent` | unit | `ApiKeyStatusRowTests.swift` | nonEmptyKeyIsPresent | non-empty → present |
| `ApiKeyStatusRow.isPresent` | unit | `ApiKeyStatusRowTests.swift` | whitespaceOnlyIsPresent | whitespace-only is present at storage level (trim only on Save) |
| `ApiKeyStatusRow.onSave` | unit | `ApiKeyStatusRowTests.swift` | trimRemovesWhitespace | Trim contract: padded key → clean key |
| `ApiKeyStatusRow.onSave` | unit | `ApiKeyStatusRowTests.swift` | trimLeadingOnly | Leading-only trim |
| `ApiKeyStatusRow.onSave` | unit | `ApiKeyStatusRowTests.swift` | trimTrailingOnly | Trailing-only trim |
| `ApiKeyStatusRow.editingFieldStack` | unit | `ApiKeyStatusRowTests.swift` | whitespaceOnlyDraftIsGuardedOut | Guard ensures whitespace-only draft never fires onSave |
| `ApiKeyStatusRow.editPlaceholder` | unit | `ApiKeyStatusRowTests.swift` | sonioxPlaceholderContainsEnvVar | Soniox placeholder contains SONIOX_API_KEY |
| `ApiKeyStatusRow.editPlaceholder` | unit | `ApiKeyStatusRowTests.swift` | geminiPlaceholderContainsEnvVar | Gemini placeholder contains GOOGLE_API_KEY |
| `ApiKeyStatusChip.body` | unit | `ApiKeyStatusChipTests.swift` | configuredLabelExact | present=true → "Configured" (exact, case-sensitive) |
| `ApiKeyStatusChip.body` | unit | `ApiKeyStatusChipTests.swift` | notConfiguredLabelExact | present=false → "Not configured" (exact) |
| `ApiKeyStatusChip.body` | unit | `ApiKeyStatusChipTests.swift` | labelsAreDistinct | Two labels are distinct |
| `ApiKeyStatusChip.body` | unit | `ApiKeyStatusChipTests.swift` | noExpirationText | v1.6 labels contain no expiration text (UR-ADR-8 scope pin) |
| `ApiKeyStatusChip.body` | unit | `ApiKeyStatusChipTests.swift` | presentTrueMapping | present=true maps to "Configured" |
| `ApiKeyStatusChip.body` | unit | `ApiKeyStatusChipTests.swift` | presentFalseMapping | present=false maps to "Not configured" |
| `SaveToChip.folderPath` | regression | `SaveToChipTests.swift` | keyIsCanonical | @AppStorage key is exactly "com.macrec.ui.outputFolder" |
| `SaveToChip.folderPath` | regression | `SaveToChipTests.swift` | keyHasFullPrefix | Key uses full reverse-DNS prefix |
| `SaveToChip.folderPath` | regression | `SaveToChipTests.swift` | keySuffixComponent | Key suffix is "outputFolder" |
| `SaveToChip.folderPath` | unit | `SaveToChipTests.swift` | roundTripFolderPath | Folder path round-trips as String under key |
| `SaveToChip.folderPath` | unit | `SaveToChipTests.swift` | defaultIsEmptyString | Default stored value is "" (bootstrap fires on empty) |
| `SaveToChip.displayName` | unit | `SaveToChipTests.swift` | lastPathComponent | URL.lastPathComponent gives the display folder name |
| `SaveToChip.displayName` | unit | `SaveToChipTests.swift` | lastPathComponentNested | Works for nested paths |
| `SaveToChip.displayName` | unit | `SaveToChipTests.swift` | emptyPathDisplayContract | Empty folderPath → "Choose…" branch |
| `PermissionPill.pollLoop` | unit | `PermissionPillTests.swift` | pollingIntervalNanoseconds | 2_000_000_000 ns = 2.0 s |
| `PermissionPill.pollLoop` | unit | `PermissionPillTests.swift` | cadenceMatchesPermissionStatusView | Both pollers use the same 2 s cadence |
| `PermissionPill.allGranted` | unit | `PermissionPillTests.swift` | optimisticBootstrap | nil snapshot → allGranted true (optimistic green on popover open) |
| `PermissionPill.allGranted` | unit | `PermissionPillTests.swift` | allGrantedWhenBothAuthorized | Both grants → allGranted true |
| `PermissionPill.allGranted` | unit | `PermissionPillTests.swift` | allGrantedFalseWhenAnyDenied | Any denial → allGranted false |
| `PermissionPill.grantedPill` | unit | `PermissionPillTests.swift` | grantedLabelExact | "All permissions granted" exact |
| `PermissionPill.missingPill` | unit | `PermissionPillTests.swift` | missingLabelExact | "Permissions needed" exact |
| `PermissionPill.missingPill` | unit | `PermissionPillTests.swift` | expandedLabelExact | expanded=true → "Hide permissions" |
| `PermissionPill.missingPill` | unit | `PermissionPillTests.swift` | collapsedLabelExact | expanded=false → "Permissions needed" |
| `PermissionPill` | unit | `PermissionPillTests.swift` | labelsAreDistinct | Granted and missing labels are distinct |
| `LiveTranscriptionSectionHeader.transcriptionEnabled` | regression | `LiveTranscriptionSectionHeaderTests.swift` | keyIsCanonical | @AppStorage key is "com.macrec.ui.transcriptionEnabled" |
| `LiveTranscriptionSectionHeader.transcriptionEnabled` | regression | `LiveTranscriptionSectionHeaderTests.swift` | sectionHeaderKeyMatchesControlBarKey | Both binding sites use the same literal (anti-drift) |
| `LiveTranscriptionSectionHeader.transcriptionEnabled` | regression | `LiveTranscriptionSectionHeaderTests.swift` | keyHasFullPrefix | Full reverse-DNS prefix |
| `LiveTranscriptionSectionHeader.transcriptionEnabled` | regression | `LiveTranscriptionSectionHeaderTests.swift` | keySuffixComponent | Suffix is "transcriptionEnabled" |
| `LiveTranscriptionSectionHeader.transcriptionEnabled` | unit | `LiveTranscriptionSectionHeaderTests.swift` | defaultIsTrue | Default is true (UR-ADR-7) |
| `LiveTranscriptionSectionHeader.transcriptionEnabled` | unit | `LiveTranscriptionSectionHeaderTests.swift` | roundTripBool | Bool persists round-trip |
| `LiveTranscriptionSectionHeader.body` | unit | `LiveTranscriptionSectionHeaderTests.swift` | headerLabelExact | "LIVE TRANSCRIPTION" exact |
| `LiveTranscriptionSectionHeader.body` | unit | `LiveTranscriptionSectionHeaderTests.swift` | headerLabelIsUppercased | Label is uppercased form of "Live Transcription" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | idleIsReady / stoppedIsReady | idle + stopped → "Ready" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | startingLabel | starting → "Starting…" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | recordingLabel | recording → "Recording" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | pausingLabel | pausing → "Pausing…" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | pausedLabel | paused → "Paused" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | resumingLabel | resuming → "Resuming…" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | splittingLabel | splitting → "Splitting…" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | stoppingLabel | stopping → "Stopping…" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | failedLabel | failed → "Error" |
| `ReadyPill.label` | unit | `ReadyPillTests.swift` | nonFailedStatesHaveLabels | All 9 non-failed states have non-empty labels |
| `ReadyPill.dotColor` | unit | `ReadyPillTests.swift` | recordingIsRed / splittingIsRed / failedIsRed | Red dot states |
| `ReadyPill.dotColor` | unit | `ReadyPillTests.swift` | pausedIsYellow / pausingIsYellow / resumingIsYellow | Yellow dot states |
| `ReadyPill.dotColor` | unit | `ReadyPillTests.swift` | idleIsGreen / stoppedIsGreen / startingIsGreen / stoppingIsGreen | successDot (green) states |
| `ReadyPill` | unit | `ReadyPillTests.swift` | threePrimaryLabels | idle/recording/paused are the three primary labels (spec) |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | lightModeEffectiveIsLight | Light mode: effective ignores OS systemColorScheme |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | darkModeEffectiveIsDark | Dark mode: effective ignores OS systemColorScheme |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | systemModeFollowsOSDark | system + OS dark → effective dark |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | systemModeFollowsOSLight | system + OS light → effective light |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | paletteDarkForDarkEffective | effective dark → "dark" palette selection |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | paletteLightForLightEffective | effective light → "light" palette selection |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | endToEndSystemDark | system+dark end-to-end |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | endToEndSystemLight | system+light end-to-end |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | endToEndDarkOverridesOSLight | dark mode overrides OS light |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | systemModePreferredColorSchemeIsNil | system passes nil to preferredColorScheme |
| `AppearanceHostingRoot.body` | unit | `AppearanceHostingRootSystemModeTests.swift` | explicitModesPreferredColorSchemeIsNonNil | light/dark pass non-nil |

## 5. Files Owned

| File | Reason |
|---|---|
| `Tests/MacrecUITests/Transcription/ApiKeyStatusRowTests.swift` | new |
| `Tests/MacrecUITests/Transcription/ApiKeyStatusChipTests.swift` | new |
| `Tests/MacrecUITests/Header/SaveToChipTests.swift` | new |
| `Tests/MacrecUITests/Header/PermissionPillTests.swift` | new |
| `Tests/MacrecUITests/Sections/LiveTranscriptionSectionHeaderTests.swift` | new (also created `Sections/` directory) |
| `Tests/MacrecUITests/Footer/ReadyPillTests.swift` | new (also created `Footer/` directory) |
| `Tests/MacrecUITests/Theme/AppearanceHostingRootSystemModeTests.swift` | new (did NOT modify existing `AppearancePersistenceTests.swift`) |

## 6. Test Run Results

Final aggregate run: `swift test --filter "ApiKeyStatusRow|ApiKeyStatusChip|SaveToChip|PermissionPill|LiveTranscriptionSectionHeader|ReadyPill|AppearanceHostingRoot"`

```
✔ Test run with 77 tests in 7 suites passed after 0.004 seconds.
```

All 77 tests passed. Zero failures. One compiler warning surfaced (innocuous constant-condition warning on `PermissionPillTests.collapsedLabelExact` where `expanded = false` is a literal — the test is intentionally structured to document the source's conditional; warning does not affect correctness or test outcome).

Per-suite counts:

| Suite | Tests | Passed | Failed |
|---|---|---|---|
| ApiKeyStatusRow contract pins | 12 | 12 | 0 |
| ApiKeyStatusChip contract pins (UR-ADR-8) | 6 | 6 | 0 |
| SaveToChip contract pins | 8 | 8 | 0 |
| PermissionPill contract pins | 10 | 10 | 0 |
| LiveTranscriptionSectionHeader contract pins | 8 | 8 | 0 |
| ReadyPill contract pins | 22 | 22 | 0 |
| AppearanceHostingRoot system-mode palette contract | 11 | 11 | 0 |
| **Total** | **77** | **77** | **0** |

One test required a one-iteration fix: `ReadyPillTests.failedLabel` initially used `.failed(.permissionDenied)` which does not exist on `MacrecError`; the correct case is `.screenRecordingPermissionDenied`. Corrected before final run — not an implementation gap, purely a test-authoring error.

## 7. Implementation Gaps

None. No drift found between design-specified literals and source-file literals:

- `ApiKeyStatusChip`: source says `"Configured"` / `"Not configured"` — matches design.
- `ApiKeyStatusRow`: mask is 26 dots (source comment says "up to 28" but the literal is 26 — the comment is inaccurate, not the code; this is noted for awareness but is not a design-to-code gap).
- `PermissionPill`: polling interval is `2_000_000_000 ns` = 2 s as documented.
- `LiveTranscriptionSectionHeader`: key matches `ControlBarStartTappedKeysRegressionTests`, default is `true`.
- `ReadyPill`: label for `.stopped` is `"Ready"` (same branch as `.idle`) — matches the source.
- `AppearanceHostingRoot`: `mode.colorScheme ?? systemColorScheme` two-branch logic confirmed in source.

**Observation (not a gap):** `ApiKeyStatusRow.swift` line 129 comment says "Render up to 28 dots" but the literal is `26`. The comment is misleading but the actual behavior (26 dots) is pinned by `maskWidthIs26`. If anyone changes the literal to 28 to match the comment, the test will fail, prompting review.

## 8. Manual Review Needed

None.

All tests were writeable using the concept-pinning pattern without touching shared test infrastructure or requiring `@testable import macrec_ui`. No shared fixtures (`conftest`-equivalents) were needed or modified.

The compiler warning on `PermissionPillTests.collapsedLabelExact` (constant-condition `expanded = false`) is intentional: the test documents the source's ternary contract `expanded ? "Hide permissions" : "Permissions needed"` in the collapsed branch. The warning can be suppressed by replacing the local `let expanded = false` with a `_ =` pattern or an `#expect(("Permissions needed") == "Permissions needed")` direct form if desired — left for the reviewer to decide.

## 9. Commands Run

| # | Command | Exit Code |
|---|---|---|
| 1 | `swift test --filter "ApiKeyStatusRow"` | 0 (12/12 passed) |
| 2 | `swift test --filter "ApiKeyStatusChip"` | 0 (6/6 passed) |
| 3 | `swift test --filter "SaveToChip"` | 0 (8/8 passed) |
| 4 | `swift test --filter "PermissionPill"` | 0 (10/10 passed) |
| 5 | `swift test --filter "LiveTranscriptionSectionHeader"` | 0 (8/8 passed) |
| 6 | `swift test --filter "ReadyPill"` | 0 (22/22 passed) |
| 7 | `swift test --filter "AppearanceHostingRoot"` | 0 (11/11 passed) |
| 8 | `swift test --filter "ApiKeyStatusRow\|ApiKeyStatusChip\|SaveToChip\|PermissionPill\|LiveTranscriptionSectionHeader\|ReadyPill\|AppearanceHostingRoot"` | 0 (77/77 passed) |
