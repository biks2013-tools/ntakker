// NtakkerSettingsUI/Panes/SharedCorePanes.swift — plan-025.
//
// Recording, Transcription and Studio panes over the shared settings file.
// Values that are unset show the default the tools use for them; a change
// is written to ~/.tool-agents/ntakker/.env at once and seen by ntakker,
// ntakker-cli and ntakker studio.

import AppKit
import NtakkerCore
import SwiftUI

/// A short "where this lives" footer shown under every shared pane.
struct SharedFileFootnote: View {
    let keys: [String]
    var body: some View {
        Text("Saved in \(SharedSettings.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) as \(keys.joined(separator: ", ")) — shared by ntakker, ntakker-cli and ntakker studio.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Recording

public struct RecordingSettingsPane: View {
    public init() {}

    @SharedSetting(SharedSettings.Keys.recordingsDir) private var folder = ""
    @SharedSetting(SharedSettings.Keys.format) private var format = OutputFormat.m4a.rawValue
    @SharedSetting(SharedSettings.Keys.layout) private var layout = TrackLayout.mixed.rawValue
    @SharedSetting(SharedSettings.Keys.micDevice) private var mic = ""
    @SharedBoolSetting(SharedSettings.Keys.micAEC) private var micAEC = false
    @State private var devices: [AudioInputDevice] = []

    public var body: some View {
        Form {
            Section("Recordings folder") {
                HStack {
                    Text(folder.isEmpty ? "Not set" : folder)
                        .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                    if !folder.isEmpty {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) } label: { Image(systemName: "folder") }
                            .help("Show in Finder")
                    }
                }
                Text("ntakker saves recordings here; ntakker studio shows the recordings in it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Picker("Format", selection: $format) {
                    ForEach(OutputFormat.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Layout", selection: $layout) {
                    Text("Mixed — one track").tag(TrackLayout.mixed.rawValue)
                    Text("Split — mic and system files").tag(TrackLayout.split.rawValue)
                    Text("Stereo split — mic left, system right").tag(TrackLayout.stereoSplit.rawValue)
                }
                Text("Split keeps the two sides apart, which ntakker studio needs for its echo filter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Device", selection: $mic) {
                    Text("System default").tag("")
                    ForEach(devices, id: \.uid) { d in Text(d.name).tag(d.uid) }
                    if !mic.isEmpty, !devices.contains(where: { $0.uid == mic }) {
                        Text("\(mic) (not connected)").tag(mic)
                    }
                }
                Toggle("Echo cancellation while recording", isOn: $micAEC)
                Text("Removes the speakers' sound from the microphone as it is recorded (ntakker's live echo canceller). Off by default.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                SharedFileFootnote(keys: [SharedSettings.Keys.recordingsDir, SharedSettings.Keys.format, SharedSettings.Keys.layout,
                                          SharedSettings.Keys.micDevice, SharedSettings.Keys.micAEC])
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = (try? AudioDeviceEnumerator.listInputs()) ?? [] }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Transcription

public struct TranscriptionSettingsPane: View {
    public init() {}

    /// CLI default when unset: Apple on-device.
    @SharedSetting(SharedSettings.Keys.transcribe) private var provider = TranscriptionProviderId.apple.rawValue
    @SharedSetting(SharedSettings.Keys.transcribeSource) private var source = TranscriptionSource.mixed.rawValue
    @SharedSetting(SharedSettings.Keys.transcribeFormat) private var format = TranscriptFormat.jsonl.rawValue
    @SharedSetting(SharedSettings.Keys.transcribeLanguage) private var languages = ""
    @State private var languageDraft = ""

    public static let providers: [(id: String, name: String)] = [
        ("none", "Off — no transcription"),
        ("apple", "Apple (on this Mac)"),
        ("apple-cloud", "Apple Cloud"),
        ("parakeet", "Parakeet (on this Mac)"),
        ("whisperkit", "WhisperKit (on this Mac)"),
        ("soniox", "Soniox"),
        ("gemini", "Google Gemini"),
        ("azure", "Azure OpenAI"),
        ("azure-openai-realtime", "Azure OpenAI Realtime"),
        ("elevenlabs", "ElevenLabs"),
    ]

    public var body: some View {
        Form {
            Section("Live transcription") {
                Picker("Provider", selection: $provider) {
                    ForEach(Self.providers, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Transcribe", selection: $source) {
                    Text("Everything (mixed)").tag(TranscriptionSource.mixed.rawValue)
                    Text("Microphone only").tag(TranscriptionSource.mic.rawValue)
                    Text("System audio only").tag(TranscriptionSource.system.rawValue)
                    Text("Both, separately").tag(TranscriptionSource.both.rawValue)
                }
                Picker("Transcript file", selection: $format) {
                    ForEach(TranscriptFormat.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                HStack {
                    TextField("Languages, e.g. el-GR, en-US", text: $languageDraft)
                        .onSubmit(saveLanguages)
                    Button("Save", action: saveLanguages).disabled(normalized(languageDraft) == languages)
                }
                Text("Comma-separated. Leave empty to let the provider detect the language. Provider keys and models are in each provider's pane.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                SharedFileFootnote(keys: [SharedSettings.Keys.transcribe, SharedSettings.Keys.transcribeSource,
                                          SharedSettings.Keys.transcribeFormat, SharedSettings.Keys.transcribeLanguage])
            }
        }
        .formStyle(.grouped)
        .onAppear { languageDraft = languages }
        .onChange(of: languages) { _, v in languageDraft = v }
    }

    private func normalized(_ s: String) -> String {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
    }

    private func saveLanguages() { languages = normalized(languageDraft) }
}

// MARK: - Studio

public struct StudioSettingsPane: View {
    public init() {}

    @SharedSetting(SharedSettings.Keys.studioEchoStrength) private var strength = "1"
    @SharedSetting(SharedSettings.Keys.studioEchoSuppression) private var suppression = "off"
    @SharedSetting(SharedSettings.Keys.studioEchoAdaptation) private var adaptation = "fast"

    public var body: some View {
        Form {
            Section("Echo filter") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Strength")
                        Spacer()
                        Text("\(Int(((Double(strength) ?? 1) * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(strength) ?? 1 },
                                          set: { strength = String(format: "%.2f", $0) }),
                           in: 0...1, step: 0.05)
                }
                Picker("Extra suppression", selection: $suppression) {
                    Text("Off").tag("off"); Text("Low").tag("low"); Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                Picker("Adaptation", selection: $adaptation) {
                    Text("Stable").tag("stable"); Text("Fast").tag("fast")
                }
                .pickerStyle(.segmented)
                Text("Used by ntakker studio's Remove echo while listening and by Export Copy with echo removal. The echo delay is set per recording, in the studio's player.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Calendar") {
                SettingsTextRow(
                    label: "Calendar command",
                    envVarName: SharedSettings.Keys.calendarCommand,
                    placeholder: "/full/path/m365mail calendar export --from {from} --to {to} --no-description",
                    helpText: "A command line that prints your calendar as JSON. {from} and {to} are replaced by the first and last day (YYYY-MM-DD). Give the program's full path: apps started from the Dock do not see your shell's PATH. Used by the studio to find the meeting a recording is (Info ▸ Meeting, and `ntakker-studio match-meetings`)."
                )
            }
            Section {
                SharedFileFootnote(keys: [SharedSettings.Keys.studioEchoStrength, SharedSettings.Keys.studioEchoSuppression,
                                          SharedSettings.Keys.studioEchoAdaptation, SharedSettings.Keys.calendarCommand])
            }
        }
        .formStyle(.grouped)
    }
}
