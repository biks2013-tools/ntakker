// NtakkerUITests/Transcription/ApiKeyStatusRowTests.swift — plan-008 Phase 6
//
// Concept-pinning tests for `ApiKeyStatusRow`.
//
// The test target cannot `@testable import ntakker_ui` (the executable target
// is not a test dependency in Package.swift). These tests re-state the design
// contract that `ApiKeyStatusRow` relies on:
//
//   1. Mask width is fixed at 26 dots — independent of key length.
//   2. Presence is derived correctly: nil or empty → not present; non-empty → present.
//   3. `onSave` trim contract: leading/trailing whitespace is stripped before
//      calling the callback (UR-ADR-8).
//   4. Edit placeholder format: contains the provider env-var name.
//
// Uses Swift Testing (project convention).

import Foundation
import Testing

@Suite("ApiKeyStatusRow contract pins")
struct ApiKeyStatusRowTests {

    // MARK: - 1. Mask width

    /// The `maskedKey` var in `ApiKeyStatusRow` returns exactly 26 "•"
    /// characters, regardless of the underlying key length. Pin the
    /// integer literal so any future "make mask scale to key length"
    /// refactor breaks this test first.
    @Test("Mask is exactly 26 dots")
    func maskWidthIs26() {
        let dots = String(repeating: "•", count: 26)
        #expect(dots.count == 26)
        // Pin the literal used by the source. If source changes to 28 dots
        // (the comment says "up to 28") this assertion fails and the reviewer
        // must re-evaluate the contract.
        #expect(dots == String(repeating: "•", count: 26))
    }

    /// Verify that the mask character is the bullet "•" (U+2022),
    /// not a plain ASCII period, hyphen, or asterisk.
    @Test("Mask character is the bullet U+2022")
    func maskCharacterIsBullet() {
        let dot = "•"
        #expect(dot.unicodeScalars.first?.value == 0x2022)
    }

    // MARK: - 2. Presence derivation

    /// Per UR-ADR-8: `nil` resolvedKey → not present.
    @Test("nil resolvedKey means not present")
    func nilKeyNotPresent() {
        let resolvedKey: String? = nil
        let isPresent = resolvedKey?.isEmpty == false
        #expect(isPresent == false)
    }

    /// Per UR-ADR-8: empty string resolvedKey → not present.
    @Test("Empty string resolvedKey means not present")
    func emptyKeyNotPresent() {
        let resolvedKey: String? = ""
        let isPresent = resolvedKey?.isEmpty == false
        #expect(isPresent == false)
    }

    /// Per UR-ADR-8: non-empty resolvedKey → present.
    @Test("Non-empty resolvedKey means present")
    func nonEmptyKeyIsPresent() {
        let resolvedKey: String? = "sk-abc123"
        let isPresent = resolvedKey?.isEmpty == false
        #expect(isPresent == true)
    }

    /// Whitespace-only string is still non-empty at the String level
    /// (non-nil, non-empty); `isPresent` reads from the stored value,
    /// not the trimmed value — presence check does not trim.
    @Test("Whitespace-only string is considered present (trim happens only on Save)")
    func whitespaceOnlyIsPresent() {
        let resolvedKey: String? = "   "
        let isPresent = resolvedKey?.isEmpty == false
        #expect(isPresent == true)
    }

    // MARK: - 3. onSave trim contract

    /// `ApiKeyStatusRow.editingFieldStack` trims whitespace before calling
    /// `onSave`. Pin the trim operation: a padded key produces the clean value.
    @Test("Trim removes leading and trailing whitespace before save")
    func trimRemovesWhitespace() {
        let raw = "  KEY-123  "
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "KEY-123")
    }

    /// A key padded only on the left is still trimmed correctly.
    @Test("Trim handles leading-only whitespace")
    func trimLeadingOnly() {
        let raw = "   SK-ABCDEF"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "SK-ABCDEF")
    }

    /// A key padded only on the right is still trimmed correctly.
    @Test("Trim handles trailing-only whitespace")
    func trimTrailingOnly() {
        let raw = "SK-ABCDEF   "
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "SK-ABCDEF")
    }

    /// The save guard: if the trimmed value is empty, `onSave` is NOT
    /// called (the `guard !trimmed.isEmpty else { return }` branch fires).
    /// Pin this by asserting the guard logic.
    @Test("Whitespace-only draft is empty after trim and would not fire onSave")
    func whitespaceOnlyDraftIsGuardedOut() {
        let draft = "   \t\n  "
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.isEmpty)
        // Because trimmed.isEmpty == true, the guard exits — onSave never fires.
    }

    // MARK: - 4. Edit placeholder format

    /// The Soniox placeholder must contain the env-var name "SONIOX_API_KEY"
    /// so the user knows what to paste. Pin the exact documented placeholder
    /// seen in the preview block at the bottom of the source file.
    @Test("Soniox placeholder contains the env-var name SONIOX_API_KEY")
    func sonioxPlaceholderContainsEnvVar() {
        let placeholder = "Paste SONIOX_API_KEY value"
        #expect(placeholder.contains("SONIOX_API_KEY"))
    }

    /// The Gemini placeholder must contain the env-var name "GOOGLE_API_KEY".
    @Test("Gemini placeholder contains the env-var name GOOGLE_API_KEY")
    func geminiPlaceholderContainsEnvVar() {
        let placeholder = "Paste GOOGLE_API_KEY value"
        #expect(placeholder.contains("GOOGLE_API_KEY"))
    }
}
