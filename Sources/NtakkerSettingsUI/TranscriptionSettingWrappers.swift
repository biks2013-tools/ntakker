// NtakkerSettingsUI/TranscriptionSettingWrappers.swift — plan-025.
//
// ntakker's popover keeps "transcription on/off", "which provider" and
// three language slots; the shared file has one `NTAKKER_TRANSCRIBE`
// (provider id, or `none` = off) and one comma-separated
// `NTAKKER_TRANSCRIBE_LANGUAGE`, the names the CLI reads. These wrappers
// present the file in the popover's shape. Unset `NTAKKER_TRANSCRIBE`
// means Apple on-device, as in the CLI.

import Foundation
import NtakkerCore
import SwiftUI

@MainActor
enum TranscriptionChoice {
    static let defaultProvider = TranscriptionProviderId.apple.rawValue
    /// The provider to restore when transcription is switched back on
    /// (UI memory, not a setting: kept in the app's preferences).
    static let lastProviderKey = "com.ntakker-cli.ui.lastTranscribeProvider"

    static var raw: String {
        SharedSettingsStore.shared.string(SharedSettings.Keys.transcribe) ?? defaultProvider
    }
    static var enabled: Bool { raw.lowercased() != "none" }
    static var provider: String {
        enabled ? raw : (UserDefaults.standard.string(forKey: lastProviderKey) ?? defaultProvider)
    }
    static func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on {
            SharedSettingsStore.shared.set(SharedSettings.Keys.transcribe, provider)
        } else {
            UserDefaults.standard.set(raw, forKey: lastProviderKey)
            SharedSettingsStore.shared.set(SharedSettings.Keys.transcribe, "none")
        }
    }
    static func setProvider(_ id: String) {
        if enabled {
            SharedSettingsStore.shared.set(SharedSettings.Keys.transcribe, id)
        } else {
            UserDefaults.standard.set(id, forKey: lastProviderKey)
        }
    }
}

/// Transcription on/off (`NTAKKER_TRANSCRIBE` is not `none`).
@MainActor @propertyWrapper
public struct SharedTranscriptionEnabled: DynamicProperty {
    public init(wrappedValue: Bool) {}
    public var wrappedValue: Bool {
        get { TranscriptionChoice.enabled }
        nonmutating set { TranscriptionChoice.setEnabled(newValue) }
    }
    public var projectedValue: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// The chosen provider, kept while transcription is off.
@MainActor @propertyWrapper
public struct SharedTranscriptionProvider: DynamicProperty {
    public init(wrappedValue: String) {}
    public var wrappedValue: String {
        get { TranscriptionChoice.provider }
        nonmutating set { TranscriptionChoice.setProvider(newValue) }
    }
    public var projectedValue: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// Slot `index` (0, 1, 2) of the comma-separated language list.
@MainActor @propertyWrapper
public struct SharedLanguageSlot: DynamicProperty {
    private let index: Int
    public init(wrappedValue: String, _ index: Int) { self.index = index }

    static func slots() -> [String] {
        let list = (SharedSettingsStore.shared.string(SharedSettings.Keys.transcribeLanguage) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (0..<3).map { $0 < list.count ? list[$0] : "" }
    }

    public var wrappedValue: String {
        get { Self.slots()[index] }
        nonmutating set {
            var s = Self.slots()
            s[index] = newValue.trimmingCharacters(in: .whitespaces)
            var seen: Set<String> = []
            let list = s.filter { !$0.isEmpty && seen.insert($0).inserted }
            SharedSettingsStore.shared.set(SharedSettings.Keys.transcribeLanguage, list.joined(separator: ","))
        }
    }
    public var projectedValue: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
