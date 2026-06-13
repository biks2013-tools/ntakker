# Plan 016 — Predefined Questions

**Status:** Design approved, awaiting user review before implementation plan.
**Date:** 2026-05-14
**Surface:** `macrec-ui` (menu-bar app). No CLI changes.
**Depends on:** plan-015 (in-recording Asking / Q&A mode).

## 1. Problem

During a recording, the Asking (Q&A) panel lets the user type a question that is sent — together with the live transcript — to an LLM provider. Users often ask the *same* questions across recordings (e.g. "Summarise the discussion so far", "What action items have been agreed?", "What risks were raised?"). Typing them every time is slow and breaks attention.

We want a small, focused mechanism for the user to maintain a personal list of predefined questions, then fire any of them with one click while a recording is in progress.

## 2. Goals & non-goals

### Goals

- Let the user create, edit, reorder, and delete predefined questions in a dedicated Settings sidebar entry.
- Make predefined questions one-click accessible while in the Asking (Q&A) panel during a recording.
- A selected predefined question is auto-submitted through the *existing* `AskService.ask(...)` flow — same streaming, same sidecar, same privacy gate — so no Q&A-pipeline changes are required.

### Non-goals (explicitly out of scope)

- Surfacing predefined questions outside the Asking panel (no toolbar widget, no global hotkeys).
- Categories, tags, or enable/disable toggles on questions.
- Import/export, sync between machines.
- A default seed list shipped with the app.
- CLI exposure (this is UI-only state for the bundled `macrec-ui` app).

## 3. UX

### 3.1 Settings — new sidebar entry

A new entry `Predefined Questions` is inserted in `SettingsCategory` between `asking` and `whisperkit`. Sidebar icon: `text.bubble`.

The section view (`PredefinedQuestionsSettingsView`) shows:

- A short explanatory header: *"These questions appear in a menu next to the Send button in Asking (Q&A). Selecting one immediately submits it."*
- A `List` of questions, each row rendering `label` (medium weight) and a truncated single-line preview of `text` (secondary style).
- Drag handle on each row for reordering (`.onMove`).
- Swipe-to-delete; tap a row to edit it.
- Buttons below the list: `+ Add`, `Edit` (toggles List edit mode for explicit reorder/delete), `Delete` (deletes the selected row, disabled if none selected).
- Empty-state placeholder: *"No predefined questions yet. Tap + Add to create one."*

The Add / Edit sheet has two fields:

- **Label** — single-line `TextField`, trimmed on save, ≤ 40 chars (character counter shown when over 30).
- **Question text** — multi-line `TextEditor`, trimmed on save, no length cap.

Save button is disabled until both fields are non-empty after trim. Cancel discards changes.

Delete confirms via a single-line alert: *"Delete '\(label)'?"*

### 3.2 Asking panel — Send menu

`AskingModeView` replaces its current Send button with a SwiftUI `Menu { ... } primaryAction: { submit() }` group:

