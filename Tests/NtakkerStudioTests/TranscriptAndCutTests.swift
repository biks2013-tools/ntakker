import AVFoundation
import Foundation
import Testing
@testable import NtakkerStudioKit
import NtakkerCore

@Suite("Segment timing and transcript documents")
struct TranscriptDocumentTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("streaming timestamps are the start; batch ones subtract the duration; nudge applies to live only")
    func placement() {
        let live = StudioFixtures.segment("a", at: t0.addingTimeInterval(10), duration: 2, model: "soniox")
        #expect(SegmentTiming.placement(of: live, audioStart: t0, exact: false, syncOffsetSec: 0) == (10, 12))
        let batch = StudioFixtures.segment("b", at: t0.addingTimeInterval(10), duration: 4, model: "parakeet")
        #expect(SegmentTiming.placement(of: batch, audioStart: t0, exact: false, syncOffsetSec: -1) == (5, 9))
        #expect(SegmentTiming.placement(of: batch, audioStart: t0, exact: true, syncOffsetSec: -1) == (10, 14))
        let early = StudioFixtures.segment("c", at: t0.addingTimeInterval(1), duration: 4, model: "gemini")
        #expect(SegmentTiming.placement(of: early, audioStart: t0, exact: false, syncOffsetSec: 0).start == 0)
    }

    @Test("edit + save keeps a one-time backup and round-trips through the reader")
    func editAndSave() throws {
        let dir = StudioFixtures.tempDir("doc")
        let url = dir.appendingPathComponent("r.transcript.jsonl")
        let a = StudioFixtures.segment("helo", at: t0, speaker: "1")
        let b = StudioFixtures.segment("world", at: t0.addingTimeInterval(3))
        try TranscriptDocument.write([a, b], to: url)

        let doc = TranscriptDocument.load(TranscriptFile(url: url, label: ""))
        #expect(doc.segments.count == 2)
        #expect(doc.updateText(id: a.id, to: "hello"))
        try doc.save()
        #expect(FileManager.default.fileExists(atPath: url.path + ".orig"))
        let again = JSONLTranscriptReader.read(from: url)
        #expect(again.map(\.text) == ["hello", "world"])
        #expect(again[0].speaker == "1")

        doc.updateText(id: b.id, to: "word")
        try doc.save()
        let orig = JSONLTranscriptReader.read(from: URL(fileURLWithPath: url.path + ".orig"))
        #expect(orig.map(\.text) == ["helo", "world"], "the backup is the untouched original")
    }

    @Test("studio metadata round-trips and names speakers")
    func metadata() throws {
        let url = StudioFixtures.tempDir("meta").appendingPathComponent("r.studio.json")
        #expect(try StudioMetadata.load(from: url) == StudioMetadata())
        var m = StudioMetadata(audioStart: t0, speakerNames: ["1": "Maria"], syncOffsetSec: 1.5)
        m.exactTimingTranscripts = ["x.transcript.jsonl"]
        try m.save(to: url)
        let back = try StudioMetadata.load(from: url)
        #expect(back == m)
        #expect(back.speakerName(for: "1") == "Maria")
        #expect(back.speakerName(for: "spk:2") == "Speaker 2")
        #expect(back.speakerName(for: nil) == nil)
        try Data("{not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try StudioMetadata.load(from: url) }
    }
}

