import Foundation

public enum TranscriptSanitizer {

    /// Energy gate threshold (≈ −40 dBFS). Samples whose peak amplitude
    /// is below this value are skipped without calling the provider —
    /// avoids billing for silence and avoids common Whisper-family
    /// hallucinations on near-silent input.
    public static let silenceThreshold: Float = 0.01

    /// Returns the maximum absolute value across `samples`. Returns 0
    /// for an empty array.
    public static func peak(_ samples: [Float]) -> Float {
        var p: Float = 0
        for v in samples {
            let a = abs(v)
            if a > p { p = a }
        }
        return p
    }

    /// Common Whisper / Parakeet / Gemini hallucinations on silent
    /// or non-speech input. Mirrors notch's list verbatim.
    private static let knownHallucinations: Set<String> = [
        "thank you", "thanks", "thanks for watching",
        "thank you for watching", "thanks so much for watching",
        "bye", "bye bye", "bye-bye", "goodbye",
        "you", "yeah", "hmm", "uh", "um", "okay", "ok",
        "subtitles by the amara.org community"
    ]

    /// Leading punctuation that opens real content (`[Speaker 1]`,
    /// `(laughs)`, a quotation, Spanish `¿` / `¡`) — kept by `clean`
    /// (EVAL-2026-10-16 TR-6). Other leading punctuation (`- `, `...`,
    /// `, `) is stripped.
    private static let openingPunctuation = CharacterSet(charactersIn: "([{\"'«“‘¿¡")

    public static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.unicodeScalars.first,
              (CharacterSet.punctuationCharacters.contains(first)
                && !openingPunctuation.contains(first))
                || CharacterSet.whitespaces.contains(first)
        {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaning = s.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        guard hasMeaning else { return "" }

        var key = s.lowercased()
        while let last = key.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(last)
                || CharacterSet.whitespaces.contains(last)
        {
            key.removeLast()
        }
        if Self.knownHallucinations.contains(key) { return "" }

        return s
    }
}
