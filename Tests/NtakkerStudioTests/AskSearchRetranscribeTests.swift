import Foundation
import Testing
@testable import NtakkerStudioKit
import NtakkerCore

@Suite("Timecode links")
struct TimecodeLinksTests {
    @Test("bracketed timecodes become seek links; links and bad codes are left alone")
    func linkify() {
        let s = TimecodeLinks.linkify("See [12:34] and [01:02:03], not [12:75] or [00:05](x).")
        #expect(s == "See [12:34](ntakker-studio://seek?t=754) and [01:02:03](ntakker-studio://seek?t=3723), not [12:75] or [00:05](x).")
        #expect(TimecodeLinks.seconds(from: URL(string: "ntakker-studio://seek?t=754")!) == 754)
        #expect(TimecodeLinks.seconds(from: URL(string: "https://seek?t=1")!) == nil)
    }
}

@Suite("Studio Ask prompts")
struct StudioAskTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("transcript text merges close lines of one speaker and uses names")
    func transcriptText() {
        let url = URL(fileURLWithPath: "/tmp/t")
        func e(_ s: Double, _ text: String, _ spk: String?, _ src: SourceTag = .microphone) -> TranscriptEntry {
            TranscriptEntry(segment: StudioFixtures.segment(text, at: t0, source: src, speaker: spk),
                            start: s, end: s + 2, transcriptURL: url)
        }
        let text = StudioAsk.transcriptText(
            entries: [e(5, "Hello", "1"), e(8, "everyone.", "1"), e(20, "Hi.", "2"), e(65, "Music", nil, .system)],
            metadata: StudioMetadata(speakerNames: ["1": "Maria"]),
            duration: 120
        )
        #expect(text == "[00:05] Maria: Hello everyone.\n[00:20] Speaker 2: Hi.\n[01:05] System audio: Music")
        #expect(StudioAsk.timecode(3723, longForm: true) == "01:02:03")
    }

    @Test("asking without a configured provider fails with the missing key")
    func missingConfig() {
        #expect(throws: NtakkerError.self) {
            _ = try StudioAsk.ask(question: "q", transcript: "", recordingName: "r", recordedAt: t0,
                                  duration: 1, history: [], env: [:])
        }
    }

    @Test("Q&A notes append; minutes replace")
    func notes() throws {
        let dir = StudioFixtures.tempDir("notes")
        let qa = dir.appendingPathComponent("r.studio-qa.md")
        try StudioNotes.appendExchange(AskExchange(question: "Q1", answer: "A1", askedAt: t0), provider: "p", model: "m", to: qa)
        try StudioNotes.appendExchange(AskExchange(question: "Q2", answer: "A2", askedAt: t0), provider: "p", model: "m", to: qa)
        let text = try String(contentsOf: qa, encoding: .utf8)
        #expect(text.hasPrefix("# Questions"))
        #expect(text.contains("## Q1") && text.contains("## Q2"))
        let minutes = dir.appendingPathComponent("r.minutes.md")
        try StudioNotes.writeMinutes("# One", provider: "p", model: "m", generatedAt: t0, to: minutes)
        try StudioNotes.writeMinutes("# Two", provider: "p", model: "m", generatedAt: t0, to: minutes)
        #expect(try String(contentsOf: minutes, encoding: .utf8).hasPrefix("# Two"))
    }
}

