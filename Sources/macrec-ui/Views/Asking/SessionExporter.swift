// macrec-ui/Views/Asking/SessionExporter.swift — plan-015 Phase 2 + 4.
// Bundles a finished session into a self-contained folder:
//
//     ~/Recordings/<folder-name>/
//       ├── transcript.md       (live transcript, Markdown)
//       ├── qa.md               (Q&A interjections, Markdown)
//       └── recording-XXX.m4a   (one or more audio files, copied)
//
// Atomic writes: each markdown file is written to a sibling `.tmp`
// and then renamed (FR-IRQ-52). Audio is *copied* — the originals
// stay in the user's configured output folder so the source-of-truth
// audio is not at risk if anything in the bundle write goes wrong
// (recording-integrity invariant).
//
// Collision handling (FR-IRQ-32): when the destination folder
// already exists, an ISO-style timestamp suffix is appended
// (`-2026-05-13T17-12-04Z`) so the new bundle never overwrites a
// previous one. The caller is told which final folder was used so it
// can reveal in Finder.
//
// Lives in `macrec-ui` (not `MacrecCore`) for now because the Q&A
// entry struct is a UI-local model in this phase. plan-015 Phase 3
// will lift the export logic into `MacrecCore/Export/TranscriptExporter.swift`
// once `QASessionHistory` is promoted to core for the floating overlay.

import Foundation
import MacrecCore

@MainActor
enum SessionExporter {

    /// Result of a successful bundle write.
    struct WriteResult {
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

        // Write transcript.md
        var transcriptURL: URL?
        if !transcript.isEmpty {
            let body = renderTranscriptMarkdown(segments: transcript)
            transcriptURL = try writeAtomically(
                contents: body,
                to: folder.appendingPathComponent("transcript.md")
            )
        }

        // Write qa.md
        var qaURL: URL?
        if !qaHistory.isEmpty {
            let body = renderQAMarkdown(history: qaHistory)
            qaURL = try writeAtomically(
                contents: body,
                to: folder.appendingPathComponent("qa.md")
            )
        }

        // Copy audio files (preserving original filenames).
        var copiedAudio: [URL] = []
        for source in audioSources {
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
                copiedAudio.append(dest)

                // Also copy any sidecar files Apple-style tools wrote
                // next to the audio (transcript / questions JSONL,
                // SRT, VTT, TXT, etc.) so the bundle is genuinely
                // self-contained.
                copySidecarsAlongside(audio: source, into: folder)
            } catch {
                // Don't abort the whole save on a single file failure
                // — the user gets a partial bundle which is better
                // than nothing.
                NSLog("SessionExporter: copy %@ → %@ failed: %@",
                      source.path, dest.path, error.localizedDescription)
            }
        }

        return WriteResult(
            folder: folder,
            transcriptFile: transcriptURL,
            qaFile: qaURL,
            audioFiles: copiedAudio
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

    /// Look for transcript / questions sidecars that `macrec` /
    /// `macrec-ui` wrote alongside the audio and copy them into the
    /// bundle next to the audio. This is best-effort — any single
    /// sidecar copy failure is logged but does not abort.
    private static func copySidecarsAlongside(audio source: URL, into destFolder: URL) {
        let fm = FileManager.default
        let dir = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        let candidates = [
            "\(base).transcript.jsonl",
            "\(base).transcript.txt",
            "\(base).transcript.srt",
            "\(base).transcript.vtt",
            "\(base).system.transcript.jsonl",
            "\(base).microphone.transcript.jsonl",
            "\(base).questions.jsonl",
        ]
        for name in candidates {
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destFolder.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
            } catch {
                NSLog("SessionExporter: sidecar copy %@ failed: %@", name, error.localizedDescription)
            }
        }
    }

    // MARK: - Markdown rendering

    /// `transcript.md` — header + chronological list of segments.
    /// Anchored to the first segment's timestamp so `[mm:ss]` reads
    /// as time-into-recording, not wall clock.
    static func renderTranscriptMarkdown(segments: [TranscriptSegment]) -> String {
        let anchor = segments.first?.timestamp ?? Date()
        var out = "# Transcript\n\n"
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]
        out += "_Recorded: \(isoOut.string(from: anchor))_  \n"
        out += "_Segments: \(segments.count)_\n\n"
        out += "---\n\n"
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

    /// `qa.md` — one section per Q&A exchange.
    static func renderQAMarkdown(history: [QAEntry]) -> String {
        var out = "# Q&A interjections\n\n"
        out += "_Exchanges: \(history.count)_\n\n"
        out += "---\n\n"
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
