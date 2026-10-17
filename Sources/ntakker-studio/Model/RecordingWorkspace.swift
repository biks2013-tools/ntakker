// ntakker-studio/Model/RecordingWorkspace.swift — plan-024 T9.
//
// Everything about the recording open in the detail view: its
// transcripts placed on the timeline, the player, the waveform, the
// cut being prepared, and the Ask / minutes / re-transcribe jobs.

import AppKit
import Foundation
import NtakkerCore
import NtakkerStudioKit
import Observation

@MainActor @Observable
final class RecordingWorkspace {
    private(set) var recording: Recording
    let player = PlayerController()

    private(set) var metadata: StudioMetadata
    private(set) var metadataError: String?
    private(set) var documents: [TranscriptFile: TranscriptDocument] = [:]
    /// Transcripts shown in the pane (and used by Ask / minutes / cut).
    var visibleTranscripts: Set<URL> = [] { didSet { rebuildEntries() } }
    private(set) var entries: [TranscriptEntry] = []
    private(set) var waveform: WaveformPeaks = .empty
    private(set) var isLoaded = false

    // Transcript pane
    var followPlayback = true
    var filterText = ""
    var hiddenSpeakers: Set<String> = []
    var editingID: UUID?
    var lastError: String?

    // Cut
    var selection: CutRange?
    private(set) var cuts: [CutRange] = []
    var previewCuts = false { didSet { applySkipRanges() } }
    /// Clean the mic of the system track's echo in the exported copy.
    var exportRemovesEcho = false
    var canRemoveEcho: Bool {
        recording.tracks.contains { $0.role == .microphone } && recording.tracks.contains { $0.role == .system }
    }
    private(set) var exportProgress: Double?
    private(set) var lastExport: CutExportResult?

    // Ask
    private(set) var exchanges: [AskExchange] = []
    private(set) var pendingQuestion: String?
    private(set) var streamingAnswer = ""
    private(set) var askProviderLine: String?
    @ObservationIgnored private var askTask: Task<Void, Never>?

    // Minutes
    private(set) var minutes: String = ""
    private(set) var minutesGenerating = false
    private(set) var minutesSavedAt: Date?
    @ObservationIgnored private var minutesTask: Task<Void, Never>?

    // Re-transcribe
    private(set) var retranscribeProgress: RetranscribeProgress?
    private(set) var retranscribeDone: RetranscribeResult?
    @ObservationIgnored private var retranscribeTask: Task<Void, Never>?

    /// Called when files of this recording changed on disk (new
    /// transcript, cut copy) so the library rescans.
    @ObservationIgnored var onFilesChanged: ((_ showOnly: [URL]?) -> Void)?

    init(recording: Recording) {
        self.recording = recording
        do {
            metadata = try StudioMetadata.load(from: recording.metadataURL)
        } catch {
            metadata = StudioMetadata()
            metadataError = "\(recording.metadataURL.lastPathComponent) could not be read (\(error.localizedDescription)); changes to speakers and timing will not be saved until it is fixed or removed."
        }
        visibleTranscripts = Set(recording.transcripts.map(\.url))
        if let saved = try? String(contentsOf: recording.minutesURL, encoding: .utf8) {
            minutes = saved
        }
    }

    var audioStart: Date { metadata.audioStart ?? recording.createdAt }
    var duration: Double { max(player.duration, waveform.duration) }

    func load() async {
        let rec = recording
        let docs = await Task.detached { () -> [TranscriptFile: TranscriptDocument] in
            var out: [TranscriptFile: TranscriptDocument] = [:]
            for t in rec.transcripts { out[t] = TranscriptDocument.load(t) }
            return out
        }.value
        documents = docs
        rebuildEntries()
        await player.load(tracks: rec.tracks)
        isLoaded = true
        let urls = rec.tracks.map(\.url)
        waveform = await Task.detached(priority: .utility) {
            (try? WaveformPeaks.load(tracks: urls, bucketCount: 2400)) ?? .empty
        }.value
    }

    /// The library rescanned this recording. Load transcripts that are
    /// new (a re-transcription); when `showOnly` is given, show just those.
    func adopt(_ updated: Recording, showOnly: [URL]? = nil) async {
        guard updated.id == recording.id else { return }
        let known = Set(documents.keys.map(\.url))
        let added = updated.transcripts.filter { !known.contains($0.url) }
        recording = updated
        if let m = try? StudioMetadata.load(from: updated.metadataURL) { metadata = m }
        let loaded = await Task.detached { added.map { ($0, TranscriptDocument.load($0)) } }.value
        for (file, doc) in loaded { documents[file] = doc }
        if let showOnly, !showOnly.isEmpty {
            visibleTranscripts = Set(showOnly)
        } else {
            visibleTranscripts.formUnion(added.map(\.url))
        }
        rebuildEntries()
    }

