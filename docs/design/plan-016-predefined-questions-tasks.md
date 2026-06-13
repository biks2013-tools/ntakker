# Predefined Questions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user maintain a list of predefined questions in Settings and submit any of them with one click from the Asking (Q&A) panel during a recording.

**Architecture:** A new `PredefinedQuestion` value type + `PredefinedQuestionsStore` ObservableObject in `MacrecCore` persist a JSON array in `UserDefaults`. The store is exposed as `@MainActor` and shared via a singleton (`PredefinedQuestionsStore.shared`) injected as `@EnvironmentObject` into the Settings scene and the popover content. A new sidebar entry `PredefinedQuestionsSettingsView` provides CRUD. `AskingModeView` wraps the existing Send button in a `Menu { … } primaryAction: { submit() }` group; selecting a predefined item sets the textarea draft and re-uses the existing `submitDraft()` path so the privacy gate and streaming behavior are unchanged.

**Tech Stack:** Swift 5.10+, SwiftUI, SwiftPM, Swift Testing framework (`Testing` library, `@Suite`/`@Test`/`#expect`). macOS 26 deployment target. No new third-party dependencies.

**Spec:** `docs/design/plan-016-predefined-questions.md`

---

## File map

- **Create** `Sources/MacrecCore/PredefinedQuestion.swift` — `PredefinedQuestion` value type.
- **Create** `Sources/MacrecCore/PredefinedQuestionsStore.swift` — `PredefinedQuestionsStore` ObservableObject (with `static let shared`).
- **Create** `Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift` — unit tests for add / update / remove / move / persistence / malformed-JSON.
- **Modify** `Sources/macrec-ui/Settings/SettingsRootView.swift` — add `case predefinedQuestions` to `SettingsCategory` + routing.
- **Create** `Sources/macrec-ui/Settings/Sections/PredefinedQuestionsSettingsView.swift` — list view + add/edit sheet + delete + reorder.
- **Modify** `Sources/macrec-ui/MacrecUIApp.swift` — inject the shared store into the Settings scene.
- **Modify** `Sources/macrec-ui/PopoverController.swift` — inject the shared store into the popover's hosted root view.
- **Modify** `Sources/macrec-ui/Views/Asking/AskingModeView.swift` — replace the Send `Button` with a `Menu` group and route picks through `submitDraft()`.

---

## Task 1: `PredefinedQuestion` value type

**Files:**
- Create: `Sources/MacrecCore/PredefinedQuestion.swift`

- [ ] **Step 1: Write the file**

```swift
// MacrecCore/PredefinedQuestion.swift — plan-016
// Value type for a user-defined predefined question shown in the
// Asking (Q&A) Send-menu and managed under Settings →
// "Predefined Questions". Persisted as a JSON array in UserDefaults
// by `PredefinedQuestionsStore`.

import Foundation

public struct PredefinedQuestion: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public var text: String

    public init(id: UUID = UUID(), label: String, text: String) {
        self.id = id
        self.label = label
        self.text = text
    }
}
```

- [ ] **Step 2: Verify the file builds**

