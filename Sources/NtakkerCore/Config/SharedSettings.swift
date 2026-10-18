// NtakkerCore/Config/SharedSettings.swift — plan-025.
//
// One settings file for ntakker, ntakker-cli and ntakker studio:
// `~/.tool-agents/ntakker/.env`. Every real setting (provider keys, the
// recordings folder, format, layout, microphone, transcription, Ask, the
// studio's echo filter) lives there under one name, so a change in any of
// the three is seen by the other two. UI state (window sizes, expanded
// sections, appearance, privacy acknowledgements) stays in each app's own
// preferences.
//
// Before plan-025 the CLI read `~/.tool-agents/ntakker-cli/.env` and the
// apps kept their recording choices in their preferences; `migrate…`
// copies those into the shared file once, never overwriting a value the
// file already has.

import Foundation

public enum SharedSettings {
    /// Tool name of the shared folder: `~/.tool-agents/ntakker/`.
    public static let toolName = "ntakker"
    /// The CLI's folder before plan-025; still holds its pid and log files.
    public static let legacyCLIToolName = "ntakker-cli"

    public static var fileURL: URL { ToolAgentsBootstrap.userEnvPath(toolName: toolName) }

    /// Names of the settings the three tools share. CLI names where the
    /// CLI already had one.
    public enum Keys {
        /// Folder ntakker records into and the studio reads.
        public static let recordingsDir = "NTAKKER_RECORDINGS_DIR"
        public static let format = ConfigResolver.Keys.format
        public static let layout = ConfigResolver.Keys.layout
        public static let micDevice = ConfigResolver.Keys.micDevice
        public static let micAEC = ConfigResolver.Keys.micAEC
        /// Provider id, or `none` for no transcription.
        public static let transcribe = ConfigResolver.Keys.transcribe
        public static let transcribeSource = ConfigResolver.Keys.transcribeSource
        public static let transcribeFormat = ConfigResolver.Keys.transcribeFormat
        /// Comma-separated BCP-47 list, e.g. `el-GR,en-US`.
        public static let transcribeLanguage = ConfigResolver.Keys.transcribeLanguage
        public static let studioEchoStrength = "NTAKKER_STUDIO_ECHO_STRENGTH"
        public static let studioEchoSuppression = "NTAKKER_STUDIO_ECHO_SUPPRESSION"
        public static let studioEchoAdaptation = "NTAKKER_STUDIO_ECHO_ADAPTATION"
    }

    // MARK: - Reading and writing

    /// Every key in the shared file (empty when the file is missing).
    public static func readAll(file: URL = fileURL) throws -> [String: String] {
        try EnvFileStore.parse(at: file)
    }

    /// Write one value; an empty value removes the key. For the real file
    /// this is `EnvFileStore.upsert` (mode 0600, and the process
    /// environment updated); another `file` (tests) is just rewritten.
    public static func write(_ key: String, _ value: String, file: URL = fileURL) throws {
        if file.standardizedFileURL == fileURL.standardizedFileURL {
            try EnvFileStore.upsert(toolName: toolName, key: key, value: value)
            return
        }
        let original = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = EnvFileStore.rewrite(source: original, key: key, value: try EnvFileStore.quoted(value))
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Migrations

    /// Copy `values` into the shared file for every key it does not have
    /// yet. Returns the keys written.
    @discardableResult
    public static func adopt(_ values: [String: String], file: URL = fileURL) throws -> [String] {
        let existing = try readAll(file: file)
        var written: [String] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key })
        where !value.isEmpty && (existing[key] ?? "").isEmpty {
            try write(key, value, file: file)
            written.append(key)
        }
        return written
    }

    /// Merge the CLI's old `~/.tool-agents/ntakker-cli/.env` into the
    /// shared file (keys the shared file lacks), then rename it to
    /// `.env.merged-into-ntakker` so it is not merged twice and nobody is
    /// misled into editing it. A missing or empty old file is left alone.
    @discardableResult
    public static func migrateLegacyCLIFile(
        from old: URL = ToolAgentsBootstrap.userEnvPath(toolName: legacyCLIToolName),
        into file: URL = fileURL
    ) throws -> [String] {
        guard FileManager.default.fileExists(atPath: old.path) else { return [] }
        let values = try EnvFileStore.parse(at: old)
        guard !values.isEmpty else { return [] }
        if file.standardizedFileURL == fileURL.standardizedFileURL {
            _ = try ToolAgentsBootstrap.ensure(toolName: toolName)
        }
        let written = try adopt(values, file: file)
        let done = old.deletingLastPathComponent().appendingPathComponent(".env.merged-into-ntakker")
        try? FileManager.default.removeItem(at: done)
        try FileManager.default.moveItem(at: old, to: done)
        return written
    }

    /// The shared-file values for ntakker's recording preferences
    /// (UserDefaults keys of the menu-bar app before plan-025).
    public static func valuesFromAppPreferences(_ d: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        func s(_ k: String) -> String? {
            guard let v = d.string(forKey: k)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        out[Keys.recordingsDir] = s("com.ntakker-cli.ui.outputFolder")
        out[Keys.format] = s("com.ntakker-cli.ui.format")
        out[Keys.layout] = s("com.ntakker-cli.ui.layout")
        if let mic = s("com.ntakker-cli.ui.micUID"), mic != "__default__" { out[Keys.micDevice] = mic }
        if let aec = d.object(forKey: "com.ntakker-cli.ui.micAEC") as? Bool { out[Keys.micAEC] = aec ? "true" : "false" }
        let enabled = d.object(forKey: "com.ntakker-cli.ui.transcriptionEnabled") as? Bool
        if let provider = s("com.ntakker-cli.ui.transcribeProvider") {
            out[Keys.transcribe] = enabled == false ? "none" : provider
        } else if enabled == false {
            out[Keys.transcribe] = "none"
        }
        out[Keys.transcribeSource] = s("com.ntakker-cli.ui.transcribeSource")
        out[Keys.transcribeFormat] = s("com.ntakker-cli.ui.transcriptFormat")
        let langs = ["com.ntakker-cli.ui.transcribeLanguage", "com.ntakker-cli.ui.transcribeLanguage2", "com.ntakker-cli.ui.transcribeLanguage3"]
            .compactMap(s)
            .reduce(into: [String]()) { acc, l in if !acc.contains(l) { acc.append(l) } }
        if !langs.isEmpty { out[Keys.transcribeLanguage] = langs.joined(separator: ",") }
        return out.compactMapValues { $0 }
    }
}
