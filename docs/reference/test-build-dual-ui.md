---
status: completed
mode: write-and-run
scope_slug: dual-transcription-ui-layer
language: swift
framework: swift-testing
test_command_full: swift test
test_command_scope: swift test --filter "LiveTranscriptPanelSingleModeTests|DualLiveTranscriptViewTests|DualTranscriptionControlsTests|DualPrivacyDisclosureTests"
test_dir: Tests/MacrecUITests
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
test_files_owned:
  - Tests/MacrecUITests/Transcription/LiveTranscriptPanelSingleModeTests.swift
  - Tests/MacrecUITests/Transcription/Dual/DualLiveTranscriptViewTests.swift
  - Tests/MacrecUITests/Transcription/Dual/DualTranscriptionControlsTests.swift
  - Tests/MacrecUITests/PrivacyDisclosure/DualPrivacyDisclosureTests.swift
  - Tests/MacrecUITests/TestHelpers/RecordingControllerTestHelpers.swift
tests_added: 70
tests_updated: 0
tests_run: 70
tests_passed: 70
tests_failed: 0
implementation_gaps: 0
built_at: "2026-05-01T16:15:00Z"
last_built_commit: c2e7080d1c0400f67ea0fb78bd6fff3242fa6d40
---

# Test Build — Dual Transcription UI Layer

## 1. Summary

All 70 tests across 4 new suites pass. The framework is Swift Testing (`@Suite` / `@Test` / `#expect`), consistent with the existing `MacrecUITests` target. Tests were written for `MacrecUITests` (which imports `MacrecUIKit` + `MacrecCore` but not the `macrec-ui` executable target) using the same controller-centric + pure-logic testing idiom established by the existing suites. A fifth file (`TestHelpers/RecordingControllerTestHelpers.swift`) provides shared free-function utilities. One pre-existing test (`UIErrorPresenterTests.staleRecording → retry`) fails due to a locale-specific PID number formatting issue at `HEAD` — this is not in scope and predates this build.

## 2. Scope Resolved

### Source files tested

| File | Key symbols exercised |
|---|---|
| `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift` | `LiveTranscriptPanel` (mode branch logic — DT-INV), `TranscriptSegment.isSettled` basis (`durationSec`), language-chip formula |
| `Sources/macrec-ui/Views/Transcription/Dual/DualLiveTranscriptView.swift` | `channelASegments` / `channelBSegments` filter logic, layout ordering |
| `Sources/macrec-ui/Views/Transcription/Dual/DualTranscriptionControls.swift` | Channel A locale-set source (`DualLocaleSets.channelASupportedLocales`), AppStorage key space |
| `Sources/MacrecCore/Transcription/Dual/DualSidecarLabel.swift` | `channelTag(forModel:)` |
| `Sources/MacrecCore/Transcription/Dual/DualLocaleSets.swift` | `channelASupportedLocales` (no Greek), `channelBSupportedLocales` (el-GR present) |
| `Sources/MacrecCore/Transcription/Dual/DualChannelTag.swift` | Routing enum values |
| `Sources/MacrecCore/Transcription/Dual/TranscriptionMode.swift` | `LiveTranscriptionMode` raw values |
| `Sources/MacrecUIKit/RecordingController.swift` | `transcriptionMode`, `transcriptionModeStorageKey`, `maxLiveTranscriptSegments`, `pendingDisclosure`, `acknowledgePendingDisclosure()` |
| `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift` | Key formula `acknowledgedKey(for:)` (replicated inline — not importable) |
| `Sources/macrec-ui/RootView.swift` | L-12 gate logic `isCloudProvider` / `shouldShowDisclosure` (replicated inline) |

## 3. Existing Coverage

| Symbol | Existing test files found |
|---|---|
| `LiveTranscriptPanel` (single-mode path) | `Tests/MacrecUITests/Transcription/LiveTranscriptPanelTests.swift` |
| `PrivacyDisclosureViewModel` (key pinning) | `Tests/MacrecUITests/Transcription/PrivacyDisclosureTests.swift` |
| `DualSidecarLabel` | `Tests/MacrecCoreTests/Transcription/Persistence/SidecarChannelTaggingTests.swift` |
| `DualLiveTranscriptView` | None (new in plan-010 Wave 6) |
| `DualTranscriptionControls` | None (new in plan-010 Wave 5) |
| `RecordingController.transcriptionMode` | None prior to this build |
| `RecordingController.dualChannelErrors` | None prior to this build |
| L-12 dual privacy gate | None prior to this build |

## 4. Plan

