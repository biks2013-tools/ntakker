// MacrecCore/Errors/MacrecError+Dual.swift — see project-design.md §DT-3, plan-010-dual-transcription.md §Wave-1
//
// Phase A (plan-010) — dual-transcription error factories.
//
// Implementation note. The base `MacrecError` enum's case list is
// LOCKED by design §2.1 (Phase 9 regression-tests stderr strings
// verbatim). Rather than introduce four new cases — which would
// require editing the locked switch arms in `description`,
// `remediation`, and `exitCode` — we expose dual-mode failures as
// **static factories** on `MacrecError` that synthesise actionable,
// channel-tagged messages on top of the existing
// `transcriptionConfigConflict(reason:)` and
// `transcriptionProviderUnavailable(reason:)` cases. The cases
// already carry the right exit-code semantics (EX_USAGE = 64 for
// configuration; EX_SOFTWARE = 70 for runtime provider failures),
// so the dual-mode errors slot into the existing exit-code table
// without modification.
//
// All four messages are written for the user, name the failing
// channel by user-visible label ("Channel A" / "Channel B") rather
// than by raw enum case (`channelA`), and include a remediation
// hint in the conflict-reason string itself (the base error's
// `remediation` switch arm provides the broader guidance).

import Foundation

extension MacrecError {

    /// Required dual-mode configuration field is missing.
    ///
    /// Mapped to `transcriptionConfigConflict(reason:)` (exit code
    /// EX_USAGE = 64). The `field` parameter is a dotted path into
    /// `RecordingOptions.dualTranscription` (e.g.
    /// `"dualTranscription.channelA.locale"`).
    public static func transcriptionConfigurationMissing(
        field: String
    ) -> MacrecError {
        .transcriptionConfigConflict(
            reason: "dual-mode transcription is enabled but required field '\(field)' is missing. Set the corresponding @AppStorage key in macrec-ui or pass the matching --transcribe-dual-* flag."
        )
    }

    /// A dual-mode channel was assigned a BCP-47 locale that the
    /// channel's provider does not support. Channel A is constrained
    /// to `SpeechTranscriber.supportedLocales` (macOS 26 on-device
    /// set, ~42 locales, NO Greek). Channel B is constrained to
    /// `SFSpeechRecognizer.supportedLocales()` (~57 locales, includes
    /// Greek).
    ///
    /// Mapped to `transcriptionConfigConflict(reason:)` (exit code
    /// EX_USAGE = 64).
    public static func transcriptionDualLocaleUnsupported(
        channel: DualChannelTag,
        locale: String
    ) -> MacrecError {
        let label = channel.userFacingLabel
        let supportedSetName = (channel == .channelA)
            ? "SpeechTranscriber.supportedLocales (Apple on-device, ~42 locales)"
            : "SFSpeechRecognizer.supportedLocales() (Apple Cloud, ~57 locales)"
        return .transcriptionConfigConflict(
            reason: "\(label) locale '\(locale)' is not supported on this macOS version. Pick a locale from \(supportedSetName)."
        )
    }

    /// Both dual-mode channels resolved to the same `(provider, locale)`
    /// pair — an invalid configuration that would route both lanes
    /// through identical sessions. Defensive guard; structurally
    /// unreachable in v1 (Channel A is always `apple`, Channel B is
    /// always `apple-cloud`).
    ///
    /// Mapped to `transcriptionConfigConflict(reason:)` (exit code
    /// EX_USAGE = 64).
    public static func transcriptionDualLocaleConflict(
        locale: String
    ) -> MacrecError {
        .transcriptionConfigConflict(
            reason: "dual-mode transcription Channel A and Channel B both resolved to the same provider AND locale '\(locale)'. Configure each channel with a distinct provider or locale."
        )
    }

    /// Per-channel runtime failure — one of the two streaming sessions
    /// failed to start, ingest a frame, or emit an event. The merged
    /// event stream surfaces this as
    /// `TranscriptionEvent.dualChannelError(channel:detail:)`; the
    /// other channel continues to emit per FR-4 (channel isolation).
    ///
    /// Mapped to `transcriptionProviderUnavailable(reason:)` (exit
    /// code EX_SOFTWARE = 70). The Manager catches the underlying
    /// error inside the per-channel drain `Task` and wraps it through
    /// this factory — never propagated as a fatal `throws` from
    /// `DualTranscriptionManager.start()`.
    public static func transcriptionDualChannelFailure(
        channel: DualChannelTag,
        underlying: Error
    ) -> MacrecError {
        let label = channel.userFacingLabel
        return .transcriptionProviderUnavailable(
            reason: "dual-mode \(label) failed: \(underlying.localizedDescription)"
        )
    }
}

// MARK: - DualChannelTag user-facing label

extension DualChannelTag {
    /// User-visible label for the channel ("Channel A" / "Channel B"),
    /// embedded into error reason strings. Distinct from the
    /// `displayName` carried inside `ChannelConfig` (which is the
    /// provider's branded name like "Apple (on-device)") — the channel
    /// label is fixed and identifies the lane regardless of which
    /// provider is currently configured for it.
    fileprivate var userFacingLabel: String {
        switch self {
        case .channelA: return "Channel A"
        case .channelB: return "Channel B"
        }
    }
}
