// NtakkerCoreTests/PredefinedQuestionsStoreTests.swift — plan-016
// Unit tests for PredefinedQuestionsStore. Each test injects a
// dedicated UserDefaults suite so they are hermetic and order-
// independent.

import Foundation
import Testing
@testable import NtakkerCore

@MainActor
@Suite("PredefinedQuestionsStore")
struct PredefinedQuestionsStoreTests {

    private static func freshDefaults(_ suite: String) -> UserDefaults {
        let name = "test.ntakker-cli.predefinedQuestions." + suite
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Empty UserDefaults yields empty questions list")
    func emptyInit() {
        let defaults = Self.freshDefaults(#function)
        let store = PredefinedQuestionsStore(defaults: defaults)
        #expect(store.questions.isEmpty)
    }

    @Test("add appends a new question and persists it")
    func addPersists() {
        let defaults = Self.freshDefaults(#function)
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
        let defaults = Self.freshDefaults(#function)
        let store = PredefinedQuestionsStore(defaults: defaults)

        store.add(label: "  Summary  ", text: "  Summarise.  ")

        #expect(store.questions[0].label == "Summary")
        #expect(store.questions[0].text == "Summarise.")
    }

    @Test("add rejects empty / whitespace-only label or text")
    func addRejectsEmpty() {
        let defaults = Self.freshDefaults(#function)
        let store = PredefinedQuestionsStore(defaults: defaults)

        store.add(label: "", text: "ok")
        store.add(label: "ok", text: "")
        store.add(label: "   ", text: "   ")

        #expect(store.questions.isEmpty)
    }

    @Test("update mutates the matching question by id and persists it")
    func updatePersists() {
        let defaults = Self.freshDefaults(#function)
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
        let defaults = Self.freshDefaults(#function)
        let store = PredefinedQuestionsStore(defaults: defaults)
        store.add(label: "Summary", text: "x")

        store.update(PredefinedQuestion(id: UUID(), label: "Other", text: "y"))

        #expect(store.questions.count == 1)
        #expect(store.questions[0].label == "Summary")
    }

    @Test("remove drops the matching question and persists the new list")
    func removePersists() {
        let defaults = Self.freshDefaults(#function)
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
        let defaults = Self.freshDefaults(#function)
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

    @Test("move handles forward moves (toOffset > source index)")
    func movePersistsForward() {
        let defaults = Self.freshDefaults(#function)
        let store = PredefinedQuestionsStore(defaults: defaults)
        store.add(label: "A", text: "1")
        store.add(label: "B", text: "2")
        store.add(label: "C", text: "3")

        // Move "A" (index 0) past "B" — SwiftUI semantics: toOffset is
        // interpreted relative to the original list, so "insert before
        // index 2" produces [B, A, C].
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(store.questions.map(\.label) == ["B", "A", "C"])

        let reloaded = PredefinedQuestionsStore(defaults: defaults)
        #expect(reloaded.questions.map(\.label) == ["B", "A", "C"])
    }

    @Test("Malformed JSON in UserDefaults yields empty list (no crash)")
    func malformedJSONRecovers() {
        let defaults = Self.freshDefaults(#function)
        defaults.set(Data("not json".utf8), forKey: "ntakker-cli.predefinedQuestions.v1")

        let store = PredefinedQuestionsStore(defaults: defaults)

        #expect(store.questions.isEmpty)
    }
}
