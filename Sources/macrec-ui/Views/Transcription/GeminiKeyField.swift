// macrec-ui/Views/Transcription/GeminiKeyField.swift
//
// SecureField + Save button for the Gemini provider's API key. Lives
// inside the "Live transcription" disclosure group in `RootView` and
// is only visible when the user has selected the `gemini` (or
// deprecated `gemini-live`) provider.
//
// Storage: `EnvFileStore.upsert(toolName: "macrec-ui",
// key: "GOOGLE_API_KEY", value: <typed>)` — writes to
// `~/.tool-agents/macrec-ui/.env` at mode 0600 AND `setenv`'s the new
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

import MacrecCore
import MacrecUIKit
import SwiftUI

/// SecureField + Save row for the Gemini API key. Only the user-
/// initiated Save persists; typing into the field does NOT touch
/// disk so the user can correct typos before committing.
struct GeminiKeyField: View {

    /// `AppDelegate.toolAgentsName`. Re-declared here so the view
    /// does not have to reach across the app target boundary.
    private static let toolAgentsName = "macrec-ui"

    /// The well-known env-var the rest of the codebase reads. See
    /// `ControlBar.startTapped()` and the documented four-tier
    /// resolution chain in `~/.tool-agents/macrec-ui/.env`.
    private static let envVarKey = "GOOGLE_API_KEY"

    /// Provider id slot — same `@AppStorage` key the picker writes to.
    /// Used to gate visibility (we only render when the user has
    /// selected a Gemini variant).
    @AppStorage("com.macrec.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    /// Field text. Seeded from the on-disk value on first appear so
    /// the user sees the existing key length (and can decide to leave
    /// it or replace it). We use `SecureField` so the characters are
    /// dot-masked.
    @State private var typed: String = ""

    /// Whether the on-disk file currently has a non-empty value for
    /// `GOOGLE_API_KEY`. Drives the green/red status dot. Refreshed on
    /// appear and after Save.
    @State private var hasStoredKey: Bool = false

    /// Transient feedback message after Save / Clear. Auto-clears
    /// after a short delay so the popover does not accumulate stale
    /// status text.
    @State private var feedback: String?

    var body: some View {
        // Only render when the picker has selected a Gemini variant.
        // Apple Speech is on-device and does not need a key.
        let normalised = providerRaw.lowercased()
        if normalised == "gemini" || normalised == "gemini-live" {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(String(localized: "Gemini API key"))
                        .font(.subheadline)
                    Circle()
                        .fill(hasStoredKey ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .help(hasStoredKey
                              ? String(localized: "Key is set in ~/.tool-agents/macrec-ui/.env")
                              : String(localized: "No key on file. Paste your Gemini key and click Save."))
                    Spacer()
                }

                HStack(spacing: 6) {
                    SecureField(
                        String(localized: "Paste GOOGLE_API_KEY value"),
                        text: $typed
                    )
                    .textFieldStyle(.roundedBorder)
                    .help(String(localized: "Stored at ~/.tool-agents/macrec-ui/.env (mode 0600). Used until you change it."))

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
