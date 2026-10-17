// ntakker-studio/Views/TranscriptPane.swift — plan-024 T9.
//
// The transcript, line by line, on the audio timeline. The line being
// played is highlighted and, with "Follow" on, kept in view. Click a
// line to play from there; double-click (or the context menu) to fix
// its text, which is saved back to the transcript file.

import AppKit
import NtakkerStudioKit
import SwiftUI

struct TranscriptPane: View {
    @Bindable var workspace: RecordingWorkspace

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if workspace.recording.transcripts.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote",
                                       description: Text("This recording was made without transcription. Use Re-transcribe on the right to create one."))
            } else if !workspace.isLoaded {
                ProgressView("Loading transcript…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                lines
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter lines", text: $workspace.filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            SpeakerFilterMenu(workspace: workspace)
            Spacer()
            Toggle(isOn: $workspace.followPlayback) { Label("Follow", systemImage: "scope") }
                .toggleStyle(.button)
                .help("Keep the line being played in view")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var lines: some View {
        let shown = workspace.shownEntries
        let active = workspace.activeEntryID
        let long = workspace.duration >= 3600
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { entry in
                        TranscriptRow(workspace: workspace, entry: entry, isActive: entry.id == active, longForm: long)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: workspace.filterText)
                }
            }
            .onChange(of: active) { _, id in
                guard workspace.followPlayback, workspace.editingID == nil, let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct SpeakerFilterMenu: View {
    @Bindable var workspace: RecordingWorkspace

    var body: some View {
        let speakers = workspace.speakers
        if speakers.count > 1 {
            Menu {
                ForEach(speakers, id: \.key) { s in
                    Toggle(isOn: Binding(
                        get: { !workspace.hiddenSpeakers.contains(s.key) },
                        set: { on in
                            if on { workspace.hiddenSpeakers.remove(s.key) } else { workspace.hiddenSpeakers.insert(s.key) }
                        }
                    )) { Text("\(s.label) (\(s.count))") }
                }
                Divider()
                Button("Show everyone") { workspace.hiddenSpeakers = [] }
            } label: {
                Label(workspace.hiddenSpeakers.isEmpty ? "All speakers" : "\(speakers.count - workspace.hiddenSpeakers.count) of \(speakers.count) speakers",
                      systemImage: "person.2")
            }
            .fixedSize()
        }
    }
}

struct TranscriptRow: View {
    let workspace: RecordingWorkspace
    let entry: TranscriptEntry
    let isActive: Bool
    let longForm: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool { workspace.editingID == entry.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                workspace.player.seek(to: entry.start)
                workspace.player.play()
            } label: {
                Text(StudioAsk.timecode(entry.start, longForm: longForm))
                    .font(.callout.monospacedDigit())
            }
            .buttonStyle(.borderless)
            .help("Play from here")
            .frame(width: longForm ? 70 : 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.speakerLabel(entry.segment))
                    .font(.caption.bold())
                    .foregroundStyle(SpeakerColor.color(for: workspace.speakerKey(entry.segment)))
                if isEditing {
                    TextField("Text", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { workspace.editingID = nil }
                        .onAppear { draft = entry.segment.text; focused = true }
                    HStack {
                        Button("Save", action: commit).keyboardShortcut(.defaultAction)
                        Button("Cancel") { workspace.editingID = nil }
                    }
                    .controlSize(.small)
                } else {
                    Text(entry.segment.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.editingID = entry.id }
        .onTapGesture { if !isEditing { workspace.player.seek(to: entry.start) } }
        .contextMenu {
            Button("Play from Here") { workspace.player.seek(to: entry.start); workspace.player.play() }
            Button("Edit Text") { workspace.editingID = entry.id }
            Divider()
            Button("Cut This Line") { workspace.addCut(CutRange(start: entry.start, end: max(entry.end, entry.start + 0.5))) }
            Button("Start Selection Here") {
                let end = workspace.selection?.end ?? max(entry.end, entry.start + 1)
                workspace.selection = CutRange(start: entry.start, end: max(end, entry.start))
            }
            Button("End Selection Here") {
                let start = workspace.selection?.start ?? entry.start
                workspace.selection = CutRange(start: start, end: max(entry.end, entry.start + 0.5))
            }
            Divider()
            Button("Copy Text") { copy(entry.segment.text) }
            Button("Copy with Time") {
                copy("[\(StudioAsk.timecode(entry.start, longForm: longForm))] \(workspace.speakerLabel(entry.segment)): \(entry.segment.text)")
            }
        }
    }

    private var rowBackground: some View {
        Group {
            if workspace.cutPlan.isRemoved((entry.start + entry.end) / 2) {
                Color.red.opacity(0.10)
            } else if isActive {
                Color.accentColor.opacity(0.16)
            } else {
                Color.clear
            }
        }
    }

    private func commit() {
        workspace.updateText(of: entry, to: draft)
        workspace.editingID = nil
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red]

    static func color(for key: String) -> Color {
        if key == "source:microphone" { return .blue }
        if key == "source:system" { return .orange }
        let n = key.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }
        return palette[Int(n % UInt32(palette.count))]
    }
}
