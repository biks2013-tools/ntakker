// NtakkerStudioKit/Joining/RecordingJoiner.swift — 2026-10-19.
//
// Joins recordings into one: typically the `.partNN` parts of a session
// that was paused and resumed (or split), but any recordings with the
// same track layout. The originals are never touched; the joined
// recording is a new one.
//
// Order and timeline. Parts are joined in the order they were recorded
// (their audio start), end to end: the pauses between them are not kept
// as silence. Every track of a part is padded with silence to the part's
// longest track, so mic and system stay aligned in the parts after it.
//
// Transcripts. A transcript of the joined recording exists for every
// label any part has (main, microphone, system, re-transcriptions). Each
// part's lines are placed as the studio shows them (its audio start,
// sync nudge and exact-timing flags), shifted by where the part begins
// in the joined audio, and written with exact timing.
//
// Metadata. The joined recording starts at the first part's start.
// Speaker names are merged (an id named in an earlier part keeps that
// name); the first linked meeting is kept. Minutes and notes are not
// carried over: they describe one part.
//
// Where it goes:
//   * the first part's folder holds only the joined recordings → a sibling
//     folder `<folder>-joined-<yyyy-MM-dd-HH-mm-ss>/`;
//   * otherwise → a subfolder `<stem>-joined-<yyyy-MM-dd-HH-mm-ss>/` of it.
// The files are named after the parts' stem without `.partNN`.

import AVFoundation
import Foundation
import NtakkerCore

public enum RecordingJoinError: Error, LocalizedError, Equatable {
    case tooFew
    case noAudio(String)
    case layoutDiffers(first: String, firstTracks: String, part: String, partTracks: String)
    case unreadable(String, String)

    public var errorDescription: String? {
        switch self {
        case .tooFew:
            return "Choose at least two recordings to join."
        case .noAudio(let name):
            return "\(name) has no audio that can be read."
        case .layoutDiffers(let first, let firstTracks, let part, let partTracks):
            return "\(first) has \(firstTracks) but \(part) has \(partTracks): only recordings with the same tracks can be joined. If a track's file was moved, put it back next to the others."
        case .unreadable(let file, let why):
            return "Could not read \(file): \(why)"
        }
    }
}

/// One recording to join, with what the studio knows about it.
public struct JoinPart: Sendable {
    public let recording: Recording
    public let metadata: StudioMetadata
    public let audioStart: Date
    /// The longest track's length, in seconds.
    public let duration: Double
    /// Each transcript's lines, placed on the part's own timeline.
    public let entriesByTranscript: [TranscriptFile: [TranscriptEntry]]

    public init(recording: Recording, metadata: StudioMetadata, audioStart: Date, duration: Double,
                entriesByTranscript: [TranscriptFile: [TranscriptEntry]]) {
        self.recording = recording
        self.metadata = metadata
        self.audioStart = audioStart
        self.duration = duration
        self.entriesByTranscript = entriesByTranscript
    }

    /// Read a recording from disk: its metadata, audio length and
    /// transcripts. A corrupt `studio.json` throws, so the parts' timing
    /// is never silently guessed.
    public static func load(_ recording: Recording) throws -> JoinPart {
        let meta = try StudioMetadata.load(from: recording.metadataURL)
        let start = meta.audioStart ?? recording.createdAt
        var byFile: [TranscriptFile: [TranscriptEntry]] = [:]
        for t in recording.transcripts {
            let exact = meta.exactTimingTranscripts.contains(t.url.lastPathComponent)
            byFile[t] = TranscriptDocument.load(t).entries(audioStart: start, exact: exact, syncOffsetSec: meta.syncOffsetSec)
        }
        let duration = RecordingTiming.duration(of: recording)
        guard duration > 0 else { throw RecordingJoinError.noAudio(recording.displayName) }
        return JoinPart(recording: recording, metadata: meta, audioStart: start, duration: duration, entriesByTranscript: byFile)
    }
}

/// What a join would do (shown before it runs) and what it did.
public struct JoinPlan: Sendable {
    public struct Item: Sendable {
        public let part: JoinPart
        /// Where the part begins in the joined audio, in seconds.
        public let offset: Double
        /// Wall-clock time between the end of the previous part and the
        /// start of this one (nil for the first). Negative when they
        /// overlap.
        public let pauseBefore: Double?
    }

    public let items: [Item]
    public let stem: String
    public let roles: [AudioTrackRole]

    public var duration: Double { items.last.map { $0.offset + $0.part.duration } ?? 0 }
    public var audioStart: Date { items.first?.part.audioStart ?? .distantPast }
    /// Labels of the joined transcripts (main first).
    public var transcriptLabels: [String] {
        var seen: [String] = []
        for item in items {
            for t in item.part.recording.transcripts where !seen.contains(t.label) { seen.append(t.label) }
        }
        return seen.sorted { order($0) < order($1) }
    }