- Clicking the **Send** body submits the textarea content — unchanged behaviour.
- Clicking the trailing **▾** chevron opens the menu listing predefined questions in user-defined order.
- Selecting a menu item submits that question's `text` through the same submit path, ignoring textarea content. The textarea is *not* cleared, so the user can keep editing what they were composing.
- A separator and a trailing **Manage…** menu item open Settings at the Predefined Questions tab via `EnvironmentValues.openSettings` (same pattern as the popover's gear button).
- If the store is empty, the menu shows a single disabled item *"No predefined questions"* followed by **Manage…**.
- The chevron is hidden when the Send button itself is disabled (e.g. no provider configured), so the menu state can never be inconsistent with the rest of the panel.

## 4. Data model & storage

### 4.1 Model

In `MacrecCore`:

```swift
public struct PredefinedQuestion: Identifiable, Codable, Equatable, Hashable {
    public let id: UUID
    public var label: String
    public var text: String
}
```

### 4.2 Store

In `MacrecCore`:

```swift
@MainActor
public final class PredefinedQuestionsStore: ObservableObject {
    @Published public private(set) var questions: [PredefinedQuestion]
    public init(defaults: UserDefaults = .standard)
    public func add(label: String, text: String)
    public func update(_ q: PredefinedQuestion)
    public func remove(id: UUID)
    public func move(fromOffsets: IndexSet, toOffset: Int)
}
```

- `init` decodes JSON from `UserDefaults` key `macrec.predefinedQuestions.v1`. On decode failure, logs a single warning and initialises with `questions = []`.
- Every mutator updates `questions`, encodes the array as JSON, and writes back to the same key. Writes are synchronous (no debouncing — the list is small).
- The store is `@MainActor`-isolated so SwiftUI views can read it directly without bridging.
- A single shared instance is created at app launch in `MacrecUIApp` and injected via `@EnvironmentObject` so both `AskingModeView` (popover) and `PredefinedQuestionsSettingsView` (Settings scene) see identical state.

### 4.3 Validation

- `label`: trimmed at save time, non-empty, ≤ 40 characters.
- `text`: trimmed at save time, non-empty, no upper bound.
- Duplicates are allowed.

## 5. Integration points

### Files touched

- `Sources/MacrecCore/PredefinedQuestion.swift` *(new)* — model.
- `Sources/MacrecCore/PredefinedQuestionsStore.swift` *(new)* — store.
- `Sources/macrec-ui/EnvironmentKeys.swift` — declare an environment object key (or rely on `@EnvironmentObject` directly — see plan).
- `Sources/macrec-ui/MacrecUIApp.swift` — instantiate the store once and inject it into the Settings scene and the popover root.
- `Sources/macrec-ui/Settings/SettingsRootView.swift` — add `case predefinedQuestions` to `SettingsCategory`, wire `displayName`, sidebar icon, and detail-view routing.
- `Sources/macrec-ui/Settings/Sections/PredefinedQuestionsSettingsView.swift` *(new)* — list + add/edit sheet + delete + reorder UI.
- `Sources/macrec-ui/Views/Asking/AskingModeView.swift` — replace Send button with the `Menu` group described in §3.2 and consume the store via `@EnvironmentObject`.

### Re-used (untouched) behaviour

- `AskService.ask(...)` — same call site, same arguments, same streaming.
- `AskPrivacyDisclosureSheet` and `pendingQuestion` — still gate cloud-provider submissions.
- `EnvFileStore` — the provider-key resolution chain is unchanged; predefined questions are UI state, not configuration.

## 6. Edge cases & error handling

- **In-flight Q&A** — a new menu-selected question is appended as a new `QAEntry` and submitted concurrently. Existing concurrent-stream behaviour is unchanged.
- **Privacy gate** — for unack'd cloud providers, the menu-selected text is placed in `pendingQuestion` and the disclosure sheet opens. Acknowledge → submit. Cancel → drop.
- **No provider configured** — the existing typed-error path renders inline via `QAEntry.errorMessage`.
- **Settings open while recording** — `@Published` propagates edits live; the menu reflects them on the next open.
- **Malformed UserDefaults JSON** — store logs `os_log` warning and starts empty. No fabricated defaults (consistent with the project's no-fallback rule for *configuration*; questions are state, so an empty list is the correct empty state).
- **Very long question text** — accepted as-is; the menu shows the *label* only, so a long body has no menu-rendering impact.

## 7. Testing

### Unit tests (in existing `Tests/` target)

- `PredefinedQuestionsStoreTests`:
  - add → persists; second store init reads the same content.
  - update → mutates in place and persists.
  - remove → drops the entry and persists.
  - move → reorders and persists.
  - decode failure on malformed JSON → empty list + warning logged.
- All tests inject `UserDefaults(suiteName: "test.macrec.predefinedQuestions")` and clean up in `tearDown`.

### Manual smoke test

1. `bash scripts/package-macrec-ui-app.sh && open dist/macrec-ui.app`.
2. Settings → Predefined Questions → add three questions (Summary, Action items, Risks).
3. Reorder via drag handle; quit and relaunch — verify order is preserved.
4. Start a recording, switch to Asking mode.
5. Click ▾ next to Send → pick each question → verify LLM response streams and is appended to the transcript sidecar.
6. Verify Manage… opens Settings on the right tab.
7. Empty the list → verify menu shows "No predefined questions" + Manage…

## 8. Open questions

None at design time.

## 9. References

- `Sources/macrec-ui/Settings/SettingsRootView.swift:14-44` — sidebar enum + display names.
- `Sources/macrec-ui/Settings/Sections/AskingSettingsView.swift` — pattern for an Asking-feature Settings section.
- `Sources/macrec-ui/Views/Asking/AskingModeView.swift:1-19` — current Send/submit path + privacy gate.
- `Sources/macrec-ui/Settings/SettingsRowHelpers.swift` — row styling helpers reused by the new section.
