// NtakkerStudioKit/Audio/EchoFilterSettings+Defaults.swift — 2026-10-17.
//
// The echo filter's strength, suppression and adaptation are app-wide
// preferences (the echo delay override is per recording, in
// `<stem>.studio.json`). Unset keys mean the 0.2.0 behaviour
// (`EchoFilterSettings.standard`).

import Foundation

extension EchoFilterSettings {
    public enum Keys {
        public static let strength = "studio.echo.strength"
        public static let suppression = "studio.echo.suppression"
        public static let adaptation = "studio.echo.adaptation"
    }

    public static func load(from d: UserDefaults = .standard) -> EchoFilterSettings {
        let std = EchoFilterSettings.standard
        return EchoFilterSettings(
            strength: d.object(forKey: Keys.strength) as? Double ?? std.strength,
            suppression: d.string(forKey: Keys.suppression).flatMap(Suppression.init(rawValue:)) ?? std.suppression,
            adaptation: d.string(forKey: Keys.adaptation).flatMap(Adaptation.init(rawValue:)) ?? std.adaptation
        )
    }

    public func save(to d: UserDefaults = .standard) {
        d.set(strength, forKey: Keys.strength)
        d.set(suppression.rawValue, forKey: Keys.suppression)
        d.set(adaptation.rawValue, forKey: Keys.adaptation)
    }
}
