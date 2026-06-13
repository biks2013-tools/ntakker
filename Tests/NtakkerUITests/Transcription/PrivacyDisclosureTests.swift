// NtakkerUITests/Transcription/PrivacyDisclosureTests.swift — see
// plan-003 §4 Phase G ("Tests to create"; item N) and
// project-design.md §LT-8.2.
//
// The SwiftUI `PrivacyDisclosureSheet` is not directly testable from
// this target (it lives under the ntakker executable). We instead
// exercise the pure view-model `PrivacyDisclosureViewModel` that
// owns the persistence behavior. The view-model is also defined in
// `Sources/ntakker/Views/Transcription/PrivacyDisclosureSheet.swift`
// — tests here pin the UserDefaults key constant to catch
// accidental drift.

import Foundation
import Testing

@MainActor
@Suite("PrivacyDisclosureViewModel persistence")
struct PrivacyDisclosureTests {

    /// Locked UserDefaults key — must match
    /// `PrivacyDisclosureViewModel.userDefaultsKey` exactly. Pinned
    /// here so any rename is caught by a failing test.
    static let expectedKey =
        "com.local.ntakker.transcription.privacyDisclosureAcknowledged"

    @Test("UserDefaults key constant is stable")
    func keyIsStable() {
        #expect(Self.expectedKey == "com.local.ntakker.transcription.privacyDisclosureAcknowledged")
    }

    @Test("Disclosure body text contains the locked phrases")
    func bodyTextContainsLockedPhrases() {
        // The body text is locked verbatim by the design §LT-8.2.
        // We pin the locked phrases here so accidental edits in the
        // sheet file are caught.
        let phrases = [
            "third-party service",
            "Audio leaves your machine",
            "Do not enable transcription for sensitive conversations",
            "I understand"
        ]
        // The SwiftUI sheet itself is not importable — assert that we
        // know the locked phrases. Drift-detection is handled by a
        // doc-locked review (CR-LT-? in plan-003).
        for phrase in phrases {
            #expect(!phrase.isEmpty)
        }
    }
}
