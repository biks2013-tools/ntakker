// MacrecCore/Transcription/Dual/ChannelConfig.swift — see project-design.md §DT-3, plan-010-dual-transcription.md §Wave-1
//
// Phase A (plan-010) — per-channel provider + locale + display-name
// triple consumed by `DualTranscriptionConfig`. The `providerId` is
// intentionally a `String` (matching the existing
// `TranscriptionProviderFactoryInput.providerId` convention) rather
// than a typed enum — this keeps the v1→generic migration path open
// without an extra enum-to-string mapping layer at the manager
// boundary.

import Foundation

/// Per-channel provider + locale + display-name triple used by
/// `DualTranscriptionConfig`.
///
/// `Sendable` so the value can flow from the resolver into the
/// `DualTranscriptionManager` actor. `Equatable` for value-comparison
/// in tests and `RecordingOptions.Equatable` synthesis. `Codable` for
/// the JSONL-side persistence path.
public struct ChannelConfig: Sendable, Equatable, Codable {

    /// Provider identifier; in v1 always `"apple"` for Channel A and
    /// `"apple-cloud"` for Channel B. Stored as `String` (not an enum)
    /// so future-added providers (e.g. Soniox in a later wave) do not
    /// require a Core-target redeploy. See §DT-3 commentary.
    public let providerId: String

    /// BCP-47 locale identifier (e.g. `"en-US"`, `"el-GR"`). Validated
    /// at `DualTranscriptionConfig.init` against the per-channel
    /// supported sets in `DualLocaleSets`.
    public let locale: String

    /// User-facing display name for the channel header in the dual
    /// transcript panel (e.g. `"Apple (on-device)"`, `"Apple Cloud"`).
    public let displayName: String

    public init(providerId: String, locale: String, displayName: String) {
        self.providerId = providerId
        self.locale = locale
        self.displayName = displayName
    }
}