@Suite("Cut plan and retiming")
struct CutPlanTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("ranges are clamped, merged and mapped")
    func plan() {
        let p = CutPlan(ranges: [CutRange(start: 50, end: 40), CutRange(start: 45, end: 60),
                                 CutRange(start: -5, end: 2), CutRange(start: 90, end: 200)], duration: 100)
        #expect(p.ranges == [CutRange(start: 0, end: 2), CutRange(start: 40, end: 60), CutRange(start: 90, end: 100)])
        #expect(p.removedDuration == 32)
        #expect(p.keptRanges == [CutRange(start: 2, end: 40), CutRange(start: 60, end: 90)])
        #expect(p.map(1) == 0)
        #expect(p.map(10) == 8)
        #expect(p.map(50) == 38)
        #expect(p.map(70) == 48)
    }

    @Test("lines inside a cut are dropped, partly cut ones kept if most survives, later ones shift")
    func retime() {
        let plan = CutPlan(ranges: [CutRange(start: 10, end: 20)], duration: 60)
        let file = URL(fileURLWithPath: "/tmp/x")
        func entry(_ s: Double, _ e: Double, _ text: String) -> TranscriptEntry {
            TranscriptEntry(segment: StudioFixtures.segment(text, at: t0.addingTimeInterval(s), duration: e - s),
                            start: s, end: e, transcriptURL: file)
        }
        let out = TranscriptRetimer.retime([
            entry(2, 5, "before"), entry(12, 15, "inside"), entry(8, 12, "mostly-kept"),
            entry(9, 19, "mostly-cut"), entry(30, 32, "after"),
        ], plan: plan, audioStart: t0)
        #expect(out.map(\.text) == ["before", "mostly-kept", "after"])
        #expect(out[0].timestamp == t0.addingTimeInterval(2))
        #expect(out[1].timestamp == t0.addingTimeInterval(8))
        #expect(out[1].durationSec == 2)
        #expect(out[2].timestamp == t0.addingTimeInterval(20))
    }

    @Test("audio cut keeps the format and the right number of frames")
    func audioCut() throws {
        let dir = StudioFixtures.tempDir("cut")
        let src = dir.appendingPathComponent("a.wav")
        StudioFixtures.writeWAV(src, seconds: 10, rate: 16_000, channels: 2)
        let dst = dir.appendingPathComponent("b.wav")
        try AudioCutter.cut(src, to: dst, plan: CutPlan(ranges: [CutRange(start: 2, end: 5)], duration: 10))
        let out = try AVAudioFile(forReading: dst)
        #expect(out.length == 7 * 16_000)
        #expect(out.fileFormat.channelCount == 2)
        #expect(out.fileFormat.sampleRate == 16_000)
    }

    @Test("exporting a cut writes a sibling folder and never touches the original")
    func export() throws {
        let root = StudioFixtures.tempDir("export")
        let folder = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("rec.wav")
        StudioFixtures.writeWAV(audio, seconds: 30)
        let tURL = folder.appendingPathComponent("rec.transcript.jsonl")
        let segs = [StudioFixtures.segment("one", at: t0.addingTimeInterval(1)),
                    StudioFixtures.segment("two", at: t0.addingTimeInterval(12)),
                    StudioFixtures.segment("three", at: t0.addingTimeInterval(25))]
        try TranscriptDocument.write(segs, to: tURL)
        let before = try Data(contentsOf: audio)

        let rec = RecordingLibraryScanner.scan(root: root)[0]
        let doc = TranscriptDocument.load(rec.transcripts[0])
        let entries = doc.entries(audioStart: t0, exact: false, syncOffsetSec: 0)
        let meta = StudioMetadata(speakerNames: ["1": "Ann"])
        let result = try RecordingCutExporter.export(
            recording: rec, plan: CutPlan(ranges: [CutRange(start: 10, end: 20)], duration: 30),
            entriesByTranscript: [rec.transcripts[0]: entries], audioStart: t0, metadata: meta,
            now: Date(timeIntervalSince1970: 1_800_000_500)
        )
        #expect(result.folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(result.folder.lastPathComponent.hasPrefix("session-cut-"))
        #expect(result.droppedLines == 1)
        #expect(try Data(contentsOf: audio) == before)

        let copy = RecordingLibraryScanner.recordings(inFolder: result.folder)[0]
        #expect(try AudioCutter.duration(of: copy.tracks[0].url) == 20)
        let newMeta = try StudioMetadata.load(from: copy.metadataURL)
        #expect(newMeta.speakerNames == ["1": "Ann"])
        #expect(newMeta.exactTimingTranscripts == ["rec.transcript.jsonl"])
        let newEntries = TranscriptDocument.load(copy.transcripts[0])
            .entries(audioStart: newMeta.audioStart!, exact: true, syncOffsetSec: 0)
        #expect(newEntries.map(\.segment.text) == ["one", "three"])
        #expect(newEntries.map(\.start) == [1, 15])
    }
}

