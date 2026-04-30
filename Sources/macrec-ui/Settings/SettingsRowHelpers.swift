// macrec-ui/Settings/SettingsRowHelpers.swift —
// Reusable Form rows used by every per-provider settings section.
//
// All rows persist their value to `~/.tool-agents/macrec-ui/.env`
// (mode 0600) via `EnvFileStore.upsert(...)`, AND `setenv` the new
// value into the running process so the next Start picks it up
// without an app restart. This mirrors `ProviderKeyField` and
// matches the documented four-tier resolution chain.

import MacrecCore
import SwiftUI

/// Tool name passed to every `EnvFileStore` call. Re-declared here so
/// the Settings views do not have to reach into the AppDelegate target.
enum SettingsConstants {
    static let toolAgentsName = "macrec-ui"
}

// MARK: - Generic single-line text row

/// Plain text row with debounced auto-save (~600 ms after the last
/// keystroke) PLUS instant commit on Tab / Enter. Status badge
/// (●/✓/⚠) shows whether the on-screen value matches the on-disk
/// value. Suitable for non-secret strings (endpoints, deployment
/// names, model ids, language codes). For secrets use
/// `ProviderKeyField` instead — secrets must NOT auto-save partial
/// keystrokes.
struct SettingsTextRow: View {

    let label: String
    let envVarName: String
    let placeholder: String
    let helpText: String?
    /// Optional documented default surfaced as italic placeholder text
    /// when the env var is unset.
    let defaultValue: String?

    @State private var typed: String = ""
    @State private var lastSaved: String = ""
    @State private var saveCounter: Int = 0
    @State private var feedback: String?

    init(
        label: String,
        envVarName: String,
        placeholder: String,
        helpText: String? = nil,
        defaultValue: String? = nil
    ) {
        self.label = label
        self.envVarName = envVarName
        self.placeholder = placeholder
        self.helpText = helpText
        self.defaultValue = defaultValue
    }

    /// `.dirty` while the user has typed a value that does not yet
    /// match disk. `.saved` once the autosave has flushed. `.error`
    /// when the most recent save threw.
    private enum SaveState: Equatable {
        case clean
        case dirty
        case saved
        case error(String)
    }

    private var state: SaveState {
        if let feedback {
            if feedback.hasPrefix("Saved") { return .saved }
            return .error(feedback)
        }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines)
            == lastSaved.trimmingCharacters(in: .whitespacesAndNewlines)
            ? .clean
            : .dirty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .frame(minWidth: 140, alignment: .leading)
                TextField(
                    placeholder,
                    text: $typed
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onChange(of: typed) { _, _ in
                    scheduleDebouncedSave()
                }
                stateBadge
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .error(let msg) = state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .clean:
            Circle().fill(Color.gray.opacity(0.5)).frame(width: 6, height: 6)
                .help(String(localized: "On disk."))
        case .dirty:
            Circle().fill(Color.orange).frame(width: 6, height: 6)
                .help(String(localized: "Editing… auto-save in ~600 ms (or press Enter)."))
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(String(localized: "Saved."))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(String(localized: "Save failed."))
        }
    }

    private func reload() {
        let stored = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName
        )
        typed = stored ?? ""
        lastSaved = typed
    }

    private func scheduleDebouncedSave() {
        saveCounter += 1
        let captured = saveCounter
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard captured == saveCounter else { return }   // user typed again
            commit()
        }
    }

    private func commit() {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip no-op writes (also resets the badge cleanly).
        if trimmed == lastSaved.trimmingCharacters(in: .whitespacesAndNewlines) {
            feedback = nil
            return
        }
        do {
            try EnvFileStore.upsert(
                toolName: SettingsConstants.toolAgentsName,
                key: envVarName,
                value: trimmed
            )
            lastSaved = trimmed
            feedback = String(localized: "Saved.")
            scheduleFeedbackClear()
        } catch {
            feedback = String(localized: "Save failed: \(error.localizedDescription)")
        }
    }

    private func scheduleFeedbackClear() {
        let snapshot = feedback
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if feedback == snapshot { feedback = nil }
        }
    }
}

// MARK: - Boolean toggle row

struct SettingsToggleRow: View {

    let label: String
    let envVarName: String
    let helpText: String?
    let defaultValue: Bool

    @State private var value: Bool = false

    init(
        label: String,
        envVarName: String,
        helpText: String? = nil,
        defaultValue: Bool = false
    ) {
        self.label = label
        self.envVarName = envVarName
        self.helpText = helpText
        self.defaultValue = defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .frame(minWidth: 140, alignment: .leading)
                Spacer()
                Toggle("", isOn: $value)
                    .labelsHidden()
                    .onChange(of: value) { _, newValue in
                        commit(newValue)
                    }
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let stored = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName
        )
        if let stored {
            switch stored.lowercased() {
            case "1", "true", "yes": value = true
            case "0", "false", "no": value = false
            default: value = defaultValue
            }
        } else {
            value = defaultValue
        }
    }

    private func commit(_ newValue: Bool) {
        let asString = newValue ? "true" : "false"
        try? EnvFileStore.upsert(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName,
            value: asString
        )
    }
}

// MARK: - Enum picker row

struct SettingsPickerRow: View {

    let label: String
    let envVarName: String
    let options: [PickerOption]
    let helpText: String?
    let defaultValue: String

    struct PickerOption: Identifiable, Hashable {
        let id: String        // env-var value
        let displayName: String
    }

    @State private var selection: String = ""

