// macrec-ui/Settings/Sections/PrivacySettingsView.swift —
// Per-provider privacy disclosure acknowledgement state, with a Reset
// button per provider so the user can re-trigger the dialog (useful
// for demos or when switching machines).

import SwiftUI

struct PrivacySettingsView: View {

    private let providers: [(id: String, displayName: String)] = [
        ("gemini", "Gemini"),
        ("soniox", "Soniox"),
        ("azure", "Azure OpenAI (batch)"),
        ("azure-openai-realtime", "Azure OpenAI (realtime)"),
        ("elevenlabs", "ElevenLabs Scribe v2")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Privacy")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsHelperText(
                    "Each cloud provider's privacy disclosure is acknowledged once per provider — switching from one cloud vendor to another (or from Azure batch to Azure realtime) re-shows the dialog with that vendor's data-residency posture. Click Reset to re-trigger the dialog on next selection."
                )

                ForEach(providers, id: \.id) { provider in
                    HStack(spacing: 12) {
                        Text(provider.displayName)
                            .frame(minWidth: 220, alignment: .leading)
                        statusBadge(for: provider.id)
                        Spacer()
                        Button(String(localized: "Reset")) {
                            reset(provider.id)
                        }
                        .disabled(!hasAcknowledged(provider.id))
                    }
                    .padding(.vertical, 4)
                    Divider()
                }

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusBadge(for providerId: String) -> some View {
        if hasAcknowledged(providerId) {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Acknowledged").foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text("Not acknowledged").foregroundStyle(.secondary)
            }
        }
    }

    private func hasAcknowledged(_ providerId: String) -> Bool {
        let key = PrivacyDisclosureViewModel.acknowledgedKey(for: providerId)
        if UserDefaults.standard.bool(forKey: key) { return true }
        // Legacy keys, in case the migration has not run yet (e.g. the
        // viewmodel singleton hasn't been instantiated this launch).
        if providerId == "gemini",
           UserDefaults.standard.bool(forKey: PrivacyDisclosureViewModel.userDefaultsKey)
        {
            return true
        }
        if providerId == "soniox",
           UserDefaults.standard.bool(forKey: PrivacyDisclosureViewModel.sonioxUserDefaultsKey)
        {
            return true
        }
        return false
    }

    private func reset(_ providerId: String) {
        UserDefaults.standard.removeObject(
            forKey: PrivacyDisclosureViewModel.acknowledgedKey(for: providerId)
        )
        // Also clear legacy keys so the disclosure surfaces again.
        if providerId == "gemini" {
            UserDefaults.standard.removeObject(forKey: PrivacyDisclosureViewModel.userDefaultsKey)
        }
        if providerId == "soniox" {
            UserDefaults.standard.removeObject(forKey: PrivacyDisclosureViewModel.sonioxUserDefaultsKey)
        }
    }
}
