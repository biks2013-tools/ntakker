// ntakker/Views/Transcription/ProviderKeyField.swift —
// plan-007 Phase 0 / Task 0.4, updated for plan-008 Unit D
// (API-key field redesign).
//
// Generic SecureField + Save row for any provider's API key. Lifts the
// exact UX of `GeminiKeyField` and `SonioxKeyField` (which mirror each
// other 1:1 today) so plan-007 can render Azure OpenAI and ElevenLabs
// key fields without copy-pasting the same 100-line view a third and
// fourth time.
//
// Storage: `EnvFileStore.upsert(toolName: "ntakker",
// key: <envVarName>, value: <typed>)` — writes to
// `~/.tool-agents/ntakker/.env` at mode 0600 AND `setenv`'s the new
// value into the running process so the very next `Start` reads it
// out of `ProcessInfo.processInfo.environment[<envVarName>]` (the
// existing wiring in `ControlBar.startTapped`). No app restart needed.
//
// Caller responsibility: the parent view (`RootView`) decides when to
// render `ProviderKeyField` based on the active provider id — this
// view does NOT gate its own visibility on the picker selection. That
// keeps the view single-purpose and easy to test.
//
// plan-008 Unit D: the inline Save / Clear UI is replaced by
// `ApiKeyStatusRow` which renders the locked-in v1.6 design
// (chip + collapsed dotted state + Replace…/Save/Cancel flow). The
// key-resolution and persistence calls below are unchanged.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// SecureField + Save / Clear row for a provider's API key. Renders
/// only the secure input + status chip + buttons; visibility gating
/// (e.g. "only when picker == 'azure'") is the parent's job.
struct ProviderKeyField: View {

    /// `AppDelegate.toolAgentsName`. Re-declared here so the view
    /// does not have to reach across the app target boundary.
    private static let toolAgentsName = "ntakker"

    /// The provider this field belongs to (e.g. `"azure"`, `"elevenlabs"`).
    /// Used only for log strings / accessibility identifiers — the
    /// env-var name is the authoritative identifier.
    let providerId: String

    /// The well-known env-var the rest of the codebase reads
    /// (e.g. `"AZURE_OPENAI_API_KEY"`, `"ELEVENLABS_API_KEY"`).
    let envVarName: String

    /// Localised label rendered above the field (e.g.
    /// "Azure OpenAI API key"). The leading provider name (everything
    /// before " API key") is used as the chip header.
    let displayLabel: String

    /// Optional vendor sign-up URL — surfaces in the placeholder /
    /// help-tooltip when the field is empty so a first-time user can
    /// click through to obtain a key.
    let helpURL: URL?

    /// Cached on-disk value used by `ApiKeyStatusRow` to decide
    /// "Configured" vs "Not configured". Refreshed on appear and
    /// after every Save / Clear.
    @State private var resolvedKey: String?

    var body: some View {
        ApiKeyStatusRow(
            providerDisplayName: providerDisplayName,
            resolvedKey: resolvedKey,
            editPlaceholder: String(localized: "Paste \(envVarName) value"),
            onSave: { newValue in save(newValue) },
            onClear: { clear() }
        )
        .accessibilityIdentifier("ProviderKeyField.\(providerId).row")
        .onAppear { refreshFromDisk() }
    }

    // MARK: - Computed copy

    /// Strip the trailing "API key" / "API Key" suffix from
    /// `displayLabel` so the chip header (which appends "API KEY"
    /// itself) does not double up.
    private var providerDisplayName: String {
        let trimmed = displayLabel.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasSuffix(" api key") {
            return String(trimmed.dropLast(" api key".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: - Actions

    /// Read the on-disk value to refresh `resolvedKey`. The actual
    /// value is held only in memory so the chip can show
    /// "Configured" / "Not configured"; it is never echoed back into
    /// any visible text field.
    private func refreshFromDisk() {
        resolvedKey = EnvFileStore.read(
            toolName: Self.toolAgentsName,
            key: envVarName
        )
    }

    private func save(_ trimmed: String) {
        do {
            try EnvFileStore.upsert(
                toolName: Self.toolAgentsName,
                key: envVarName,
                value: trimmed
            )
            resolvedKey = trimmed
        } catch {
            refreshFromDisk()
        }
    }

    private func clear() {
        do {
            try EnvFileStore.upsert(
                toolName: Self.toolAgentsName,
                key: envVarName,
                value: ""
            )
            resolvedKey = nil
        } catch {
            refreshFromDisk()
        }
    }
}
