// macrec-ui/Views/Transcription/SonioxKeyField.swift — plan-006 follow-up,
// updated for plan-008 Unit D (API-key field redesign).
//
// SecureField + Save button for the Soniox provider's API key. Lives
// inside the "Live transcription" disclosure group in `RootView` and
// is only visible when the user has selected the `soniox` provider.
//
// Storage: `EnvFileStore.upsert(toolName: "macrec-ui",
// key: "SONIOX_API_KEY", value: <typed>)` — writes to
// `~/.tool-agents/macrec-ui/.env` at mode 0600 AND `setenv`'s the new
// value into the running process so the very next `Start` reads it
// out of `ProcessInfo.processInfo.environment["SONIOX_API_KEY"]` (the
// existing wiring in `ControlBar.startTapped`). No app restart needed.
//
// Persistence rule: the on-disk file IS the source of truth — the key
// survives across launches "until the user changes it" (per the user
// request). At app launch `AppDelegate` calls
// `EnvFileStore.loadIntoProcess(toolName:)` which seeds the merged
// keys into `ProcessInfo`.
//
// plan-008 Unit D: the inline Save / Clear UI is replaced by
// `ApiKeyStatusRow` which renders the locked-in v1.6 design
// (chip + collapsed dotted state + Replace…/Save/Cancel flow). The
// key-resolution and persistence calls below are unchanged.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// SecureField + Save row for the Soniox API key. Only the user-
/// initiated Save persists; typing into the field does NOT touch
/// disk so the user can correct typos before committing.
struct SonioxKeyField: View {

    /// `AppDelegate.toolAgentsName`. Re-declared here so the view
    /// does not have to reach across the app target boundary.
    private static let toolAgentsName = "macrec-ui"

    /// The vendor-canonical env var the rest of the codebase reads
    /// (see `ConfigResolver.Keys.sonioxApiKey`). Resolved through
    /// the four-tier chain in `~/.tool-agents/macrec-ui/.env`.
    private static let envVarKey = "SONIOX_API_KEY"

    /// Provider id slot — same `@AppStorage` key the picker writes to.
    /// Used to gate visibility (we only render when the user has
    /// selected the Soniox provider).
    @AppStorage("com.macrec.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    /// Cached on-disk value used by `ApiKeyStatusRow` to decide
    /// "Configured" vs "Not configured". Refreshed on appear and
    /// after every Save / Clear. We store the actual value (not just
    /// a Bool) so a future plan can extend the chip with metadata
    /// derived from the key without reshaping this view.
    @State private var resolvedKey: String?

    var body: some View {
        // Only render when the picker has selected the Soniox provider.
        if providerRaw.lowercased() == "soniox" {
            ApiKeyStatusRow(
                providerDisplayName: "Soniox",
                resolvedKey: resolvedKey,
                editPlaceholder: String(localized: "Paste SONIOX_API_KEY value"),
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
            // Persistence failed — refresh from disk so the chip
            // reflects whatever IS on disk (likely the prior value).
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