    private func order(_ label: String) -> String {
        switch label {
        case "": return "0"
        case "microphone": return "1"
        case "system": return "2"
        default: return "3" + label
        }
    }
}

public struct JoinResult: Sendable {
    public let folder: URL
    public let stem: String
    public let parts: Int
    public let duration: Double
    public let lines: Int
}

public enum RecordingJoiner {

    /// Order the parts by start and check they can be joined.
    public static func plan(_ parts: [JoinPart]) throws -> JoinPlan {
        guard parts.count >= 2 else { throw RecordingJoinError.tooFew }
        let ordered = parts.sorted { $0.audioStart < $1.audioStart }
        let roles = ordered[0].recording.tracks.map(\.role)
        for p in ordered.dropFirst() where Set(p.recording.tracks.map(\.role)) != Set(roles) {
            throw RecordingJoinError.layoutDiffers(
                first: ordered[0].recording.displayName, firstTracks: describe(roles),
                part: p.recording.displayName, partTracks: describe(p.recording.tracks.map(\.role))
            )
        }
        var items: [JoinPlan.Item] = []
        var offset = 0.0
        for (i, p) in ordered.enumerated() {
            let pause = i == 0 ? nil : p.audioStart.timeIntervalSince(ordered[i - 1].audioStart.addingTimeInterval(ordered[i - 1].duration))
            items.append(JoinPlan.Item(part: p, offset: offset, pauseBefore: pause))
            offset += p.duration
        }
        return JoinPlan(items: items, stem: baseStem(ordered[0].recording.stem), roles: roles)
    }

