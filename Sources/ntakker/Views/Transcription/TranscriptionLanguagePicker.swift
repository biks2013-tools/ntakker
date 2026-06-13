// ntakker/Views/Transcription/TranscriptionLanguagePicker.swift
//
// SwiftUI picker for the transcription language(s). Lists every locale
// `SFSpeechRecognizer.supportedLocales()` reports as on-device-available
// — these are the same locale identifiers `SpeechAnalyzer` accepts and
// the same set `ConfigResolver` validates against when the CLI parses
// `NTAKKER_TRANSCRIBE_LANGUAGE` (see
// `Sources/NtakkerCore/Config/ConfigResolver.swift:315-329`). The first
// time the user picks a locale that isn't already on disk, the
// `SpeechAnalyzerAdapter` triggers a one-shot
// `AssetInventory.assetInstallationRequest(...)` download (~tens of MB)
// — no extra UI work needed here.
//
// Two `@AppStorage` slots:
//
//   * `com.ntakker-cli.ui.transcribeLanguage`  — primary locale identifier
//                                            (e.g. `"el-GR"`). Empty
//                                            string means "use
//                                            `Locale.current`" (the
//                                            engine's documented
//                                            fallback inside
//                                            `AppleSpeechTranscriptionProvider.openStreamingSession`).
//   * `com.ntakker-cli.ui.transcribeLanguage2` — optional secondary locale
//                                            for the Apple provider's
//                                            dual-locale path. Empty
//                                            string means "single-
//                                            locale". Persisted across
//                                            launches so a user who
//                                            usually transcribes Greek
//                                            + English doesn't have to
//                                            re-pick on every open.
//
// `ControlBar.startTapped()` reads both slots and packs them into
// `RecordingOptions.transcriptionLanguageHints` as a 0-, 1-, or
// 2-element array (drops empties, deduplicates so the user can't pass
// the same locale twice).
//
// Dual-locale toggle is visible only when the active transcription
// provider is `apple` — Gemini's REST shape consumes only the first
// language hint as a prompt-side note (see
// `GeminiRESTTranscriptionProvider.swift:67-68`), so showing the
// secondary picker for Gemini would mislead the user.
//
// Disabled while a session is in flight, matching every other picker
// in the popover (AC-UI-8 / AC-LT-19 spirit).

import AVFoundation
import NtakkerCore
import NtakkerUIKit
import Speech
import SwiftUI

/// Sentinel raw value persisted when the user wants the engine to
/// resolve `Locale.current` at session start instead of pinning a
/// specific BCP-47 tag. Empty string is reserved as the storage form
/// of "no preference saved yet"; the sentinel makes "explicit
/// system-default" round-trip cleanly through the Picker selection
/// machinery.
private let kSystemDefaultLocaleSentinel = "__system__"

