// ntakker-studio/Views/LibrarySidebar.swift — plan-024 T9.
//
// Recordings grouped by month. While the search field has text, the
// list shows the matching recordings and, below them, the transcript
// lines that match across the whole library; clicking a line opens its
// recording at that moment.

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
