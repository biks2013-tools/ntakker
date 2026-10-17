// NtakkerCore/Transcription/Persistence/RewritableSegmentFile.swift
//
// EVAL-2026-06-12 F33 (plan-023 T2): the id-keyed in-place rewrite
// machinery the four format writers (JSONL, TXT, SRT, VTT) used to copy
// verbatim. It owns the file handle and the `[UUID: Range<UInt64>]`
// byte index, and implements the two grow paths:
//
//   * short-grow — the new rendering fits the old slot: rewrite it in
//     place, padded with spaces before the terminator, so the file's
//     line structure is unchanged;
//   * long-grow — it does not fit: overwrite the old slot with a
//     same-length tombstone supplied by the format, append the new
//     rendering at end-of-file, and repoint the index there.
//
// The format writers keep only rendering and their tombstone shape.
// Not thread-safe; the owning `TranscriptSidecarWriter` actor
// serialises every call.

import Foundation

final class RewritableSegmentFile {

    let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    /// Write bytes at end-of-file without indexing them (a header).
    func writeUnindexed(_ bytes: Data) throws {
        try handle.write(contentsOf: bytes)
    }

    /// Append `bytes` for `id` at end-of-file and index the range.
    func append(_ bytes: Data, for id: UUID) throws {
        let start = try handle.offset()
        try handle.write(contentsOf: bytes)
        index[id] = start..<(try handle.offset())
    }

    /// Rewrite `id`'s slot with `bytes`, which end in `terminator`.
    /// `tombstone(length)` must return exactly `length` bytes. Returns
    /// false — writing nothing — when `id` has no slot yet.
    func rewrite(
        _ bytes: Data,
        for id: UUID,
        terminator: Data,
        tombstone: (Int) -> Data
    ) throws -> Bool {
        guard let range = index[id] else { return false }
        let oldLength = Int(range.upperBound - range.lowerBound)
        if bytes.count <= oldLength {
            let body = bytes.prefix(bytes.count - terminator.count)
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: Self.pad(Data(body), to: oldLength, terminator: terminator))
            try handle.seekToEnd()
        } else {
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: tombstone(oldLength))
            try handle.seekToEnd()
            try append(bytes, for: id)
        }
        return true
    }

    func close() throws {
        try handle.close()
    }

    /// `head` + spaces + `terminator`, `length` bytes long. A `head`
    /// already too long for that is returned with the terminator and no
    /// padding.
    static func pad(_ head: Data, to length: Int, terminator: Data) -> Data {
        var out = head
        let spaces = length - head.count - terminator.count
        if spaces > 0 { out.append(Data(repeating: 0x20, count: spaces)) }
        out.append(terminator)
        return out
    }
}
