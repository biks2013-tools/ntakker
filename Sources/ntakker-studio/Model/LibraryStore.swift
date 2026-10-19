// ntakker-studio/Model/LibraryStore.swift — plan-024 T9.
//
// The library: which folder, the recordings in it, the transcript
// search, and which recording is open.
//
// Library folder. The studio keeps its own setting
// (`studio.libraryFolder`). On first launch it adopts ntakker's
// recording folder (`com.ntakker-cli.ui.outputFolder` in the
// `com.giorgosmarinos.ntakker` defaults); when that is not set either, the app
// asks the user to choose a folder — there is no silent default.

import AppKit
import Foundation
import NtakkerCore
import NtakkerSettingsUI
import NtakkerStudioKit
import Observation

@MainActor @Observable
final class LibraryStore {
    static let folderKey = "studio.libraryFolder"
    static let ntakkerDefaultsSuite = "com.giorgosmarinos.ntakker"
    /// ntakker's bundle id before the public release; its preferences
    /// still hold the folder until ntakker has run once under the new id.
    static let legacyNtakkerDefaultsSuite = "com.local.ntakker"
    static let ntakkerFolderKey = "com.ntakker-cli.ui.outputFolder"

    private(set) var root: URL?
    private(set) var recordings: [Recording] = []
    private(set) var isScanning = false
    private(set) var indexedLines = 0

    var query = "" { didSet { scheduleSearch() } }
    private(set) var hits: [SearchHit] = []
    private(set) var searching = false

    /// The recordings selected in the sidebar. One opens in the detail
    /// view; several show the join panel.
    var selection: Set<String> = [] {
        didSet {
            if selectedID != (oldValue.count == 1 ? oldValue.first : nil) { openSelected() }
            if selection != oldValue { prepareJoin() }
        }
    }
    /// The one selected recording (nil when none or several are).
    var selectedID: String? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    private(set) var workspace: RecordingWorkspace?
    /// The selected recordings, oldest first.
    var selectedRecordings: [Recording] {
        recordings.filter { selection.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }
    /// The other parts of `recording`'s session (same folder, same stem
    /// without `.partNN`), itself included, when it has any.
    func sessionParts(of recording: Recording) -> [Recording] {
        guard recording.partNumber != nil else { return [] }
        let base = RecordingJoiner.baseStem(recording.stem)
        let parts = recordings.filter {
            $0.folder.standardizedFileURL == recording.folder.standardizedFileURL
                && $0.partNumber != nil && RecordingJoiner.baseStem($0.stem) == base
        }
        return parts.count >= 2 ? parts : []
    }

    @ObservationIgnored private let index = TranscriptSearchIndex()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeek: (id: String, time: Double, transcript: URL?)?

    init() {
        // plan-025: the library is the shared recordings folder
        // (NTAKKER_RECORDINGS_DIR in ~/.tool-agents/ntakker/.env), the one
        // ntakker records into. Carry over a folder chosen before, once.
        let store = SharedSettingsStore.shared
        if store.string(SharedSettings.Keys.recordingsDir) == nil {
            let d = UserDefaults.standard
            let previous = [d.string(forKey: Self.folderKey)]
                + [Self.ntakkerDefaultsSuite, Self.legacyNtakkerDefaultsSuite].map {
                    UserDefaults(suiteName: $0)?.string(forKey: Self.ntakkerFolderKey)
                }
            if let folder = previous.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                store.set(SharedSettings.Keys.recordingsDir, folder)
            }
        }
        root = store.string(SharedSettings.Keys.recordingsDir).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The shared recordings folder changed (here, in ntakker, or by hand).
    func followSharedFolder() {
        let path = SharedSettingsStore.shared.string(SharedSettings.Keys.recordingsDir)
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        selectedID = nil
        Task { await rescan() }
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
        SharedSettingsStore.shared.set(SharedSettings.Keys.recordingsDir, url.path)
        followSharedFolder()
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

    /// Open a recording by folder (after a cut export or a join).
    func reveal(folder: URL) {
        if let rec = recordings.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            selectedID = rec.id
        }
    }

    // MARK: - Join

    /// The join of the selected recordings, when two or more are selected.
    private(set) var joinPlan: JoinPlan?
    private(set) var joinPlanError: String?
    private(set) var joinPreparing = false
    private(set) var joinProgress: Double?
    private(set) var joinError: String?
    @ObservationIgnored private var joinPrepareTask: Task<Void, Never>?

    /// Read the selected recordings and check they can be joined.
    private func prepareJoin() {
        joinPrepareTask?.cancel()
        joinPlan = nil
        joinPlanError = nil
        joinError = nil
        let recs = selectedRecordings
        guard recs.count >= 2 else { joinPreparing = false; return }
        joinPreparing = true
        joinPrepareTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<JoinPlan, Error> in
                Result { try RecordingJoiner.plan(try recs.map(JoinPart.load)) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let plan): joinPlan = plan
            case .failure(let error): joinPlanError = error.localizedDescription
            }
            joinPreparing = false
        }
    }

    /// Write the joined recording, then open it.
    func join() {
        guard let plan = joinPlan, joinProgress == nil else { return }
        joinProgress = 0
        joinError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RecordingJoiner.join(plan) { p in
                        Task { @MainActor in if self.joinProgress != nil { self.joinProgress = p } }
                    }
                }.value
                joinProgress = nil
                await rescan()
                reveal(folder: result.folder)
            } catch {
                joinProgress = nil
                joinError = "Join failed: \(error.localizedDescription)"
            }
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
