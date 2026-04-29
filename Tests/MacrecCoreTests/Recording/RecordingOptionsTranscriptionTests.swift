// MacrecCoreTests/Recording/RecordingOptionsTranscriptionTests.swift —
// see project-design.md §LT-5.4 / plan-003 Phase C.
//
// These are the **regression tests for plan-003 R-Top2** — the latent bug
// flagged by the codebase scan §5: `RecordingOptions.withOutput(_:)` MUST
// forward every transcription field. Without this test, every pause/resume
// segment rotation would silently lose transcription options.

import Foundation
import Testing
@testable import MacrecCore

@Suite("RecordingOptions — live transcription fields")
struct RecordingOptionsTranscriptionTests {

    // MARK: - Defaults (design §LT-5.4)

    @Test("Default values match the design")
    func defaultsMatchDesign() {
        let url = URL(fileURLWithPath: "/tmp/macrec-out.m4a")
        let opts = RecordingOptions(output: url)

        // RecordingOptions.init's default for transcriptionProviderId is nil
        // (the resolver is responsible for the plan-005 default flip to
        // "apple"; the bare value-type init keeps the no-transcription
        // shape so tests / construction sites that don't want the side
        // effects opt in explicitly).
        #expect(opts.transcriptionProviderId == nil)
        #expect(opts.transcriptionSource == .mixed)
        #expect(opts.transcriptionFormat == .jsonl)
        #expect(opts.transcriptionApiKey == nil)
        #expect(opts.transcriptionKeyExpiresAt == nil)
        #expect(opts.transcriptionModelId == nil)
        #expect(opts.transcriptionLanguageHints == [])
    }

    @Test("Explicit transcription field values are preserved on init")
    func explicitOverridesPreserved() {
        let url = URL(fileURLWithPath: "/tmp/macrec-out.m4a")
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)

        let opts = RecordingOptions(
            output: url,
            transcriptionProviderId: "gemini-live",
            transcriptionSource: .both,
            transcriptionFormat: .srt,
            transcriptionApiKey: "secret-key",
            transcriptionKeyExpiresAt: expiry,
            transcriptionModelId: "gemini-3.1-flash-live-preview",
            transcriptionLanguageHints: ["en"]
        )

