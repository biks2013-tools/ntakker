// NtakkerStudioKit/Library/RecordingLibraryScanner.swift — plan-024 T2.
//
// Walks a library folder and groups its files into `Recording`s (see
// `Recording.swift` for the naming rules). Pure file-system read: it
// never opens an audio file, so a library of a few hundred recordings
// scans in milliseconds.

import Foundation

public enum RecordingLibraryScanner {

    public static let audioExtensions: Set<String> = ["m4a", "wav", "caf"]
    static let transcriptSuffix = ".transcript.jsonl"
    /// Session-folder files written by ntakker's Save.
    static let sessionNotes = ["transcript.md", "qa.md"]
    /// Folder depth searched below the library root.
    public static let maxDepth = 4

    /// All recordings under `root`, newest first.
    public static func scan(root: URL, fileManager: FileManager = .default) -> [Recording] {
        var out: [Recording] = []
        scanDirectory(root, depth: 0, fileManager: fileManager, into: &out)
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    /// The recordings of one folder (not recursive).
    public static func recordings(inFolder folder: URL, fileManager: FileManager = .default) -> [Recording] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = entries.filter { !isDirectory($0) }
        return group(files: files, folder: folder)
    }

    private static func scanDirectory(_ dir: URL, depth: Int, fileManager: FileManager, into out: inout [Recording]) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        var files: [URL] = []
        for entry in entries {
            if isDirectory(entry) {
                if depth < maxDepth, entry.pathExtension != "app" {
                    scanDirectory(entry, depth: depth + 1, fileManager: fileManager, into: &out)
                }
            } else {
                files.append(entry)
            }
        }
        out.append(contentsOf: group(files: files, folder: dir))
    }

    /// Group the files of one folder into recordings.
    static func group(files: [URL], folder: URL) -> [Recording] {
        var tracksByStem: [String: [AudioTrack]] = [:]
        for file in files where audioExtensions.contains(file.pathExtension.lowercased()) {
            let base = file.deletingPathExtension().lastPathComponent
            let (stem, role) = splitRole(base)
            tracksByStem[stem, default: []].append(AudioTrack(url: file, role: role))
        }
        guard !tracksByStem.isEmpty else { return [] }

        // Longest stem first, so `x.part01` claims its transcripts
        // before `x` does.
        let stems = tracksByStem.keys.sorted { $0.count > $1.count }
        var transcriptsByStem: [String: [TranscriptFile]] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(transcriptSuffix) else { continue }
            let prefix = String(name.dropLast(transcriptSuffix.count))
            guard let stem = stems.first(where: { prefix == $0 || prefix.hasPrefix($0 + ".") }) else { continue }
            let label = prefix == stem ? "" : String(prefix.dropFirst(stem.count + 1))
            // `x.part01.transcript.jsonl` with no `x.part01` audio is not `x`'s.
            if label.split(separator: ".").first.map(isPartToken) == true { continue }
            transcriptsByStem[stem, default: []].append(TranscriptFile(url: file, label: label))
        }

        let names = Set(files.map(\.lastPathComponent))
        let notes = sessionNotes.filter(names.contains).map { folder.appendingPathComponent($0) }

        // Stems without their `.partNN`: one base means the folder is a
        // single recording's session folder.
        let bases = Set(tracksByStem.keys.map { stem -> String in
            if let last = stem.split(separator: ".").last, isPartToken(last) {
                return String(stem.dropLast(last.count + 1))
            }
            return stem
        })

        return tracksByStem.map { stem, tracks in
            let ordered = tracks.sorted { order($0.role) < order($1.role) }
            let transcripts = (transcriptsByStem[stem] ?? []).sorted { transcriptOrder($0) < transcriptOrder($1) }
            var attachments: [URL] = []
            for suffix in ["minutes.md", "studio-qa.md"] where names.contains("\(stem).\(suffix)") {
                attachments.append(folder.appendingPathComponent("\(stem).\(suffix)"))
            }
            attachments.append(contentsOf: notes)
            let created = ordered.compactMap { creationDate($0.url) }.min() ?? .distantPast
            let size = ordered.reduce(Int64(0)) { $0 + fileSize($1.url) }
            return Recording(
                folder: folder, stem: stem, tracks: ordered, transcripts: transcripts,
                attachments: attachments, createdAt: created, byteSize: size,
                sharesFolder: bases.count > 1
            )
        }
    }

    /// `name.mic` → (`name`, .microphone); `name.system` → (`name`, .system).
    static func splitRole(_ base: String) -> (String, AudioTrackRole) {
        if base.hasSuffix(".mic") { return (String(base.dropLast(4)), .microphone) }
        if base.hasSuffix(".system") { return (String(base.dropLast(7)), .system) }
        return (base, .mixed)
    }

    static func isPartToken(_ token: Substring) -> Bool {
        token.count == 6 && token.hasPrefix("part") && Int(token.dropFirst(4)) != nil
    }

    private static func order(_ role: AudioTrackRole) -> Int {
        switch role {
        case .mixed: return 0
        case .microphone: return 1
        case .system: return 2
        }
    }

    private static func transcriptOrder(_ t: TranscriptFile) -> String {
        switch t.label {
        case "": return "0"
        case "microphone": return "1"
        case "system": return "2"
        default: return "3" + t.label
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func creationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
