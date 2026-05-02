// MacrecCore/Transcription/Dual/DualSidecarLabel.swift — see project-design.md §DT-2 (OQ-3 resolution) / §DT-7
//
// Phase B / Lane L-3 (plan-010) — pure helper that maps a `DualChannelTag`
// to the user-facing channel label string baked into sidecar lines.
//
// The label is a compact uppercase string ("EN" for Channel A, "EL" for
// Channel B in the v1 default English-Greek configuration) used by:
//
//   * `SrtTranscriptWriter` — speaker-prefix style: `EN: Hello world`.
//   * `VttTranscriptWriter` — voice tag: `<v EN>Hello world</v>`.
//   * `JsonlTranscriptWriter` — optional `channel` convenience field:
//     `{"channel": "EN", ...}`.
//
// Rationale for the labels (DT-ADR-10):
//   * Matches the de-facto SRT speaker-prefix convention (uppercase).
//   * VTT's `<v EN>` tag is the spec-compliant voice-tag form.
//   * Consumers (mpv, VLC, Premiere Pro) render either as a speaker tag.
//
// Why not `"A"` / `"B"`?
//   * The investigator initially proposed `A`/`B` (matching the routing
//     tag's enum-case suffix), but the design (§DT-2 OQ-3) elevated to
//     `EN` / `EL` because human readers immediately understand the
//     language abbreviation. The routing tag stays `channelA` /
//     `channelB` — that is the implementation-internal identifier — but
//     the user-visible label is the language abbreviation.
//
// Future-wave note (OQ-3 resolution generalisation):
//   * For locales other than the v1 English-Greek pair the helper
//     falls back to the BCP-47 primary language subtag, uppercased
//     (e.g. `de-DE` → `"DE"`, `fr-CA` → `"FR"`, `zh-Hant-TW` →
//     `"ZH"`). The fallback uses the first hyphen-separated segment
//     so it works for both two-letter (`de`) and three-letter (`yue`)
//     primary subtags. The fallback is invoked by the sidecar writer
//     ONLY for locale identifiers that are not the v1 default
//     `en-*` / `el-*` pair; the static `channelLabel(for:)` form
//     consumed by the v1 wave returns the hard-coded `EN` / `EL`
//     because the v1 spec hard-wires Channel A → English, Channel B
//     → Greek.

import Foundation

/// Helper that derives the user-visible channel label embedded in
/// sidecar lines from a `DualChannelTag` (or, for future generic-
/// dispatch waves, from a BCP-47 locale identifier).
///
/// Stateless — no instances are ever constructed.
public enum DualSidecarLabel {

    /// Map a routing tag to its v1 user-facing channel label.
    ///
    /// Hard-wired per §DT-2 OQ-3 resolution:
    ///   * `.channelA` → `"EN"` (Apple on-device, English by default)
    ///   * `.channelB` → `"EL"` (Apple Cloud, Greek by default)
    ///
    /// For future waves that generalise the channel-language coupling,
    /// call `channelLabel(forLocale:)` with the resolved BCP-47 locale
    /// identifier instead.
    public static func channelLabel(for tag: DualChannelTag) -> String {
        switch tag {
        case .channelA: return "EN"
        case .channelB: return "EL"
        }
    }

    /// Map a BCP-47 locale identifier to its uppercase primary-language
    /// subtag. Used by the sidecar writer when a future wave wires a
    /// non-v1 locale into one of the channels (e.g. Channel A becomes
    /// German on a localised user's Mac).
    ///
    /// Examples:
    ///   * `"en-US"` → `"EN"`
    ///   * `"el-GR"` → `"EL"`
    ///   * `"de-DE"` → `"DE"`
    ///   * `"fr-CA"` → `"FR"`
    ///   * `"zh-Hant-TW"` → `"ZH"`
    ///   * `""` → `""` (defensive — caller should never pass empty,
    ///     but the fallback returns empty rather than crashing)
    public static func channelLabel(forLocale identifier: String) -> String {
        guard let primary = identifier.split(separator: "-").first else {
            return ""
        }
        return String(primary).uppercased()
    }

    // MARK: - Lane L-6 (plan-010 Wave 4) — model → channel tag mapping
    //
    // The four format writers branch on the v1 provider id stored in
    // `TranscriptSegment.model` to derive the routing tag, which then
    // flows through `channelLabel(for:)` to produce the user-facing
    // label embedded in the sidecar line. Centralising the mapping in
    // ONE helper guarantees the four writers cannot drift; if a future
    // wave adds a third provider (or renames an existing one) only this
    // helper changes.

    /// Map a `TranscriptSegment.model` value to the routing tag used by
    /// the sidecar writers in dual mode.
    ///
    /// V1 mapping (DT-ADR-5 + plan-010 §Wave-4 Lane-L-6):
    ///   * `"apple"`       → `.channelA`
    ///   * `"apple-cloud"` → `.channelB`
    ///
    /// Returns `nil` for any other value (e.g. `"gemini-live"`,
    /// `"soniox"`, `nil` model). The dual-mode format writers MUST treat
    /// a `nil` return as a soft warning condition and emit the segment
    /// WITHOUT a channel label rather than silently picking a wrong
    /// channel — see plan-010 §Wave-4 Lane-L-6 "no fallbacks" guidance.
    public static func channelTag(forModel model: String?) -> DualChannelTag? {
        switch model {
        case "apple":       return .channelA
        case "apple-cloud": return .channelB
        default:            return nil
        }
    }
}
