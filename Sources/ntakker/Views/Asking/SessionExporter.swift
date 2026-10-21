// ntakker/Views/Asking/SessionExporter.swift — plan-015 Phase 2 + 4.
// Bundles a finished session into a self-contained folder:
//
//     ~/Recordings/<folder-name>/
//       ├── transcript.md       (live transcript, Markdown)
//       ├── qa.md               (Q&A interjections, Markdown)
//       └── recording-XXX.m4a   (one or more audio files, moved)
//
// Atomic writes: each markdown file is written to a sibling `.tmp`
// and then renamed (FR-IRQ-52). Audio + transcript / questions JSONL
// sidecars are *moved* (copy-then-delete-original) so the saved folder
// is the sole home of the captured session — no leftover duplicates
// remain in the user's configured output folder. The
// recording-integrity invariant is preserved: each original is only
// deleted after `FileManager.copyItem(...)` returned without throwing;
// on copy failure the source file is untouched and the operation is
// logged but does not abort the rest of the bundle.
//
// Collision handling (FR-IRQ-32): when the destination folder
// already exists, an ISO-style timestamp suffix is appended
// (`-2026-05-13T17-12-04Z`) so the new bundle never overwrites a
// previous one. The caller is told which final folder was used so it
// can reveal in Finder.
//
// Lives in `ntakker` (not `NtakkerCore`) for now because the Q&A
// entry struct is a UI-local model in this phase. plan-015 Phase 3
// will lift the export logic into `NtakkerCore/Export/TranscriptExporter.swift`
// once `QASessionHistory` is promoted to core for the floating overlay.

import Foundation
import NtakkerCore
import NtakkerUIKit
import os

/// Not main-actor bound: `RootView.performSessionSave` runs `write` on
/// a background task (EVAL-2026-10-16 H2). Everything here is file I/O
/// over value-type inputs.
enum SessionExporter {

    /// Subsystem-tagged logger so Console.app can reliably filter on
    /// `subsystem == com.giorgosmarinos.ntakker` AND `category == SessionExporter`.
    /// NSLog from a `.app` launched via `open` does not always surface
    /// in the unified log; `Logger` always does.
    private static let log = Logger(
        subsystem: "com.giorgosmarinos.ntakker",
        category: "SessionExporter"
    )

