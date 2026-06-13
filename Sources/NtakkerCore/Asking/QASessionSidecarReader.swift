// NtakkerCore/Asking/QASessionSidecarReader.swift
//
// Read-side counterpart to `QASessionSidecar.write(...)`. Parses the
// `<base>.questions.jsonl` sidecar into a `[QASidecarEntry]` array so
// the SessionExporter can render the COMPLETE Q&A history into the
// bundle's `qa.md` even when the in-memory `AskingSessionStore.history`
// was cleared by `clearSession()` (e.g. between "Save and start new"
// cycles in a long meeting).
//
// File layout:
//
//   line 1: header object — `{"schema":"qa-sidecar/v1", ...}` (skipped)
//   line N: one `QASidecarEntry` per line
//
// Returns an empty array on any read / decode error; callers fall back
// to the in-memory history list.

import Foundation

public enum QASessionSidecarReader {

    /// Header line shape — defensive `Decodable` so the reader can
    /// recognise and skip it regardless of which keys the writer chose
    /// to include in this build.
    private struct HeaderProbe: Decodable {
        let schema: String?
        let recording_basename: String?
    }

    public static func read(from url: URL) -> [QASidecarEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()
        var result: [QASidecarEntry] = []
        var sawFirstLine = false

        text.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8) else { return }
            // First non-empty line is the header — skip it if it has
            // the schema marker, otherwise treat it as a normal entry
            // so older files (pre-header) still parse.
            if !sawFirstLine {
                sawFirstLine = true
                if let probe = try? decoder.decode(HeaderProbe.self, from: lineData),
                   probe.schema != nil
                {
                    return
                }
            }
            if let entry = try? decoder.decode(QASidecarEntry.self, from: lineData) {
                result.append(entry)
            }
        }

        return result
    }
}