        #expect(opts.transcriptionProviderId == "gemini-live")
        #expect(opts.transcriptionSource == .both)
        #expect(opts.transcriptionFormat == .srt)
        #expect(opts.transcriptionApiKey == "secret-key")
        #expect(opts.transcriptionKeyExpiresAt == expiry)
        #expect(opts.transcriptionModelId == "gemini-3.1-flash-live-preview")
        #expect(opts.transcriptionLanguageHints == ["en"])
    }

    // MARK: - withOutput(_:) regression test (plan-003 R-Top2 — MANDATORY)

    @Test("withOutput(_:) preserves every transcription field — plan-003 R-Top2")
    func testWithOutputPreservesTranscriptionFields() {
        let original = RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/macrec-original.m4a"),
            transcriptionProviderId: "gemini-live",
            transcriptionSource: .both,
            transcriptionFormat: .vtt,
            transcriptionApiKey: "rotating-secret",
            transcriptionKeyExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            transcriptionModelId: "gemini-3.1-flash-live-preview",
            transcriptionLanguageHints: ["el"]
        )

        let next = original.withOutput(URL(fileURLWithPath: "/tmp/macrec-part02.m4a"))

        // The new output URL is updated.
        #expect(next.output.path == "/tmp/macrec-part02.m4a")

        // EVERY transcription field must round-trip verbatim.
        #expect(next.transcriptionProviderId == original.transcriptionProviderId)
        #expect(next.transcriptionSource == original.transcriptionSource)
        #expect(next.transcriptionFormat == original.transcriptionFormat)
        #expect(next.transcriptionApiKey == original.transcriptionApiKey)
        #expect(next.transcriptionKeyExpiresAt == original.transcriptionKeyExpiresAt)
        #expect(next.transcriptionModelId == original.transcriptionModelId)
        #expect(next.transcriptionLanguageHints == original.transcriptionLanguageHints)

        // And the non-transcription fields too — we are checking the whole
        // copy in case a future reviewer drops a field by accident.
        #expect(next.format == original.format)
        #expect(next.layout == original.layout)
        #expect(next.micChannel == original.micChannel)
        #expect(next.sampleRate == original.sampleRate)
        #expect(next.bitDepth == original.bitDepth)
        #expect(next.bitrate == original.bitrate)
        #expect(next.micDevice == original.micDevice)
        #expect(next.logLevel == original.logLevel)
        #expect(next.maxDuration == original.maxDuration)
        #expect(next.overwrite == original.overwrite)
        #expect(next.runMode == original.runMode)
        #expect(next.pidFile == original.pidFile)
        #expect(next.logFile == original.logFile)
        #expect(next.stopTimeout == original.stopTimeout)
    }

    @Test("withOutput(_:) preserves nil-default transcription fields")
    func withOutputPreservesDefaults() {
        let original = RecordingOptions(output: URL(fileURLWithPath: "/tmp/a.m4a"))
        let next = original.withOutput(URL(fileURLWithPath: "/tmp/b.m4a"))

        #expect(next.transcriptionProviderId == nil)
        #expect(next.transcriptionSource == .mixed)
        #expect(next.transcriptionFormat == .jsonl)
        #expect(next.transcriptionApiKey == nil)
        #expect(next.transcriptionKeyExpiresAt == nil)
        #expect(next.transcriptionModelId == nil)
        #expect(next.transcriptionLanguageHints == [])
    }

    // MARK: - No-fallback discipline — invalid raw values raise

    @Test("Invalid MACREC_TRANSCRIBE_SOURCE raises (no fallback)")
    func invalidSourceRaisesNotFallback() {
        // Note: parsing happens in `ConfigResolver`. This test asserts that
        // the resolver propagates invalidConfigValue (exit 64) instead of
        // silently falling back to `.mixed`. The exhaustive integration test
        // lives in `ConfigResolverTranscriptionTests`; this is a quick sanity
        // shape check that the enum's RawRepresentable rejects junk.
        #expect(TranscriptionSource(rawValue: "invalid") == nil)
        #expect(TranscriptFormat(rawValue: "invalid") == nil)
        #expect(TranscriptionProviderId(rawValue: "invalid") == nil)
    }

    @Test("TranscriptFormat is CaseIterable with the four documented cases")
    func transcriptFormatCases() {
        let raws = Set(TranscriptFormat.allCases.map(\.rawValue))
        #expect(raws == Set(["jsonl", "srt", "vtt", "txt"]))
    }

    @Test("TranscriptionProviderId is CaseIterable with v1 cases")
    func providerIdCases() {
        let raws = Set(TranscriptionProviderId.allCases.map(\.rawValue))
        #expect(raws.contains("none"))
        #expect(raws.contains("apple"))   // plan-005 Phase G
        #expect(raws.contains("gemini"))
        #expect(raws.contains("gemini-live"))
    }

    @Test("Equatable — two options with the same transcription fields are equal")
    func equatableHonoursTranscriptionFields() {
        let a = RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/a.m4a"),
            transcriptionProviderId: "gemini-live",
            transcriptionSource: .mixed,
            transcriptionFormat: .jsonl
        )
        let b = RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/a.m4a"),
            transcriptionProviderId: "gemini-live",
            transcriptionSource: .mixed,
            transcriptionFormat: .jsonl
        )
        #expect(a == b)

        let c = RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/a.m4a"),
            transcriptionProviderId: "gemini-live",
            transcriptionSource: .mic,    // changed
            transcriptionFormat: .jsonl
        )
        #expect(a != c)
    }
}
