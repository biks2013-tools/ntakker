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
import os

/// Not main-actor bound: `RootView.performSessionSave` runs `write` on
/// a background task (EVAL-2026-10-16 H2). Everything here is file I/O
/// over value-type inputs.
enum SessionExporter {

    /// Subsystem-tagged logger so Console.app can reliably filter on
    /// `subsystem == com.local.ntakker` AND `category == SessionExporter`.
    /// NSLog from a `.app` launched via `open` does not always surface
    /// in the unified log; `Logger` always does.
    private static let log = Logger(
        subsystem: "com.local.ntakker",
        category: "SessionExporter"
    )

    /// Pair of sidecar URLs alongside the source audio. Either field
    /// may be `nil` when the corresponding file is missing — that is
    /// the normal case for sessions that recorded without
    /// transcription, or that never received a question.
    private struct SourceSidecars {
        let transcript: URL?
        let questions: URL?
    }

    /// Locate the transcript / questions JSONL sidecars alongside the
    /// FIRST audio source. Both writers key off the same base URL the
    /// engine reports on `.segmentCompleted`, so probing one location
    /// per session is sufficient — we just have to be tolerant of both
    /// the stem-based (`<stem>.transcript.jsonl`) and base-based
    /// (`<base>.questions.jsonl`) naming families.
    private static func locateSourceSidecars(audioSources: [URL]) -> SourceSidecars {
        guard let source = audioSources.first else {
            return SourceSidecars(transcript: nil, questions: nil)
        }
        let fm = FileManager.default
        let dir = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        let stem = source.deletingPathExtension().lastPathComponent

        // Transcript probe — engine writes `<stem>.transcript.jsonl`,
        // some older builds wrote `<base>.transcript.jsonl`. Honour
        // both so the move works regardless of which writer produced
        // the file.
        let transcriptCandidates = [
            dir.appendingPathComponent("\(stem).transcript.jsonl"),
            dir.appendingPathComponent("\(base).transcript.jsonl"),
        ]
        let transcript = transcriptCandidates.first { fm.fileExists(atPath: $0.path) }

        // Questions probe — `QASessionSidecar.write` keys off the bare
        // audio URL (`<base>.questions.jsonl`). Stem-based fallback
        // included for symmetry.
        let questionsCandidates = [
            dir.appendingPathComponent("\(base).questions.jsonl"),
            dir.appendingPathComponent("\(stem).questions.jsonl"),
        ]
        let questions = questionsCandidates.first { fm.fileExists(atPath: $0.path) }

        return SourceSidecars(transcript: transcript, questions: questions)
    }

    /// Expand a single audio source URL into the actual files on disk.
    ///
    /// The `SessionCoordinator` emits `.segmentCompleted` with the BARE
    /// `options.output` URL (e.g. `recording.m4a`). For the `split`
    /// layout the bare URL does not exist on disk — the engine wrote
    /// `recording.system.m4a` and `recording.mic.m4a` side by side
    /// (`SegmentNamer.splitSidecarURLs`). For `mixed` / `stereo-split`
    /// the bare URL IS the actual file.
    ///
    /// Returns whatever exists on disk so the caller can iterate and
    /// move the real files into the bundle.
    private static func expandAudioSources(_ source: URL) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: source.path) {
            return [source]
        }
        // Split layout — look for `<stem>.system.<ext>` + `<stem>.mic.<ext>`
        // siblings. `SegmentNamer.splitSidecarURLs(baseURL:)` constructs
        // exactly these two URLs; we inline that derivation here so
        // SessionExporter does not need to import NtakkerUIKit just for
        // a two-line URL transform.
        let folder = source.deletingLastPathComponent()
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let systemName = ext.isEmpty ? "\(stem).system" : "\(stem).system.\(ext)"
        let micName    = ext.isEmpty ? "\(stem).mic"    : "\(stem).mic.\(ext)"
        let candidates = [
            folder.appendingPathComponent(systemName),
            folder.appendingPathComponent(micName),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.path) }
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
        let sidecars = locateSourceSidecars(audioSources: audioSources)
        let transcriptFromSidecar = sidecars.transcript.flatMap { url -> [TranscriptSegment]? in
            let parsed = JSONLTranscriptReader.read(from: url)
            return parsed.isEmpty ? nil : parsed
        }
        let qaFromSidecar = sidecars.questions.flatMap { url -> [QASidecarEntry]? in
            let parsed = QASessionSidecarReader.read(from: url)
            return parsed.isEmpty ? nil : parsed
        }
        log.notice("sidecar discovery: transcript=\(sidecars.transcript?.lastPathComponent ?? "—", privacy: .public) (\(transcriptFromSidecar?.count ?? -1, privacy: .public) seg) questions=\(sidecars.questions?.lastPathComponent ?? "—", privacy: .public) (\(qaFromSidecar?.count ?? -1, privacy: .public) entries)")

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
        // Two naming families produced by the engine:
        //   * Stem-based   (no audio extension): `<stem>.transcript.jsonl`
        //                                        `<stem>.transcript.txt`
        //                                        `<stem>.transcript.srt`
        //                                        `<stem>.transcript.vtt`
        //                                        `<stem>.system.transcript.jsonl`
        //                                        `<stem>.microphone.transcript.jsonl`
        //   * Base-based   (full audio filename): `<base>.questions.jsonl`
        // We probe both for every candidate so layout changes in either
        // writer can't silently strand a sidecar in the source folder.
        let base = source.lastPathComponent
        let stem = source.deletingPathExtension().lastPathComponent
        var seen = Set<String>()
        let candidates: [String] = [
            "\(stem).transcript.jsonl",
            "\(stem).transcript.txt",
            "\(stem).transcript.srt",
            "\(stem).transcript.vtt",
            "\(stem).system.transcript.jsonl",
            "\(stem).microphone.transcript.jsonl",
            "\(stem).questions.jsonl",
            "\(base).transcript.jsonl",
            "\(base).transcript.txt",
            "\(base).transcript.srt",
            "\(base).transcript.vtt",
            "\(base).system.transcript.jsonl",
            "\(base).microphone.transcript.jsonl",
            "\(base).questions.jsonl",
        ].filter { seen.insert($0).inserted }
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
