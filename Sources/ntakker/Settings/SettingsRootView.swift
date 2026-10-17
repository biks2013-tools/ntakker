// ntakker/Settings/SettingsRootView.swift —
// The Settings window (⌘, or the popover's gear). Since plan-025 it is the
// shared settings view: every setting ntakker, ntakker-cli and ntakker
// studio share (recording, transcription, Ask, providers, studio), stored
// in ~/.tool-agents/ntakker/.env, with ntakker's own panes around them.

import NtakkerSettingsUI
import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        SharedSettingsView(
            leading: [
                SettingsPane(id: "general", title: "General", systemImage: "gearshape") { GeneralSettingsView() },
                SettingsPane(id: "permissions", title: "Permissions", systemImage: "checkmark.shield") { PermissionsSettingsView() },
            ],
            trailing: [
                SettingsPane(id: "predefinedQuestions", title: "Predefined Questions", systemImage: "text.bubble") { PredefinedQuestionsSettingsView() },
                SettingsPane(id: "privacy", title: "Privacy", systemImage: "lock.shield") { PrivacySettingsView() },
                SettingsPane(id: "about", title: "About", systemImage: "info.circle") { AboutSettingsView() },
            ],
            selectionKey: "com.ntakker-cli.ui.settings.selectedPane"
        )
    }
}
