// ntakker-studio/Views/ContentView.swift — plan-024 T9.

import NtakkerStudioKit
import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            if library.root == nil {
                ChooseLibraryView()
            } else if let ws = library.workspace {
                RecordingDetailView(workspace: ws)
                    .id(ws.recording.id)
            } else {
                ContentUnavailableView(
                    "No recording selected",
                    systemImage: "waveform",
                    description: Text("Pick a recording on the left, or search inside every transcript.")
                )
            }
        }
        .searchable(text: $library.query, placement: .sidebar, prompt: "Search recordings and transcripts")
        .onAppear {
            PlaybackKeys.player = { library.workspace?.player }
        }
    }
}

struct ChooseLibraryView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        ContentUnavailableView {
            Label("Choose your recordings folder", systemImage: "folder.badge.questionmark")
        } description: {
            Text("ntakker studio reads the recordings ntakker saved. Pick the folder that holds them (usually ~/Recordings).")
        } actions: {
            Button("Choose Folder…") { library.chooseFolder() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct StudioSettingsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Form {
            LabeledContent("Library folder") {
                HStack {
                    Text(library.root?.path ?? "Not chosen")
                        .foregroundStyle(library.root == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…") { library.chooseFolder() }
                }
            }
            LabeledContent("Ask, minutes and re-transcription") {
                Text("Use ntakker's settings in ~/.tool-agents/ntakker/.env (NTAKKER_ASK_PROVIDER, provider keys). Change them in ntakker's Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
    }
}
