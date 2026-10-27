import Foundation
import Testing
@testable import NtakkerStudioKit

/// Renaming recordings and moving them to the Trash from the library
/// (2026-10-27).
@Suite("Rename and Trash")
struct RecordingFileOpsTests {

    /// Well after the files were written, so they don't look in use.
    private let later = Date().addingTimeInterval(3_600)

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func rec(_ root: URL, stem: String) -> Recording {
        RecordingLibraryScanner.scan(root: root).first { $0.stem == stem }!
    }

    @Test("a recording's files: everything named after its stem, not a longer stem's")
    func filesOfRecording() {
        let root = StudioFixtures.tempDir("ops-files")
        for n in ["eee.mic.m4a", "eee.system.m4a", "eee.transcript.jsonl", "eee.transcript.jsonl.orig",
                  "eee.m4a.questions.jsonl", "eee.studio.json", "eee.minutes.md",
                  "eee4.mic.m4a", "eee4.transcript.jsonl",
                  "x.m4a", "x.part01.m4a", "x.part01.transcript.jsonl"] {
            StudioFixtures.touch(root.appendingPathComponent(n))
        }
        #expect(RecordingFileOps.files(of: rec(root, stem: "eee")).map(\.lastPathComponent) == [
            "eee.m4a.questions.jsonl", "eee.mic.m4a", "eee.minutes.md", "eee.studio.json",
            "eee.system.m4a", "eee.transcript.jsonl", "eee.transcript.jsonl.orig",
        ])
        #expect(RecordingFileOps.files(of: rec(root, stem: "x")).map(\.lastPathComponent) == ["x.m4a"])
    }

    @Test("a recording with its own folder: rename renames the folder")
    func renameFolder() throws {
        let root = StudioFixtures.tempDir("ops-folder")
        let s = root.appendingPathComponent("meeting-2026-10-16")
        for n in ["rec.mic.m4a", "rec.system.m4a", "rec.transcript.jsonl", "transcript.md"] {
            StudioFixtures.touch(s.appendingPathComponent(n))
        }
        let r = rec(root, stem: "rec")
        #expect(RecordingFileOps.currentName(r, libraryRoot: root) == "meeting-2026-10-16")
        let (folder, stem) = try RecordingFileOps.rename(r, to: "  Budget review ", libraryRoot: root, now: later)
        #expect(folder.lastPathComponent == "Budget review" && stem == "rec")
        #expect(names(root) == ["Budget review"])
        #expect(names(folder) == ["rec.mic.m4a", "rec.system.m4a", "rec.transcript.jsonl", "transcript.md"])
        #expect(RecordingLibraryScanner.scan(root: root).map(\.displayName) == ["Budget review"])
    }

    @Test("loose recordings in the library folder: rename renames their files")
    func renameFiles() throws {
        let root = StudioFixtures.tempDir("ops-loose")
        for n in ["eee.mic.m4a", "eee.system.m4a", "eee.transcript.jsonl", "eee.m4a.questions.jsonl",
                  "eee2.mic.m4a", "eee2.transcript.jsonl"] {
            StudioFixtures.touch(root.appendingPathComponent(n))
        }
        let r = rec(root, stem: "eee")
        #expect(RecordingFileOps.renameTarget(r, libraryRoot: root) == .files)
        let (_, stem) = try RecordingFileOps.rename(r, to: "standup", libraryRoot: root, now: later)
        #expect(stem == "standup")
        #expect(names(root) == ["eee2.mic.m4a", "eee2.transcript.jsonl", "standup.m4a.questions.jsonl",
                                "standup.mic.m4a", "standup.system.m4a", "standup.transcript.jsonl"])
        let renamed = rec(root, stem: "standup")
        #expect(renamed.tracks.count == 2 && renamed.transcripts.count == 1)
    }

    @Test("the only recording in the library folder never renames the library folder")
    func neverRenamesTheRoot() throws {
        let root = StudioFixtures.tempDir("ops-root")
        StudioFixtures.touch(root.appendingPathComponent("solo.m4a"))
        let r = rec(root, stem: "solo")
        #expect(RecordingFileOps.renameTarget(r, libraryRoot: root) == .files)
        try RecordingFileOps.rename(r, to: "solo2", libraryRoot: root, now: later)
        #expect(names(root) == ["solo2.m4a"])
    }

    @Test("bad names, clashes and a recording still being written are refused, and nothing moves")
    func refusals() {
        let root = StudioFixtures.tempDir("ops-refuse")
        for n in ["a.m4a", "a.transcript.jsonl", "b.transcript.jsonl", "b.m4a"] {
            StudioFixtures.touch(root.appendingPathComponent(n))
        }
        StudioFixtures.touch(root.appendingPathComponent("taken/x.m4a"))
        StudioFixtures.touch(root.appendingPathComponent("mine/y.m4a"))
        let a = rec(root, stem: "a")
        let before = names(root)
        #expect(throws: RecordingFileOpsError.emptyName) { try RecordingFileOps.rename(a, to: "  ", libraryRoot: root, now: later) }
        #expect(throws: RecordingFileOpsError.invalidName("x/y")) { try RecordingFileOps.rename(a, to: "x/y", libraryRoot: root, now: later) }
        #expect(throws: RecordingFileOpsError.invalidName(".hidden")) { try RecordingFileOps.rename(a, to: ".hidden", libraryRoot: root, now: later) }
        #expect(throws: RecordingFileOpsError.alreadyExists("b.m4a")) { try RecordingFileOps.rename(a, to: "b", libraryRoot: root, now: later) }
        #expect(throws: RecordingFileOpsError.alreadyExists("taken")) {
            try RecordingFileOps.rename(rec(root, stem: "y"), to: "taken", libraryRoot: root, now: later)
        }
        #expect(throws: RecordingFileOpsError.stillRecording("a")) { try RecordingFileOps.rename(a, to: "c", libraryRoot: root) }
        #expect(throws: RecordingFileOpsError.stillRecording("a")) { try RecordingFileOps.moveToTrash(a, libraryRoot: root) }
        #expect(names(root) == before)
    }

    @Test("Move to Trash: the session folder when nothing else is in it, otherwise only the recording's files")
    func trashItems() {
        let root = StudioFixtures.tempDir("ops-trash")
        let s = root.appendingPathComponent("session")
        for n in ["rec.m4a", "rec.transcript.jsonl", "qa.md"] { StudioFixtures.touch(s.appendingPathComponent(n)) }
        let p = root.appendingPathComponent("parts")
        for n in ["rec.part01.m4a", "rec.part01.transcript.jsonl", "rec.part02.m4a", "transcript.md"] {
            StudioFixtures.touch(p.appendingPathComponent(n))
        }
        for n in ["eee.m4a", "eee.transcript.jsonl", "eee2.m4a"] { StudioFixtures.touch(root.appendingPathComponent(n)) }

        #expect(RecordingFileOps.trashItems(rec(root, stem: "rec"), libraryRoot: root).map { $0.resolvingSymlinksInPath().path }
                == [s.resolvingSymlinksInPath().path])
        #expect(RecordingFileOps.trashItems(rec(root, stem: "rec.part01"), libraryRoot: root).map(\.lastPathComponent)
                == ["rec.part01.m4a", "rec.part01.transcript.jsonl"])
        #expect(RecordingFileOps.trashItems(rec(root, stem: "eee"), libraryRoot: root).map(\.lastPathComponent)
                == ["eee.m4a", "eee.transcript.jsonl"], "never the library folder itself")
    }

    @Test("Move to Trash moves the files out of the library")
    func moveToTrash() throws {
        let root = StudioFixtures.tempDir("ops-trash-real")
        for n in ["gone.m4a", "gone.transcript.jsonl", "kept.m4a"] { StudioFixtures.touch(root.appendingPathComponent(n)) }
        let trashed = try RecordingFileOps.moveToTrash(rec(root, stem: "gone"), libraryRoot: root, now: later)
        #expect(names(root) == ["kept.m4a"])
        #expect(trashed.count == 2)
        for url in trashed { try? FileManager.default.removeItem(at: url) }
    }
}
