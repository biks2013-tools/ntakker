// ntakker/Views/Transcription/PrivacyDisclosureSheet.swift —
// project-design.md §LT-8.2 (FR-53, AC-LT-9), originally added in
// plan-003 Phase G, extended in plan-006 Phase H (Soniox), and
// re-shaped in plan-007 Phase 0 / Task 0.3 to be fully per-provider:
//
//   * The body text is provider-specific (`bodyText(for:)`).
//   * The acknowledgement flag is per-provider
//     (`UserDefaults` key
//     `com.local.ntakker.transcription.privacy.{providerId}.acknowledged`)
//     so users opt in once per data-residency posture rather than once
//     forever — selecting Azure for the first time after Gemini was
//     already acknowledged correctly re-shows the dialog.
//   * The legacy single boolean
//     (`com.local.ntakker.transcription.privacyDisclosureAcknowledged`)
//     is migrated on first run after upgrade to the Gemini-specific
//     key so existing users do not see the dialog a second time for
//     Gemini.
//   * The plan-006 Soniox-specific flag
//     (`com.local.ntakker.transcription.hasAcceptedSonioxDisclosure`)
//     is migrated to the per-provider key for Soniox.
//
// Per the design §LT-8.2 the privacy disclosure remains discoverable
// via a separate help popover (the `?` icon next to the picker —
// covered by `TranscriptionPicker`'s `.help(...)`).

import SwiftUI

/// Pure view-model for the privacy-disclosure flow. Tests inject a
/// `UserDefaults` instance to verify the persistence behavior.
public final class PrivacyDisclosureViewModel {

    /// Legacy single-boolean key from plan-003 / plan-005. Retained
    /// for the migration path on first-run-after-upgrade. Reads here
    /// continue to work for back-compat callers; new code MUST use
    /// `acknowledgedKey(for:)`.
    public static let userDefaultsKey =
        "com.local.ntakker.transcription.privacyDisclosureAcknowledged"

    /// Legacy plan-006 Soniox-specific key. Retained for the migration
    /// path; new code MUST use `acknowledgedKey(for: "soniox")`.
    public static let sonioxUserDefaultsKey =
        "com.local.ntakker.transcription.hasAcceptedSonioxDisclosure"

    /// Per-provider key (plan-007 Task 0.3). Use this for Azure,
    /// Azure Realtime, ElevenLabs, and any future cloud provider.
    /// Returns the `UserDefaults` key under which the per-provider
    /// acknowledgement boolean is stored.
    public static func acknowledgedKey(for providerId: String) -> String {
        "com.local.ntakker.transcription.privacy.\(providerId).acknowledged"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyFlagsIfNeeded()
    }

    /// Whether the user has already acknowledged the disclosure for
    /// `providerId`. Reads the per-provider key; the legacy keys are
    /// migrated on the first call.
    public func hasAcknowledged(provider providerId: String) -> Bool {
        defaults.bool(forKey: Self.acknowledgedKey(for: providerId))
    }

    /// Persist the acknowledgement for `providerId`.
    public func acknowledge(provider providerId: String) {
        defaults.set(true, forKey: Self.acknowledgedKey(for: providerId))
    }

    /// Reset the acknowledgement (testing / debug only).
    public func reset(provider providerId: String) {
        defaults.removeObject(forKey: Self.acknowledgedKey(for: providerId))
    }

    // MARK: - Back-compat (legacy combined-flag callers)

    /// Legacy boolean retained for the existing RootView wiring and any
    /// tests that pinned it. Mirrors the Gemini-specific per-provider
    /// key so a first-run-after-upgrade user does not see the Gemini
    /// dialog twice.
    public var hasAcknowledged: Bool {
        defaults.bool(forKey: Self.acknowledgedKey(for: "gemini"))
    }

    public func acknowledge() {
        defaults.set(true, forKey: Self.acknowledgedKey(for: "gemini"))
    }

    public func reset() {
        defaults.removeObject(forKey: Self.acknowledgedKey(for: "gemini"))
    }

    public var hasAcknowledgedSoniox: Bool {
        defaults.bool(forKey: Self.acknowledgedKey(for: "soniox"))
    }

