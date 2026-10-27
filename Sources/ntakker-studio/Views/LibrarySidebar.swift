// ntakker-studio/Views/LibrarySidebar.swift — plan-024 T9.
//
// Recordings grouped by month. While the search field has text, the
// list shows the matching recordings and, below them, the transcript
// lines that match across the whole library; clicking a line opens its
// recording at that moment.
//
// 2026-10-27: right-click a recording to rename it, show it in Finder or
// move it to the Trash (also the Delete key and the File menu).

import NtakkerStudioKit
import SwiftUI

struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var library

    private enum Row: Hashable {
        case recording(String)
        case hit(String)
    }

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selection) {
            if library.query.isEmpty {
                ForEach(months, id: \.title) { month in
                    Section(month.title) {
                        ForEach(month.recordings) { rec in
                            RecordingRow(recording: rec).tag(rec.id)
                        }
                    }
                }
            } else {
                let recs = library.filteredRecordings
                if !recs.isEmpty {
                    Section("Recordings") {
                        ForEach(recs) { rec in RecordingRow(recording: rec).tag(rec.id) }
                    }
                }
                Section {
                    if library.hits.isEmpty {
                        Text(library.searching ? "Searching…" : library.query.count < 2 ? "Type at least 2 letters" : "No transcript lines match")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.hits) { hit in
                        SearchHitRow(hit: hit, query: library.query)
                            .contentShape(Rectangle())
                            .onTapGesture { library.open(hit) }
                    }
                } header: {
                    Text(library.hits.count >= 300 ? "In transcripts (first 300)" : "In transcripts (\(library.hits.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Rename…") { library.requestRename(ids) }
                    .disabled(ids.count != 1)
                Button("Show in Finder") { library.revealInFinder(ids) }
                Divider()
                Button(ids.count == 1 ? "Move to Trash" : "Move \(ids.count) Recordings to Trash", role: .destructive) {
                    library.requestTrash(ids)
                }
            }
        }
        .onDeleteCommand { library.requestTrash() }
        .sheet(item: $library.renameRequest) { rec in
            RenameRecordingSheet(recording: rec)
        }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { !library.trashRequest.isEmpty }, set: { if !$0 { library.trashRequest = [] } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let recs = library.trashRequest
                library.trashRequest = []
                Task { await library.moveToTrash(recs) }
            }
            Button("Cancel", role: .cancel) { library.trashRequest = [] }
        } message: {
            Text(trashMessage)
        }
        .alert(
            "Couldn't change the recording",
            isPresented: Binding(get: { library.fileOpError != nil }, set: { if !$0 { library.fileOpError = nil } })
        ) {
            Button("OK", role: .cancel) { library.fileOpError = nil }
        } message: {
            Text(library.fileOpError ?? "")
        }
        .overlay {
            if library.recordings.isEmpty, library.root != nil, !library.isScanning {
                ContentUnavailableView("No recordings", systemImage: "tray",
                                       description: Text("Nothing ntakker recorded was found in \(library.root?.lastPathComponent ?? "")."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                if library.isScanning { ProgressView().controlSize(.small) }
                Text(footer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { Task { await library.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan the library")
                Button { library.chooseFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Choose the library folder")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var trashTitle: String {
        let recs = library.trashRequest
        return recs.count == 1 ? "Move “\(recs[0].displayName)” to the Trash?" : "Move \(recs.count) recordings to the Trash?"
    }

    private var trashMessage: String {
        let bytes = library.trashRequest.reduce(Int64(0)) { $0 + $1.byteSize }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let whose = library.trashRequest.count == 1 ? "Its" : "Their"
        return "\(whose) audio (\(size)), transcripts, minutes and notes go to the Trash. Finder's Put Back restores them."
    }

    private var footer: String {
        "\(library.recordings.count) recordings · \(library.indexedLines) lines indexed"
    }

    private var months: [(title: String, recordings: [Recording])] {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        var order: [String] = []
        var groups: [String: [Recording]] = [:]
        for r in library.recordings {
            let key = r.createdAt == .distantPast ? "Undated" : f.string(from: r.createdAt)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

/// Rename a recording: its session folder, or its files when it shares
/// its folder.
struct RenameRecordingSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let recording: Recording

    @State private var name = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Recording").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 360)
                .focused($focused)
                .onSubmit(save)
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || trimmed.isEmpty || trimmed == library.renameName(of: recording))
            }
        }
        .padding(20)
        .onAppear {
            name = library.renameName(of: recording)
            focused = true
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var note: String {
        if library.renameRenamesSession(recording) {
            return "Renames the session folder, so every part of the session takes the new name."
        }
        return recording.sharesFolder
            ? "Renames the recording's files (audio, transcripts, minutes and notes) in \(recording.folder.lastPathComponent)."
            : "Renames the recording's folder."
    }

    private func save() {
        guard !working, !trimmed.isEmpty else { return }
        working = true
        error = nil
        Task {
            error = await library.rename(recording, to: trimmed)
            working = false
            if error == nil { dismiss() }
        }
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.displayName).lineLimit(1)
            HStack(spacing: 6) {
                Text(recording.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                if recording.tracks.count > 1 { Image(systemName: "person.2.wave.2") }
                if recording.transcripts.isEmpty {
                    Text("no transcript")
                } else {
                    Image(systemName: "text.quote")
                    if recording.transcripts.count > 1 { Text("\(recording.transcripts.count)") }
                }
                if recording.attachments.contains(where: { $0.lastPathComponent.hasSuffix(".minutes.md") }) {
                    Image(systemName: "list.bullet.clipboard").help("Has minutes")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.recordingName).font(.caption.bold()).lineLimit(1)
                Spacer()
                Text(StudioAsk.timecode(hit.start, longForm: hit.start >= 3600))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("\(hit.speaker): \(hit.text)")
                .font(.callout)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}
