// NtakkerStudioKit/Audio/EchoFilterSettings+Defaults.swift — 2026-10-17,
// moved to the shared settings file by plan-025.
//
// The echo filter's strength, suppression and adaptation live in the
// shared ~/.tool-agents/ntakker/.env (`NTAKKER_STUDIO_ECHO_*`), so they
// show in both apps' Settings windows. The echo delay override is per
// recording, in `<stem>.studio.json`. Unset keys mean the 0.2.0 behaviour
// (`EchoFilterSettings.standard`).

import Foundation
import NtakkerCore

extension EchoFilterSettings {
    /// The settings in `values` (the shared file's contents).
    public static func from(_ values: [String: String]) -> EchoFilterSettings {
        let std = EchoFilterSettings.standard
        return EchoFilterSettings(
            strength: values[SharedSettings.Keys.studioEchoStrength].flatMap(Double.init) ?? std.strength,
            suppression: values[SharedSettings.Keys.studioEchoSuppression].flatMap(Suppression.init(rawValue:)) ?? std.suppression,
            adaptation: values[SharedSettings.Keys.studioEchoAdaptation].flatMap(Adaptation.init(rawValue:)) ?? std.adaptation
        )
    }

    /// The settings in the shared file now.
    public static func load() -> EchoFilterSettings {
        from((try? SharedSettings.readAll()) ?? [:])
    }

    /// The shared-file values for these settings.
    public var fileValues: [String: String] {
        [
            SharedSettings.Keys.studioEchoStrength: String(format: "%.2f", strength),
            SharedSettings.Keys.studioEchoSuppression: suppression.rawValue,
            SharedSettings.Keys.studioEchoAdaptation: adaptation.rawValue,
        ]
    }
}