    public func acknowledgeSoniox() {
        defaults.set(true, forKey: Self.acknowledgedKey(for: "soniox"))
    }

    public func resetSoniox() {
        defaults.removeObject(forKey: Self.acknowledgedKey(for: "soniox"))
    }

    // MARK: - Migration

    /// Plan-007 Task 0.3 migration: when `defaults` carries either
    /// of the two legacy flags AND the corresponding per-provider key
    /// is unset, copy the truthy state across and remove the legacy
    /// key. Idempotent — subsequent calls observe a clean state.
    private func migrateLegacyFlagsIfNeeded() {
        // Gemini: legacy combined flag → gemini-specific per-provider key.
        if defaults.bool(forKey: Self.userDefaultsKey),
           !defaults.bool(forKey: Self.acknowledgedKey(for: "gemini"))
        {
            defaults.set(true, forKey: Self.acknowledgedKey(for: "gemini"))
        }
        defaults.removeObject(forKey: Self.userDefaultsKey)

        // Soniox: legacy plan-006 flag → soniox-specific per-provider key.
        if defaults.bool(forKey: Self.sonioxUserDefaultsKey),
           !defaults.bool(forKey: Self.acknowledgedKey(for: "soniox"))
        {
            defaults.set(true, forKey: Self.acknowledgedKey(for: "soniox"))
        }
        defaults.removeObject(forKey: Self.sonioxUserDefaultsKey)
    }
}

/// Modal sheet that presents the privacy disclosure text. Shown by
/// `RootView` via `.sheet(isPresented: $showSheet)` when the
/// transcription picker first flips into a cloud provider AND the
/// per-provider acknowledgement boolean for that provider is `false`.
struct PrivacyDisclosureSheet: View {

    /// The provider id that the user is enabling. The sheet's title
    /// and body text are selected from this; if `nil`, the generic
    /// pre-plan-007 copy is rendered (and acknowledgement falls back
    /// to the Gemini key for back-compat).
    var selectedProvider: String? = nil

    /// Closure invoked when the user taps "I understand".
    let onAcknowledge: () -> Void