@Suite("Transcript search index")
struct TranscriptSearchIndexTests {
    @Test("finds lines by every word, ignoring case and accents, and refreshes changed files")
    func search() async throws {
        let root = StudioFixtures.tempDir("search")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        StudioFixtures.touch(root.appendingPathComponent("a.m4a"))
        let tURL = root.appendingPathComponent("a.transcript.jsonl")
        try TranscriptDocument.write([
            StudioFixtures.segment("Η συμφωνία υπογράφηκε", at: t0.addingTimeInterval(1)),
            StudioFixtures.segment("Budget review next week", at: t0.addingTimeInterval(9)),
        ], to: tURL)
        var meta = StudioMetadata(audioStart: t0)
        meta.syncOffsetSec = 0
        try meta.save(to: root.appendingPathComponent("a.studio.json"))

        let index = TranscriptSearchIndex()
        await index.update(with: RecordingLibraryScanner.scan(root: root))
        #expect(await index.search("ΣΥΜΦΩΝΙΑ").map(\.start) == [1])
        #expect(await index.search("review budget").count == 1)
        #expect(await index.search("budget friday").isEmpty)

        try await Task.sleep(for: .milliseconds(1100))
        try TranscriptDocument.write([StudioFixtures.segment("friday budget", at: t0)], to: tURL)
        await index.update(with: RecordingLibraryScanner.scan(root: root))
        #expect(await index.search("budget friday").count == 1)

        await index.update(with: [])
        #expect(await index.lineCount == 0)
    }
}

@Suite("Retranscriber")
struct RetranscriberTests {
    @Test("cuts at quiet frames and writes an exact-timed transcript")
    func run() async throws {
        let root = StudioFixtures.tempDir("retx")
        let audio = root.appendingPathComponent("rec.wav")
        // 3 bursts of tone (0–8 s, 12–20 s, 24–30 s) separated by silence.
        StudioFixtures.writeWAV(audio, seconds: 30) { i in
            let t = Double(i) / 16_000
            let loud = t < 8 || (t >= 12 && t < 20) || t >= 24
            return loud ? sinf(Float(i) * 0.05) * 0.5 : 0
        }
        let rec = RecordingLibraryScanner.scan(root: root)[0]
        let provider = FakeTranscriptionProvider(script: ["first part", "second part", "third part"])
        let options = TranscriptionOptions(providerId: "fake", apiKey: nil, modelId: nil, languageHints: ["en"],
                                           customSystemInstruction: nil, keyExpiresAt: nil)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // Chunking: aim at 9 s, cut by 14 s.
        var starts: [Double] = []
        try await Retranscriber.forEachChunk(of: audio, policy: .silenceCut(targetSeconds: 9, maxSeconds: 14)) { samples, start, _ in
            starts.append(start)
            #expect(samples.count <= 14 * 16_000)
        }
        #expect(starts.count == 3)
        #expect(starts[0] == 0)
        #expect(abs(starts[1] - 9.025) < 0.01, "first quiet frame after 9 s")

        let result = try await Retranscriber.run(
            recording: rec, provider: provider, options: options, audioStart: t0,
            now: Date(timeIntervalSince1970: 1_800_000_900), progress: { _ in }
        )
        #expect(result.files.count == 1)
        #expect(result.files[0].lastPathComponent.hasPrefix("rec.fake-"))
        let meta = try StudioMetadata.load(from: rec.metadataURL)
        #expect(meta.exactTimingTranscripts == [result.files[0].lastPathComponent])
        let segs = JSONLTranscriptReader.read(from: result.files[0])
        #expect(segs.first?.timestamp == t0)
        #expect(segs.first?.language == "en")
        #expect(segs.count >= 2)
    }

    @Test("streaming-only providers are refused")
    func refusesStreaming() {
        #expect(throws: RetranscribeError.self) {
            _ = try Retranscriber.makeProvider(providerId: "soniox", languages: [])
        }
    }
}

@Suite("EchoDelayEstimator")
struct EchoDelayEstimatorTests {
    @Test("finds the lag of a delayed envelope; nil for unrelated or silent tracks")
    func lag() {
        var state: UInt64 = 5
        let sys: [Float] = (0..<20_000).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        let mic = [Float](repeating: 0, count: 120) + sys.dropLast(120).map { $0 * 0.4 }
        #expect(EchoDelayEstimator.estimate(mic: mic, system: sys) == 0.12)
        #expect(EchoDelayEstimator.estimate(mic: [Float](repeating: 0, count: 20_000), system: sys) == nil)
    }
}
