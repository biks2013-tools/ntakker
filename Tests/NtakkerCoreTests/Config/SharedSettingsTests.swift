import Foundation
import Testing
@testable import NtakkerCore

/// plan-025 — one settings file for ntakker, ntakker-cli and ntakker studio.
/// Every test works on temporary files, never the real ~/.tool-agents.
@Suite("SharedSettings")
struct SharedSettingsTests {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("shared-settings-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("adopt writes only the keys the file lacks")
    func adopt() throws {
        let file = tempDir().appendingPathComponent(".env")
        try "NTAKKER_FORMAT=wav\nSONIOX_API_KEY=abc\n".write(to: file, atomically: true, encoding: .utf8)
        let written = try SharedSettings.adopt([
            "NTAKKER_FORMAT": "m4a", "NTAKKER_LAYOUT": "split", "NTAKKER_RECORDINGS_DIR": "/x y", "EMPTY": "",
        ], file: file)
        #expect(written == ["NTAKKER_LAYOUT", "NTAKKER_RECORDINGS_DIR"])
        let all = try SharedSettings.readAll(file: file)
        #expect(all["NTAKKER_FORMAT"] == "wav", "existing value kept")
        #expect(all["NTAKKER_LAYOUT"] == "split")
        #expect(all["NTAKKER_RECORDINGS_DIR"] == "/x y")
        #expect(all["SONIOX_API_KEY"] == "abc")
        #expect(all["EMPTY"] == nil)
    }

    @Test("the CLI's old file is merged once and renamed")
    func legacyCLI() throws {
        let root = tempDir()
        let old = root.appendingPathComponent("ntakker-cli/.env")
        let shared = root.appendingPathComponent("ntakker/.env")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "NTAKKER_TRANSCRIBE=soniox\nNTAKKER_FORMAT=caf\n".write(to: old, atomically: true, encoding: .utf8)
        try "NTAKKER_FORMAT=m4a\n".write(to: shared, atomically: true, encoding: .utf8)
        let written = try SharedSettings.migrateLegacyCLIFile(from: old, into: shared)
        #expect(written == ["NTAKKER_TRANSCRIBE"])
        #expect(try SharedSettings.readAll(file: shared) == ["NTAKKER_FORMAT": "m4a", "NTAKKER_TRANSCRIBE": "soniox"])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().appendingPathComponent(".env.merged-into-ntakker").path))
        #expect(try SharedSettings.migrateLegacyCLIFile(from: old, into: shared).isEmpty, "nothing left to merge")
    }

    @Test("ntakker's preferences map onto the CLI's names")
    func appPreferences() {
        let suite = "shared-settings-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("/Users/me/Recordings", forKey: "com.ntakker-cli.ui.outputFolder")
        d.set("wav", forKey: "com.ntakker-cli.ui.format")
        d.set("split", forKey: "com.ntakker-cli.ui.layout")
        d.set("__default__", forKey: "com.ntakker-cli.ui.micUID")
        d.set(true, forKey: "com.ntakker-cli.ui.micAEC")
        d.set("soniox", forKey: "com.ntakker-cli.ui.transcribeProvider")
        d.set(false, forKey: "com.ntakker-cli.ui.transcriptionEnabled")
        d.set("both", forKey: "com.ntakker-cli.ui.transcribeSource")
        d.set("el-GR", forKey: "com.ntakker-cli.ui.transcribeLanguage")
        d.set("en-US", forKey: "com.ntakker-cli.ui.transcribeLanguage2")
        d.set("el-GR", forKey: "com.ntakker-cli.ui.transcribeLanguage3")
        let v = SharedSettings.valuesFromAppPreferences(d)
        #expect(v == [
            "NTAKKER_RECORDINGS_DIR": "/Users/me/Recordings",
            "NTAKKER_FORMAT": "wav",
            "NTAKKER_LAYOUT": "split",
            "NTAKKER_MIC_AEC": "true",
            "NTAKKER_TRANSCRIBE": "none",
            "NTAKKER_TRANSCRIBE_SOURCE": "both",
            "NTAKKER_TRANSCRIBE_LANGUAGE": "el-GR,en-US",
        ])
        // The values are ones the CLI accepts.
        let resolved = try? ConfigResolver(toolName: "x", shellEnv: [:], userEnv: v.merging(["OUTPUT_PATH": "/tmp/a.wav"]) { a, _ in a }, localEnv: [:])
            .resolve(cliOverrides: [:])
        #expect(resolved?.format == .wav)
        #expect(resolved?.layout == .split)
        #expect(resolved?.micAEC == true)
        #expect(resolved?.transcriptionProviderId == nil, "none = no transcription")
    }
}
