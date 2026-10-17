// NtakkerStudioKit/Retranscribe/Retranscriber.swift — plan-024 T7.
//
// Runs a finished recording through one of ntakker's batch
// transcription providers and writes a new transcript next to it.
//
//   * Provider settings come from the same place as ntakker's:
//     `ConfigResolver(toolName: "ntakker")` reads the shell env and
//     `~/.tool-agents/ntakker/.env`; the provider id (and optionally
//     the languages) are passed as overrides.
//   * Audio is decoded to 16 kHz mono and cut into chunks at quiet
//     moments, the way the live batch pipeline does, but with longer
//     chunks since there is no latency to keep down.
//   * Each chunk becomes one segment stamped `audioStart + chunk
//     start`, so the new transcript's timing is exact; its filename is
//     added to the recording's `exactTimingTranscripts`.
//
// Output: `<stem>.<provider>-<yyyyMMdd-HHmm>.transcript.jsonl`, and for
// a split recording one file per track
// (`<stem>.microphone.<provider>-….transcript.jsonl`, `…system…`).
// Streaming-only providers (apple, apple-cloud, soniox,
// azure-openai-realtime) are refused.

import AVFoundation
import Foundation
import Logging
import NtakkerCore

public enum RetranscribeError: Error, LocalizedError {
    case notBatchCapable(String)
    case decode(URL, String)

    public var errorDescription: String? {
        switch self {
        case .notBatchCapable(let id):
            return "\(id) only transcribes live audio. Pick one of: \(Retranscriber.batchProviderIds.joined(separator: ", "))."
        case .decode(let url, let why):
            return "Could not decode \(url.lastPathComponent): \(why)"
        }
    }
}

public struct RetranscribeProgress: Sendable {
    /// 0…1 over all tracks.
    public let fraction: Double
    public let segmentsSoFar: Int
    public let lastText: String?

    public init(fraction: Double, segmentsSoFar: Int, lastText: String?) {
        self.fraction = fraction
        self.segmentsSoFar = segmentsSoFar
        self.lastText = lastText
    }
}

public struct RetranscribeResult: Sendable {
    public let files: [URL]
    public let segmentCount: Int
}

public enum Retranscriber {

    /// Provider ids that can transcribe a recorded file.
    public static let batchProviderIds = ["parakeet", "whisperkit", "gemini", "azure", "elevenlabs"]

    /// Chunking for cloud providers (`ChunkPolicy.drainAll` live):
    /// aim for 20 s, cut at the first quiet frame, never past 30 s.
    public static let cloudChunking = ChunkPolicy.silenceCut(targetSeconds: 20, maxSeconds: 30)

    static let sampleRate = 16_000.0
    static let frameSamples = 800 // 50 ms at 16 kHz

    /// Build the provider and its options from ntakker's configuration.
    public static func makeProvider(
        providerId: String,
        languages: [String]
    ) throws -> (any TranscriptionProvider, TranscriptionOptions) {
        guard batchProviderIds.contains(providerId) else { throw RetranscribeError.notBatchCapable(providerId) }
        var overrides = [
            ConfigResolver.Keys.output: NSTemporaryDirectory() + "ntakker-studio-retranscribe.m4a",
            ConfigResolver.Keys.transcribe: providerId,
        ]
        if !languages.isEmpty {
            overrides[ConfigResolver.Keys.transcribeLanguage] = languages.joined(separator: ",")
        }
        let options = try ConfigResolver(toolName: "ntakker").resolve(cliOverrides: overrides)
        let logger = Logger(label: "ntakker-studio.retranscribe.provider")
        let provider = try TranscriptionProviderFactory.build(
            TranscriptionProviderFactoryInput(options: options, logger: logger)
        )
        guard provider.supportedModes.contains(.batch) else { throw RetranscribeError.notBatchCapable(providerId) }
        let trOptions = TranscriptionOptions(
            providerId: provider.id,
            apiKey: options.transcriptionApiKey,
            modelId: options.transcriptionModelId,
            languageHints: options.transcriptionLanguageHints,
            customSystemInstruction: nil,
            keyExpiresAt: options.transcriptionKeyExpiresAt
        )
        return (provider, trOptions)
    }