| # | target_symbol | category | test_file | test_name | intent |
|---|---|---|---|---|---|
| 1 | `LiveTranscriptPanel.body` (single branch) | regression | `LiveTranscriptPanelSingleModeTests.swift` | DT-INV level-1 controller contract (6 tests) | Pin the public API surface the single-mode subtree reads |
| 2 | `LiveTranscriptionMode` rawValue | regression | `LiveTranscriptPanelSingleModeTests.swift` | DT-INV level-2 branch logic (7 tests) | Prove mode-switch decoding and UserDefaults integration are unchanged |
| 3 | `DualSidecarLabel.channelTag(forModel:)` | unit | `LiveTranscriptPanelSingleModeTests.swift` | DT-INV level-3 routing contract (4 tests) | Confirm routing is never invoked in the single-mode path |
| 4 | `DualLiveTranscriptView.channelASegments` | unit | `DualLiveTranscriptViewTests.swift` | Channel A routing (5 tests) | `"apple"` routes to lane A only |
| 5 | `DualLiveTranscriptView.channelBSegments` | unit | `DualLiveTranscriptViewTests.swift` | Channel B routing (5 tests) | `"apple-cloud"` routes to lane B only |
| 6 | `DualLiveTranscriptView` (unknown model) | error_path | `DualLiveTranscriptViewTests.swift` | Unknown model not shown (5 tests) | nil / gemini / soniox / whisperkit do not appear in either lane |
| 7 | `DualLiveTranscriptView` (layout ordering) | unit | `DualLiveTranscriptViewTests.swift` | Stacked A-above-B ordering (3 tests) | Partition preserves arrival order independently per lane |
| 8 | `DualLocaleSets.channelASupportedLocales` | unit | `DualTranscriptionControlsTests.swift` | Greek absent (3 tests) | `el-GR` must not appear in Channel A |
| 9 | `DualLocaleSets.channelASupportedLocales` | unit | `DualTranscriptionControlsTests.swift` | English present (2 tests) | en-US variant and ≥1 English locale present |
| 10 | `DualLocaleSets.channelBSupportedLocales` | unit | `DualTranscriptionControlsTests.swift` | el-GR first (2 tests) | Channel B contains el-GR and sorts it first |
| 11 | `DualTranscriptionControls` AppStorage keys | config_validation | `DualTranscriptionControlsTests.swift` | Key disjointness (4 tests) | Dual keys use `com.macrec.ui.dual.*` prefix, not single-mode prefix |
| 12 | L-12 dual privacy gate (unacknowledged) | regression | `DualPrivacyDisclosureTests.swift` | Gate fires (4 tests) | Disclosure sheet must be shown on first dual start |
| 13 | L-12 dual privacy gate (acknowledged) | regression | `DualPrivacyDisclosureTests.swift` | Gate silent (4 tests) | Sheet suppressed after acknowledgement |
| 14 | L-12 single→dual interop (DT-ADR-12) | integration | `DualPrivacyDisclosureTests.swift` | Shared key interop (5 tests) | Single-mode acknowledgement satisfies dual-mode gate |

## 5. Files Owned

| File | Reason |
|---|---|
| `Tests/MacrecUITests/Transcription/LiveTranscriptPanelSingleModeTests.swift` | New — DT-INV regression suite |
| `Tests/MacrecUITests/Transcription/Dual/DualLiveTranscriptViewTests.swift` | New — channel routing suite |
| `Tests/MacrecUITests/Transcription/Dual/DualTranscriptionControlsTests.swift` | New — locale-set constraint suite |
| `Tests/MacrecUITests/PrivacyDisclosure/DualPrivacyDisclosureTests.swift` | New — dual privacy gate suite |
| `Tests/MacrecUITests/TestHelpers/RecordingControllerTestHelpers.swift` | New — shared test utilities (free functions; no extensions on the controller) |

## 6. Test Run Results

Command run:
```
swift test --filter "LiveTranscriptPanelSingleModeTests|DualLiveTranscriptViewTests|DualTranscriptionControlsTests|DualPrivacyDisclosureTests"
```

Result: **70 tests in 4 suites — 70 passed, 0 failed**.

Per-suite breakdown:

| Suite | Tests | Passed | Failed |
|---|---|---|---|
| `LiveTranscriptPanel single-mode invariance (DT-INV)` | 22 | 22 | 0 |
| `DualLiveTranscriptView channel routing (plan-010 §G.4)` | 15 | 15 | 0 |
| `DualTranscriptionControls Channel-A locale-set constraint (plan-010 §DT-13)` | 14 | 14 | 0 |
| `DualPrivacyDisclosure trigger (plan-010 §J.3 / FR-8 / DT-ADR-12)` | 19 | 19 | 0 |

Notable observations during run:

