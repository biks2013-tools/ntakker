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

    /// Common Whisper / Parakeet / Gemini hallucinations on silent or
    /// non-speech input that are never a real utterance on their own —
    /// always dropped.
    private static let knownHallucinations: Set<String> = [
        "thanks for watching", "thank you for watching",
        "thanks so much for watching",
        "you", "hmm", "uh", "um",
        "subtitles by the amara.org community"
    ]

    /// Hallucinations that are ALSO genuine short replies ("yeah", "ok",
    /// "thanks"). EVAL-2026-10-16 TR-7: these are dropped only when the
    /// chunk was quiet (peak below `plausibleReplyMinPeak`) or its level
    /// is unknown; a clearly voiced chunk keeps them.
    private static let plausibleReplies: Set<String> = [
        "thank you", "thanks",
        "bye", "bye bye", "bye-bye", "goodbye",
        "yeah", "okay", "ok"
    ]

    /// Peak (≈ −26 dBFS) above which a chunk is treated as clearly
    /// voiced for `plausibleReplies`. Well above the −40 dBFS energy
    /// gate, so near-silent chunks that slip through the gate still have
    /// their "thank you"-style hallucinations removed.
    public static let plausibleReplyMinPeak: Float = 0.05

    /// Leading punctuation that opens real content (`[Speaker 1]`,
    /// `(laughs)`, a quotation, Spanish `¿` / `¡`) — kept by `clean`
    /// (EVAL-2026-10-16 TR-6). Other leading punctuation (`- `, `...`,
    /// `, `) is stripped.
    private static let openingPunctuation = CharacterSet(charactersIn: "([{\"'«“‘¿¡")

    /// - Parameter chunkPeak: peak amplitude of the audio the text was
    ///   transcribed from (`peak(_:)`), or `nil` when unknown.
    public static func clean(_ raw: String, chunkPeak: Float? = nil) -> String {
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
        if Self.plausibleReplies.contains(key) {
            let voiced = chunkPeak.map { $0 >= Self.plausibleReplyMinPeak } ?? false
            if !voiced { return "" }
        }

        return s
    }
}
