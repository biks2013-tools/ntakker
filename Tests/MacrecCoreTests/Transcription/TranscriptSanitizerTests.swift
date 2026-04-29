import Foundation
import Testing
@testable import MacrecCore

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
}