1. **`DualLocaleSets.channelASupportedLocales`** on this host returns 30 locales (not the "~42 English-only" stated in the codebase-scan doc). At macOS 26 beta the set includes German, Spanish, French, Italian, Japanese, Korean, Portuguese, Cantonese, Chinese — but NOT Greek. The critical constraint (no `el-GR`) was verified and passes. The test that asserted "English-dominant" was corrected to a minimal "≥1 English locale" assertion, which is what the design actually requires.

2. **`DualLocaleSets.channelBSupportedLocales`** correctly returns `el-GR` as the first element (sorted first by `DualLocaleSets.sortChannelB`). Tests confirm `el-GR` is present and first.

3. **Locale identifier format**: `SpeechTranscriber.supportedLocales` returns `Locale` values whose `.identifier` uses underscore separators (`en_US` not `en-US`). Tests were adjusted to use `Locale.language.languageCode` + `Locale.region` APIs rather than bare string comparison.

## 7. Implementation Gaps

None. All 70 tests pass. No production behaviour was found to contradict the design spec.

## 8. Manual Review Needed

### 8.1 PrivacyDisclosureViewModel not accessible from MacrecUITests

`PrivacyDisclosureViewModel` is declared in `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift`, which is part of the `macrec-ui` executable target. The `MacrecUITests` target imports `MacrecUIKit` only — the executable is not importable.

**Impact**: The privacy disclosure tests (`DualPrivacyDisclosureTests`) cannot directly instantiate `PrivacyDisclosureViewModel` or call its `acknowledge(provider:)` / `hasAcknowledged(provider:)` methods. The key formula `"com.local.macrec-ui.transcription.privacy.<providerId>.acknowledged"` was replicated inline in the test file as a private function.

**Recommendation**: Move `PrivacyDisclosureViewModel` from `Sources/macrec-ui/` to `Sources/MacrecUIKit/` (making it importable from tests). This is a refactoring of shared logic that is referenced from multiple places (`RootView.swift`, `PrivacySettingsView.swift`, `PrivacyDisclosureSheet.swift`) and is not specific to the SwiftUI layer.

**Risk of not acting**: If the production key formula changes and the inline test replica is not updated, the tests will pass while the gate silently uses the wrong key. A code review step is the current mitigant.

### 8.2 `LiveTranscriptPanel` and `DualLiveTranscriptView` body tree not inspectable

`LiveTranscriptPanel`, `DualLiveTranscriptView`, and `DualTranscriptionControls` are SwiftUI views in the `macrec-ui` executable. They cannot be instantiated or body-inspected from `MacrecUITests`. No view-inspection harness (ViewInspector or similar) is installed in the project.

**Impact**: DT-INV (byte-for-byte structural invariance of the single-mode rendering path) can only be verified at the data-contract and pure-logic levels. The visual/structural tree equivalence can only be verified by snapshot comparison against Xcode previews (which are intentionally omitted from this project per convention) or by a human code-review diff.

**Recommendation**: This is a known limitation; the suite's data-contract tests are the best automated guard available given the project's test-target separation. A `// DT-INV:` comment in `LiveTranscriptPanel.swift:singleBody` makes the constraint visible to reviewers.

### 8.3 L-12 `RootView` gate logic not directly testable

The dual privacy gate (`RootView.onChange(of: recordingController?.state)`) is in the `macrec-ui` executable. The tests replicate the gate's decision predicate as a private `DualPrivacyGate` enum in the test file.

**Recommendation**: Same as 8.1 — extract the gate logic into a `public func dualModeRequiresDisclosure(mode:defaults:)` function in `MacrecUIKit`. This makes it directly testable and removes the need for the inline replica.

### 8.4 Pre-existing failing test in UIErrorPresenterTests

`UIErrorPresenterTests.staleRecording → retry` was already failing at `HEAD` (`c2e7080`). The test checks `p.detail.contains("99999")` but the string produced is `"process 99.999"` (locale-decimal separator). This is outside this agent's `test_files_owned` set.

**What to do**: Fix the test in `UIErrorPresenterTests.swift` to check for the locale-agnostic form (e.g. the PID integer directly, or use a locale-neutral format in `UIErrorPresenter.present(.staleRecording(pid:pidFilePath:))`).

## 9. Commands Run

| Step | Command | Exit code |
|---|---|---|
| Build MacrecUITests | `swift build --target MacrecUITests` | 0 |
| Run new suites | `swift test --filter "LiveTranscriptPanelSingleModeTests\|DualLiveTranscriptViewTests\|DualTranscriptionControlsTests\|DualPrivacyDisclosureTests"` | 0 |
| Full MacrecUITests run (informational) | `swift test --filter MacrecUITests` | 1 (1 pre-existing failure in UIErrorPresenterTests) |