    init(
        label: String,
        envVarName: String,
        options: [PickerOption],
        helpText: String? = nil,
        defaultValue: String
    ) {
        self.label = label
        self.envVarName = envVarName
        self.options = options
        self.helpText = helpText
        self.defaultValue = defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .frame(minWidth: 140, alignment: .leading)
                Spacer()
                Picker("", selection: $selection) {
                    ForEach(options) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: selection) { _, newValue in
                    commit(newValue)
                }
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let stored = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName
        )
        let normalised = (stored?.isEmpty == false) ? stored! : defaultValue
        if options.contains(where: { $0.id == normalised }) {
            selection = normalised
        } else {
            selection = defaultValue
        }
    }

    private func commit(_ newValue: String) {
        try? EnvFileStore.upsert(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName,
            value: newValue
        )
    }
}

// MARK: - Numeric (Int) row

struct SettingsIntRow: View {

    let label: String
    let envVarName: String
    let range: ClosedRange<Int>
    let helpText: String?
    let defaultValue: Int?

    @State private var raw: String = ""
    @State private var lastSaved: String = ""
    @State private var saveCounter: Int = 0
    @State private var errorText: String?
    @State private var savedFlash: Bool = false

    init(
        label: String,
        envVarName: String,
        range: ClosedRange<Int>,
        helpText: String? = nil,
        defaultValue: Int? = nil
    ) {
        self.label = label
        self.envVarName = envVarName
        self.range = range
        self.helpText = helpText
        self.defaultValue = defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .frame(minWidth: 140, alignment: .leading)
                TextField(defaultPlaceholder, text: $raw)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit { commit() }
                    .onChange(of: raw) { _, _ in scheduleDebouncedSave() }
                badge
                Spacer()
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var badge: some View {
        if errorText != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if savedFlash {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if raw != lastSaved {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        } else {
            Circle().fill(Color.gray.opacity(0.5)).frame(width: 6, height: 6)
        }
    }

    private var defaultPlaceholder: String {
        if let defaultValue {
            return String(localized: "default \(defaultValue)")
        }
        return String(localized: "(unset)")
    }

    private func reload() {
        let stored = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName
        )
        raw = stored ?? ""
        lastSaved = raw
    }

    private func scheduleDebouncedSave() {
        saveCounter += 1
        let captured = saveCounter
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard captured == saveCounter else { return }
            commit()
        }
    }

    private func commit() {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == lastSaved { return }
        if trimmed.isEmpty {
            try? EnvFileStore.upsert(
                toolName: SettingsConstants.toolAgentsName,
                key: envVarName,
                value: ""
            )
            lastSaved = trimmed
            errorText = nil
            flashSaved()
            return
        }
        guard let parsed = Int(trimmed), range.contains(parsed) else {
            errorText = String(localized: "Must be an integer in \(range.lowerBound)..\(range.upperBound).")
            return
        }
        try? EnvFileStore.upsert(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName,
            value: String(parsed)
        )
        lastSaved = trimmed
        errorText = nil
        flashSaved()
    }

    private func flashSaved() {
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedFlash = false
        }
    }
}

// MARK: - Numeric (Float) row

struct SettingsFloatRow: View {

    let label: String
    let envVarName: String
    let range: ClosedRange<Float>
    let helpText: String?
    let defaultValue: Float?

    @State private var raw: String = ""
    @State private var lastSaved: String = ""
    @State private var saveCounter: Int = 0
    @State private var errorText: String?
    @State private var savedFlash: Bool = false

    init(
        label: String,
        envVarName: String,
        range: ClosedRange<Float>,
        helpText: String? = nil,
        defaultValue: Float? = nil
    ) {
        self.label = label
        self.envVarName = envVarName
        self.range = range
        self.helpText = helpText
        self.defaultValue = defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label)
                    .frame(minWidth: 140, alignment: .leading)
                TextField(defaultPlaceholder, text: $raw)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit { commit() }
                    .onChange(of: raw) { _, _ in scheduleDebouncedSave() }
                badge
                Spacer()
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var badge: some View {
        if errorText != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if savedFlash {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if raw != lastSaved {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        } else {
            Circle().fill(Color.gray.opacity(0.5)).frame(width: 6, height: 6)
        }
    }

    private var defaultPlaceholder: String {
        if let defaultValue {
            return String(localized: "default \(String(format: "%.2f", defaultValue))")
        }
        return String(localized: "(unset)")
    }

    private func reload() {
        let stored = EnvFileStore.read(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName
        )
        raw = stored ?? ""
        lastSaved = raw
    }

    private func scheduleDebouncedSave() {
        saveCounter += 1
        let captured = saveCounter
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard captured == saveCounter else { return }
            commit()
        }
    }

    private func commit() {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == lastSaved { return }
        if trimmed.isEmpty {
            try? EnvFileStore.upsert(
                toolName: SettingsConstants.toolAgentsName,
                key: envVarName,
                value: ""
            )
            lastSaved = trimmed
            errorText = nil
            flashSaved()
            return
        }
        guard let parsed = Float(trimmed), range.contains(parsed) else {
            errorText = String(localized: "Must be a decimal in \(String(format: "%.2f", range.lowerBound))..\(String(format: "%.2f", range.upperBound)).")
            return
        }
        try? EnvFileStore.upsert(
            toolName: SettingsConstants.toolAgentsName,
            key: envVarName,
            value: String(parsed)
        )
        lastSaved = trimmed
        errorText = nil
        flashSaved()
    }

    private func flashSaved() {
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedFlash = false
        }
    }
}

// MARK: - Section header / footer

struct SettingsSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 8)
    }
}

struct SettingsHelperText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}
