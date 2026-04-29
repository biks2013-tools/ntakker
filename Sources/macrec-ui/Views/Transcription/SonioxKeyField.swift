// macrec-ui/Views/Transcription/SonioxKeyField.swift — plan-006 follow-up
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
// Mirrors `GeminiKeyField.swift` 1:1 — only the env-var name, the
// localized labels, and the provider-id gate differ.

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

    /// Field text. We use `SecureField` so the characters are
    /// dot-masked. The on-disk value is NOT seeded into the field —
    /// pre-filling a secret defeats the masking. The dot indicator
    /// is the single signal of "yes, a key is set".
    @State private var typed: String = ""

    /// Whether the on-disk file currently has a non-empty value for
    /// `SONIOX_API_KEY`. Drives the green/red status dot. Refreshed on
    /// appear and after Save / Clear.
    @State private var hasStoredKey: Bool = false

    /// Transient feedback message after Save / Clear. Auto-clears
    /// after a short delay so the popover does not accumulate stale
    /// status text.
    @State private var feedback: String?

    var body: some View {
        // Only render when the picker has selected the Soniox provider.
        if providerRaw.lowercased() == "soniox" {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(String(localized: "Soniox API key"))
                        .font(.subheadline)
                    Circle()
                        .fill(hasStoredKey ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .help(hasStoredKey
                              ? String(localized: "Key is set in ~/.tool-agents/macrec-ui/.env")
                              : String(localized: "No key on file. Paste your Soniox key (from console.soniox.com) and click Save."))
                    Spacer()
                }

                HStack(spacing: 6) {
                    SecureField(
                        String(localized: "Paste SONIOX_API_KEY value"),
                        text: $typed
                    )
                    .textFieldStyle(.roundedBorder)
                    .help(String(localized: "Stored at ~/.tool-agents/macrec-ui/.env (mode 0600). Used until you change it. Get a key at https://console.soniox.com."))

                    Button(String(localized: "Save")) {
                        save()
                    }
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(String(localized: "Persist the key to ~/.tool-agents/macrec-ui/.env."))

                    if hasStoredKey {
                        Button(String(localized: "Clear")) {
                            clear()
                        }
                        .help(String(localized: "Remove the stored key from ~/.tool-agents/macrec-ui/.env."))
                    }
                }

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { refreshFromDisk() }
        }
    }

    // MARK: - Actions

    /// Read the on-disk value to refresh `hasStoredKey`. The value
    /// itself is NOT placed back into the SecureField — pre-filling a
    /// secret field defeats the masking. The dot indicator is the
    /// single signal of "yes, a key is set".
    private func refreshFromDisk() {
        let stored = EnvFileStore.read(
            toolName: Self.toolAgentsName,
            key: Self.envVarKey
        )
        hasStoredKey = (stored != nil)
    }

    private func save() {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try EnvFileStore.upsert(
                toolName: Self.toolAgentsName,
                key: Self.envVarKey,
                value: trimmed
            )
            typed = ""
            hasStoredKey = true
            showFeedback(String(localized: "Saved. The key takes effect on the next Start."))
        } catch {
            showFeedback(String(localized: "Save failed: \(error.localizedDescription)"))
        }
    }

    private func clear() {
        do {
            try EnvFileStore.upsert(
                toolName: Self.toolAgentsName,
                key: Self.envVarKey,
                value: ""
            )
            typed = ""
            hasStoredKey = false
            showFeedback(String(localized: "Key removed."))
        } catch {
            showFeedback(String(localized: "Clear failed: \(error.localizedDescription)"))
        }
    }

    private func showFeedback(_ message: String) {
        feedback = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Only clear if the message is still the same one we set
            // — a more recent Save may have superseded it.
            if feedback == message {
                feedback = nil
            }
        }
    }
}
