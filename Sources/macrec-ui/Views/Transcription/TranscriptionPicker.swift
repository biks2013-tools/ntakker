// macrec-ui/Views/Transcription/TranscriptionPicker.swift — see
// project-design.md §LT-8.1 / §LT-8.3 and plan-003 Phase G, updated
// for plan-004 Phase H (provider rename) and plan-005 Phase H
// (Apple Speech option, default selection).
//
// SwiftUI `Picker` over the live-transcription provider choice. v1.5
// surfaces:
//
//   * `Apple Speech (on-device)` — `apple` provider (streaming, on-device);
//                                   the new default. No API key required.
//   * `Gemini (cloud)` — `gemini` provider (rest-batch); greys out / shows
//                the missing-key affordance when GOOGLE_API_KEY is not
//                resolved (FR-53; design §LT-8.3).
//   * `None`   — transcription disabled.
//
// Persistence: the chosen provider is stored under the canonical
// `com.macrec.ui.transcribeProvider` UserDefaults key. The
// `RecordingController.options.transcriptionProviderId` is mirrored
// from this on each `setOptions(_:)` call from the popover root view.
// Existing users with persisted `"gemini-live"` values are handled by
// the resolver's deprecation alias — no migration code needed here.
//
// Disabled-while-recording: transcription provider cannot be changed
// after the recording starts (AC-LT-19). Locked the same way
// `FormatPicker` locks during a session.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Picker for the live-transcription provider. Drives the picker via
/// the `RecordingController`'s `options.transcriptionProviderId`
/// indirectly through the `@AppStorage`-backed `providerRaw` slot,
/// which is read by `RootView` when it builds the `RecordingOptions`.
struct TranscriptionPicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted provider id. `"apple"` (default, plan-005 Phase H)
    /// selects the on-device Apple Speech streaming provider; `"gemini"`
    /// selects the v1 rest-batch provider; `"none"` disables
    /// transcription. Persisted `"gemini-live"` values from a previous
    /// release are accepted by the resolver as a deprecated alias.
    @AppStorage("com.macrec.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    /// Whether the picker should be disabled because a session is
    /// already running.
    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// The resolved API-key state from the controller. The controller
    /// flips this to `true` when `transcriptionProviderId != .none`
    /// AND `transcriptionApiKey == nil`. The badge / tooltip are
    /// driven from this.
    private var missingKey: Bool {
        recordingController?.transcriptionMissingKey ?? false
    }

    /// Exposed for tests so they can inspect the resolved tooltip.
    static let missingKeyTooltip =
        "Set GOOGLE_API_KEY in ~/.tool-agents/macrec-ui/.env"

    var body: some View {
        HStack(spacing: 6) {
            Picker(String(localized: "Transcribe"), selection: $providerRaw) {
                Text("Apple Speech (on-device)").tag("apple")
                Text("WhisperKit (on-device, multilingual)").tag("whisperkit")
                Text("Gemini (cloud)").tag("gemini")
                Text("None").tag("none")
            }
            .pickerStyle(.menu)
            .disabled(isLocked)
            .help(String(localized: "Live transcription provider for the next recording. WhisperKit is on-device and supports ~99 languages including Greek; Apple Speech is also on-device but limited to locales whose model Apple has shipped to your Mac; Gemini is cloud and requires an API key."))

            // Missing-key affordance — small red-dot badge with the
            // tooltip text. Only visible when the picker selection
            // requires a key but none is resolved.
            if missingKey {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .help(Self.missingKeyTooltip)
            }
        }
    }
}
