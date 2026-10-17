// NtakkerCore/PredefinedQuestionsStore.swift — plan-016
// MainActor-isolated ObservableObject backing the predefined-questions
// list. Persists a JSON-encoded array of PredefinedQuestion under a
// versioned UserDefaults key. Initialiser accepts a UserDefaults
// instance so tests can inject an isolated suite.

import Foundation
import os
import Combine

@MainActor
public final class PredefinedQuestionsStore: ObservableObject {

    /// Process-wide shared instance used by the menu-bar app. Tests
    /// MUST inject their own `UserDefaults` via the designated init
    /// instead of touching `.shared`.
    public static let shared = PredefinedQuestionsStore()

    /// Versioned key — bump the suffix when introducing a schema
    /// change that requires migration.
    private static let storageKey = "ntakker-cli.predefinedQuestions.v1"

    private static let log = Logger(
        subsystem: "com.giorgosmarinos.ntakker",
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

    public func add(label: String, text: String) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText  = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedText.isEmpty else { return }
        questions.append(PredefinedQuestion(label: trimmedLabel, text: trimmedText))
        persist()
    }

    public func update(_ q: PredefinedQuestion) {
        guard let idx = questions.firstIndex(where: { $0.id == q.id }) else { return }
        let trimmedLabel = q.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText  = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedText.isEmpty else { return }
        questions[idx] = PredefinedQuestion(id: q.id, label: trimmedLabel, text: trimmedText)
        persist()
    }

    public func remove(id: UUID) {
        guard let idx = questions.firstIndex(where: { $0.id == id }) else { return }
        questions.remove(at: idx)
        persist()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        // Re-implement SwiftUI's `MutableCollection.move(fromOffsets:toOffset:)`
        // here so NtakkerCore stays free of SwiftUI. Semantics match the
        // SwiftUI extension used by `List.onMove` exactly: `toOffset` is the
        // pre-removal index where the moved slice should be inserted.
        let sortedFrom = fromOffsets.sorted()
        let moving = sortedFrom.map { questions[$0] }
        // Adjust the insertion offset for elements that will be removed from
        // positions before it.
        let removedBeforeToOffset = sortedFrom.filter { $0 < toOffset }.count
        let adjustedInsert = toOffset - removedBeforeToOffset
        for idx in sortedFrom.reversed() {
            questions.remove(at: idx)
        }
        questions.insert(contentsOf: moving, at: adjustedInsert)
        persist()
    }
}