struct TranscriptionLanguagePicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted primary locale id. Empty string OR the sentinel mean
    /// "use Locale.current".
    @AppStorage("com.ntakker-cli.ui.transcribeLanguage")
    private var primaryRaw: String = ""

    /// Persisted optional secondary locale id. Empty string means
    /// "single-locale" (or, for ElevenLabs, that the user has only
    /// picked one language so far).
    @AppStorage("com.ntakker-cli.ui.transcribeLanguage2")
    private var secondaryRaw: String = ""

    /// 2026-05-01 — third optional locale slot. Used by the ElevenLabs
    /// path. Empty string means "no third language picked".
    /// `ControlBar.startTapped` reads this via the same
    /// `transcribeLanguage3` `@AppStorage` slot so picker writes flow
    /// straight into `RecordingOptions.transcriptionLanguageHints`.
    @AppStorage("com.ntakker-cli.ui.transcribeLanguage3")
    private var tertiaryRaw: String = ""

    /// Mirrors `TranscriptionPicker`'s slot — used so this picker only
    /// shows the extra-locale toggles for providers that actually
    /// consume them.
    @AppStorage("com.ntakker-cli.ui.transcribeProvider")
    private var providerRaw: String = "apple"

    /// On-device-installable locale set, populated on appear. Empty
    /// means SFSpeechRecognizer returned nothing yet (initial render
    /// before the framework warms up).
    @State private var supportedLocales: [Locale] = []

    /// Whether the dual-locale (Apple-only) section is expanded. Driven
    /// by the secondary slot's emptiness so the UI state matches the
    /// persisted intent on every open.
    @State private var dualEnabled: Bool = false

    // MARK: - Derived state

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed: return false
        default: return true
        }
    }

    /// Both Apple (dual-locale parallel recognizers) and ElevenLabs
    /// (multi-language soft-hint mode) accept a second slot.
    private var supportsDualLocale: Bool {
        let p = providerRaw.lowercased()
        return p == "apple" || p == "elevenlabs"
    }

    /// 2026-05-01 — only ElevenLabs accepts a third slot today. Apple's
    /// `SpeechAnalyzer` API is hard-capped at two locales; if exposed
    /// here for Apple the third value would silently drop inside the
    /// provider.
    private var supportsTertiaryLocale: Bool {
        providerRaw.lowercased() == "elevenlabs"
    }

    /// True only for ElevenLabs — drives the helper text that explains
    /// the API has no hard language allow-list.
    private var isElevenLabsProvider: Bool {
        providerRaw.lowercased() == "elevenlabs"
    }

    /// Current primary selection rendered into the Picker's tag space.
    /// Empty persisted value normalises to the sentinel so a row is
    /// always selected.
    private var primaryBinding: Binding<String> {
        Binding(
            get: { primaryRaw.isEmpty ? kSystemDefaultLocaleSentinel : primaryRaw },
            set: { newValue in
                if newValue == kSystemDefaultLocaleSentinel {
                    primaryRaw = ""
                } else {
                    primaryRaw = newValue
                }
                // If the user picked the same locale for primary and
                // secondary, clear the secondary so the resolved hints
                // list stays unique. The dualEnabled toggle stays on so
                // the user can pick a different secondary right away.
                if !secondaryRaw.isEmpty, secondaryRaw == primaryRaw {
                    secondaryRaw = ""
                }
            }
        )
    }

    private var secondaryBinding: Binding<String> {
        Binding(
            get: { secondaryRaw.isEmpty ? kSystemDefaultLocaleSentinel : secondaryRaw },
            set: { newValue in
                if newValue == kSystemDefaultLocaleSentinel {
                    secondaryRaw = ""
                } else {
                    secondaryRaw = newValue
                }
                // De-dup against tertiary the same way the primary
                // setter de-dups against secondary.
                if !tertiaryRaw.isEmpty,
                   tertiaryRaw == secondaryRaw || tertiaryRaw == primaryRaw
                {
                    tertiaryRaw = ""
                }
            }
        )
    }

    private var tertiaryBinding: Binding<String> {
        Binding(
            get: { tertiaryRaw.isEmpty ? kSystemDefaultLocaleSentinel : tertiaryRaw },
            set: { newValue in
                if newValue == kSystemDefaultLocaleSentinel {
                    tertiaryRaw = ""
                } else {
                    tertiaryRaw = newValue
                }
            }
        )
    }

    private var dualToggleBinding: Binding<Bool> {
        Binding(
            get: { dualEnabled || !secondaryRaw.isEmpty },
            set: { newValue in
                dualEnabled = newValue
                if !newValue {
                    // Toggling OFF clears the persisted secondary so
                    // the next start() doesn't smuggle a stale second
                    // locale into the recording.
                    secondaryRaw = ""
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                String(localized: "Language"),
                selection: primaryBinding
            ) {
                Text(systemDefaultLabel())
                    .tag(kSystemDefaultLocaleSentinel)
                if !supportedLocales.isEmpty {
                    Divider()
                    ForEach(sortedLocales(), id: \.identifier) { locale in
                        Text(displayName(for: locale))
                            .tag(locale.identifier)
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(isLocked || supportedLocales.isEmpty)
            .help(String(localized: "Primary language for the transcript. The on-device language pack downloads automatically the first time it's used."))

            if supportsDualLocale {
                Toggle(
                    isElevenLabsProvider
                        ? String(localized: "Add more languages (ElevenLabs auto-detect)")
                        : String(localized: "Add a second language (Apple dual-locale)"),
                    isOn: dualToggleBinding
                )
                .toggleStyle(.checkbox)
                .disabled(isLocked || supportedLocales.isEmpty)
                .help(isElevenLabsProvider
                    ? String(localized: "ElevenLabs accepts up to 3 languages. With 2+ languages selected, the provider switches off the single-language hint and lets Scribe v2 auto-detect (code-switching mode), which is what the docs recommend for bilingual content.")
                    : String(localized: "Apple Speech can run two recognizers in parallel and reconcile per-utterance results across them. Useful for bilingual recordings."))

                if dualToggleBinding.wrappedValue {
                    Picker(
                        String(localized: "Second language"),
                        selection: secondaryBinding
                    ) {
                        Text(String(localized: "(none)"))
                            .tag(kSystemDefaultLocaleSentinel)
                        if !supportedLocales.isEmpty {
                            Divider()
                            ForEach(secondaryCandidates(), id: \.identifier) { locale in
                                Text(displayName(for: locale))
                                    .tag(locale.identifier)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isLocked || supportedLocales.isEmpty)
                    .help(isElevenLabsProvider
                        ? String(localized: "Second target language. Adding a second language hides the single-language hint from the API and switches to auto-detect.")
                        : String(localized: "Optional second language. The provider runs both recognizers in parallel and picks the best per-utterance result."))

                    if supportsTertiaryLocale {
                        Picker(
                            String(localized: "Third language"),
                            selection: tertiaryBinding
                        ) {
                            Text(String(localized: "(none)"))
                                .tag(kSystemDefaultLocaleSentinel)
                            if !supportedLocales.isEmpty {
                                Divider()
                                ForEach(tertiaryCandidates(), id: \.identifier) { locale in
                                    Text(displayName(for: locale))
                                        .tag(locale.identifier)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isLocked || supportedLocales.isEmpty || secondaryRaw.isEmpty)
                        .help(String(localized: "Optional third target language (ElevenLabs only — Apple's API caps at two)."))
                    }
                }
            }

            if isElevenLabsProvider {
                Text(String(localized: "ElevenLabs has no hard language allow-list — Scribe v2 may still emit other languages it recognises in the audio. Use the keyterms field in Settings → ElevenLabs to bias the model toward your target vocabulary."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if supportedLocales.isEmpty {
                Text(String(localized: "No on-device speech locales available. Install one via System Settings > General > Language & Region."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { refreshSupportedLocales() }
    }

    // MARK: - Helpers

    /// Re-enumerate the on-device speech locales. Pure read; called
    /// from `.task`. SFSpeechRecognizer's set is process-stable, so
    /// we don't need to subscribe to any device-change notification.
    private func refreshSupportedLocales() {
        let raw = SFSpeechRecognizer.supportedLocales()
        // Filter out any identifiers that don't survive the same
        // canonicalisation `AppleSpeechTranscriptionProvider.canonicalize`
        // applies — gives the user a list whose every entry is
        // guaranteed to round-trip cleanly into the engine.
        supportedLocales = raw.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
        // Sync the toggle state with the persisted secondary slot —
        // if the user previously picked a second locale, default to
        // having the toggle ON.
        if !secondaryRaw.isEmpty {
            dualEnabled = true
        }
    }

    /// Render `el-GR` as `Greek (Greece) — el-GR`. Falls back to the
    /// raw identifier if the system can't localise it.
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

    /// First row label for the primary picker; explains what
    /// "system default" actually does at runtime so the user doesn't
    /// have to guess.
    private func systemDefaultLabel() -> String {
        let current = Locale.current
        let id = current.identifier
        if let resolved = displayNameComponents(for: current) {
            return String(
                localized: "System default (\(resolved) — \(id))"
            )
        }
        return String(localized: "System default (\(id))")
    }

    private func displayNameComponents(for locale: Locale) -> String? {
        let lang = locale.language.languageCode?.identifier
        let langName = lang.flatMap {
            Locale.current.localizedString(forLanguageCode: $0)?
                .capitalized(with: Locale.current)
        }
        let region = locale.language.region?.identifier
        let regionName = region.flatMap {
            Locale.current.localizedString(forRegionCode: $0)
        }
        switch (langName, regionName) {
        case let (lang?, region?): return "\(lang), \(region)"
        case let (lang?, nil):     return lang
        default:                   return nil
        }
    }

    /// The supported set, less whatever the primary picker is currently
    /// pinned to (so the user can't pick the same locale twice and
    /// trigger the dedup in `ControlBar.startTapped()`).
    private func secondaryCandidates() -> [Locale] {
        let primaryId = primaryRaw
        guard !primaryId.isEmpty else { return supportedLocales }
        return supportedLocales.filter { $0.identifier != primaryId }
    }

    /// The supported set, less whatever the primary AND secondary
    /// pickers are currently pinned to. Used by the ElevenLabs-only
    /// third slot.
    private func tertiaryCandidates() -> [Locale] {
        var excluded: Set<String> = []
        if !primaryRaw.isEmpty   { excluded.insert(primaryRaw) }
        if !secondaryRaw.isEmpty { excluded.insert(secondaryRaw) }
        return supportedLocales.filter { !excluded.contains($0.identifier) }
    }

    private func sortedLocales() -> [Locale] {
        // Already sorted in `refreshSupportedLocales`; kept as a separate
        // method so the body reads symmetrically with `secondaryCandidates`.
        supportedLocales
    }
}
