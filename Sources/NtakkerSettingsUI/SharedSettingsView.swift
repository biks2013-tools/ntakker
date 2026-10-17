// NtakkerSettingsUI/SharedSettingsView.swift — plan-025.
//
// The Settings window content both apps embed: every shared setting,
// grouped (Recording, Transcription, Ask, each provider, Studio), plus
// the app's own panes before and after them.

import AppKit
import NtakkerCore
import SwiftUI

/// A pane an app adds next to the shared ones.
public struct SettingsPane: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let content: () -> AnyView

    public init<V: View>(id: String, title: String, systemImage: String, @ViewBuilder content: @escaping () -> V) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.content = { AnyView(content()) }
    }
}

public struct SharedSettingsView: View {
    private let leading: [SettingsPane]
    private let trailing: [SettingsPane]
    private let selectionKey: String
    @State private var selection: String = ""
    @Bindable private var store = SharedSettingsStore.shared

    /// - Parameters:
    ///   - leading / trailing: the app's own panes, shown before / after the shared ones.
    ///   - selectionKey: UserDefaults key remembering the last pane (per app).
    public init(leading: [SettingsPane] = [], trailing: [SettingsPane] = [], selectionKey: String) {
        self.leading = leading
        self.trailing = trailing
        self.selectionKey = selectionKey
    }

    public static let sharedPanes: [SettingsPane] = [
        SettingsPane(id: "recording", title: "Recording", systemImage: "record.circle") { RecordingSettingsPane() },
        SettingsPane(id: "transcription", title: "Transcription", systemImage: "text.quote") { TranscriptionSettingsPane() },
        SettingsPane(id: "asking", title: "Asking (Q&A)", systemImage: "bubble.left.and.text.bubble.right") { AskingSettingsView() },
        SettingsPane(id: "whisperkit", title: "WhisperKit (on-device)", systemImage: "cpu") { WhisperKitSettingsView() },
        SettingsPane(id: "parakeet", title: "Parakeet (on-device)", systemImage: "bird") { ParakeetSettingsView() },
        SettingsPane(id: "gemini", title: "Gemini", systemImage: "sparkles") { GeminiSettingsView() },
        SettingsPane(id: "soniox", title: "Soniox", systemImage: "waveform.path") { SonioxSettingsView() },
        SettingsPane(id: "azure", title: "Azure OpenAI", systemImage: "cloud") { AzureBatchSettingsView() },
        SettingsPane(id: "azureRealtime", title: "Azure OpenAI Realtime", systemImage: "cloud.bolt") { AzureRealtimeSettingsView() },
        SettingsPane(id: "elevenlabs", title: "ElevenLabs", systemImage: "mic.badge.plus") { ElevenLabsSettingsView() },
        SettingsPane(id: "studio", title: "Studio", systemImage: "waveform") { StudioSettingsPane() },
    ]

    private var all: [SettingsPane] { leading + Self.sharedPanes + trailing }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { current }, set: { select($0) })) {
                if !leading.isEmpty {
                    Section("This app") { rows(leading) }
                }
                Section("Shared by ntakker, ntakker-cli and ntakker studio") { rows(Self.sharedPanes) }
                if !trailing.isEmpty {
                    Section("This app") { rows(trailing) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.loadError {
                    Text(error).font(.callout).foregroundStyle(.orange).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1))
                }
                (all.first { $0.id == current }?.content() ?? AnyView(EmptyView()))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                HStack {
                    Text(SharedSettings.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([SharedSettings.fileURL]) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            store.reload()
            selection = UserDefaults.standard.string(forKey: selectionKey) ?? ""
        }
    }

    private var current: String {
        all.contains { $0.id == selection } ? selection : (all.first?.id ?? "")
    }

    private func select(_ id: String) {
        selection = id
        UserDefaults.standard.set(id, forKey: selectionKey)
    }

    @ViewBuilder
    private func rows(_ panes: [SettingsPane]) -> some View {
        ForEach(panes) { p in
            Label(p.title, systemImage: p.systemImage).tag(p.id)
        }
    }
}
