// ntakker/RecordingStarter.swift — plan-015 Phase 1.8 / FR-IRQ-56 step 7.
//
// Shared helper that composes a `RecordingOptions` from the same
// `@AppStorage`-backed `UserDefaults` keys that `ControlBar.startTapped`
// reads, then asks the controller to start. Both the legacy Start
// button (`ControlBar.startTapped`) and `clearSession()` (RootView's
// New-Session-restart path) call into here so the option composition
// is single-source-of-truth.
//
// This file is the *new* canonical site for the composition; the old
// inline implementation in `ControlBar.swift` now just forwards to here.

import Foundation
import Logging
import NtakkerCore
import NtakkerUIKit
import NtakkerSettingsUI

@MainActor
enum RecordingStarter {
    private static let logger = Logger(label: "ntakker-cli.ui.recordingStarter")

    /// Compose `RecordingOptions` from the persisted `UserDefaults`
    /// state (the same slots that `ControlBar` and the various Settings
    /// views read) and forward to the controller.
    ///
    /// Side effects: when `com.ntakker-cli.ui.outputFolder` is empty (first
    /// launch / first programmatic start), the default `~/Recordings/`
    /// directory is resolved + persisted (FR-36 / R-32) before
    /// composition.
    static func start(controller: RecordingController) {
        let d = UserDefaults.standard
        let store = SharedSettingsStore.shared

        // FR-36 default-folder fallback (R-32).
        let folderPath: String = {
            let stored = store.string(SharedSettings.Keys.recordingsDir) ?? ""
            if stored.isEmpty {
                let resolved = DefaultRecordingFolder.resolve()
                store.set(SharedSettings.Keys.recordingsDir, resolved)
                logger.debug("resolved default folder on Start: \(resolved)")
                return resolved
            }
            return stored
        }()

        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let format = OutputFormat(
            rawValue: store.string(SharedSettings.Keys.format) ?? OutputFormat.m4a.rawValue
        ) ?? .m4a
        let layout = TrackLayout(
            rawValue: store.string(SharedSettings.Keys.layout) ?? TrackLayout.mixed.rawValue
        ) ?? .mixed

        let basenameStored = d.string(forKey: "com.ntakker-cli.ui.basename") ?? ""
        let resolvedBasename: String = {
            let trimmed = basenameStored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? FilenameGenerator.default(now: Date())
                : trimmed
        }()

        let outputURL = folder
            .appendingPathComponent(resolvedBasename)
            .appendingPathExtension(format.rawValue)

        let micUID = store.string(SharedSettings.Keys.micDevice) ?? ""
        let micDevice: String? = {
            if micUID.isEmpty || micUID == "__default__" { return nil }
            return micUID
        }()

        let micAEC: Bool = store.bool(SharedSettings.Keys.micAEC) ?? false

        // plan-025: one NTAKKER_TRANSCRIBE in the shared file (provider id,
        // or "none" = off; unset = apple, as in the CLI).
        let transcribeRawShared = store.string(SharedSettings.Keys.transcribe) ?? "apple"
        let transcriptionEnabled = transcribeRawShared.lowercased() != "none"
        let transcribeProviderRaw = transcribeRawShared

        let effectiveProvider: String = transcriptionEnabled ? transcribeProviderRaw : "none"
        let normalizedProvider = effectiveProvider.lowercased()
        let transcriptionActive = !normalizedProvider.isEmpty
            && normalizedProvider != "none"
            && normalizedProvider != "noop"
        let resolvedProviderId: String? = transcriptionActive ? normalizedProvider : nil
        let resolvedTranscriptionSource = TranscriptionSource(
            rawValue: store.string(SharedSettings.Keys.transcribeSource) ?? TranscriptionSource.mixed.rawValue
        ) ?? .mixed
        let resolvedTranscriptionFormat = TranscriptFormat(
            rawValue: store.string(SharedSettings.Keys.transcribeFormat) ?? TranscriptFormat.jsonl.rawValue
        ) ?? .jsonl

        let resolvedTranscriptionApiKey: String? = {
            guard transcriptionActive else { return nil }
            let envVar: String?
            switch (resolvedProviderId ?? "").lowercased() {
            case "gemini", "gemini-live":           envVar = "GOOGLE_API_KEY"
            case "soniox":                          envVar = "SONIOX_API_KEY"
            case "azure", "azure-openai-realtime":  envVar = "AZURE_OPENAI_API_KEY"
            case "elevenlabs":                      envVar = "ELEVENLABS_API_KEY"
            default:                                envVar = nil
            }
            guard let envVar else { return nil }
            return resolvedEnvValue(envVar)
        }()

        let azureProviderActive = transcriptionActive
            && ((resolvedProviderId ?? "").lowercased() == "azure"
                || (resolvedProviderId ?? "").lowercased() == "azure-openai-realtime")
        let azureOpenAIEndpoint: URL? = {
            guard azureProviderActive,
                  let raw = resolvedEnvValue("AZURE_OPENAI_ENDPOINT") else { return nil }
            return URL(string: raw)
        }()
        let azureOpenAIDeployment: String? = azureProviderActive
            ? resolvedEnvValue("AZURE_OPENAI_DEPLOYMENT") : nil
        let azureOpenAIApiVersion: String? = azureProviderActive
            ? resolvedEnvValue("AZURE_OPENAI_API_VERSION") : nil

        let resolvedLanguageHints: [String] = {
            guard transcriptionActive else { return [] }
            var seen: Set<String> = []
            var out: [String] = []
            let list = (store.string(SharedSettings.Keys.transcribeLanguage) ?? "").split(separator: ",")
            for raw in list {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if seen.insert(trimmed).inserted { out.append(trimmed) }
            }
            return out
        }()

        let elevenLabsActive = transcriptionActive
            && (resolvedProviderId ?? "").lowercased() == "elevenlabs"
        let elevenLabsKeyterms: [String]? = {
            guard elevenLabsActive,
                  let raw = resolvedEnvValue("ELEVENLABS_KEYTERMS"), !raw.isEmpty
            else { return nil }
            var seen: Set<String> = []
            var out: [String] = []
            for piece in raw.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted { out.append(trimmed) }
            }
            return out.isEmpty ? nil : out
        }()
        let elevenLabsNumSpeakers: Int? = {
            guard elevenLabsActive,
                  let raw = resolvedEnvValue("ELEVENLABS_NUM_SPEAKERS"),
                  let n = Int(raw), (1...32).contains(n)
            else { return nil }
            return n
        }()
        let elevenLabsDiarize: Bool? = {
            guard elevenLabsActive,
                  let raw = resolvedEnvValue("ELEVENLABS_DIARIZE")?.lowercased() else { return nil }
            switch raw {
            case "1", "true", "yes", "on":  return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }()

        let options = RecordingOptions(
            output: outputURL,
            format: format,
            layout: layout,
            micDevice: micDevice,
            micAEC: micAEC,
            transcriptionProviderId: resolvedProviderId,
            transcriptionSource: resolvedTranscriptionSource,
            transcriptionFormat: resolvedTranscriptionFormat,
            transcriptionApiKey: resolvedTranscriptionApiKey,
            transcriptionLanguageHints: resolvedLanguageHints,
            azureOpenAIEndpoint: azureOpenAIEndpoint,
            azureOpenAIDeployment: azureOpenAIDeployment,
            azureOpenAIApiVersion: azureOpenAIApiVersion,
            elevenLabsDiarize: elevenLabsDiarize,
            elevenLabsNumSpeakers: elevenLabsNumSpeakers,
            elevenLabsKeyterms: elevenLabsKeyterms
        )

        logger.debug(
            "starting recording: output=\(outputURL.path) format=\(format.rawValue) layout=\(layout.rawValue) transcribe=\(resolvedProviderId ?? "none")"
        )
        controller.setOptions(options)
        controller.start()
    }

    /// Mirror of `ControlBar.resolvedEnvValue` — the four-tier env
    /// resolution chain (local > user > shell). Kept in sync with
    /// `EnvFileStore.read(toolName:key:)` so the popover's env view
    /// agrees with the Settings panel.
    private static func resolvedEnvValue(_ envVar: String) -> String? {
        if let fromEnvFile = EnvFileStore.read(toolName: "ntakker", key: envVar),
           !fromEnvFile.isEmpty
        {
            return fromEnvFile
        }
        return ProcessInfo.processInfo.environment[envVar]
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
