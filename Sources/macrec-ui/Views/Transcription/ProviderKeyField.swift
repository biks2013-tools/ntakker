// macrec-ui/Views/Transcription/ProviderKeyField.swift —
// plan-007 Phase 0 / Task 0.4.
//
// Generic SecureField + Save row for any provider's API key. Lifts the
// exact UX of `GeminiKeyField` and `SonioxKeyField` (which mirror each
// other 1:1 today) so plan-007 can render Azure OpenAI and ElevenLabs
// key fields without copy-pasting the same 100-line view a third and
// fourth time.
//
// Storage: `EnvFileStore.upsert(toolName: "macrec-ui",
// key: <envVarName>, value: <typed>)` — writes to
// `~/.tool-agents/macrec-ui/.env` at mode 0600 AND `setenv`'s the new
// value into the running process so the very next `Start` reads it
// out of `ProcessInfo.processInfo.environment[<envVarName>]` (the
// existing wiring in `ControlBar.startTapped`). No app restart needed.
//
// Caller responsibility: the parent view (`RootView`) decides when to
// render `ProviderKeyField` based on the active provider id — this
// view does NOT gate its own visibility on the picker selection. That
// keeps the view single-purpose and easy to test.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// SecureField + Save / Clear row for a provider's API key. Renders
/// only the secure input + status dot + buttons; visibility gating
/// (e.g. "only when picker == 'azure'") is the parent's job.
struct ProviderKeyField: View {

    /// `AppDelegate.toolAgentsName`. Re-declared here so the view
    /// does not have to reach across the app target boundary.
    private static let toolAgentsName = "macrec-ui"

    /// The provider this field belongs to (e.g. `"azure"`, `"elevenlabs"`).
    /// Used only for log strings / accessibility identifiers — the
    /// env-var name is the authoritative identifier.
    let providerId: String

    /// The well-known env-var the rest of the codebase reads
    /// (e.g. `"AZURE_OPENAI_API_KEY"`, `"ELEVENLABS_API_KEY"`).
    let envVarName: String

    /// Localised label rendered above the field (e.g.
    /// "Azure OpenAI API key").
    let displayLabel: String

    /// Optional vendor sign-up URL — surfaces in the placeholder /
    /// help-tooltip when the field is empty so a first-time user can
    /// click through to obtain a key.
    let helpURL: URL?

    /// Field text. We use `SecureField` so the characters are
    /// dot-masked. The on-disk value is NOT seeded into the field —
    /// pre-filling a secret defeats the masking. The dot indicator
    /// is the single signal of "yes, a key is set".
    @State private var typed: String = ""

    /// Whether the on-disk file currently has a non-empty value for
    /// `envVarName`. Drives the green/red status dot. Refreshed on
    /// appear and after Save / Clear.
    @State private var hasStoredKey: Bool = false

    /// Transient feedback message after Save / Clear. Auto-clears
    /// after a short delay so the popover does not accumulate stale
    /// status text.
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(displayLabel)
                    .font(.subheadline)
                Circle()
                    .fill(hasStoredKey ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .help(hasStoredKey
                          ? String(localized: "Key is set in ~/.tool-agents/macrec-ui/.env")
                          : noKeyHelpText)
                Spacer()
            }

            HStack(spacing: 6) {
                SecureField(
                    String(localized: "Paste \(envVarName) value"),
                    text: $typed
                )
                .textFieldStyle(.roundedBorder)
                .help(helpTooltip)
                .accessibilityIdentifier("ProviderKeyField.\(providerId).field")

                Button(String(localized: "Save")) {
                    save()
                }
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(String(localized: "Persist the key to ~/.tool-agents/macrec-ui/.env."))
                .accessibilityIdentifier("ProviderKeyField.\(providerId).save")

                if hasStoredKey {
                    Button(String(localized: "Clear")) {
                        clear()
                    }
                    .help(String(localized: "Remove the stored key from ~/.tool-agents/macrec-ui/.env."))
                    .accessibilityIdentifier("ProviderKeyField.\(providerId).clear")
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

    // MARK: - Computed copy

    private var noKeyHelpText: String {
        if let helpURL {
            return String(localized: "No key on file. Get one at \(helpURL.absoluteString) and click Save.")
        }
        return String(localized: "No key on file. Paste your \(envVarName) value and click Save.")
    }

    private var helpTooltip: String {
        if let helpURL {
            return String(localized: "Stored at ~/.tool-agents/macrec-ui/.env (mode 0600). Used until you change it. Get a key at \(helpURL.absoluteString).")
        }
        return String(localized: "Stored at ~/.tool-agents/macrec-ui/.env (mode 0600). Used until you change it.")
    }

    // MARK: - Actions

    /// Read the on-disk value to refresh `hasStoredKey`. The value
    /// itself is NOT placed back into the SecureField — pre-filling a
    /// secret field defeats the masking.
    private func refreshFromDisk() {
        let stored = EnvFileStore.read(
            toolName: Self.toolAgentsName,
            key: envVarName
        )
        hasStoredKey = (stored != nil)
    }

    private func save() {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try EnvFileStore.upsert(
                toolName: Self.toolAgentsName,
                key: envVarName,
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
                key: envVarName,
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