    func close() {
        askTask?.cancel()
        minutesTask?.cancel()
        retranscribeTask?.cancel()
        player.teardown()
    }

    // MARK: - Entries

    func isExact(_ file: TranscriptFile) -> Bool {
        metadata.exactTimingTranscripts.contains(file.url.lastPathComponent)
    }

    private func rebuildEntries() {
        var all: [TranscriptEntry] = []
        for (file, doc) in documents where visibleTranscripts.contains(file.url) {
            all += doc.entries(audioStart: audioStart, exact: isExact(file), syncOffsetSec: metadata.syncOffsetSec)
        }
        entries = all.sorted { $0.start < $1.start }
    }

    /// Entries after the speaker and text filters.
    var shownEntries: [TranscriptEntry] {
        let words = TranscriptSearchIndex.fold(filterText).split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { e in
            if hiddenSpeakers.contains(speakerKey(e.segment)) { return false }
            guard !words.isEmpty else { return true }
            let folded = TranscriptSearchIndex.fold(e.segment.text)
            return words.allSatisfy(folded.contains)
        }
    }

    /// The line being played: the last one that started at or before now.
    var activeEntryID: UUID? {
        let t = player.currentTime
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let e = entries[lo - 1]
        return t - max(e.end, e.start + 1) < 8 ? e.id : nil
    }

    func speakerKey(_ s: TranscriptSegment) -> String {
        s.speaker.flatMap { $0.isEmpty ? nil : $0 } ?? "source:" + s.source.rawValue
    }

    func speakerLabel(_ s: TranscriptSegment) -> String {
        StudioAsk.speakerLabel(s, metadata: metadata)
    }

    /// Distinct speakers in the visible transcripts: key, raw id, lines.
    var speakers: [(key: String, raw: String?, label: String, count: Int, first: Double)] {
        var seen: [String: (String?, String, Int, Double)] = [:]
        for e in entries {
            let k = speakerKey(e.segment)
            if let v = seen[k] {
                seen[k] = (v.0, v.1, v.2 + 1, v.3)
            } else {
                seen[k] = (e.segment.speaker, speakerLabel(e.segment), 1, e.start)
            }
        }
        return seen.map { (key: $0.key, raw: $0.value.0, label: $0.value.1, count: $0.value.2, first: $0.value.3) }
            .sorted { $0.first < $1.first }
    }

    var transcriptText: String {
        StudioAsk.transcriptText(entries: entries, metadata: metadata, duration: duration)
    }

    // MARK: - Metadata edits

    private func saveMetadata(_ change: (inout StudioMetadata) -> Void) {
        guard metadataError == nil else { lastError = metadataError; return }
        var m = metadata
        change(&m)
        do {
            try m.save(to: recording.metadataURL)
            metadata = m
            rebuildEntries()
        } catch {
            lastError = "Could not save \(recording.metadataURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func renameSpeaker(raw: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveMetadata { m in
            if trimmed.isEmpty { m.speakerNames[raw] = nil } else { m.speakerNames[raw] = trimmed }
        }
    }

    func setSyncOffset(_ seconds: Double) {
        saveMetadata { $0.syncOffsetSec = (seconds * 100).rounded() / 100 }
    }

    // MARK: - Text edits

