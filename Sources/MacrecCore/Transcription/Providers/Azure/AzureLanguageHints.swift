// Sources/MacrecCore/Transcription/Providers/Azure/AzureLanguageHints.swift —
// Plan-007 follow-up (2026-04-30): shared resolver that maps the
// project's `[String]` language-hint array into the
// `(language, prompt)` tuple the Azure transcription APIs accept.
//
// Why this exists: Azure's `gpt-4o-mini-transcribe` (batch and
// realtime) defines `language` as a single ISO-639-1 string — there
// is no array form, no comma-separated form, and no documented
// multi-language switch. The OpenAI guide explicitly recommends
// using the `prompt` field for language steering when no single code
// captures the audio (e.g. code-switching between English and Greek):
// <https://platform.openai.com/docs/guides/speech-to-text>.
//
// Resolution rules:
//   * 0 hints → `(language: nil, prompt: customInstruction)` — full
//     auto-detect, no language nudge.
//   * 1 hint  → `(language: <stripped, lower-cased>, prompt: customInstruction)` —
//     pin the language for accuracy and latency.
//   * 2+ hints → `(language: nil, prompt: customInstruction + " " +
//     <auto-built multi-language hint>)` — omit `language` so the
//     model auto-detects per utterance, and append a verbatim
//     instruction telling the model to transcribe each utterance in
//     its native script.
//
// The auto-built multi-language hint uses English language names
// (regardless of the UI locale) so the model's prompt is consistent.

import Foundation

public enum AzureLanguageHints {

    /// Resolve a hint list + optional caller-provided prompt into the
    /// shape Azure accepts. The output `language` is always either a
    /// single ISO-639-1 code or `nil`. The output `prompt` may merge
    /// the caller's custom instruction with an auto-built
    /// multi-language hint when 2+ hints are supplied.
    public static func resolve(
        hints: [String],
        customInstruction: String?
    ) -> (language: String?, prompt: String?) {
        let normalised = canonicalise(hints)

        let baseInstruction = customInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        switch normalised.count {
        case 0:
            return (language: nil, prompt: baseInstruction)
        case 1:
            return (language: normalised[0], prompt: baseInstruction)
        default:
            let multilingualHint = makeMultilingualPrompt(codes: normalised)
            let combinedPrompt: String = {
                if let baseInstruction {
                    return baseInstruction + "\n\n" + multilingualHint
                }
                return multilingualHint
            }()
            return (language: nil, prompt: combinedPrompt)
        }
    }

    /// Strip BCP-47 region tags (`en-US` → `en`), lowercase, drop
    /// blank entries, dedupe while preserving order.
    static func canonicalise(_ hints: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for hint in hints {
            let trimmed = hint.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let stripped: String = {
                if let dash = trimmed.firstIndex(where: { $0 == "-" || $0 == "_" }) {
                    return String(trimmed[..<dash])
                }
                return trimmed
            }().lowercased()
            guard !stripped.isEmpty else { continue }
            if seen.insert(stripped).inserted {
                out.append(stripped)
            }
        }
        return out
    }

    /// Compose the verbatim multi-language hint text. Uses English
    /// names regardless of UI locale so the prompt is consistent for
    /// the model.
    static func makeMultilingualPrompt(codes: [String]) -> String {
        let names = codes.map { displayName(forCode: $0) }
        let joined: String = {
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            case 2: return "\(names[0]) and \(names[1])"
            default:
                let head = names.dropLast().joined(separator: ", ")
                return "\(head), and \(names.last!)"
            }
        }()
        return """
        The audio contains speech in \(joined). \
        Transcribe each utterance in its original language using the original script — do not translate.
        """
    }

    /// Map an ISO-639-1 / ISO-639-3 code to its English display name.
    /// Falls back to the upper-cased code when the locale lookup
    /// returns nil (e.g. unknown / non-standard code).
    static func displayName(forCode code: String) -> String {
        let englishLocale = Locale(identifier: "en")
        if let name = englishLocale.localizedString(forLanguageCode: code), !name.isEmpty {
            return name
        }
        return code.uppercased()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
