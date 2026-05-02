// MacrecCore/Transcription/Dual/DualTranscriptionConfig.swift — see project-design.md §DT-3, plan-010-dual-transcription.md §Wave-1
//
// Phase A (plan-010) — the resolved, validated configuration consumed
// by `DualTranscriptionManager`. Carried inside
// `RecordingOptions.dualTranscription`; non-nil presence is the
// single signal that `RecordingSession` should construct the dual
// manager rather than the single-provider one.
//
// All four validation guards in `init` raise `MacrecError` (no
// fallbacks, per CLAUDE.md "You must never create fallback solutions
// for configuration settings."). The validation is a defensive
// backstop — the UI / CLI layers SHOULD have already constrained
// inputs to the per-channel locale sets via `DualLocaleSets`, but
// stale `@AppStorage` values from a prior macOS minor release could
// carry an unsupported locale; this guard catches it before a
// `RecordingSession.start()` consumes the value.

import Foundation

/// Resolved dual-transcription configuration.
///
/// `Sendable` so the value can flow into the `DualTranscriptionManager`
/// actor; `Equatable` for value-comparison in tests and the
/// `RecordingOptions.Equatable` synthesised conformance; `Codable` so
/// the value can be persisted and round-tripped through CLI / config-
/// file boundaries.
public struct DualTranscriptionConfig: Sendable, Equatable, Codable {

    /// Channel A — Apple on-device. Hardwired to `providerId == "apple"`
    /// in v1; the structure is provider-agnostic so future waves can
    /// substitute a different on-device provider without breaking the
    /// `RecordingOptions` shape.
    public let channelA: ChannelConfig

    /// Channel B — Apple Cloud. Hardwired to
    /// `providerId == "apple-cloud"` in v1.
    public let channelB: ChannelConfig

    /// Audio source fed to BOTH channels. The dual orchestrator fans
    /// out the same `AlignedFrame` to two `AudioDownsampler` instances
    /// — both downsamplers receive identical frames.
    public let source: TranscriptionSource

    /// Sidecar transcript format. ONE merged sidecar carries segments
    /// from both channels (FR-7); the channel is identified by the
    /// segment's `model` field (`"apple"` / `"apple-cloud"`) and, for
    /// JSONL only, an OPTIONAL convenience `channel: "A" | "B"` field.
    public let sidecarFormat: TranscriptFormat

    /// Throwing initialiser with all four validation guards. NO
    /// fallbacks per CLAUDE.md — every missing or invalid field
    /// raises a `MacrecError`.
    ///
    /// Guards (in order):
    ///   1. Channel A locale non-empty
    ///   2. Channel B locale non-empty
    ///   3. Channel A locale ∈ `DualLocaleSets.channelASupportedLocales`
    ///   4. Channel B locale ∈ `DualLocaleSets.channelBSupportedLocales`
    ///   5. Defensive: same providerId AND same locale → conflict
    ///      (structurally unreachable in v1 since providers differ
    ///      by construction; the guard catches future-wave
    ///      misconfigurations).
    public init(
        channelA: ChannelConfig,
        channelB: ChannelConfig,
        source: TranscriptionSource,
        sidecarFormat: TranscriptFormat
    ) throws {
        // Guard 1 + 2 — non-empty locale identifiers.
        guard !channelA.locale.isEmpty else {
            throw MacrecError.transcriptionConfigurationMissing(
                field: "dualTranscription.channelA.locale"
            )
        }
        guard !channelB.locale.isEmpty else {
            throw MacrecError.transcriptionConfigurationMissing(
                field: "dualTranscription.channelB.locale"
            )
        }

        // Normalize BCP-47 hyphen form (`en-US`) → macOS canonical
        // identifier form (`en_US`) before set-membership checks.
        // User-facing inputs (CLI flags, AppStorage defaults, design
        // docs) all use BCP-47 hyphen form; macOS `Locale.identifier`
        // returns underscore form. Without normalization, valid
        // inputs would be rejected.
        let canonicalChannelALocale = Locale(identifier: channelA.locale).identifier
        let canonicalChannelBLocale = Locale(identifier: channelB.locale).identifier

        // Guard 3 — Channel A locale must be in
        // SpeechTranscriber.supportedLocales.
        let channelAIdentifiers = DualLocaleSets.channelASupportedLocales
            .map(\.identifier)
        guard channelAIdentifiers.contains(canonicalChannelALocale) else {
            throw MacrecError.transcriptionDualLocaleUnsupported(
                channel: .channelA, locale: channelA.locale
            )
        }

        // Guard 4 — Channel B locale must be in
        // SFSpeechRecognizer.supportedLocales().
        let channelBIdentifiers = DualLocaleSets.channelBSupportedLocales
            .map(\.identifier)
        guard channelBIdentifiers.contains(canonicalChannelBLocale) else {
            throw MacrecError.transcriptionDualLocaleUnsupported(
                channel: .channelB, locale: channelB.locale
            )
        }

        // Guard 5 — defensive: two channels MUST differ on at least
        // one of (provider, locale). In v1 they always differ on
        // provider; the guard catches future misconfigurations.
        if channelA.providerId == channelB.providerId
            && channelA.locale == channelB.locale {
            throw MacrecError.transcriptionDualLocaleConflict(
                locale: channelA.locale
            )
        }

        self.channelA = channelA
        self.channelB = channelB
        self.source = source
        self.sidecarFormat = sidecarFormat
    }
}