    func updateText(of entry: TranscriptEntry, to text: String) {
        guard let (file, doc) = documents.first(where: { $0.key.url == entry.transcriptURL }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.segment.text else { return }
        doc.updateText(id: entry.id, to: trimmed)
        do {
            try doc.save()
        } catch {
            lastError = "Could not save \(file.url.lastPathComponent): \(error.localizedDescription)"
        }
        rebuildEntries()
    }

    // MARK: - Cuts

    func addSelectionAsCut() {
        guard let s = selection, s.duration > 0.05 else { return }
        cuts = CutPlan(ranges: cuts + [s], duration: duration).ranges
        selection = nil
        applySkipRanges()
    }

    func addCut(_ r: CutRange) {
        cuts = CutPlan(ranges: cuts + [r], duration: duration).ranges
        applySkipRanges()
    }

    func removeCut(_ r: CutRange) {
        cuts.removeAll { $0 == r }
        applySkipRanges()
    }

    func clearCuts() {
        cuts = []
        applySkipRanges()
    }

    private func applySkipRanges() {
        player.skipRanges = previewCuts ? cuts.map { $0.start...$0.end } : []
    }

    var cutPlan: CutPlan { CutPlan(ranges: cuts, duration: duration) }

    func exportCut() {
        let removeEcho = exportRemovesEcho && canRemoveEcho
        guard exportProgress == nil, !cuts.isEmpty || removeEcho else { return }
        let rec = recording, plan = cutPlan, start = audioStart, meta = metadata
        var byFile: [TranscriptFile: [TranscriptEntry]] = [:]
        for (file, doc) in documents {
            byFile[file] = doc.entries(audioStart: start, exact: isExact(file), syncOffsetSec: meta.syncOffsetSec)
        }
        let entriesByFile = byFile
        exportProgress = 0
        lastExport = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RecordingCutExporter.export(
                        recording: rec, plan: plan, entriesByTranscript: entriesByFile,
                        audioStart: start, metadata: meta, removeEcho: removeEcho
                    ) { p in
                        Task { @MainActor in
                            if self.exportProgress != nil { self.exportProgress = p }
                        }
                    }
                }.value
                lastExport = result
                onFilesChanged?(nil)
            } catch {
                lastError = "Export failed: \(error.localizedDescription)"
            }
            exportProgress = nil
        }
    }

    // MARK: - Ask

    var isAsking: Bool { pendingQuestion != nil }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking else { return }
        let stream: StudioAskStream
        do {
            stream = try StudioAsk.ask(
                question: q, transcript: transcriptText, recordingName: recording.displayName,
                recordedAt: audioStart, duration: duration, history: exchanges
            )
        } catch {
            lastError = Self.describe(error)
            return
        }
        askProviderLine = "\(stream.provider.displayName) · \(stream.model)"
        pendingQuestion = q
        streamingAnswer = ""
        askTask = Task {
            do {
                for try await token in stream.tokens { streamingAnswer += token }
                let x = AskExchange(question: q, answer: streamingAnswer, askedAt: Date())
                exchanges.append(x)
                try? StudioNotes.appendExchange(x, provider: stream.provider.rawValue, model: stream.model, to: recording.studioQAURL)
            } catch is CancellationError {
            } catch {
                lastError = "Ask failed: \(Self.describe(error))"
            }
            pendingQuestion = nil
            streamingAnswer = ""
        }
    }

    func stopAsking() { askTask?.cancel() }

    // MARK: - Minutes

    func generateMinutes(language: String?) {
        guard !minutesGenerating else { return }
        let stream: StudioAskStream
        do {
            stream = try StudioAsk.minutes(
                transcript: transcriptText, recordingName: recording.displayName,
                recordedAt: audioStart, duration: duration, language: language
            )
        } catch {
            lastError = Self.describe(error)
            return
        }
        askProviderLine = "\(stream.provider.displayName) · \(stream.model)"
        let previous = minutes
        minutes = ""
        minutesGenerating = true
        minutesTask = Task {
            do {
                for try await token in stream.tokens { minutes += token }
                let now = Date()
                try StudioNotes.writeMinutes(minutes, provider: stream.provider.rawValue, model: stream.model, generatedAt: now, to: recording.minutesURL)
                minutes = (try? String(contentsOf: recording.minutesURL, encoding: .utf8)) ?? minutes
                minutesSavedAt = now
                onFilesChanged?(nil)
            } catch is CancellationError {
                minutes = previous
            } catch {
                lastError = "Minutes failed: \(Self.describe(error))"
                if minutes.isEmpty { minutes = previous }
            }
            minutesGenerating = false
        }
    }

    func stopMinutes() { minutesTask?.cancel() }

    // MARK: - Re-transcribe

    var isRetranscribing: Bool { retranscribeTask != nil }

    func retranscribe(providerId: String, languages: [String]) {
        guard retranscribeTask == nil else { return }
        let built: (any TranscriptionProvider, TranscriptionOptions)
        do {
            built = try Retranscriber.makeProvider(providerId: providerId, languages: languages)
        } catch {
            lastError = Self.describe(error)
            return
        }
        let rec = recording, start = audioStart
        retranscribeDone = nil
        retranscribeProgress = RetranscribeProgress(fraction: 0, segmentsSoFar: 0, lastText: nil)
        retranscribeTask = Task {
            do {
                let result = try await Retranscriber.run(
                    recording: rec, provider: built.0, options: built.1, audioStart: start
                ) { p in
                    Task { @MainActor in
                        if self.retranscribeTask != nil { self.retranscribeProgress = p }
                    }
                }
                retranscribeDone = result
                onFilesChanged?(result.files)
            } catch is CancellationError {
            } catch {
                lastError = "Re-transcription failed: \(Self.describe(error))"
            }
            retranscribeTask = nil
            retranscribeProgress = nil
        }
    }

    func cancelRetranscribe() { retranscribeTask?.cancel() }

    static func describe(_ error: Error) -> String {
        if let e = error as? NtakkerError { return e.description }
        return error.localizedDescription
    }
}
