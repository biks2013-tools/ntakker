// NtakkerCore/Transcription/Persistence/JSONLTranscriptReader.swift
//
// Read-side counterpart to `JSONLTranscriptWriter`. Parses the
// `<stem>.transcript.jsonl` sidecar produced during recording back into
// a `[TranscriptSegment]` array so the SessionExporter can render the
// COMPLETE transcript into the bundle's `transcript.md` instead of the
// rolling-cap in-memory list owned by `RecordingController`.
//
// File layout (one JSON object per line, terminated by `\n`):
//
//   * Normal segment: `{"id":"…", "timestamp":"…", "source":"system|microphone",
//                       "text":"…", "model":"…", "durationSec":…,
//                       "language":"…", "speaker":"…"}`
//   * Tombstone:      `{"_tombstone":true, "id":"…"}`
//                     (older slot superseded by a newer line later in
//                     the file — drop it).
//
// Update semantics (see `JSONLTranscriptWriter.updateSegment(_:)`):
//
//   * Short-grow updates rewrite the existing line in place (no
//     tombstone). The reader's two-pass logic correctly takes the only
//     line that exists for that id.
//   * Long-grow updates tombstone the old slot and append a new line
//     at end-of-file. The reader's two-pass logic walks once to gather
//     tombstoned ids, then walks again skipping any line whose id was
//     tombstoned and selecting the LAST valid entry per id (i.e. the
//     appended one) as the canonical segment.

import Foundation

public enum JSONLTranscriptReader {

    /// One-line wire shape — must match the encoder's `Wire` struct
    /// inside `JSONLTranscriptWriter.encode(_:)`. Plus the tombstone
    /// flag, which is keyed `_tombstone` per the writer.
    private struct WireLine: Decodable {
        let id: String?
        let timestamp: String?
        let source: String?
        let text: String?
        let model: String?
        let durationSec: Double?
        let language: String?
        let speaker: String?
        let _tombstone: Bool?
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Read the JSONL sidecar at `url` and reconstruct the segments
    /// list, honouring tombstones and de-duplicating any id that
    /// appears in multiple lines (last-write-wins). Returns an empty
    /// array on any read / decode error — callers fall back to the
    /// in-memory list.
    public static func read(from url: URL) -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()

        // First pass: collect tombstoned ids so we can drop their
        // earlier line on the second pass.
        var tombstoned = Set<UUID>()
        text.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let wire = try? decoder.decode(WireLine.self, from: lineData),
                  wire._tombstone == true,
                  let idStr = wire.id,
                  let id = UUID(uuidString: idStr)
            else { return }
            tombstoned.insert(id)
        }

        // Second pass: take the LAST valid (non-tombstoned) entry per
        // id. Order in the file matches the order segments were
        // appended; preserving that order in the result keeps
        // chronological semantics for the renderer.
        var byId: [UUID: TranscriptSegment] = [:]
        var order: [UUID] = []
        text.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let wire = try? decoder.decode(WireLine.self, from: lineData),
                  wire._tombstone != true,
                  let idStr = wire.id,
                  let id = UUID(uuidString: idStr),
                  !tombstoned.contains(id),
                  let timestampStr = wire.timestamp,
                  let timestamp = isoFormatter.date(from: timestampStr),
                  let sourceStr = wire.source,
                  let source = SourceTag(rawValue: sourceStr),
                  let text = wire.text
            else { return }

            let segment = TranscriptSegment(
                id: id,
                timestamp: timestamp,
                lastUpdated: timestamp,
                text: text,
                source: source,
                model: wire.model,
                durationSec: wire.durationSec,
                language: wire.language,
                speaker: wire.speaker
            )
            if byId[id] == nil {
                order.append(id)
            }
            byId[id] = segment
        }

        return order.compactMap { byId[$0] }
    }
}
