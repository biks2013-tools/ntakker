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

@Suite("Echo filter settings and residual suppression")
struct EchoProcessorTests {
    private func noise(_ n: Int, seed: UInt64, amp: Float) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return (Float(s >> 40) / Float(1 << 24) * 2 - 1) * amp
        }
    }
    private func power(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)) }
    private func db(_ a: Float, _ b: Float) -> Float { 10 * log10(a / max(b, 1e-12)) }

    @Test("with no echo estimate the suppressor reconstructs its input, 512 samples late")
    func reconstruction() {
        let x = noise(20_000, seed: 1, amp: 0.4)
        let res = ResidualEchoSuppressor(overSubtraction: 1.6, floor: 0.08)
        var out: [Float] = []
        for i in stride(from: 0, to: x.count, by: 3_000) {
            let j = min(x.count, i + 3_000)
            out += res.process(output: Array(x[i..<j]), echo: [Float](repeating: 0, count: j - i))
        }
        #expect(out.count == x.count)
        let err = (1_024..<x.count).map { abs(out[$0] - x[$0 - 512]) }.max() ?? 1
        #expect(err < 1e-4, "max reconstruction error \(err)")
    }

    @Test("a residual that follows the echo estimate is suppressed")
    func suppresses() {
        let echo = noise(48_000, seed: 2, amp: 0.4)
        let residual = echo.map { $0 * 0.2 }
        let res = ResidualEchoSuppressor(overSubtraction: 1.6, floor: 0.08)
        let out = res.process(output: residual, echo: echo)
        #expect(db(power(residual[10_000...]), power(out[10_000...])) > 10)
    }

    @Test("strength 0 returns the mic, 0.5 sits halfway")
    func strength() {
        let rate = 16_000.0, delay = 80
        let ref = noise(32_000, seed: 3, amp: 0.3)
        let mic = (0..<ref.count).map { i in i >= delay ? 0.5 * ref[i - delay] : 0 }
        let zero = EchoProcessor(sampleRate: rate, settings: .init(strength: 0, suppression: .off, adaptation: .fast))
        #expect(zero.process(mic: mic, reference: ref) == mic)
        let full = EchoProcessor(sampleRate: rate, settings: .standard)
        let half = EchoProcessor(sampleRate: rate, settings: .init(strength: 0.5, suppression: .off, adaptation: .fast))
        let f = full.process(mic: mic, reference: ref), h = half.process(mic: mic, reference: ref)
        let err = (0..<mic.count).map { abs(h[$0] - (0.5 * mic[$0] + 0.5 * f[$0])) }.max() ?? 1
        #expect(err < 1e-5)
    }

    @Test("on a distorted echo, high suppression removes more than the canceller alone")
    func nonlinearEcho() {
        let rate = 16_000.0, delay = 80
        let ref = noise(16_000 * 10, seed: 4, amp: 0.5)
        // Loudspeaker distortion: the canceller can only model the linear part.
        let mic = (0..<ref.count).map { i in i >= delay ? 0.5 * tanhf(2.5 * ref[i - delay]) : 0 }
        func run(_ s: EchoFilterSettings.Suppression) -> Float {
            let p = EchoProcessor(sampleRate: rate, settings: .init(strength: 1, suppression: s, adaptation: .fast))
            var out: [Float] = []
            for i in stride(from: 0, to: mic.count, by: 4_096) {
                let j = min(mic.count, i + 4_096)
                out += p.process(mic: Array(mic[i..<j]), reference: Array(ref[i..<j]))
            }
            let tail = (mic.count - 32_000)..<mic.count
            return db(power(mic[tail]), power(out[tail]))
        }
        let off = run(.off), high = run(.high), low = run(.low)
        #expect(high > off + 3, "off \(off) dB, low \(low) dB, high \(high) dB")
        #expect(low > off, "off \(off) dB, low \(low) dB")
    }

    @Test("local speech over the echo keeps most of its level with suppression")
    func doubleTalk() {
        let rate = 16_000.0, delay = 80
        let ref = noise(16_000 * 10, seed: 6, amp: 0.3)
        let echo = (0..<ref.count).map { i in i >= delay ? 0.3 * ref[i - delay] : 0 }
        // A 300 Hz tone stands in for local speech in the last 3 s, over the echo.
        let speech: [Float] = (0..<ref.count).map { i in i >= 16_000 * 7 ? 0.3 * sinf(Float(i) * 2 * .pi * 300 / Float(rate)) : 0 }
        let mic = zip(echo, speech).map { $0 + $1 }
        for (s, maxLoss) in [(EchoFilterSettings.Suppression.low, Float(1.5)), (.high, Float(3))] {
            let p = EchoProcessor(sampleRate: rate, settings: .init(strength: 1, suppression: s, adaptation: .fast))
            var out: [Float] = []
            for i in stride(from: 0, to: mic.count, by: 4_096) {
                let j = min(mic.count, i + 4_096)
                out += p.process(mic: Array(mic[i..<j]), reference: Array(ref[i..<j]))
            }
            // Speech level: correlate the output with the tone (delayed by the latency).
            let lat = p.latency
            let range = (16_000 * 8)..<(mic.count - lat)
            let num = range.reduce(Float(0)) { $0 + out[$1 + lat] * speech[$1] }
            let den = range.reduce(Float(0)) { $0 + speech[$1] * speech[$1] }
            let loss = -20 * log10(max(1e-6, num / den))
            #expect(loss < maxLoss, "\(s): speech level down \(loss) dB")
        }
    }

    @Test("stable adaptation still converges, more slowly than fast")
    func adaptation() {
        let rate = 16_000.0, delay = 80
        let ref = noise(16_000 * 3, seed: 5, amp: 0.3)
        let mic = (0..<ref.count).map { i in i >= delay ? 0.5 * ref[i - delay] : 0 }
        func reduction(_ a: EchoFilterSettings.Adaptation) -> Float {
            let p = EchoProcessor(sampleRate: rate, settings: .init(strength: 1, suppression: .off, adaptation: a))
            let out = p.process(mic: mic, reference: ref)
            let tail = 32_000..<mic.count
            return db(power(mic[tail]), power(out[tail]))
        }
        let fast = reduction(.fast), stable = reduction(.stable)
        #expect(stable > 3, "stable \(stable) dB")
        #expect(fast > stable, "fast \(fast) dB vs stable \(stable) dB after 2 s")
    }
}

@Suite("Echo settings in the shared file")
struct EchoSettingsFileTests {
    @Test("round-trip through the shared-file values; unset or bad values mean the defaults")
    func roundTrip() {
        let s = EchoFilterSettings(strength: 0.75, suppression: .high, adaptation: .stable)
        #expect(EchoFilterSettings.from(s.fileValues) == s)
        #expect(EchoFilterSettings.from([:]) == .standard)
        #expect(EchoFilterSettings.from([SharedSettings.Keys.studioEchoSuppression: "loud"]) == .standard)
        #expect(s.fileValues[SharedSettings.Keys.studioEchoStrength] == "0.75")
    }
}