Run: `swift build --target MacrecCore`
Expected: PASS (no compile errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/MacrecCore/PredefinedQuestion.swift
git commit -m "feat(macrec-ui): add PredefinedQuestion value type (plan-016)"
```

---

## Task 2: `PredefinedQuestionsStore` — empty-init test (TDD red)

**Files:**
- Test: `Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift`

- [ ] **Step 1: Create the test file with the first failing test**

```swift
// MacrecCoreTests/PredefinedQuestionsStoreTests.swift — plan-016
// Unit tests for PredefinedQuestionsStore. Each test injects a
// dedicated UserDefaults suite so they are hermetic and order-
// independent.

import Foundation
import Testing
@testable import MacrecCore

@MainActor
@Suite("PredefinedQuestionsStore")
struct PredefinedQuestionsStoreTests {

    private static func freshDefaults(_ suite: String = #function) -> UserDefaults {
        let name = "test.macrec.predefinedQuestions." + suite
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Empty UserDefaults yields empty questions list")
    func emptyInit() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)
        #expect(store.questions.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test — expect compile failure**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: FAIL — "cannot find 'PredefinedQuestionsStore' in scope".

- [ ] **Step 3: Create the minimal store to pass this test**

Create `Sources/MacrecCore/PredefinedQuestionsStore.swift`:

```swift
// MacrecCore/PredefinedQuestionsStore.swift — plan-016
// MainActor-isolated ObservableObject backing the predefined-questions
// list. Persists a JSON-encoded array of PredefinedQuestion under a
// versioned UserDefaults key. Initialiser accepts a UserDefaults
// instance so tests can inject an isolated suite.

import Foundation
import os
import SwiftUI

@MainActor
public final class PredefinedQuestionsStore: ObservableObject {

    /// Process-wide shared instance used by the menu-bar app. Tests
    /// MUST inject their own `UserDefaults` via the designated init
    /// instead of touching `.shared`.
    public static let shared = PredefinedQuestionsStore()

    /// Versioned key — bump the suffix when introducing a schema
    /// change that requires migration.
    private static let storageKey = "macrec.predefinedQuestions.v1"

    private static let log = Logger(
        subsystem: "com.local.macrec-ui",
        category: "PredefinedQuestionsStore"
    )

    private let defaults: UserDefaults

    @Published public private(set) var questions: [PredefinedQuestion]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.questions = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> [PredefinedQuestion] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([PredefinedQuestion].self, from: data)
        } catch {
            log.warning("Failed to decode predefined questions: \(error.localizedDescription, privacy: .public). Starting empty.")
            return []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(questions)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Self.log.error("Failed to encode predefined questions: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 4: Run the test — expect pass**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: PASS — 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/PredefinedQuestionsStore.swift Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift
git commit -m "feat(macrec-ui): scaffold PredefinedQuestionsStore with empty-init test (plan-016)"
```

---

## Task 3: `add` — TDD

**Files:**
- Test: `Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift`
- Modify: `Sources/MacrecCore/PredefinedQuestionsStore.swift`

- [ ] **Step 1: Add the failing test**

Append inside the `@Suite` struct:

```swift
    @Test("add appends a new question and persists it")
    func addPersists() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)

        store.add(label: "Summary", text: "Summarise the discussion so far.")

        #expect(store.questions.count == 1)
        #expect(store.questions[0].label == "Summary")
        #expect(store.questions[0].text == "Summarise the discussion so far.")

        // New store reading the same defaults sees the persisted entry.
        let reloaded = PredefinedQuestionsStore(defaults: defaults)
        #expect(reloaded.questions.count == 1)
        #expect(reloaded.questions[0].label == "Summary")
    }

    @Test("add trims whitespace from label and text")
    func addTrims() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)

        store.add(label: "  Summary  ", text: "  Summarise.  ")

        #expect(store.questions[0].label == "Summary")
        #expect(store.questions[0].text == "Summarise.")
    }
```

- [ ] **Step 2: Run — expect compile failure (`add` not defined)**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: FAIL — "value of type 'PredefinedQuestionsStore' has no member 'add'".

- [ ] **Step 3: Add `add` to the store**

Append inside `PredefinedQuestionsStore`:

```swift
    public func add(label: String, text: String) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText  = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedText.isEmpty else { return }
        questions.append(PredefinedQuestion(label: trimmedLabel, text: trimmedText))
        persist()
    }
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: PASS — 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/PredefinedQuestionsStore.swift Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift
git commit -m "feat(macrec-ui): implement PredefinedQuestionsStore.add (plan-016)"
```

---

## Task 4: `update` — TDD

**Files:**
- Test + Modify: same as Task 3.

- [ ] **Step 1: Add the failing test**

```swift
    @Test("update mutates the matching question by id and persists it")
    func updatePersists() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)
        store.add(label: "Summary", text: "old")
        let id = store.questions[0].id

        store.update(PredefinedQuestion(id: id, label: "Summary v2", text: "new"))

        #expect(store.questions[0].label == "Summary v2")
        #expect(store.questions[0].text == "new")

        let reloaded = PredefinedQuestionsStore(defaults: defaults)
        #expect(reloaded.questions[0].label == "Summary v2")
        #expect(reloaded.questions[0].text == "new")
    }

    @Test("update is a no-op when the id does not match any question")
    func updateUnknownIdIsNoop() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)
        store.add(label: "Summary", text: "x")

        store.update(PredefinedQuestion(id: UUID(), label: "Other", text: "y"))

        #expect(store.questions.count == 1)
        #expect(store.questions[0].label == "Summary")
    }
```

- [ ] **Step 2: Run — expect compile failure (`update` not defined)**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: FAIL.

- [ ] **Step 3: Add `update` to the store**

```swift
    public func update(_ q: PredefinedQuestion) {
        guard let idx = questions.firstIndex(where: { $0.id == q.id }) else { return }
        let trimmedLabel = q.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText  = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedText.isEmpty else { return }
        questions[idx] = PredefinedQuestion(id: q.id, label: trimmedLabel, text: trimmedText)
        persist()
    }
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: PASS — 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/PredefinedQuestionsStore.swift Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift
git commit -m "feat(macrec-ui): implement PredefinedQuestionsStore.update (plan-016)"
```

---

## Task 5: `remove` and `move` — TDD

- [ ] **Step 1: Add the failing tests**

```swift
    @Test("remove drops the matching question and persists the new list")
    func removePersists() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)
        store.add(label: "A", text: "1")
        store.add(label: "B", text: "2")
        let idB = store.questions[1].id

        store.remove(id: idB)

        #expect(store.questions.count == 1)
        #expect(store.questions[0].label == "A")

        let reloaded = PredefinedQuestionsStore(defaults: defaults)
        #expect(reloaded.questions.count == 1)
        #expect(reloaded.questions[0].label == "A")
    }

    @Test("move reorders the list and persists the new order")
    func movePersists() {
        let defaults = Self.freshDefaults()
        let store = PredefinedQuestionsStore(defaults: defaults)
        store.add(label: "A", text: "1")
        store.add(label: "B", text: "2")
        store.add(label: "C", text: "3")

        // Move "C" (index 2) to position 0.
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(store.questions.map(\.label) == ["C", "A", "B"])

        let reloaded = PredefinedQuestionsStore(defaults: defaults)
        #expect(reloaded.questions.map(\.label) == ["C", "A", "B"])
    }
```

- [ ] **Step 2: Run — expect compile failure**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: FAIL — `remove`/`move` not defined.

- [ ] **Step 3: Add `remove` and `move` to the store**

```swift
    public func remove(id: UUID) {
        guard let idx = questions.firstIndex(where: { $0.id == id }) else { return }
        questions.remove(at: idx)
        persist()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        questions.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: PASS — 7 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/PredefinedQuestionsStore.swift Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift
git commit -m "feat(macrec-ui): implement remove + move on PredefinedQuestionsStore (plan-016)"
```

---

## Task 6: malformed-JSON recovery — TDD

- [ ] **Step 1: Add the failing test**

```swift
    @Test("Malformed JSON in UserDefaults yields empty list (no crash)")
    func malformedJSONRecovers() {
        let defaults = Self.freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "macrec.predefinedQuestions.v1")

        let store = PredefinedQuestionsStore(defaults: defaults)

        #expect(store.questions.isEmpty)
    }
```

- [ ] **Step 2: Run — expect pass (already implemented in Task 2)**

Run: `swift test --filter PredefinedQuestionsStoreTests`
Expected: PASS — 8 tests passed. This test guards the existing recovery path; no production code change.

- [ ] **Step 3: Commit**

```bash
git add Tests/MacrecCoreTests/PredefinedQuestionsStoreTests.swift
git commit -m "test(macrec-ui): cover malformed-JSON recovery in PredefinedQuestionsStore (plan-016)"
```

---

## Task 7: Add `SettingsCategory.predefinedQuestions` sidebar entry

**Files:**
- Modify: `Sources/macrec-ui/Settings/SettingsRootView.swift`

- [ ] **Step 1: Add the enum case + display name + icon + routing**

Edit `SettingsRootView.swift`. After `case asking` (line 22), insert `case predefinedQuestions`:

```swift
enum SettingsCategory: String, Identifiable, CaseIterable, Hashable {
    case general
    case permissions
    case asking
    case predefinedQuestions
    case whisperkit
    case parakeet
    case gemini
    case soniox
    case azure
    case azureRealtime
    case elevenlabs
    case privacy
    case about
```

In `displayName`, after the `.asking` line:

```swift
        case .predefinedQuestions: return String(localized: "Predefined Questions")
```

In `systemIcon`, after the `.asking` line:

```swift
        case .predefinedQuestions: return "text.bubble"
```

In `detailView(for:)`, after `case .asking: AskingSettingsView()`:

```swift
        case .predefinedQuestions: PredefinedQuestionsSettingsView()
```

- [ ] **Step 2: Verify it still builds (compile error is expected — view does not exist yet)**

Run: `swift build --product macrec-ui`
Expected: FAIL — "cannot find 'PredefinedQuestionsSettingsView' in scope". This is intentional; the next task adds it. Do NOT commit yet.

---

## Task 8: Create `PredefinedQuestionsSettingsView`

**Files:**
- Create: `Sources/macrec-ui/Settings/Sections/PredefinedQuestionsSettingsView.swift`

- [ ] **Step 1: Write the view file**

```swift
// macrec-ui/Settings/Sections/PredefinedQuestionsSettingsView.swift —
// plan-016. Settings sidebar detail view: list of predefined
// questions with add / edit / delete / reorder.

import MacrecCore
import SwiftUI

struct PredefinedQuestionsSettingsView: View {
    @EnvironmentObject private var store: PredefinedQuestionsStore

    @State private var selectedID: PredefinedQuestion.ID?
    @State private var editing: EditingTarget?
    @State private var pendingDeleteID: PredefinedQuestion.ID?

    enum EditingTarget: Identifiable {
        case create
        case update(PredefinedQuestion)
        var id: String {
            switch self {
            case .create: return "create"
            case .update(let q): return q.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Predefined Questions")
                .font(.title2.weight(.semibold))

            Text("These questions appear in a menu next to the Send button in Asking (Q&A). Selecting one immediately submits it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if store.questions.isEmpty {
                emptyState
            } else {
                list
            }

            HStack(spacing: 12) {
                Button {
                    editing = .create
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button {
                    if let id = selectedID,
                       let q = store.questions.first(where: { $0.id == id }) {
                        editing = .update(q)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(selectedID == nil)

                Button(role: .destructive) {
                    pendingDeleteID = selectedID
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedID == nil)

                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(item: $editing) { target in
            PredefinedQuestionEditor(
                target: target,
                onSave: { label, text in
                    switch target {
                    case .create:
                        store.add(label: label, text: text)
                    case .update(let original):
                        store.update(PredefinedQuestion(id: original.id, label: label, text: text))
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .alert(item: $pendingDeleteID) { id in
            let label = store.questions.first(where: { $0.id == id })?.label ?? ""
            return Alert(
                title: Text("Delete '\(label)'?"),
                primaryButton: .destructive(Text("Delete")) {
                    store.remove(id: id)
                    if selectedID == id { selectedID = nil }
                    pendingDeleteID = nil
                },
                secondaryButton: .cancel { pendingDeleteID = nil }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No predefined questions yet. Tap + Add to create one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(store.questions) { q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.label)
                        .font(.body.weight(.medium))
                    Text(q.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(q.id)
                .contextMenu {
                    Button("Edit") { editing = .update(q) }
                    Button("Delete", role: .destructive) { pendingDeleteID = q.id }
                }
            }
            .onMove { offsets, dest in
                store.move(fromOffsets: offsets, toOffset: dest)
            }
            .onDelete { offsets in
                for idx in offsets {
                    store.remove(id: store.questions[idx].id)
                }
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 200)
    }
}

// MARK: - Editor sheet

private struct PredefinedQuestionEditor: View {
    let target: PredefinedQuestionsSettingsView.EditingTarget
    let onSave: (_ label: String, _ text: String) -> Void
    let onCancel: () -> Void

    @State private var label: String
    @State private var text: String

    private static let labelLimit = 40

    init(
        target: PredefinedQuestionsSettingsView.EditingTarget,
        onSave: @escaping (_ label: String, _ text: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.onSave = onSave
        self.onCancel = onCancel
        switch target {
        case .create:
            _label = State(initialValue: "")
            _text  = State(initialValue: "")
        case .update(let q):
            _label = State(initialValue: q.label)
            _text  = State(initialValue: q.text)
        }
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool {
        !trimmedLabel.isEmpty
            && trimmedLabel.count <= Self.labelLimit
            && !trimmedText.isEmpty
    }

    private var title: String {
        switch target {
        case .create:  return String(localized: "Add Predefined Question")
        case .update:  return String(localized: "Edit Predefined Question")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Label")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Short label shown in the menu", text: $label)
                    .textFieldStyle(.roundedBorder)
                if trimmedLabel.count > 30 {
                    Text("\(trimmedLabel.count) / \(Self.labelLimit)")
                        .font(.caption)
                        .foregroundStyle(trimmedLabel.count > Self.labelLimit ? .red : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Question text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedLabel, trimmedText)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Alert helper

extension UUID: Identifiable { public var id: UUID { self } }
```

- [ ] **Step 2: Verify it builds**

Run: `swift build --product macrec-ui`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/macrec-ui/Settings/SettingsRootView.swift Sources/macrec-ui/Settings/Sections/PredefinedQuestionsSettingsView.swift
git commit -m "feat(macrec-ui): add Predefined Questions settings sidebar entry + CRUD view (plan-016)"
```

---

## Task 9: Inject the shared store into the Settings scene

**Files:**
- Modify: `Sources/macrec-ui/MacrecUIApp.swift`

- [ ] **Step 1: Add `.environmentObject(...)` to the Settings scene**

Replace lines 58–62 (`Settings { … }` block) with:

```swift
        Settings {
            AppearanceHostingRoot {
                SettingsRootView()
                    .environmentObject(PredefinedQuestionsStore.shared)
            }
        }
```

Also add `import MacrecCore` if it is not already present at the top of the file (it is not, per the current file).

- [ ] **Step 2: Verify it builds**

Run: `swift build --product macrec-ui`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/macrec-ui/MacrecUIApp.swift
git commit -m "feat(macrec-ui): inject PredefinedQuestionsStore into Settings scene (plan-016)"
```

---

## Task 10: Inject the shared store into the popover content

**Files:**
- Modify: `Sources/macrec-ui/PopoverController.swift`

- [ ] **Step 1: Add `.environmentObject(...)` to the popover's hosted root**

In `PopoverController.swift` find the `let composed = AnyView(...)` block (around line 128). Add the environment object inside the `AppearanceHostingRoot` closure:

```swift
        let composed = AnyView(
            AppearanceHostingRoot {
                rootView
                    .environment(\.recordingController, recordingController)
                    .environment(\.popoverBehavior, behaviorSetter)
                    .environmentObject(PredefinedQuestionsStore.shared)
            }
        )
```

If `import MacrecCore` is not already at the top of the file, add it.

- [ ] **Step 2: Verify it builds**

Run: `swift build --product macrec-ui`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/macrec-ui/PopoverController.swift
git commit -m "feat(macrec-ui): inject PredefinedQuestionsStore into popover (plan-016)"
```

---

## Task 11: Replace the Send button in `AskingModeView` with a `Menu` group

**Files:**
- Modify: `Sources/macrec-ui/Views/Asking/AskingModeView.swift`

- [ ] **Step 1: Inject the store**

Inside the `struct AskingModeView: View` declaration (near the existing `@ObservedObject var store: AskingSessionStore` on line 186), add a new environment-object property:

```swift
    @EnvironmentObject private var predefinedStore: PredefinedQuestionsStore
    @Environment(\.openSettings) private var openSettings
```

If `import MacrecCore` is not already at the top of the file, add it. (It is — verify and skip if present.)

- [ ] **Step 2: Replace the Send `Button` with a `Menu` group**

Replace the entire `Button(action: submitDraft) { ... }.disabled(!canSubmit).help(...)` block (lines 339–350 in the current file) with:

```swift
                Menu {
                    if predefinedStore.questions.isEmpty {
                        Text("No predefined questions")
                            .foregroundStyle(.secondary)
                        Divider()
                    } else {
                        Section("Predefined questions") {
                            ForEach(predefinedStore.questions) { q in
                                Button(q.label) {
                                    pickPredefined(q)
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Manage…") {
                        openSettings()
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(canSubmit ? palette.accent : palette.tertiary)
                        )
                } primaryAction: {
                    submitDraft()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canSubmit && predefinedStore.questions.isEmpty)
                .help(String(localized: "Send question (Return), or pick a predefined one"))
```

- [ ] **Step 3: Add the predefined-question picker**

Immediately after the existing `private func submitDraft()` (just before the closing brace of the struct, around line 400), add:

```swift
    /// Selecting a predefined question loads its text into the draft
    /// and routes through `submitDraft()` so the privacy gate, the
    /// AskService submit, and the streaming behavior all stay on a
    /// single code path.
    private func pickPredefined(_ q: PredefinedQuestion) {
        draft = q.text
        submitDraft()
    }
```

- [ ] **Step 4: Verify it builds**

Run: `swift build --product macrec-ui`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macrec-ui/Views/Asking/AskingModeView.swift
git commit -m "feat(macrec-ui): expose predefined questions in Asking Send menu (plan-016)"
```

---

## Task 12: Run the full test suite + package the app

**Files:** none.

- [ ] **Step 1: Run all MacrecCore tests**

Run: `swift test`
Expected: PASS — all tests green, including the eight new `PredefinedQuestionsStore` tests.

- [ ] **Step 2: Build the release bundle**

Run: `bash scripts/package-macrec-ui-app.sh`
Expected: `dist/macrec-ui.app` produced without errors.

- [ ] **Step 3: Smoke test (manual)**

```
open dist/macrec-ui.app
```

Walk through this checklist:

1. Click the menu-bar icon → click the gear → Settings opens.
2. Sidebar contains a new entry "Predefined Questions" between "Asking (Q&A)" and "WhisperKit (on-device)". Click it.
3. Empty-state placeholder is shown. Click `+ Add`. Editor sheet opens.
4. Type label `Summary`, text `Summarise the discussion so far.`. Save.
5. Repeat for `Action items` / `List concrete action items agreed.` and `Risks` / `What risks have been raised?`.
6. Drag `Risks` to the top of the list. Quit `macrec-ui` (popover → Quit). Relaunch via `open /Applications/macrec-ui.app`.
7. Re-open Settings → Predefined Questions. Verify the order is preserved (Risks, Summary, Action items).
8. Start a recording (popover → Start). Switch to Asking mode.
9. Click the down-chevron beside the Send arrow. Verify the three questions appear plus a `Manage…` item.
10. Pick "Summary". Verify a Q&A entry appears in the panel and the LLM answer streams in. Verify the Asking sidecar is written when the recording stops.
11. Click ▾ again → Manage…. Verify Settings opens directly on the "Predefined Questions" sidebar entry.
12. Delete all three questions via Settings. Reopen the Send menu in the popover. Verify it shows "No predefined questions" (disabled) + "Manage…".

- [ ] **Step 4: Commit any incidental fixes**

If the smoke test surfaced a bug, fix it, add a focused unit test if applicable, and commit. Otherwise no commit.

---

## Self-review (run after the plan is written)

**Spec coverage** — every spec section maps to a task:

| Spec § | Topic | Task(s) |
|---|---|---|
| §3.1 | Settings sidebar entry + CRUD UI | Tasks 7, 8 |
| §3.2 | Asking panel Send-menu | Tasks 10, 11 |
| §4.1 | `PredefinedQuestion` model | Task 1 |
| §4.2 | Store (init, add, update, remove, move, persist) | Tasks 2–5 |
| §4.2 | Malformed-JSON recovery | Task 6 |
| §4.3 | Validation (trim, label ≤ 40, non-empty) | Tasks 3, 4, 8 |
| §5 | Files touched | File map ✔ |
| §6 | Edge cases (in-flight Q&A, privacy gate, no provider, empty list) | Task 11 (menu empty-state), Task 12 (smoke step 12) |
| §7 | Unit tests + manual smoke test | Tasks 2–6, 12 |

**Placeholder scan** — no "TBD", "TODO", "implement later", or "Similar to Task N" patterns. All code blocks contain complete code. All commands include expected output.

**Type consistency** — `PredefinedQuestion(id:label:text:)` initialiser is used identically across the store, tests, and `PredefinedQuestionEditor`. The store API (`add(label:text:) / update(_:) / remove(id:) / move(fromOffsets:toOffset:)`) matches across spec §4.2, Tasks 2–5, and the view code in Task 8.
