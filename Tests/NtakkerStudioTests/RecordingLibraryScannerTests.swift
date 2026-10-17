import Foundation
import Testing
@testable import NtakkerStudioKit

@Suite("RecordingLibraryScanner")
struct RecordingLibraryScannerTests {

    @Test("split session folder: two tracks, three transcripts, session notes")
    func splitSession() {
        let root = StudioFixtures.tempDir("lib")
        let s = root.appendingPathComponent("meeting-2026-10-16-18-40")
        for name in [
            "recording-2026-10-16-17-03.mic.m4a", "recording-2026-10-16-17-03.system.m4a",
            "recording-2026-10-16-17-03.microphone.transcript.jsonl",
            "recording-2026-10-16-17-03.system.transcript.jsonl",
            "recording-2026-10-16-17-03.parakeet-20261017-0900.transcript.jsonl",
            "recording-2026-10-16-17-03.transcript.jsonl.orig",
            "transcript.md", "qa.md",
        ] { StudioFixtures.touch(s.appendingPathComponent(name)) }

        let recs = RecordingLibraryScanner.scan(root: root)
        #expect(recs.count == 1)
        let r = recs[0]
        #expect(r.stem == "recording-2026-10-16-17-03")
        #expect(r.tracks.map(\.role) == [.microphone, .system])
        #expect(r.transcripts.map(\.label) == ["microphone", "system", "parakeet-20261017-0900"])
        #expect(r.attachments.map(\.lastPathComponent).sorted() == ["qa.md", "transcript.md"])
        #expect(r.displayName == "meeting-2026-10-16-18-40")
    }

    @Test("parts are separate recordings and keep their own transcripts")
    func parts() {
        let root = StudioFixtures.tempDir("parts")
        for name in [
            "rec.part01.m4a", "rec.part01.transcript.jsonl",
            "rec.part02.m4a", "rec.part02.transcript.jsonl",
            "rec.part03.transcript.jsonl", // no audio
        ] { StudioFixtures.touch(root.appendingPathComponent(name)) }
        let recs = RecordingLibraryScanner.scan(root: root).sorted { $0.stem < $1.stem }
        #expect(recs.map(\.stem) == ["rec.part01", "rec.part02"])
        #expect(recs[0].transcripts.map(\.url.lastPathComponent) == ["rec.part01.transcript.jsonl"])
        #expect(recs[0].partNumber == 1)
    }

    @Test("loose files in one folder group by stem; transcripts without audio are ignored")
    func looseFiles() {
        let root = StudioFixtures.tempDir("loose")
        for name in ["eee.mic.m4a", "eee.system.m4a", "eee.transcript.jsonl",
                     "eee2.wav", "eee2.transcript.jsonl", "orphan.transcript.jsonl", "notes.txt"] {
            StudioFixtures.touch(root.appendingPathComponent(name))
        }
        let recs = RecordingLibraryScanner.scan(root: root).sorted { $0.stem < $1.stem }
        #expect(recs.map(\.stem) == ["eee", "eee2"])
        #expect(recs[0].transcripts.count == 1)
        #expect(recs[1].tracks.map(\.role) == [.mixed])
        #expect(recs[1].displayName == "eee2")
    }
}
