// NtakkerCore/Asking/AskContextWindow.swift
//
// User-selectable transcript-context window for the Ask flow. Lets the
// caller pick HOW MUCH of the live transcript is bundled into the LLM
// prompt — orthogonal to the env-level default `contextMinutes` that
// drives a session-wide default.
//
// The popover's Asking pane lets the user toggle between five concrete
// options (full conversation / 15-min / 10-min / 2-min / none). Each
// is mapped to one of the three cases below, which `AskPromptBuilder`
// honours when constructing the user-message payload:
//
//   * `.full`        — every segment in `segments` is included
//                      (still subject to the 32 KB head-truncation
//                      guardrail).
//   * `.minutes(n)`  — only segments whose `lastUpdated` is within the
//                      most-recent `n` minutes of the last segment.
//   * `.none`        — the transcript window is empty; the model answers
//                      from general knowledge only.
//
// `Codable` so the UI can persist the user's last choice via
// `@AppStorage` without writing a custom JSON dance per call-site.

import Foundation

public enum AskContextWindow: Sendable, Equatable, Codable, Hashable {
    case full
    case minutes(Int)
    case none

    /// Stable string identifier used by `@AppStorage` and by URL
    /// query-parameter encodings. Picks dash-separated lower-case
    /// tokens so logs stay readable.
    public var storageID: String {
        switch self {
        case .full:           return "full"
        case .none:           return "none"
        case .minutes(let n): return "minutes-\(n)"
        }
    }

    /// Parse a `storageID` back into the case. Returns `nil` when the
    /// payload does not match any known shape — callers must decide
    /// whether to fall through to a default or raise.
    public static func fromStorageID(_ raw: String) -> AskContextWindow? {
        switch raw {
        case "full":  return AskContextWindow.full
        case "none":  return AskContextWindow.none
        default:
            guard raw.hasPrefix("minutes-"),
                  let n = Int(raw.dropFirst("minutes-".count)),
                  n > 0
            else { return nil }
            return .minutes(n)
        }
    }

    /// Human-readable label shown to the user (popover picker, sidecar
    /// metadata). Localized via `String(localized:)` so the UI strings
    /// stay translatable.
    public var displayLabel: String {
        switch self {
        case .full:           return String(localized: "Complete conversation")
        case .none:           return String(localized: "No context")
        case .minutes(let n): return String(localized: "Last \(n) min")
        }
    }

    /// Compact label used in tight chrome (the picker chip, the QA
    /// sidecar header). Always ASCII / single-line.
    public var compactLabel: String {
        switch self {
        case .full:           return "all"
        case .none:           return "none"
        case .minutes(let n): return "\(n)m"
        }
    }

    /// Maps the case onto the legacy `contextMinutes: Int` field on
    /// `AskRequestMetadata` for sidecar persistence. `.full` and
    /// `.none` use sentinel values (`-1` and `0`) so downstream tools
    /// can still round-trip the metadata while preserving the user's
    /// choice. New callers should prefer carrying the enum end-to-end
    /// rather than the legacy Int.
    public var legacyContextMinutes: Int {
        switch self {
        case .full:           return -1
        case .none:           return 0
        case .minutes(let n): return n
        }
    }
}