@Suite("Waveform peaks")
struct WaveformPeaksTests {
    @Test("peaks follow the loud and quiet halves")
    func halves() throws {
        let url = StudioFixtures.tempDir("wave").appendingPathComponent("a.wav")
        StudioFixtures.writeWAV(url, seconds: 4) { i in i < 32_000 ? sinf(Float(i) * 0.05) * 0.8 : 0 }
        let w = try WaveformPeaks.load(tracks: [url], bucketCount: 8)
        #expect(w.duration == 4)
        #expect(w.peaks[0...3].allSatisfy { $0 > 0.7 })
        #expect(w.peaks[4...7].allSatisfy { $0 == 0 })
    }

    /// Timing on a real file: STUDIO_WAVEFORM_FILE=/path swift test --filter WaveformPeaks
    @Test("real file timing", .enabled(if: ProcessInfo.processInfo.environment["STUDIO_WAVEFORM_FILE"] != nil))
    func realFile() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STUDIO_WAVEFORM_FILE"]!)
        let t = Date()
        let w = try WaveformPeaks.load(tracks: [url], bucketCount: 2400)
        print("waveform: \(w.duration) s of audio in \(Date().timeIntervalSince(t)) s")
    }
}

/// A real AAC file: STUDIO_CUT_FILE=/path.m4a STUDIO_CUT_OUT=/dir swift test --filter RealFileCut
@Suite("Real file cut", .enabled(if: ProcessInfo.processInfo.environment["STUDIO_CUT_FILE"] != nil))
struct RealFileCutTests {
    @Test("an m4a cuts to the expected length in the same format")
    func m4a() throws {
        let env = ProcessInfo.processInfo.environment
        let src = URL(fileURLWithPath: env["STUDIO_CUT_FILE"]!)
        let dst = URL(fileURLWithPath: env["STUDIO_CUT_OUT"]!).appendingPathComponent("cut-" + src.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        let duration = try AudioCutter.duration(of: src)
        try AudioCutter.cut(src, to: dst, plan: CutPlan(ranges: [CutRange(start: 1, end: 3)], duration: duration))
        let out = try AVAudioFile(forReading: dst)
        let inFile = try AVAudioFile(forReading: src)
        print("cut: \(duration) s → \(try AudioCutter.duration(of: dst)) s, format \(out.fileFormat.settings[AVFormatIDKey] ?? "?") vs \(inFile.fileFormat.settings[AVFormatIDKey] ?? "?")")
        #expect(abs(try AudioCutter.duration(of: dst) - (duration - 2)) < 0.1)
        #expect(out.fileFormat.sampleRate == inFile.fileFormat.sampleRate)
    }
}

/// Echo filter on a real split recording:
/// STUDIO_AEC_DIR=<folder with <stem>.mic.m4a + <stem>.system.m4a> swift test --filter RealEchoFilter
@Suite("Real echo filter", .enabled(if: ProcessInfo.processInfo.environment["STUDIO_AEC_DIR"] != nil))
struct RealEchoFilterTests {
    @Test("mic energy while the system side is active, before and after the filter")
    func measure() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STUDIO_AEC_DIR"]!)
        let rec = try #require(RecordingLibraryScanner.recordings(inFolder: dir).first { $0.tracks.count == 2 })
        let micURL = rec.tracks.first { $0.role == .microphone }!.url
        let sysURL = rec.tracks.first { $0.role == .system }!.url
        let micF = try AVAudioFile(forReading: micURL)
        let sysF = try AVAudioFile(forReading: sysURL)
        let refF = try AVAudioFile(forReading: sysURL)
        let rate = micF.processingFormat.sampleRate
        let lag = try EchoDelayEstimator.estimate(micURL: micURL, systemURL: sysURL, duration: Double(micF.length) / rate) ?? 0
        let delay = AVAudioFramePosition(max(0, lag - 0.02) * rate)
        let aec = SoftwareAECProcessor(config: SoftwareAECProcessor.playbackConfiguration(sampleRate: rate))
        let start = AVAudioFramePosition(Double(ProcessInfo.processInfo.environment["STUDIO_AEC_START"] ?? "600")! * rate)
        let total = Int(180 * rate), block = 8192
        func monoBlock(_ f: AVAudioFile, _ n: Int) -> [Float] {
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            try? f.read(into: b, frameCount: AVAudioFrameCount(n))
            let ch = Int(f.processingFormat.channelCount), got = Int(b.frameLength)
            return (0..<n).map { i in i < got ? (0..<ch).reduce(Float(0)) { $0 + b.floatChannelData![$1][i] } / Float(ch) : 0 }
        }
        micF.framePosition = start; sysF.framePosition = start; refF.framePosition = start - delay
        var before: Float = 0, after: Float = 0, activeBlocks = 0
        let t0 = Date()
        var done = 0
        while done < total {
            let m = monoBlock(micF, block), s = monoBlock(sysF, block), r = monoBlock(refF, block)
            let out = aec.processAligned(mic: m, reference: r)
            let sysPow = s.reduce(0) { $0 + $1 * $1 } / Float(block)
            if done > Int(10 * rate), sysPow > 1e-4 {   // after 10 s of settling, system audible
                before += m.reduce(0) { $0 + $1 * $1 }; after += out.reduce(0) { $0 + $1 * $1 }; activeBlocks += 1
            }
            done += block
        }
        let secs = Date().timeIntervalSince(t0)
        print("echo filter: \(rec.displayName): delay \(Int(lag * 1000)) ms, system-active blocks \(activeBlocks), mic energy reduced by \(10 * log10(before / max(after, 1e-12))) dB; 180 s of audio in \(secs) s (debug build)")
    }
}

