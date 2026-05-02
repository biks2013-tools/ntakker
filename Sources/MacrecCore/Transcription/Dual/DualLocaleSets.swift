// MacrecCore/Transcription/Dual/DualLocaleSets.swift — see project-design.md §DT-3 / §DT-9, plan-010-dual-transcription.md §Wave-1
//
// Phase A (plan-010) — single source of truth for the per-channel
// supported-locale sets used by the dual-transcription Channel A and
// Channel B locale pickers AND by `DualTranscriptionConfig.init`'s
// defensive validation backstop.
//
// IMPORTANT — the asymmetry between the two sets is the whole point of
// this file:
//
//   * Channel A (Apple on-device) sources from
//     `SpeechTranscriber.supportedLocales` — the macOS 26 on-device
//     `SpeechAnalyzer` set (~42 locales). EXCLUDES Greek (`el-GR`)
//     at macOS 26 launch. (Verified empirically; see
//     `docs/reference/apple-cloud-stt-investigation-2026-05.md §Q5`.)
//
//   * Channel B (Apple Cloud) sources from
//     `SFSpeechRecognizer.supportedLocales()` — the cloud-path set
//     (~57 locales). INCLUDES Greek.
//
// The Channel A locale picker MUST NOT reuse the existing
// `TranscriptionLanguagePicker`'s locale source (which uses
// `SFSpeechRecognizer.supportedLocales()` and would erroneously
// include Greek for an `apple` on-device session). This module
// enforces the distinction in one place.
//
// Synchronous bridge note. `SpeechTranscriber.supportedLocales` on
// macOS 26 is an `async` static accessor (`get async`). Both
// `DualTranscriptionConfig.init` and the SwiftUI pickers consume the
// list synchronously. We bridge by primer-on-first-use: the first
// access blocks on a one-shot `DispatchSemaphore` while the async
// query runs in a detached `Task`, then caches the resolved
// `[Locale]` for every subsequent access. The block is bounded by a
// 5-second timeout — if Apple's API hangs (it should not; the call
// is purely metadata) the helper returns an empty set and
// `DualTranscriptionConfig.init` will then raise
// `MacrecError.transcriptionDualLocaleUnsupported` to surface the
// problem at the configuration boundary (no fallback per project
// CLAUDE.md). The first-use blocking happens at most once per
// process lifetime; subsequent calls are O(1).

import Foundation
import Speech

/// Per-channel supported-locale sets for dual-transcription mode.
///
/// `enum` (no cases) used as a namespace — the helper has no instance
/// state beyond the two cached arrays guarded by `localeCacheLock`.
public enum DualLocaleSets {

    // MARK: - Defaults

    /// Default locale identifier for Channel A (Apple on-device).
    /// English (United States) is the v1 default per the user's primary
    /// "Greek with English code-switched words" use-case where the
    /// English-only on-device side captures the inserted English words.
    public static let channelADefaultLocale: String = "en-US"

    /// Default locale identifier for Channel B (Apple Cloud).
    /// Greek is the v1 default — `el-GR` is the only Greek locale
    /// `SFSpeechRecognizer.supportedLocales()` exposes.
    public static let channelBDefaultLocale: String = "el-GR"

    // MARK: - Public locale sets

    /// macOS 26 on-device locale set, sourced from
    /// `SpeechTranscriber.supportedLocales`. Sorted with English
    /// variants first, then alphabetical by identifier.
    ///
    /// EXCLUDES locales not in the on-device set (notably `el-GR` at
    /// the macOS 26 launch).
    public static var channelASupportedLocales: [Locale] {
        cachedChannelALocales()
    }

    /// `SFSpeechRecognizer.supportedLocales()` — the cloud-path
    /// supported set. Sorted with `el-GR` first, then English
    /// variants, then alphabetical.
    public static var channelBSupportedLocales: [Locale] {
        cachedChannelBLocales()
    }

    // MARK: - Caching

    /// Lock guarding the two `_cached*Locales` arrays. `NSLock` (not an
    /// actor) because the public surface is synchronous.
    private static let localeCacheLock = NSLock()
    nonisolated(unsafe) private static var _cachedChannelALocales: [Locale]? = nil
    nonisolated(unsafe) private static var _cachedChannelBLocales: [Locale]? = nil

    /// Bound on the first-use blocking wait for the async
    /// `SpeechTranscriber.supportedLocales` query. The metadata call
    /// is normally instant; the timeout is a defensive ceiling.
    private static let asyncResolveTimeoutSeconds: Int = 5

    private static func cachedChannelALocales() -> [Locale] {
        localeCacheLock.lock()
        if let cached = _cachedChannelALocales {
            localeCacheLock.unlock()
            return cached
        }
        localeCacheLock.unlock()

        let resolved = resolveChannelALocalesBlocking()
        let sorted = sortChannelA(resolved)

        localeCacheLock.lock()
        _cachedChannelALocales = sorted
        localeCacheLock.unlock()
        return sorted
    }

    private static func cachedChannelBLocales() -> [Locale] {
        localeCacheLock.lock()
        if let cached = _cachedChannelBLocales {
            localeCacheLock.unlock()
            return cached
        }
        localeCacheLock.unlock()

        let resolved = SFSpeechRecognizer.supportedLocales()
        let sorted = sortChannelB(Array(resolved))

        localeCacheLock.lock()
        _cachedChannelBLocales = sorted
        localeCacheLock.unlock()
        return sorted
    }

    /// Bridge the async `SpeechTranscriber.supportedLocales` accessor
    /// to a synchronous return. Uses a `DispatchSemaphore`-bounded
    /// wait; if the metadata query exceeds `asyncResolveTimeoutSeconds`
    /// the helper returns an empty array (the config-init defensive
    /// guard then raises `MacrecError.transcriptionDualLocaleUnsupported`,
    /// which is the correct user-visible failure mode per the project's
    /// no-fallback rule).
    private static func resolveChannelALocalesBlocking() -> [Locale] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var resolved: [Locale] = []
        Task.detached {
            let locales = await SpeechTranscriber.supportedLocales
            resolved = locales
            semaphore.signal()
        }
        let outcome = semaphore.wait(timeout: .now() + .seconds(asyncResolveTimeoutSeconds))
        if outcome == .timedOut {
            return []
        }
        return resolved
    }

    // MARK: - Sorting

    /// Channel A ordering: English variants first (alphabetical by
    /// identifier), then everything else alphabetical.
    private static func sortChannelA(_ locales: [Locale]) -> [Locale] {
        locales.sorted { lhs, rhs in
            let lhsEng = isEnglish(lhs)
            let rhsEng = isEnglish(rhs)
            if lhsEng != rhsEng { return lhsEng && !rhsEng }
            return lhs.identifier < rhs.identifier
        }
    }

    /// Channel B ordering: `el-GR` first, then English variants
    /// (alphabetical), then everything else alphabetical.
    private static func sortChannelB(_ locales: [Locale]) -> [Locale] {
        locales.sorted { lhs, rhs in
            let lhsGreek = lhs.identifier == "el-GR"
            let rhsGreek = rhs.identifier == "el-GR"
            if lhsGreek != rhsGreek { return lhsGreek && !rhsGreek }

            let lhsEng = isEnglish(lhs)
            let rhsEng = isEnglish(rhs)
            if lhsEng != rhsEng { return lhsEng && !rhsEng }

            return lhs.identifier < rhs.identifier
        }
    }

    private static func isEnglish(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }
}
