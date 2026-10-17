// ntakker-studio/Model/LibraryStore.swift — plan-024 T9.
//
// The library: which folder, the recordings in it, the transcript
// search, and which recording is open.
//
// Library folder. The studio keeps its own setting
// (`studio.libraryFolder`). On first launch it adopts ntakker's
// recording folder (`com.ntakker-cli.ui.outputFolder` in the
// `com.local.ntakker` defaults); when that is not set either, the app
// asks the user to choose a folder — there is no silent default.

import AppKit
import Foundation
import NtakkerStudioKit
import Observation

@MainActor @Observable
final class LibraryStore {
    static let folderKey = "studio.libraryFolder"
    static let ntakkerDefaultsSuite = "com.local.ntakker"
    static let ntakkerFolderKey = "com.ntakker-cli.ui.outputFolder"

    private(set) var root: URL?
    private(set) var recordings: [Recording] = []
    private(set) var isScanning = false
    private(set) var indexedLines = 0

    var query = "" { didSet { scheduleSearch() } }
    private(set) var hits: [SearchHit] = []
    private(set) var searching = false

    var selectedID: String? { didSet { if selectedID != oldValue { openSelected() } } }
    private(set) var workspace: RecordingWorkspace?

    @ObservationIgnored private let index = TranscriptSearchIndex()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeek: (id: String, time: Double, transcript: URL?)?

    init() {
        let d = UserDefaults.standard
        if let stored = d.string(forKey: Self.folderKey), !stored.isEmpty {
            root = URL(fileURLWithPath: stored, isDirectory: true)
        } else if let ntakker = UserDefaults(suiteName: Self.ntakkerDefaultsSuite)?.string(forKey: Self.ntakkerFolderKey),
                  !ntakker.isEmpty {
            root = URL(fileURLWithPath: ntakker, isDirectory: true)
            d.set(ntakker, forKey: Self.folderKey)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as library"
        panel.message = "Choose the folder that holds your ntakker recordings."
        if let root { panel.directoryURL = root }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        root = url
        selectedID = nil
        Task { await rescan() }
    }

    func rescan() async {
        guard let root else { return }
        isScanning = true
        let found = await Task.detached { RecordingLibraryScanner.scan(root: root) }.value
        recordings = found
        isScanning = false
        if let ws = workspace, let updated = found.first(where: { $0.id == ws.recording.id }) {
            await ws.adopt(updated)
        }
        await index.update(with: found)
        indexedLines = await index.lineCount
        if !query.isEmpty { scheduleSearch() }
    }

    /// Rescan after a workspace wrote files; show `showOnly` transcripts.
    func filesChanged(in ws: RecordingWorkspace, showOnly: [URL]?) {
        Task {
            await rescan()
            if let showOnly, let updated = recordings.first(where: { $0.id == ws.recording.id }) {
                await ws.adopt(updated, showOnly: showOnly)
            }
        }
    }

    // MARK: - Selection

    private func openSelected() {
        workspace?.close()
        workspace = nil
        guard let id = selectedID, let rec = recordings.first(where: { $0.id == id }) else { return }
        let ws = RecordingWorkspace(recording: rec)
        ws.onFilesChanged = { [weak self, weak ws] showOnly in
            guard let self, let ws else { return }
            self.filesChanged(in: ws, showOnly: showOnly)
        }
        workspace = ws
        Task {
            await ws.load()
            if let p = pendingSeek, p.id == id {
                pendingSeek = nil
                if let t = p.transcript { ws.visibleTranscripts.insert(t) }
                ws.player.seek(to: p.time)
            }
        }
    }

    /// Open a search hit: select its recording and seek to the line.
    func open(_ hit: SearchHit) {
        if selectedID == hit.recordingID, let ws = workspace, ws.isLoaded {
            ws.visibleTranscripts.insert(hit.transcriptURL)
            ws.player.seek(to: hit.start)
        } else {
            pendingSeek = (hit.recordingID, hit.start, hit.transcriptURL)
            selectedID = hit.recordingID
        }
    }

    /// Open a recording by folder (after a cut export).
    func reveal(folder: URL) {
        if let rec = recordings.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            selectedID = rec.id
        }
    }

    // MARK: - Search

    var filteredRecordings: [Recording] {
        let words = TranscriptSearchIndex.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return recordings }
        return recordings.filter { r in
            let name = TranscriptSearchIndex.fold(r.displayName + " " + r.stem)
            return words.allSatisfy(name.contains)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else {
            hits = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await index.search(q, limit: 300)
            guard !Task.isCancelled else { return }
            hits = found
            searching = false
        }
    }
}
