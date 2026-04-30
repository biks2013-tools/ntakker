// macrec-ui/Settings/SettingsRootView.swift —
// Sidebar-style preferences root, attached to the SwiftUI `Settings { … }`
// scene in MacrecUIApp. Opened via ⌘, or via the gear button in the
// popover (which calls `EnvironmentValues.openSettings`).
//
// Scope locked by user direction (2026-04-29): Settings only owns the
// cloud-provider API keys + per-provider tuning knobs. The popover
// keeps the provider picker, source picker, format picker, language
// picker, and the recording defaults (folder, format, layout). The
// two surfaces stay in sync because they read/write the same env vars
// via EnvFileStore + ProcessInfo.

import SwiftUI

/// Sidebar entries. The order is locked: General first (app-wide
/// preferences — theme picker etc.), then Permissions (urgent /
/// first-run signal), then providers in declaration order (matching
/// the popover picker), then Privacy, then About.
enum SettingsCategory: String, Identifiable, CaseIterable, Hashable {
    case general
    case permissions
    case gemini
    case soniox
    case azure
    case azureRealtime
    case elevenlabs
    case privacy
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:       return String(localized: "General")
        case .permissions:   return String(localized: "Permissions")
        case .gemini:        return String(localized: "Gemini")
        case .soniox:        return String(localized: "Soniox")
        case .azure:         return String(localized: "Azure OpenAI")
        case .azureRealtime: return String(localized: "Azure OpenAI Realtime")
        case .elevenlabs:    return String(localized: "ElevenLabs")
        case .privacy:       return String(localized: "Privacy")
        case .about:         return String(localized: "About")
        }
    }

    var systemIcon: String {
        switch self {
        case .general:       return "gearshape"
        case .permissions:   return "checkmark.shield"
        case .gemini:        return "sparkles"
        case .soniox:        return "waveform.path"
        case .azure:         return "cloud"
        case .azureRealtime: return "cloud.bolt"
        case .elevenlabs:    return "mic.badge.plus"
        case .privacy:       return "lock.shield"
        case .about:         return "info.circle"
        }
    }
}

struct SettingsRootView: View {

    /// Persisted across launches so reopening Settings lands the user
    /// on the section they last edited.
    @AppStorage("com.macrec.ui.settings.selectedCategory")
    private var selectedRaw: String = SettingsCategory.general.rawValue

    private var selected: SettingsCategory {
        SettingsCategory(rawValue: selectedRaw) ?? .general
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: Binding<SettingsCategory>(
                get: { selected },
                set: { selectedRaw = $0.rawValue }
            )) { category in
                Label(category.displayName, systemImage: category.systemIcon)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView(for: selected)
                .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 540)
    }

    @ViewBuilder
    private func detailView(for category: SettingsCategory) -> some View {
        switch category {
        case .general:       GeneralSettingsView()
        case .permissions:   PermissionsSettingsView()
        case .gemini:        GeminiSettingsView()
        case .soniox:        SonioxSettingsView()
        case .azure:         AzureBatchSettingsView()
        case .azureRealtime: AzureRealtimeSettingsView()
        case .elevenlabs:    ElevenLabsSettingsView()
        case .privacy:       PrivacySettingsView()
        case .about:         AboutSettingsView()
        }
    }
}
