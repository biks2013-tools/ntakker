// macrec-ui/Settings/Sections/PermissionsSettingsView.swift —
// macOS TCC permission status panel for the Settings window.
//
// Reuses `PermissionStatusView` in `.always` mode so the rows render
// regardless of grant state — useful as a verification surface when
// the popover variant (`.onlyWhenIssues`) has hidden itself.

import SwiftUI

struct PermissionsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Permissions")
                    .font(.title2).bold()
                    .padding(.bottom, 4)

                SettingsHelperText(
                    "macrec needs Screen Recording (system audio capture via ScreenCaptureKit) and Microphone (input capture via AVFoundation). Both grants are bundle-id-bound — granting them to macrec-ui does NOT also grant them to the macrec CLI binary, and vice versa."
                )

                SettingsSectionHeader("Status")
                PermissionStatusView(visibility: .always)
                    .padding(.vertical, 4)

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("If a grant looks stuck")
                Text("If you previously denied a permission, the system prompt will not re-appear automatically — click 'Open Settings' next to the row to jump straight to the relevant System Settings → Privacy & Security panel and toggle macrec-ui on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("After flipping a switch in System Settings, macOS may ask you to relaunch macrec-ui for the new grant to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                SettingsSectionHeader("Reset (advanced)")
                Text("To force the system prompts to re-appear from scratch, run in Terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("tccutil reset ScreenCapture com.local.macrec-ui\ntccutil reset Microphone com.local.macrec-ui")
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                    .textSelection(.enabled)
                Text("Then quit and relaunch macrec-ui.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