    /// The segment stem a source's sidecars are named after. Split-layout
    /// audio (`<stem>.system.<ext>` / `<stem>.mic.<ext>`) shares the
    /// sidecars of `<stem>`, so the per-side suffix is stripped.
    private static func segmentStem(of source: URL) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        for side in [".system", ".mic"] where stem.hasSuffix(side) {
            return String(stem.dropLast(side.count))
        }
        return stem
    }

    /// Every sidecar filename the engine / app may have written for one
    /// audio source (EVAL-2026-10-16 UI-1):
    ///   * transcripts: `<stem>.[system.|microphone.]transcript.<fmt>`;
    ///     for `.part01` also the bare-stem names a pre-fix build left
    ///     behind (segment 1 used to keep them after its audio was renamed);
    ///   * legacy base-based transcripts: `<base>.transcript.<fmt>`;
    ///   * questions: `<base>.questions.jsonl` / `<stem>.questions.jsonl`.
    private static func sidecarNameCandidates(for source: URL) -> [String] {
        let base = source.lastPathComponent
        let stem = segmentStem(of: source)
        var stems = [stem]
        if stem.hasSuffix(".part01") {
            stems.append(String(stem.dropLast(".part01".count)))
        }
        var names: [String] = []
        for s in stems {
            for format in TranscriptFormat.allCases {
                names.append("\(s).transcript.\(format.rawValue)")
                names.append("\(s).system.transcript.\(format.rawValue)")
                names.append("\(s).microphone.transcript.\(format.rawValue)")
            }
            names.append("\(s).questions.jsonl")
        }
        for format in TranscriptFormat.allCases {
            names.append("\(base).transcript.\(format.rawValue)")
        }
        names.append("\(base).questions.jsonl")
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// All JSONL transcript sidecars on disk for the session, across
    /// every part and every per-source file.
    private static func locateTranscriptSidecars(audioSources: [URL]) -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [URL] = []
        for source in audioSources {
            let dir = source.deletingLastPathComponent()
            for name in sidecarNameCandidates(for: source)
            where name.hasSuffix(".transcript.jsonl") {
                let url = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path), seen.insert(url.path).inserted else { continue }
                found.append(url)
            }
        }
        return found
    }

    /// The questions sidecar. `persistQASidecarIfNeeded` writes the whole
    /// history next to the LAST completed segment, so probe from the end.
    private static func locateQuestionsSidecar(audioSources: [URL]) -> URL? {
        let fm = FileManager.default
        for source in audioSources.reversed() {
            let dir = source.deletingLastPathComponent()
            for name in sidecarNameCandidates(for: source) where name.hasSuffix(".questions.jsonl") {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Read and merge transcript sidecars: newest line per segment id,
    /// sorted by timestamp. `nil` when nothing was read.
    private static func mergedTranscript(from urls: [URL]) -> [TranscriptSegment]? {
        var byId: [UUID: TranscriptSegment] = [:]
        for url in urls {
            for segment in JSONLTranscriptReader.read(from: url) {
                byId[segment.id] = segment
            }
        }
        guard !byId.isEmpty else { return nil }
        return byId.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Expand a single audio source URL into the actual files on disk.
    ///
    /// The `SessionCoordinator` emits `.segmentCompleted` with the BARE
    /// `options.output` URL (e.g. `recording.m4a`), except for a
    /// split-layout part 1, which it reports as the renamed
    /// `recording.part01.system.m4a`. `SegmentNamer.audioFiles` resolves
    /// both to every file of the part (the single file, or the system
    /// and mic siblings), so Save moves part 1's mic too.
    private static func expandAudioSources(_ source: URL) -> [URL] {
        SegmentNamer.audioFiles(forCompletedSegment: source)
    }

    /// Result of a successful bundle write.
    struct WriteResult: Sendable {
        let folder: URL
        let transcriptFile: URL?
        let qaFile: URL?
        let audioFiles: [URL]
    }

    enum ExportError: LocalizedError {
        case noContent
        case folderResolutionFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noContent:
                return String(localized: "Nothing to save — no audio, transcript, or Q&A produced yet.")
            case .folderResolutionFailed:
                return String(localized: "Could not resolve a writable ~/Recordings folder.")
            case .writeFailed(let why):
                return String(localized: "Save failed: \(why)")
            }
        }
    }

    /// Write a complete session bundle.
    ///
    /// - Parameters:
    ///   - folderName: Already-sanitised folder name (see
    ///     `SaveSessionDialog.sanitized`). Must be non-empty.
    ///   - transcript: Live transcript segments from
    ///     `RecordingController.transcriptSegments`.
    ///   - qaHistory: Q&A entries from `AskingSessionStore.history`.
    ///   - audioSources: Source `m4a` (or other) files to copy into
    ///     the new folder. Typically
    ///     `RecordingController.completedSegments`.
    static func write(
        folderName: String,
        transcript: [TranscriptSegment],
        qaHistory: [QAEntry],
        audioSources: [URL]
    ) throws -> WriteResult {

        // Guard against the "user clicked Save before recording
        // anything" case. The dialog allows Save with empty content;
        // surfacing a clean error is friendlier than writing an empty
        // bundle.
        let hasContent = !transcript.isEmpty
            || !qaHistory.isEmpty
            || !audioSources.isEmpty
        guard hasContent else { throw ExportError.noContent }

        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ExportError.folderResolutionFailed }

        // Resolve `~/Recordings/<name>/`, suffixing on collision.
        let recordingsRoot = try resolveRecordingsRoot()
        let folder = try resolveCollisionFreeFolder(base: recordingsRoot, name: trimmedName)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed("could not create \(folder.path): \(error.localizedDescription)")
        }

        // Prefer the on-disk JSONL sidecars when present — they are
        // the engine's source-of-truth and carry the COMPLETE session
        // history. The in-memory `transcript` / `qaHistory` arrays
        // are subject to:
        //   * a rolling-cap of 100 segments on `transcriptSegments`
        //     (`RecordingController.maxLiveTranscriptSegments`), and
        //   * a `clearSession()` reset on `askingStore.history` after
        //     "Save and start new" cycles
        // — so for long sessions the in-memory copy is truncated to
        // the latest part. Reading from the JSONL files lets the bundle
        // capture every segment / question that was ever produced.
        // When no sidecar is found (transcription disabled, or no
        // questions asked) we fall back to the in-memory arrays, which
        // is still correct for that case.
        let transcriptSidecars = locateTranscriptSidecars(audioSources: audioSources)
        let questionsSidecar = locateQuestionsSidecar(audioSources: audioSources)
        let transcriptFromSidecar = mergedTranscript(from: transcriptSidecars)
        let qaFromSidecar = questionsSidecar.flatMap { url -> [QASidecarEntry]? in
            let parsed = QASessionSidecarReader.read(from: url)
            return parsed.isEmpty ? nil : parsed
        }
        log.notice("sidecar discovery: transcripts=\(transcriptSidecars.map(\.lastPathComponent).joined(separator: ","), privacy: .public) (\(transcriptFromSidecar?.count ?? -1, privacy: .public) seg) questions=\(questionsSidecar?.lastPathComponent ?? "—", privacy: .public) (\(qaFromSidecar?.count ?? -1, privacy: .public) entries)")

        // Write transcript.md — ALWAYS produced, even when the live
        // transcript is empty (per user preference 2026-05-15). An
        // empty session yields a header + "(no segments)" stub so the
        // bundle always has a predictable layout.
        let transcriptBody: String
        if let segs = transcriptFromSidecar {
            transcriptBody = renderTranscriptMarkdown(segments: segs)
        } else {
            transcriptBody = renderTranscriptMarkdown(segments: transcript)
        }
        let transcriptURL = try writeAtomically(
            contents: transcriptBody,
            to: folder.appendingPathComponent("transcript.md")
        )

        // Write qa.md — same unconditional rule. Prefer the on-disk
        // questions.jsonl over the (possibly cleared) in-memory list.
        let qaBody: String
        if let entries = qaFromSidecar {
            qaBody = renderQAMarkdown(entries: entries)
        } else {
            qaBody = renderQAMarkdown(history: qaHistory)
        }
        let qaURL = try writeAtomically(
            contents: qaBody,
            to: folder.appendingPathComponent("qa.md")
        )

        // Expand each abstract audio source (the bare URL from
        // `SessionCoordinator.segmentCompleted`) into the real files on
        // disk — this is what unblocks the split-layout case where the
        // bare URL never existed and the engine actually wrote
        // `<stem>.system.<ext>` + `<stem>.mic.<ext>`.
        let resolvedAudioFiles: [URL] = audioSources.flatMap(expandAudioSources)

        log.notice("bundle=\(folder.path, privacy: .public) transcriptSegments=\(transcript.count, privacy: .public) qaEntries=\(qaHistory.count, privacy: .public) audioSourcesAbstract=\(audioSources.count, privacy: .public) audioFilesResolved=\(resolvedAudioFiles.count, privacy: .public)")

        // Move audio files (preserving original filenames). H2: a
        // `moveItem` is a rename on the same volume (instant, versus
        // copying ~690 MB per hour of WAV); across volumes Foundation
        // copies and removes the source only after the copy succeeds,
        // so the recording-integrity invariant still holds. The
        // sidecar lookup uses the BARE URL from `audioSources` so the
        // `<stem>.transcript.jsonl` (stem-based, no extension prefix)
        // family lands in the bundle even when the audio itself is a
        // pair of split-layout sidecars.
        var movedAudio: [URL] = []
        for source in resolvedAudioFiles {
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: source, to: dest)
                movedAudio.append(dest)
            } catch {
                // Don't abort the whole save on a single file failure
                // — the user gets a partial bundle which is better
                // than nothing. Source stays in place when the move
                // throws, so nothing is lost.
                log.error("move \(source.path, privacy: .public) → \(dest.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Sidecars are keyed off the BARE audio URL the engine reports
        // (one bare URL per session, even when the split layout produced
        // two real audio files), so we drive the sidecar move from
        // `audioSources` — not `resolvedAudioFiles` — to avoid scanning
        // the same source folder twice for the same set of sidecars.
        for source in audioSources {
            moveSidecarsAlongside(audio: source, into: folder)
        }

        return WriteResult(
            folder: folder,
            transcriptFile: transcriptURL,
            qaFile: qaURL,
            audioFiles: movedAudio
        )
    }

    // MARK: - Path resolution

    private static func resolveRecordingsRoot() throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Recordings", isDirectory: true)
        if !fm.fileExists(atPath: root.path) {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw ExportError.folderResolutionFailed
            }
        }
        return root
    }

    /// Pick a destination that does not already exist on disk. If
    /// `<base>/<name>/` exists, retry with `<name>-YYYY-MM-DDTHH-MM-SSZ`.
    private static func resolveCollisionFreeFolder(base: URL, name: String) throws -> URL {
        let direct = base.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        let stamp = collisionStamp()
        let suffixed = base.appendingPathComponent("\(name)-\(stamp)", isDirectory: true)
        return suffixed
    }

    private static func collisionStamp() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.string(from: Date())
    }

    // MARK: - Atomic write

    @discardableResult
    private static func writeAtomically(contents: String, to url: URL) throws -> URL {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try contents.data(using: .utf8)?.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ExportError.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Sidecar discovery

    /// Look for transcript / questions sidecars that `ntakker-cli` /
    /// `ntakker` wrote alongside the audio and move them into the
    /// bundle next to the audio (copy-then-delete-original). This is
    /// best-effort — any single sidecar copy failure is logged but
    /// does not abort, and the source is only unlinked after a
    /// successful copy.
    private static func moveSidecarsAlongside(audio source: URL, into destFolder: URL) {
        let fm = FileManager.default
        let dir = source.deletingLastPathComponent()
        // Every naming family the engine / app produce for this source
        // — see `sidecarNameCandidates(for:)`.
        let candidates = sidecarNameCandidates(for: source)
        for name in candidates {
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destFolder.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.moveItem(at: src, to: dst)
                log.info("moved sidecar \(name, privacy: .public) → \(destFolder.path, privacy: .public)")
            } catch {
                log.error("sidecar move \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Markdown rendering

    /// `transcript.md` — header + chronological list of segments.
    /// Anchored to the first segment's timestamp so `[mm:ss]` reads
    /// as time-into-recording, not wall clock. When `segments` is
    /// empty the file is still written with a "(no segments captured)"
    /// stub line so the bundle layout stays predictable.
    static func renderTranscriptMarkdown(segments: [TranscriptSegment]) -> String {
        let anchor = segments.first?.timestamp ?? Date()
        var out = "# Transcript\n\n"
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]
        out += "_Recorded: \(isoOut.string(from: anchor))_  \n"
        out += "_Segments: \(segments.count)_\n\n"
        out += "---\n\n"
        if segments.isEmpty {
            out += "_(no transcript segments were produced during this session — live transcription may have been disabled or the provider did not return any segments.)_\n"
            return out
        }
        for seg in segments {
            let offset = max(0, seg.timestamp.timeIntervalSince(anchor))
            let mm = Int(offset) / 60
            let ss = Int(offset) % 60
            let ts = String(format: "[%02d:%02d]", mm, ss)
            let source: String = (seg.source == .microphone) ? "mic" : "system"
            let speaker = seg.speaker.map { " · \($0)" } ?? ""
            let lang = (seg.language.map { " · \($0)" }) ?? ""
            out += "**\(ts)** _(\(source)\(speaker)\(lang))_  \n"
            out += "\(seg.text)\n\n"
        }
        return out
    }

    /// `qa.md` rendered from the on-disk `<base>.questions.jsonl`
    /// sidecar. Used by the SessionExporter when the JSONL is present
    /// so the bundle's `qa.md` reflects the COMPLETE recorded history
    /// — including questions asked before a `clearSession()` cycle, or
    /// asked while the in-memory rolling history was still populating.
    static func renderQAMarkdown(entries: [QASidecarEntry]) -> String {
        var out = "# Q&A interjections\n\n"
        out += "_Exchanges: \(entries.count)_\n\n"
        out += "---\n\n"
        if entries.isEmpty {
            out += "_(no questions were asked during this session.)_\n"
            return out
        }
        let isoIn = ISO8601DateFormatter()
        isoIn.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]
        for entry in entries {
            let totalSecs = entry.ts_recording_ms / 1000
            let mm = totalSecs / 60
            let ss = totalSecs % 60
            let ts = String(format: "%02d:%02d", mm, ss)
            let provider = entry.provider.isEmpty
                ? ""
                : " — \(entry.provider) · `\(entry.model)`"
            out += "## \(ts) — Q\(provider)\n\n"
            out += "\(entry.question)\n\n"
            out += "### A\n\n"
            if entry.answer.isEmpty {
                out += "_(no answer recorded)_\n\n"
            } else {
                out += "\(entry.answer)\n\n"
            }
            if let startMs = entry.transcript_window_start_ms,
               let endMs = entry.transcript_window_end_ms {
                let start = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
                let end   = Date(timeIntervalSince1970: Double(endMs)   / 1000.0)
                out += "_Transcript window: \(isoOut.string(from: start)) → \(isoOut.string(from: end))_\n\n"
            }
            out += "---\n\n"
        }
        return out
    }

    /// `qa.md` — one section per Q&A exchange. When `history` is empty
    /// the file is still written with a stub line so the bundle layout
    /// is predictable.
    static func renderQAMarkdown(history: [QAEntry]) -> String {
        var out = "# Q&A interjections\n\n"
        out += "_Exchanges: \(history.count)_\n\n"
        out += "---\n\n"
        if history.isEmpty {
            out += "_(no questions were asked during this session.)_\n"
            return out
        }
        for entry in history {
            let mm = Int(entry.recordingTimestampSeconds) / 60
            let ss = Int(entry.recordingTimestampSeconds) % 60
            let ts = String(format: "%02d:%02d", mm, ss)
            let providerTag: String = {
                guard let p = entry.provider else { return "" }
                if let m = entry.model { return " — \(p.displayName) · `\(m)`" }
                return " — \(p.displayName)"
            }()
            out += "## \(ts) — Q\(providerTag)\n\n"
            out += "\(entry.question)\n\n"
            out += "### A\n\n"
            if let err = entry.errorMessage {
                out += "> **Error:** \(err)\n\n"
            } else if entry.answer.isEmpty {
                out += "_(no answer produced)_\n\n"
            } else {
                out += "\(entry.answer)\n\n"
            }
            if let start = entry.windowStart, let end = entry.windowEnd {
                let isoFmt = ISO8601DateFormatter()
                isoFmt.formatOptions = [.withInternetDateTime]
                out += "_Transcript window: \(isoFmt.string(from: start)) → \(isoFmt.string(from: end))_\n\n"
            }
            out += "---\n\n"
        }
        return out
    }
}
