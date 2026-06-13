// NtakkerCore/PredefinedQuestion.swift — plan-016
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
