// ntakker-studio/Views/ContentView.swift — plan-024 T9.

import NtakkerCore
import NtakkerSettingsUI
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
        .onChange(of: SharedSettingsStore.shared.string(SharedSettings.Keys.recordingsDir)) { _, _ in
            library.followSharedFolder()
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

/// The studio's Settings window: the shared settings view (plan-025).
struct StudioSettingsView: View {
    var body: some View {
        SharedSettingsView(selectionKey: "studio.settings.selectedPane")
    }
}
