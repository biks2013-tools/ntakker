// NtakkerStudioKit/Library/RecordingFileOps.swift — 2026-10-27.
//
// Renaming a recording and moving it to the Trash, from the studio's
// library (no trip to Finder).
//
// What a recording's files are: every file of its folder whose name is
// `<stem>.…` (tracks, transcripts and their backups, the studio's
// metadata, minutes, Q&A, ntakker's question logs), except those of
// another recording with a longer stem (`x.part01.…` is not `x`'s).
//
// Rename renames what the library shows as the recording's name:
//   • the recording has its session folder to itself → the folder (for a
//     split session, the folder holds every part, so all parts follow);
//   • it shares its folder (or lies in the library folder itself) → its
//     files, `<stem>.…` → `<new>.…`.
//
// Move to Trash puts the whole session folder in the Trash when no other
// recording lives in it, otherwise only the recording's files. Nothing is
// deleted for good: Finder's Put Back restores it. The library folder
// itself is never renamed or trashed, and a recording whose audio was
// written in the last few seconds (ntakker is still recording it) is
// left alone.

import Foundation

public enum RecordingFileOpsError: LocalizedError, Equatable {
    case emptyName
    case invalidName(String)
    case alreadyExists(String)
    case stillRecording(String)
    case outsideLibrary(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "The name can't be empty."
        case .invalidName(let n): return "“\(n)” can't be used as a name: no “/” or “:”, and it can't start with a dot."
        case .alreadyExists(let n): return "“\(n)” already exists in that folder."
        case .stillRecording(let n): return "“\(n)” is still being recorded. Stop the recording first."
        case .outsideLibrary(let n): return "“\(n)” is not inside the library folder."
        }
    }
}

public enum RecordingFileOps {

    /// Audio written this recently means ntakker is still recording.
    public static let activeWriteWindow: TimeInterval = 10

    public enum RenameTarget: Equatable, Sendable {
        /// The session folder (holds only this recording, or its parts).
        case folder(URL)
        /// The recording's own files.
        case files
    }

    /// What renaming `recording` renames.
    public static func renameTarget(_ recording: Recording, libraryRoot: URL) -> RenameTarget {
        let folder = recording.folder.standardizedFileURL
        if !recording.sharesFolder, folder != libraryRoot.standardizedFileURL, isInside(folder, libraryRoot) {
            return .folder(recording.folder)
        }
        return .files
    }

    /// The name the rename starts from (and replaces).
    public static func currentName(_ recording: Recording, libraryRoot: URL) -> String {
        switch renameTarget(recording, libraryRoot: libraryRoot) {
        case .folder(let url): return url.lastPathComponent
        case .files: return recording.stem
        }
    }

    /// The files that belong to `recording` (see the header).
    public static func files(of recording: Recording, fileManager: FileManager = .default) -> [URL] {
        let others = RecordingLibraryScanner.recordings(inFolder: recording.folder, fileManager: fileManager)
            .map(\.stem)
            .filter { $0 != recording.stem && $0.hasPrefix(recording.stem + ".") }
        let names = (try? fileManager.contentsOfDirectory(atPath: recording.folder.path)) ?? []
        return names
            .filter { $0.hasPrefix(recording.stem + ".") }
            .filter { name in !others.contains { name.hasPrefix($0 + ".") } }
            .sorted()
            .map { recording.folder.appendingPathComponent($0) }
    }

    /// Rename `recording` to `newName`. Returns the folder and stem it
    /// has afterwards (unchanged when the name is unchanged).
    @discardableResult
    public static func rename(
        _ recording: Recording, to newName: String, libraryRoot: URL,
        now: Date = Date(), fileManager: FileManager = .default
    ) throws -> (folder: URL, stem: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RecordingFileOpsError.emptyName }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw RecordingFileOpsError.invalidName(name)
        }
        guard isInside(recording.folder, libraryRoot) else {
            throw RecordingFileOpsError.outsideLibrary(recording.displayName)
        }
        try ensureNotRecording(recording, now: now, fileManager: fileManager)

        switch renameTarget(recording, libraryRoot: libraryRoot) {
        case .folder(let folder):
            guard name != folder.lastPathComponent else { return (recording.folder, recording.stem) }
            let dest = folder.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            // A case-only change ("meeting" → "Meeting") is the same
            // path on a case-insensitive volume, not a clash.
            if fileManager.fileExists(atPath: dest.path),
               name.lowercased() != folder.lastPathComponent.lowercased() {
                throw RecordingFileOpsError.alreadyExists(name)
            }
            try fileManager.moveItem(at: folder, to: dest)
            return (dest, recording.stem)

        case .files:
            guard name != recording.stem else { return (recording.folder, recording.stem) }
            let moves = files(of: recording, fileManager: fileManager).map { src -> (URL, URL) in
                let rest = src.lastPathComponent.dropFirst(recording.stem.count)
                return (src, recording.folder.appendingPathComponent(name + rest))
            }
            let sources = Set(moves.map { $0.0.lastPathComponent.lowercased() })
            if let clash = moves.first(where: {
                fileManager.fileExists(atPath: $0.1.path) && !sources.contains($0.1.lastPathComponent.lowercased())
            }) {
                throw RecordingFileOpsError.alreadyExists(clash.1.lastPathComponent)
            }
            // All or nothing: undo the moves made so far on a failure.
            var done: [(URL, URL)] = []
            do {
                for (src, dest) in moves {
                    try fileManager.moveItem(at: src, to: dest)
                    done.append((src, dest))
                }
            } catch {
                for (src, dest) in done.reversed() { try? fileManager.moveItem(at: dest, to: src) }
                throw error
            }
            return (recording.folder, name)
        }
    }

    /// What moving `recording` to the Trash moves: its session folder
    /// when nothing else lives there, otherwise its files.
    public static func trashItems(
        _ recording: Recording, libraryRoot: URL, fileManager: FileManager = .default
    ) -> [URL] {
        let folder = recording.folder.standardizedFileURL
        let mine = files(of: recording, fileManager: fileManager)
        let others = RecordingLibraryScanner.recordings(inFolder: recording.folder, fileManager: fileManager)
            .filter { $0.stem != recording.stem }
        if others.isEmpty, folder != libraryRoot.standardizedFileURL, isInside(folder, libraryRoot) {
            return [recording.folder]
        }
        return mine
    }

    /// Move `recording` to the Trash. Returns where each item went.
    @discardableResult
    public static func moveToTrash(
        _ recording: Recording, libraryRoot: URL,
        now: Date = Date(), fileManager: FileManager = .default
    ) throws -> [URL] {
        guard isInside(recording.folder, libraryRoot) else {
            throw RecordingFileOpsError.outsideLibrary(recording.displayName)
        }
        try ensureNotRecording(recording, now: now, fileManager: fileManager)
        var trashed: [URL] = []
        for item in trashItems(recording, libraryRoot: libraryRoot, fileManager: fileManager) {
            var result: NSURL?
            try fileManager.trashItem(at: item, resultingItemURL: &result)
            trashed.append((result as URL?) ?? item)
        }
        return trashed
    }

    /// Throws when an audio file of `recording` was written in the last
    /// `activeWriteWindow` seconds.
    public static func ensureNotRecording(_ recording: Recording, now: Date = Date(), fileManager: FileManager = .default) throws {
        for track in recording.tracks {
            let modified = (try? fileManager.attributesOfItem(atPath: track.url.path))?[.modificationDate] as? Date
            if let modified, now.timeIntervalSince(modified) < activeWriteWindow {
                throw RecordingFileOpsError.stillRecording(recording.displayName)
            }
        }
    }

    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
