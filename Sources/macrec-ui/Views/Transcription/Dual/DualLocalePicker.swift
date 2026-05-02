// macrec-ui/Views/Transcription/Dual/DualLocalePicker.swift —
// plan-010 Phase F (Lane L-8); see project-design §DT-8 (UI design,
// "Locale-picker constraints" sub-section) and §DT-9 (AppStorage keys).
//
// Generic locale `Picker` used by the dual-transcription Channel A and
// Channel B rows. The supported-locale set is INJECTED by the caller —
// this view does NOT consult `SFSpeechRecognizer.supportedLocales()` or
// `SpeechTranscriber.supportedLocales` directly. The constraint that
// Channel A draws ONLY from `DualLocaleSets.channelASupportedLocales`
// and Channel B ONLY from `DualLocaleSets.channelBSupportedLocales` is
// enforced at the construction site in `DualTranscriptionControls`.
//
// Why this is a separate view (not `TranscriptionLanguagePicker`):
// `TranscriptionLanguagePicker` hard-codes `SFSpeechRecognizer.supportedLocales()`
// and would erroneously include Greek for Channel A. Sharing the view
// would silently break the design's #1 fragility (plan-010 §DT-13 lane
// notes: "a user picking Greek for the on-device English channel would
// silently fail at session-open").
//
// Display formatting matches `TranscriptionLanguagePicker`: each row
// renders as `Greek (Greece) — el-GR` (language name + region + raw
// identifier suffix) so the user sees both the human-friendly name and
// the BCP-47 tag the engine actually uses.
//
// Disabled while a session is in flight — same lock behaviour as every
// other transcription picker (AC-LT-19 spirit).

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Generic locale picker used by the dual-transcription Channel A and
/// Channel B rows. The caller supplies the `supportedLocales` array
/// (see class header for the asymmetry between the two channels).
struct DualLocalePicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Picker label rendered to the left of the menu (e.g. "Locale").
    let label: String

    /// Caller-supplied supported-locale set. MUST come from
    /// `DualLocaleSets.channelASupportedLocales` for Channel A or
    /// `DualLocaleSets.channelBSupportedLocales` for Channel B — the
    /// view does NOT validate or filter the array further.
    let supportedLocales: [Locale]

    /// `@AppStorage`-bound BCP-47 identifier slot driven by the caller.
    @Binding var selection: String

    /// Optional `help` tooltip override. Falls back to a generic
    /// "Language for this channel" message when nil.
    let help: String?

    init(
        label: String,
        supportedLocales: [Locale],
        selection: Binding<String>,
        help: String? = nil
    ) {
        self.label = label
        self.supportedLocales = supportedLocales
        self._selection = selection
        self.help = help
    }

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    var body: some View {
        Picker(label, selection: $selection) {
            if supportedLocales.isEmpty {
                Text(String(localized: "(no locales available)"))
                    .tag("")
            } else {
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(displayName(for: locale))
                        .tag(locale.identifier)
                }
            }
        }
        .pickerStyle(.menu)
        .disabled(isLocked || supportedLocales.isEmpty)
        .help(help ?? String(localized: "Language for this channel. The on-device asset downloads automatically the first time a new locale is used."))
    }

    // MARK: - Helpers

    /// Render `el-GR` as `Greek (Greece) — el-GR`. Falls back to the
    /// raw identifier if the system can't localise it. Mirrors the
    /// formatting in `TranscriptionLanguagePicker.displayName(for:)`
    /// so the two pickers are visually consistent.
    private func displayName(for locale: Locale) -> String {
        let lang = locale.language.languageCode?.identifier ?? locale.identifier
        let langName = Locale.current.localizedString(forLanguageCode: lang)?
            .capitalized(with: Locale.current)
        let region = locale.language.region?.identifier
        let regionName = region.flatMap {
            Locale.current.localizedString(forRegionCode: $0)
        }
        switch (langName, regionName) {
        case let (lang?, region?):
            return "\(lang) (\(region)) — \(locale.identifier)"
        case let (lang?, nil):
            return "\(lang) — \(locale.identifier)"
        default:
            return locale.identifier
        }
    }
}