/// Echo delay estimate: STUDIO_AEC_DIR=… swift test --filter EchoDelay
@Suite("Echo delay", .enabled(if: ProcessInfo.processInfo.environment["STUDIO_AEC_DIR"] != nil))
struct EchoDelayTests {
    @Test("lag of the mic behind the system track (envelope cross-correlation)")
    func lag() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STUDIO_AEC_DIR"]!)
        let rec = try #require(RecordingLibraryScanner.recordings(inFolder: dir).first { $0.tracks.count == 2 })
        func env(_ url: URL) throws -> [Float] {
            let f = try AVAudioFile(forReading: url)
            let rate = f.processingFormat.sampleRate, hop = Int(rate / 1000)   // 1 ms envelope
            f.framePosition = AVAudioFramePosition(600 * rate)
            let n = Int(120 * rate)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            try f.read(into: b, frameCount: AVAudioFrameCount(n))
            let d = b.floatChannelData![0]
            return stride(from: 0, to: Int(b.frameLength) - hop, by: hop).map { s in
                var e: Float = 0; for i in s..<(s + hop) { e += d[i] * d[i] }; return (e / Float(hop)).squareRoot()
            }
        }
        var m = try env(rec.tracks.first { $0.role == .microphone }!.url)
        var s = try env(rec.tracks.first { $0.role == .system }!.url)
        let mm = m.reduce(0, +) / Float(m.count), sm = s.reduce(0, +) / Float(s.count)
        m = m.map { $0 - mm }; s = s.map { $0 - sm }
        var best = (lag: 0, c: -Float.infinity)
        for lag in -1000...1000 {           // ±1 s, mic later = positive
            var c: Float = 0
            for i in max(0, -lag)..<min(s.count, m.count - lag) { c += s[i] * m[i + lag] }
            if c > best.c { best = (lag, c) }
        }
        print("echo delay: \(rec.displayName): mic lags system by \(best.lag) ms")
    }
}

