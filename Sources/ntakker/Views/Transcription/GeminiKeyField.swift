// ntakker/Views/Transcription/GeminiKeyField.swift —
// updated for plan-008 Unit D (API-key field redesign).
//
// SecureField + Save button for the Gemini provider's API key. Lives
// inside the "Live transcription" disclosure group in `RootView` and
// is only visible when the user has selected the `gemini` (or
// deprecated `gemini-live`) provider.
//
// Storage: `EnvFileStore.upsert(toolName: "ntakker",
// key: "GOOGLE_API_KEY", value: <typed>)` — writes to
// `~/.tool-agents/ntakker/.env` at mode 0600 AND `setenv`'s the new
// value into the running process so the very next `Start` reads it
// out of `ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]` (the
// existing wiring in `ControlBar.startTapped`). No app restart needed.
//
// Persistence rule: the on-disk file IS the source of truth — the key
// survives across launches "until the user changes it" (per the user
// request). At app launch `AppDelegate` calls
// `EnvFileStore.loadIntoProcess(toolName:)` which seeds the merged
// keys into `ProcessInfo`.
//
// Note on `RecordingController.transcriptionMissingKey` invalidation:
// the controller's flag is recomputed inside `setOptions(_:)`, which
// is called by `RootView` whenever the user clicks Start (the entire
// `RecordingOptions` is re-composed at that point). So the missing-key
// dot in `TranscriptionPicker` automatically picks up the new key the
// next time the popover reads it.
//
// plan-008 Unit D: the inline Save / Clear UI is replaced by
// `ApiKeyStatusRow` which renders the locked-in v1.6 design
// (chip + collapsed dotted state + Replace…/Save/Cancel flow). The
// key-resolution and persistence calls below are unchanged.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// SecureField + Save row for the Gemini API key. Only the user-
/// initiated Save persists; typing into the field does NOT touch
/// disk so the user can correct typos before committing.
struct GeminiKeyField: View {

    /// `AppDelegate.toolAgentsName`. Re-declared here so the view
    /// does not have to reach across the app target boundary.
    private static let toolAgentsName = "ntakker"

    /// The well-known env-var the rest of the codebase reads. See
    /// `ControlBar.startTapped()` and the documented four-tier
    /// resolution chain in `~/.tool-agents/ntakker/.env`.
    private static let envVarKey = "GOOGLE_API_KEY"

    /// Provider id slot — same `@AppStorage` key the picker writes to.
    /// Used to gate visibility (we only render when the user has
    /// selected a Gemini variant).
    @AppStorage("com.ntakker-cli.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    /// Cached on-disk value used by `ApiKeyStatusRow` to decide
    /// "Configured" vs "Not configured". Refreshed on appear and
    /// after every Save / Clear.
    @State private var resolvedKey: String?

    var body: some View {
        // Only render when the picker has selected a Gemini variant.
        // Apple Speech is on-device and does not need a key.
        let normalised = providerRaw.lowercased()
        if normalised == "gemini" || normalised == "gemini-live" {
            ApiKeyStatusRow(
                providerDisplayName: "Gemini",
                resolvedKey: resolvedKey,
                editPlaceholder: String(localized: "Paste GOOGLE_API_KEY value"),
                onSave: { newValue in save(newValue) },
                onClear: { clear() }
            )
            .onAppear { refreshFromDisk() }
        }
    }

    // MARK: - Actions

    /// Read the on-disk value to refresh `resolvedKey`. The actual
    /// value is held only in memory so the chip can show
    /// "Configured" / "Not configured"; it is never echoed back into
    /// any visible text field — the masked-dots state in
    /// `ApiKeyStatusRow` is the only on-screen affordance.
    private func refreshFromDisk() {
        resolvedKey = EnvFileStore.read(
            toolName: Self.toolAgentsName,
            key: Self.envVarKey
        )
    }

    private func save(_ trimmed: String) {
        do {
            try EnvFileStore.upsert(
                toolName: Self.toolAgentsName,
                key: Self.envVarKey,
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
                key: Self.envVarKey,
                value: ""
            )
            resolvedKey = nil
        } catch {
            refreshFromDisk()
        }
    }
}
