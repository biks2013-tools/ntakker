// test_scripts/probe-apple-speech-locales.swift
//
// One-shot diagnostic for the apple-speech "empty transcript" bug.
//
// Reports:
//   1. The user's Locale.current.identifier (the value the apple
//      provider falls back to when no MACREC_TRANSCRIBE_LANGUAGE is set).
//   2. The full sorted set of SFSpeechRecognizer.supportedLocales()
//      identifiers.
//   3. Whether `Locale.current.identifier` is in the supported set
//      verbatim, and whether plain canonical variants (`en-US`,
//      `en_US`, the language code alone) are in the set.
//   4. (When run on macOS 26+) Whether `SpeechTranscriber` can be
//      constructed for `en-US`, and whether
//      `AssetInventory.status(forModules:)` reports the model as
//      `.installed`.
//
// Run with:
//   swift test_scripts/probe-apple-speech-locales.swift
//
// (No build / no Package edits — this is a top-level script that uses
// only system-framework imports.)

import Foundation
import Speech

let cur = Locale.current
print("Locale.current                       = \(cur)")
print("Locale.current.identifier            = \(cur.identifier)")
print("Locale.current.language.languageCode = \(String(describing: cur.language.languageCode))")
print("Locale.current.region                = \(String(describing: cur.region))")
print("")

let supported = SFSpeechRecognizer.supportedLocales()
let supportedIds = supported.map { $0.identifier }.sorted()
print("SFSpeechRecognizer.supportedLocales().count = \(supportedIds.count)")
print("First 30 supported ids: \(supportedIds.prefix(30).joined(separator: ", "))")
print("")

let supportedSet = Set(supportedIds)

func check(_ id: String) {
    let inSet = supportedSet.contains(id)
    print("  '\(id)' supported? \(inSet ? "YES" : "no")")
}

print("Membership checks:")
check(cur.identifier)
check("en-US")
check("en_US")
check("en")
check("el-GR")
check("el_GR")
check("el")
print("")

if #available(macOS 26.0, *) {
    print("macOS 26+ — probing SpeechTranscriber + AssetInventory for 'en-US':")
    let locale = Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    Task {
        let status = await AssetInventory.status(forModules: [transcriber])
        print("  AssetInventory.status(en-US)   = \(status)")

        // Also probe Locale.current verbatim — that's what the provider
        // does when languageHints is empty.
        let curTranscriber = SpeechTranscriber(locale: cur, preset: .progressiveTranscription)
        let curStatus = await AssetInventory.status(forModules: [curTranscriber])
        print("  AssetInventory.status(Locale.current=\(cur.identifier)) = \(curStatus)")
        exit(0)
    }
    RunLoop.main.run()
} else {
    print("Skipping SpeechAnalyzer probe — running on pre-macOS-26.")
}
