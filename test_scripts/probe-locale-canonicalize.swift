// test_scripts/probe-locale-canonicalize.swift
//
// Probes several candidate canonicalisation strategies for
// Locale.current values that include regional-override extensions
// like `en_US@rg=grzzzz`. The streaming Apple-Speech provider needs
// the bare `<lang>-<region>` (`en-US`) form because that is what
// `SFSpeechRecognizer.supportedLocales()` returns.
//
// Run with:
//   swift test_scripts/probe-locale-canonicalize.swift

import Foundation
import Speech

// Strategy A — current implementation: language.languageCode + locale.region
func canonA(_ locale: Locale) -> String? {
    guard
        let lang = locale.language.languageCode?.identifier,
        let region = locale.region?.identifier
    else { return nil }
    return "\(lang)-\(region)"
}

// Strategy B — language.languageCode + language.region
//   `Locale.Language.region` is the language's primary region,
//   independent of the `@rg=...` regional override (which only
//   affects formatting, not the language pair itself).
func canonB(_ locale: Locale) -> String? {
    guard
        let lang = locale.language.languageCode?.identifier,
        let region = locale.language.region?.identifier
    else { return nil }
    return "\(lang)-\(region)"
}

// Strategy C — split the raw identifier on `@` to drop extensions,
//   then normalise underscore → hyphen.
func canonC(_ locale: Locale) -> String {
    let core = locale.identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? locale.identifier
    return core.replacingOccurrences(of: "_", with: "-")
}

// Strategy D — Locale.Components(identifier:) decomposition
func canonD(_ locale: Locale) -> String? {
    let comps = Locale.Components(identifier: locale.identifier)
    guard
        let lang = comps.languageComponents.languageCode?.identifier,
        let region = comps.languageComponents.region?.identifier
    else { return nil }
    return "\(lang)-\(region)"
}

let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier })

let cases: [String] = [
    Locale.current.identifier,
    "en_US@rg=grzzzz",
    "en_US",
    "en-US",
    "el_GR",
    "el-GR",
    "fr_FR",
    "fr-FR@calendar=hebrew",
]

func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
print("\(pad("raw", 26)) | \(pad("A", 14)) | \(pad("B", 14)) | \(pad("C", 14)) | D")
print(String(repeating: "-", count: 90))
for raw in cases {
    let loc = Locale(identifier: raw)
    let a = canonA(loc) ?? "<nil>"
    let b = canonB(loc) ?? "<nil>"
    let c = canonC(loc)
    let d = canonD(loc) ?? "<nil>"
    func tag(_ s: String) -> String { "\(s) \(supported.contains(s) ? "✓" : "✗")" }
    print("\(pad(raw, 26)) | \(pad(tag(a), 14)) | \(pad(tag(b), 14)) | \(pad(tag(c), 14)) | \(tag(d))")
}
