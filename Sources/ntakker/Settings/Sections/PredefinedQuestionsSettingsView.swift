// ntakker/Settings/Sections/PredefinedQuestionsSettingsView.swift —
// plan-016. Settings sidebar detail view: list of predefined
// questions with add / edit / delete / reorder.

import NtakkerCore
import SwiftUI
import NtakkerSettingsUI

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

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
