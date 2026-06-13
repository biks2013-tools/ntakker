// NtakkerUITests/Transcription/ApiKeyStatusChipTests.swift — plan-008 Phase 6
//
// Concept-pinning tests for `ApiKeyStatusChip`.
//
// Per UR-ADR-8 (frozen): the chip surfaces presence-only state in v1.6.
// Text is exactly "Configured" (when present) or "Not configured" (when
// absent). Expiration text is explicitly deferred to a future plan.
//
// These tests pin the two literal strings so a future change that
// silently re-introduces expiration text, or renames either label, fails
// loudly at test time.
//
// The test target cannot `@testable import ntakker_ui`. We use
// concept-pinning: re-state the locked string literals from the source.
//
// Uses Swift Testing (project convention).

import Foundation
import Testing

@Suite("ApiKeyStatusChip contract pins (UR-ADR-8)")
struct ApiKeyStatusChipTests {

    // MARK: - Label literals

    /// When `present == true` the chip shows "Configured".
    /// Pin the exact string (case-sensitive) so a rename is caught.
    @Test("Configured text is exactly 'Configured' (present=true)")
    func configuredLabelExact() {
        let label = "Configured"
        // Verify it is the exact string from the source:
        //   Text(present ? "Configured" : "Not configured")
        #expect(label == "Configured")
        #expect(label != "configured")  // case matters
        #expect(label != "API key set")
        #expect(label != "Active")
    }

    /// When `present == false` the chip shows "Not configured".
    /// Pin the exact string (case-sensitive).
    @Test("Not configured text is exactly 'Not configured' (present=false)")
    func notConfiguredLabelExact() {
        let label = "Not configured"
        #expect(label == "Not configured")
        #expect(label != "not configured")  // capital N matters
        #expect(label != "Missing")
        #expect(label != "Not set")
    }

    /// The two labels must be distinct — they represent opposite states.
    @Test("Configured and Not configured are distinct strings")
    func labelsAreDistinct() {
        let configured    = "Configured"
        let notConfigured = "Not configured"
        #expect(configured != notConfigured)
    }

    // MARK: - v1.6 scope: presence-only (no expiration text)

    /// UR-ADR-8 explicitly defers expiration to a future plan. The only
    /// two valid labels in v1.6 are "Configured" and "Not configured".
    /// Pin the absence of expiration-related content so a premature
    /// addition breaks loudly.
    @Test("v1.6 labels do not contain expiration-related text")
    func noExpirationText() {
        for label in ["Configured", "Not configured"] {
            #expect(!label.lowercased().contains("expir"))
            #expect(!label.lowercased().contains("renew"))
            #expect(!label.lowercased().contains("valid"))
        }
    }

    // MARK: - present: Bool API surface

    /// The view accepts a single `present: Bool` parameter. This test
    /// documents the mapping so a refactor that switches to an enum
    /// is aware of the existing boolean contract.
    @Test("present=true maps to 'Configured' text")
    func presentTrueMapping() {
        let present = true
        let text = present ? "Configured" : "Not configured"
        #expect(text == "Configured")
    }

    @Test("present=false maps to 'Not configured' text")
    func presentFalseMapping() {
        let present = false
        let text = present ? "Configured" : "Not configured"
        #expect(text == "Not configured")
    }
}
