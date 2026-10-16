import Foundation
import Testing
@testable import NtakkerCore

@Suite("TranscriptSanitizer")
struct TranscriptSanitizerTests {

    @Test("peak returns 0 for empty samples")
    func peakEmpty() {
        #expect(TranscriptSanitizer.peak([]) == 0)
    }

    @Test("peak returns max abs across samples")
    func peakMaxAbs() {
        #expect(TranscriptSanitizer.peak([0.0, -0.7, 0.3, -0.1]) == 0.7)
    }

    @Test("clean strips leading punctuation and whitespace")
    func cleanStripsLeadingPunct() {
        #expect(TranscriptSanitizer.clean("   ,. hello world") == "hello world")
    }

    @Test("clean returns empty for punctuation-only input")
    func cleanRejectsPunctOnly() {
        #expect(TranscriptSanitizer.clean("...,,,!!!") == "")
    }

    @Test("clean drops known hallucinations regardless of trailing punctuation")
    func cleanDropsHallucinations() {
        for token in ["thank you", "Thanks for watching!", "you", "Subtitles by the Amara.org community"] {
            #expect(TranscriptSanitizer.clean(token) == "", "expected '\(token)' to be filtered")
        }
    }

    @Test("clean preserves real text untouched")
    func cleanPreservesRealText() {
        #expect(TranscriptSanitizer.clean("The quick brown fox.") == "The quick brown fox.")
    }

    @Test("TR-6: opening brackets and quotes are kept")
    func cleanKeepsOpeningPunctuation() {
        #expect(TranscriptSanitizer.clean("[Speaker 1] hello there") == "[Speaker 1] hello there")
        #expect(TranscriptSanitizer.clean("  (laughs) right") == "(laughs) right")
        #expect(TranscriptSanitizer.clean("\u{201C}Quoted\u{201D} line") == "\u{201C}Quoted\u{201D} line")
        #expect(TranscriptSanitizer.clean("¿Qué tal?") == "¿Qué tal?")
        #expect(TranscriptSanitizer.clean("- ... [Speaker 2] yes") == "[Speaker 2] yes")
    }

    @Test("TR-7: short replies survive a voiced chunk, not a quiet one")
    func plausibleRepliesDependOnLevel() {
        for word in ["Yeah.", "ok", "Thank you!", "okay"] {
            #expect(TranscriptSanitizer.clean(word, chunkPeak: 0.3) == word, "\(word) on a voiced chunk")
            #expect(TranscriptSanitizer.clean(word, chunkPeak: 0.02) == "", "\(word) on a quiet chunk")
            #expect(TranscriptSanitizer.clean(word) == "", "\(word) with unknown level")
        }
    }

    @Test("TR-7: pure hallucinations are dropped at any level")
    func pureHallucinationsAlwaysDropped() {
        for phrase in ["Thanks for watching!", "you", "um", "Subtitles by the Amara.org community"] {
            #expect(TranscriptSanitizer.clean(phrase, chunkPeak: 0.8) == "", "\(phrase)")
        }
    }
}

