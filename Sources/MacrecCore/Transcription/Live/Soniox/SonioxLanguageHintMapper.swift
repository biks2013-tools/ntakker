// Sources/MacrecCore/Transcription/Live/Soniox/SonioxLanguageHintMapper.swift
//
// Plan-006 Phase D / Unit D1: Soniox language-hint normaliser.
//
// Soniox accepts ISO 639-1 hints (e.g. "el", "en") in the
// `language_hints` config field. BCP-47 region tags such as "el-GR"
// or "en-US" cause a 400 error. This namespace strips region tags,
// lowercases, dedupes preserving order, and filters empties so the
// caller can feed user-supplied locale identifiers directly.

import Foundation

public enum SonioxLanguageHintMapper {

    /// `macrec` v1 default hints — Greek + English (FR-SX-9).
    public static let defaultHints: [String] = ["el", "en"]

    /// Strip BCP-47 region tags ("el-GR" → "el", "en-US" → "en"),
    /// lowercase, dedupe preserving order, filter empties / whitespace.
    public static func map(_ inputs: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in inputs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let primary = trimmed
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            let normalised = primary.lowercased()
            guard !normalised.isEmpty else { continue }
            if seen.insert(normalised).inserted {
                result.append(normalised)
            }
        }
        return result
    }
}
