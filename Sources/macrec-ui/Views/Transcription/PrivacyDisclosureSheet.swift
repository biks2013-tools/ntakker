// macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift — see
// project-design.md §LT-8.2 (FR-53, AC-LT-9) and plan-003 Phase G.
//
// Modal sheet shown ONCE per app install before the user enables
// live transcription for the first time. Persists a flag in
// `UserDefaults` so subsequent sessions skip the alert.
//
// Per the design §LT-8.2 the privacy disclosure remains
// discoverable via a separate help popover (the `?` icon next to
// the picker — covered by `TranscriptionPicker`'s `.help(...)`).

import SwiftUI

/// Pure view-model for the privacy-disclosure flow. Tests inject a
/// `UserDefaults` instance to verify the persistence behavior.
public final class PrivacyDisclosureViewModel {

    /// Canonical UserDefaults key for the acknowledged flag. Locked
    /// by the design §LT-8.2.
    public static let userDefaultsKey =
        "com.local.macrec-ui.transcription.privacyDisclosureAcknowledged"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the user has already acknowledged the disclosure.
    public var hasAcknowledged: Bool {
        defaults.bool(forKey: Self.userDefaultsKey)
    }

    /// Persist the acknowledgement.
    public func acknowledge() {
        defaults.set(true, forKey: Self.userDefaultsKey)
    }

    /// Reset the acknowledgement (testing / debug only).
    public func reset() {
        defaults.removeObject(forKey: Self.userDefaultsKey)
    }
}

/// Modal sheet that presents the privacy disclosure text. Shown by
/// `RootView` via `.sheet(isPresented: $showSheet)` when the
/// transcription picker first flips from `none` to a real provider
/// AND `hasAcknowledged == false`.
struct PrivacyDisclosureSheet: View {

    /// Closure invoked when the user taps "I understand".
    let onAcknowledge: () -> Void

    /// Closure invoked when the user dismisses without acknowledging
    /// (resets the picker to `none`).
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live transcription sends audio to a third-party API")
                .font(.headline)

            Text(Self.bodyText)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("I understand", action: onAcknowledge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Locked body text (design §LT-8.2). Verbatim — NOT translated;
    /// the user's prompt requires this exact wording.
    static let bodyText = """
        When live transcription is enabled, your audio is sent to a third-party service \
        (e.g., Google's Gemini API) for processing. Audio leaves your machine. Do not \
        enable transcription for sensitive conversations. Click 'I understand' to continue.
        """
}
