// NtakkerUIKit/LegacyDefaultsMigration.swift
//
// ntakker's bundle id changed from `com.local.ntakker` to
// `com.giorgosmarinos.ntakker` for the public, notarized release
// (2026-10-17). macOS keeps app preferences per bundle id, so the first
// launch under the new id copies every setting from the old preferences
// domain, once. Keys already set under the new id are never overwritten.
// Permissions (Microphone, Screen Recording, Speech) cannot be carried
// over; macOS asks for them again.

import Foundation

public enum LegacyDefaultsMigration {
    public static let legacyDomain = "com.local.ntakker"
    public static let doneKey = "com.giorgosmarinos.ntakker.migratedLegacyDefaults"

    /// Copy the legacy domain's settings into `defaults` once.
    /// - Returns: the number of settings copied (0 when already done or
    ///   when there is nothing to copy).
    @discardableResult
    public static func run(defaults: UserDefaults = .standard,
                           legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: legacyDomain)) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        var copied = 0
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: doneKey)
        return copied
    }
}
