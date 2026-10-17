// ntakker/Settings/Sections/GeneralSettingsView.swift —
// "General" tab in the Settings window. See plan-008 Phase 2 (Unit C
// in project-design §UR-10) and project-design §UR-4.5.
//
// Currently exposes a single "Appearance" picker bound to
// `AppearanceMode.userDefaultsKey` (the canonical `@AppStorage` key
// shared with the popover header switcher and the app-level
// `.preferredColorScheme(_:)` modifiers). Future app-wide preferences
// (general behavior toggles, telemetry, etc.) belong in this same
// section.

import SwiftUI
import NtakkerSettingsUI
import NtakkerUIKit

struct GeneralSettingsView: View {

    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceRaw: String = AppearanceMode.defaultRawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsSectionHeader("Appearance")
                Picker(selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImageName)
                            .tag(mode.rawValue)
                    }
                } label: {
                    Text("Theme")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                SettingsHelperText("Choose how the menu-bar popover and Settings window look. 'System' follows your macOS appearance.")

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 480, height: 320)
}