    /// Transcribe every track of `recording` with `provider`.
    public static func run(
        recording: Recording,
        provider: any TranscriptionProvider,
        options: TranscriptionOptions,
        audioStart: Date,
        now: Date = Date(),
        progress: @escaping @Sendable (RetranscribeProgress) -> Void
    ) async throws -> RetranscribeResult {
        try await provider.prepare()
        let policy: ChunkPolicy = provider.chunkPolicy == .drainAll ? cloudChunking : provider.chunkPolicy
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let suffix = "\(options.providerId)-\(f.string(from: now))"
        let split = recording.tracks.count > 1

        var files: [URL] = []
        var total = 0
        for (i, track) in recording.tracks.enumerated() {
            var segments: [TranscriptSegment] = []
            let base = Double(i) / Double(recording.tracks.count)
            let share = 1 / Double(recording.tracks.count)
            try await forEachChunk(of: track.url, policy: policy) { samples, startSec, fraction in
                try Task.checkCancellation()
                let raw = try await provider.transcribe(samples: samples, source: track.role.sourceTag, options: options)
                let text = TranscriptSanitizer.clean(raw, chunkPeak: TranscriptSanitizer.peak(samples))
                if !text.isEmpty {
                    let ts = audioStart.addingTimeInterval(startSec)
                    segments.append(TranscriptSegment(
                        timestamp: ts, lastUpdated: ts, text: text,
                        source: track.role.sourceTag, model: options.providerId,
                        durationSec: Double(samples.count) / sampleRate,
                        language: options.languageHints.count == 1 ? options.languageHints[0] : nil
                    ))
                }
                progress(RetranscribeProgress(
                    fraction: base + fraction * share,
                    segmentsSoFar: total + segments.count,
                    lastText: text.isEmpty ? nil : text
                ))
            }
            let label = split ? "\(track.role.fileToken).\(suffix)" : suffix
            let url = recording.transcriptURL(label: label)
            try TranscriptDocument.write(segments, to: url)
            files.append(url)
            total += segments.count
        }

        var meta = try StudioMetadata.load(from: recording.metadataURL)
        if meta.audioStart == nil { meta.audioStart = audioStart }
        meta.exactTimingTranscripts.append(contentsOf: files.map(\.lastPathComponent))
        try meta.save(to: recording.metadataURL)
        return RetranscribeResult(files: files, segmentCount: total)
    }

    // MARK: - Decoding and chunking

    /// Decode `url` to 16 kHz mono and hand out chunks cut by `policy`.
    /// `body` gets the samples, the chunk's start in seconds and the
    /// fraction of the file read so far.
    static func forEachChunk(
        of url: URL,
        policy: ChunkPolicy,
        body: ([Float], Double, Double) async throws -> Void
    ) async throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw RetranscribeError.decode(url, error.localizedDescription)
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768),
              let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384)
        else { throw RetranscribeError.decode(url, "unsupported audio format") }
        // Mono: mix the channels down rather than keeping only the first.
        converter.downmix = true

        let (targetSec, maxSec): (Double, Double) = {
            switch policy {
            case .drainAll: return (20, 30)
            case .silenceCut(let t, let m): return (t, m)
            }
        }()
        let targetN = Int(targetSec * sampleRate)
        let maxN = Int(maxSec * sampleRate)

        var pending: [Float] = []
        var pendingStart = 0.0
        var finished = false
        let length = max(1, Double(file.length))

        while !finished {
            outBuf.frameLength = 0
            var readError: Error?
            let status = converter.convert(to: outBuf, error: nil) { _, inputStatus in
                // Reading at the end throws eofErr (-39) instead of
                // returning an empty buffer.
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuf
            }
            if let readError { throw RetranscribeError.decode(url, readError.localizedDescription) }
            if status == .error { throw RetranscribeError.decode(url, "conversion failed") }
            if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
                pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && outBuf.frameLength == 0) {
                finished = true
            }
            let fraction = min(1, Double(file.framePosition) / length)
            while pending.count >= maxN || (pending.count >= targetN && quietCut(in: pending, from: targetN, to: pending.count) != nil) {
                let cut = cutPoint(in: pending, targetN: targetN, maxN: maxN)
                let chunk = Array(pending[0..<cut])
                pending.removeFirst(cut)
                try await body(chunk, pendingStart, fraction)
                pendingStart += Double(cut) / sampleRate
            }
        }
        // A tail shorter than one 50 ms frame carries no speech.
        if pending.count >= frameSamples {
            try await body(pending, pendingStart, 1)
        }
    }

    /// Where to cut `samples`: the first quiet 50 ms frame at or after
    /// `targetN`, else the quietest frame before `maxN`.
    static func cutPoint(in samples: [Float], targetN: Int, maxN: Int) -> Int {
        let upper = min(samples.count, maxN)
        if let q = quietCut(in: samples, from: targetN, to: upper) { return q }
        var best = upper, bestRMS = Float.greatestFiniteMagnitude
        var i = targetN
        while i + frameSamples <= upper {
            let r = rms(samples, i, frameSamples)
            if r < bestRMS { bestRMS = r; best = i + frameSamples / 2 }
            i += frameSamples
        }
        return max(1, best)
    }

    static func quietCut(in samples: [Float], from: Int, to: Int) -> Int? {
        var i = from
        while i + frameSamples <= to {
            if rms(samples, i, frameSamples) < TranscriptSanitizer.silenceThreshold { return i + frameSamples / 2 }
            i += frameSamples
        }
        return nil
    }

    static func rms(_ s: [Float], _ start: Int, _ n: Int) -> Float {
        var sum: Float = 0
        for k in start..<(start + n) { sum += s[k] * s[k] }
        return (sum / Float(n)).squareRoot()
    }
}