@Suite("Echo-cleaned copy")
struct EchoCleanerTests {
    /// System: noise bursts (so the envelope has structure). Mic: the
    /// system's echo 150 ms later at half level, plus a 1 kHz tone of
    /// local "speech" from 15 s to 17 s while the system is silent.
    private func makeSplit(in dir: URL, seconds: Double = 20, rate: Double = 48_000) -> (mic: URL, sys: URL) {
        let n = Int(seconds * rate), delay = Int(0.150 * rate)
        var state: UInt64 = 9
        var sys = [Float](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let t = Double(i) / rate
            let on = Int(t * 2) % 3 != 2 && !(t >= 14.5 && t < 17.5)
            sys[i] = on ? (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.3 : 0
        }
        let mic: [Float] = (0..<n).map { i in
            let t = Double(i) / rate
            let echo: Float = i >= delay ? 0.5 * sys[i - delay] : 0
            let speech: Float = (t >= 15 && t < 17) ? sinf(Float(t) * 2 * .pi * 1000) * 0.3 : 0
            return echo + speech
        }
        let micURL = dir.appendingPathComponent("rec.mic.wav"), sysURL = dir.appendingPathComponent("rec.system.wav")
        StudioFixtures.writeWAV(micURL, seconds: seconds, rate: rate) { mic[$0] }
        StudioFixtures.writeWAV(sysURL, seconds: seconds, rate: rate) { sys[$0] }
        return (micURL, sysURL)
    }

    private func power(_ url: URL, from: Double, to: Double) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        let rate = f.processingFormat.sampleRate
        f.framePosition = AVAudioFramePosition(from * rate)
        let n = AVAudioFrameCount((to - from) * rate)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: b, frameCount: n)
        let d = b.floatChannelData![0]
        return (0..<Int(b.frameLength)).reduce(Float(0)) { $0 + d[$1] * d[$1] } / Float(b.frameLength)
    }

    @Test("a 150 ms echo is removed (> 10 dB) from the start, local speech is kept")
    func cleans() throws {
        let dir = StudioFixtures.tempDir("clean")
        let (mic, sys) = makeSplit(in: dir)
        let out = dir.appendingPathComponent("clean.wav")
        let lag = try EchoCleaner.clean(micURL: mic, systemURL: sys, to: out)
        #expect(abs(lag - 0.150) < 0.003, "estimated delay \(lag)")
        let echoBefore = try power(mic, from: 1, to: 5), echoAfter = try power(out, from: 1, to: 5)
        #expect(10 * log10(echoBefore / echoAfter) > 10, "early echo reduced by \(10 * log10(echoBefore / echoAfter)) dB")
        let speechBefore = try power(mic, from: 15.2, to: 16.8), speechAfter = try power(out, from: 15.2, to: 16.8)
        #expect(abs(10 * log10(speechBefore / speechAfter)) < 1, "speech level changed by \(10 * log10(speechBefore / speechAfter)) dB")
        #expect(try AudioCutter.duration(of: out) == 20)
    }

    @Test("export with echo removal and no cuts writes a -clean- copy with all lines")
    func exportClean() throws {
        let root = StudioFixtures.tempDir("export-clean")
        let folder = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = makeSplit(in: folder, seconds: 8)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try TranscriptDocument.write([StudioFixtures.segment("hello", at: t0.addingTimeInterval(2))],
                                     to: folder.appendingPathComponent("rec.microphone.transcript.jsonl"))
        let rec = RecordingLibraryScanner.scan(root: root)[0]
        let entries = TranscriptDocument.load(rec.transcripts[0]).entries(audioStart: t0, exact: false, syncOffsetSec: 0)
        let result = try RecordingCutExporter.export(
            recording: rec, plan: CutPlan(ranges: [], duration: 8),
            entriesByTranscript: [rec.transcripts[0]: entries], audioStart: t0, metadata: StudioMetadata(),
            removeEcho: true, now: Date(timeIntervalSince1970: 1_800_000_500)
        )
        #expect(result.folder.lastPathComponent.hasPrefix("session-clean-"))
        #expect(result.echoDelay != nil)
        let copy = RecordingLibraryScanner.recordings(inFolder: result.folder)[0]
        #expect(copy.tracks.map(\.role) == [.microphone, .system])
        #expect(TranscriptDocument.load(copy.transcripts[0]).segments.map(\.text) == ["hello"])
        let hidden = try FileManager.default.contentsOfDirectory(atPath: result.folder.path).filter { $0.hasPrefix(".cleaning") }
        #expect(hidden.isEmpty, "temporary file removed")
    }

    @Test("nothing to export without cuts or echo removal")
    func nothingToDo() throws {
        let root = StudioFixtures.tempDir("export-none")
        _ = makeSplit(in: root, seconds: 2)
        let rec = RecordingLibraryScanner.scan(root: root)[0]
        #expect(throws: AudioCutError.self) {
            _ = try RecordingCutExporter.export(recording: rec, plan: CutPlan(ranges: [], duration: 2),
                                                entriesByTranscript: [:], audioStart: Date(), metadata: StudioMetadata())
        }
    }
}