    /// Closure invoked when the user dismisses without acknowledging
    /// (resets the picker to `none`).
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.headline(for: selectedProvider))
                .font(.headline)

            Text(Self.bodyText(for: selectedProvider))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("I understand") {
                    onAcknowledge()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Per-provider copy (locked verbatim — design §LT-8.2 +
    //         plan-007 §7.1 / §7.2 / §A2.9)

    /// Sheet title. Provider-aware to make the dialog unambiguous when
    /// a user toggles between cloud providers.
    static func headline(for providerId: String?) -> String {
        switch providerId?.lowercased() {
        case "azure":
            return "Live transcription will use Microsoft Azure OpenAI Service (batch)"
        case "azure-openai-realtime":
            return "Live transcription will stream to Microsoft Azure OpenAI Realtime"
        case "elevenlabs":
            return "Live transcription will use ElevenLabs Scribe v2"
        case "soniox":
            return "Live transcription will use Soniox real-time STT"
        case "gemini", "gemini-live":
            return "Live transcription will use Google's Gemini API"
        case "apple-cloud":
            return "Live transcription will use Apple's Speech Recognition cloud"
        default:
            return "Live transcription sends audio to a third-party API"
        }
    }

    /// Provider-specific body copy. Locked verbatim per plan-007 §7
    /// and §A2.9. The Azure copy makes the no-training contract
    /// explicit; the ElevenLabs copy points users at the Zero
    /// Retention enterprise option.
    static func bodyText(for providerId: String?) -> String {
        switch providerId?.lowercased() {
        case "azure":
            return azureBodyText
        case "azure-openai-realtime":
            return azureRealtimeBodyText
        case "elevenlabs":
            return elevenLabsBodyText
        case "soniox":
            return sonioxBodyText
        case "gemini", "gemini-live":
            return geminiBodyText
        case "apple-cloud":
            return appleCloudBodyText
        default:
            return legacyCombinedBodyText
        }
    }

    /// Legacy pre-plan-007 copy. Retained for the `selectedProvider == nil`
    /// fallback so existing call sites that did not pass a provider id
    /// keep rendering the original wording.
    static let legacyCombinedBodyText = """
        When live transcription is enabled, your audio is sent to a third-party service \
        (e.g., Google's Gemini API) for processing. Audio leaves your machine. Do not \
        enable transcription for sensitive conversations. Click 'I understand' to continue.
        """

    /// Legacy alias retained so existing tests / call sites pinning the
    /// raw `bodyText` static continue to compile. New code must use
    /// `bodyText(for:)` instead.
    static let bodyText = legacyCombinedBodyText

    // MARK: - Per-provider verbatim copy

    static let geminiBodyText = """
        Audio is sent to Google's Gemini API for transcription. Audio leaves your \
        machine. Per Google's published terms, paid Gemini API audio is not used to \
        improve Google's models without your explicit consent; the free tier may be \
        used for product improvement (see Google AI privacy policy). For details see \
        https://ai.google.dev/gemini-api/terms and https://ai.google.dev/gemini-api/docs/privacy.
        """

    static let azureBodyText = """
        Audio will be sent to Microsoft Azure OpenAI Service for transcription. \
        Microsoft contractually commits that your audio and transcripts are never \
        used to train AI models and are never shared with OpenAI or other parties. \
        Data is processed in the Azure region associated with your resource \
        (currently Global Standard, which may route through East US 2). A Data \
        Processing Agreement covers this transfer. For full details, see Microsoft's \
        Azure OpenAI data privacy documentation at \
        https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy \
        and the Microsoft Online Services DPA at https://aka.ms/DPA.
        """

    static let azureRealtimeBodyText = """
        Audio will be streamed live to Microsoft Azure OpenAI Service for transcription \
        over a secure WebSocket. Microsoft contractually commits that your audio and \
        transcripts are never used to train AI models and are never shared with OpenAI \
        or other parties. Audio is processed in real time and is NOT retained per Azure \
        data privacy policy. The session is capped at 60 minutes — recordings longer \
        than that will reconnect transparently. Data is processed in the Azure region \
        associated with your resource (currently Global Standard, which may route \
        through East US 2). For full details, see Microsoft's Azure OpenAI data privacy \
        documentation at \
        https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy \
        and the Microsoft Online Services DPA at https://aka.ms/DPA.
        """

    static let elevenLabsBodyText = """
        Audio will be sent to ElevenLabs (US-based, SOC 2 Type II certified, ISO 27001, \
        GDPR-compliant). By default ElevenLabs retains audio and transcripts for service \
        operation; Enterprise customers can enable Zero Retention mode \
        (`enable_logging=false`). Audio is not used to train models without explicit \
        opt-in. EU data residency is available on Enterprise tier through account \
        settings. For full details, see ElevenLabs' privacy policy at \
        https://elevenlabs.io/privacy and the Data Processing Addendum at \
        https://elevenlabs.io/dpa.
        """

    static let sonioxBodyText = """
        Audio is streamed to Soniox cloud servers (default \
        `wss://stt-rt.soniox.com/transcribe-websocket`; EU/JP regional endpoints \
        available via `NTAKKER_SONIOX_ENDPOINT`). Soniox does not store audio by \
        default; configure retention in your Soniox console. See \
        https://soniox.com/docs/stt/data-residency and https://soniox.com/privacy.
        """

    static let appleCloudBodyText = """
        ntakker will send your captured audio to Apple's Speech Recognition \
        servers via the system `SFSpeechRecognizer` API. macOS prompts you for \
        permission the first time the API is used (the system Speech Recognition \
        toggle). No API key is required and no third-party billing is involved; \
        Apple enforces a device-wide quota of approximately 1,000 requests per \
        hour and roughly 60 seconds of audio per request — ntakker-cli automatically \
        rotates the underlying recognition task every 55 seconds to stay inside \
        that limit. Apple states recognition data is processed under their \
        privacy policy; see https://support.apple.com/guide/iphone/control-access-\
        to-information-in-apps-iph251e92810/ios and Apple's Privacy Policy at \
        https://www.apple.com/legal/privacy/ for the current terms.
        """
}