    /// Write the joined recording. `progress` gets 0…1.
    public static func join(
        _ plan: JoinPlan,
        now: Date = Date(),
        progress: @escaping (Double) -> Void = { _ in }
    ) throws -> JoinResult {
        let fm = FileManager.default
        let dest = destinationFolder(for: plan, now: now)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            let total = Double(plan.roles.count) * plan.duration
            var done = 0.0
            for role in plan.roles {
                let sources = try plan.items.map { item -> (URL, Double) in
                    guard let track = item.part.recording.tracks.first(where: { $0.role == role }) else {
                        throw RecordingJoinError.layoutDiffers(
                            first: plan.items[0].part.recording.displayName, firstTracks: describe(plan.roles),
                            part: item.part.recording.displayName, partTracks: describe(item.part.recording.tracks.map(\.role)))
                    }
                    return (track.url, item.part.duration)
                }
                let ext = sources[0].0.pathExtension
                let out = dest.appendingPathComponent(trackName(stem: plan.stem, role: role, ext: ext))
                try AudioJoiner.concatenate(sources, to: out) { seconds in
                    progress(0.95 * (done + seconds) / max(1, total))
                }
                done += plan.duration
                try? fm.setAttributes([.creationDate: plan.audioStart], ofItemAtPath: out.path)
            }

            var lines = 0
            var exact: [String] = []
            for label in plan.transcriptLabels {
                let segments = joinedSegments(plan, label: label)
                lines += segments.count
                let name = label.isEmpty ? "\(plan.stem).transcript.jsonl" : "\(plan.stem).\(label).transcript.jsonl"
                try TranscriptDocument.write(segments, to: dest.appendingPathComponent(name))
                exact.append(name)
            }

            var names: [String: String] = [:]
            for item in plan.items {
                for (raw, name) in item.part.metadata.speakerNames where names[raw] == nil { names[raw] = name }
            }
            let meta = StudioMetadata(
                audioStart: plan.audioStart,
                speakerNames: names,
                syncOffsetSec: 0,
                exactTimingTranscripts: exact,
                meeting: plan.items.lazy.compactMap(\.part.metadata.meeting).first
            )
            try meta.save(to: dest.appendingPathComponent("\(plan.stem).studio.json"))
            progress(1)
            return JoinResult(folder: dest, stem: plan.stem, parts: plan.items.count, duration: plan.duration, lines: lines)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// The lines of every part's `label` transcript on the joined timeline.
    static func joinedSegments(_ plan: JoinPlan, label: String) -> [TranscriptSegment] {
        plan.items.flatMap { item -> [TranscriptSegment] in
            guard let file = item.part.recording.transcripts.first(where: { $0.label == label }) else { return [] }
            return (item.part.entriesByTranscript[file] ?? []).map { e in
                let s = e.segment
                let timestamp = plan.audioStart.addingTimeInterval(item.offset + e.start)
                return TranscriptSegment(
                    id: s.id, timestamp: timestamp, lastUpdated: timestamp, text: s.text, source: s.source,
                    confidence: s.confidence, model: s.model,
                    durationSec: s.durationSec == nil ? nil : max(0, e.end - e.start),
                    language: s.language, speaker: s.speaker
                )
            }
        }
    }

    /// `x.part03` → `x`.
    public static func baseStem(_ stem: String) -> String {
        if let last = stem.split(separator: ".").last, RecordingLibraryScanner.isPartToken(last) {
            return String(stem.dropLast(last.count + 1))
        }
        return stem
    }

    static func trackName(stem: String, role: AudioTrackRole, ext: String) -> String {
        switch role {
        case .mixed: return "\(stem).\(ext)"
        case .microphone: return "\(stem).mic.\(ext)"
        case .system: return "\(stem).system.\(ext)"
        }
    }

    static func describe(_ roles: [AudioTrackRole]) -> String {
        let set = Set(roles)
        if set == [.mixed] { return "one mixed track" }
        if set == [.microphone, .system] { return "mic + system tracks" }
        if set == [.microphone] { return "only a microphone track" }
        if set == [.system] { return "only a system-audio track" }
        return roles.map(\.fileToken).joined(separator: " + ")
    }

    static func destinationFolder(for plan: JoinPlan, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = f.string(from: now)
        let first = plan.items[0].part.recording
        let joined = Set(plan.items.map(\.part.recording.id))
        let alone = RecordingLibraryScanner.recordings(inFolder: first.folder).allSatisfy { joined.contains($0.id) }
        let base: URL
        let name: String
        if alone {
            base = first.folder.deletingLastPathComponent()
            name = "\(first.folder.lastPathComponent)-joined-\(stamp)"
        } else {
            base = first.folder
            name = "\(plan.stem)-joined-\(stamp)"
        }
        var candidate = base.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(name)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}

public enum AudioJoiner {
    static let chunkFrames: AVAudioFrameCount = 65_536

    /// Write the `sources` one after the other into `destination`, in the
    /// first source's file format. Each source is padded with silence to
    /// its given length (seconds) when shorter; a source in another
    /// sample rate or channel count is converted. `progress` gets the
    /// seconds written so far.
    public static func concatenate(
        _ sources: [(url: URL, length: Double)],
        to destination: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        guard let firstURL = sources.first?.url else { return }
        let first = try open(firstURL)
        let format = first.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: first.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw RecordingJoinError.unreadable(firstURL.lastPathComponent, "could not allocate a buffer")
        }
        let rate = format.sampleRate
        var before = 0.0
        for (url, length) in sources {
            let input = url == firstURL ? first : try open(url)
            input.framePosition = 0
            let target = AVAudioFramePosition((length * rate).rounded())
            var written: AVAudioFramePosition = 0
            func report() { progress(before + Double(written) / rate) }

            if input.processingFormat == format {
                // Reading past the end throws (eofErr) rather than
                // returning nothing: stop at the file's length.
                let readable = min(target, input.length)
                while written < readable {
                    let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), readable - written))
                    try input.read(into: buffer, frameCount: want)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                    written += AVAudioFramePosition(buffer.frameLength)
                    report()
                }
            } else {
                written = try convert(input, into: output, format: format, limit: target, progress: { written = $0; report() })
            }
            // Silence up to the part's length.
            while written < target {
                let n = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), target - written))
                buffer.frameLength = n
                for ch in 0..<Int(format.channelCount) {
                    if let data = buffer.floatChannelData?[ch] { data.update(repeating: 0, count: Int(n)) }
                    else if let data = buffer.int16ChannelData?[ch] { data.update(repeating: 0, count: Int(n)) }
                    else if let data = buffer.int32ChannelData?[ch] { data.update(repeating: 0, count: Int(n)) }
                }
                try output.write(from: buffer)
                written += AVAudioFramePosition(n)
                report()
            }
            before += Double(target) / rate
        }
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do { return try AVAudioFile(forReading: url) } catch {
            throw RecordingJoinError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
    }

    /// Convert `input` to `format` and append up to `limit` frames to
    /// `output`. Returns the frames written.
    private static func convert(
        _ input: AVAudioFile, into output: AVAudioFile, format: AVAudioFormat,
        limit: AVAudioFramePosition, progress: (AVAudioFramePosition) -> Void
    ) throws -> AVAudioFramePosition {
        let source = input.processingFormat
        guard let converter = AVAudioConverter(from: source, to: format),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunkFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw RecordingJoinError.unreadable(input.url.lastPathComponent, "cannot convert \(source) to \(format)")
        }
        var written: AVAudioFramePosition = 0
        var readError: Error?
        var finished = false
        while written < limit {
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                let left = input.length - input.framePosition
                if finished || left <= 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), left)))
                } catch {
                    readError = error
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw RecordingJoinError.unreadable(input.url.lastPathComponent, readError.localizedDescription) }
            if status == .error {
                throw RecordingJoinError.unreadable(input.url.lastPathComponent, convError?.localizedDescription ?? "conversion failed")
            }
            if outBuffer.frameLength > 0 {
                let keep = min(AVAudioFramePosition(outBuffer.frameLength), limit - written)
                outBuffer.frameLength = AVAudioFrameCount(keep)
                try output.write(from: outBuffer)
                written += keep
                progress(written)
            }
            if status == .endOfStream || (finished && outBuffer.frameLength == 0) { break }
        }
        return written
    }
}
