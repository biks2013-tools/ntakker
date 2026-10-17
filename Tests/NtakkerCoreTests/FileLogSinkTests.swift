import Foundation
import Testing
@testable import NtakkerCore

/// EVAL-2026-10-16 A6 (plan-022 T2): the file log sink writes in
/// batches off the caller's thread and rotates by size.
@Suite("FileLogSink")
struct FileLogSinkTests {

    private func tempLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ntakker-sink-\(UUID().uuidString)")
            .appendingPathExtension("log")
    }

    @Test("every appended line is on disk after flush, in order")
    func appendThenFlush() throws {
        let url = tempLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try FileLogSink.open(at: url)
        for i in 0..<1_000 { sink.append("line \(i)\n") }
        sink.flush()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1_000)
        #expect(lines.first == "line 0")
        #expect(lines.last == "line 999")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("the file rotates to .1 past the size limit")
    func rotatesBySize() throws {
        let url = tempLog()
        let backup = url.appendingPathExtension("1")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }
        let sink = try FileLogSink.open(at: url, rotationBytes: 1_000)
        let line = String(repeating: "x", count: 99) + "\n"   // 100 bytes
        for _ in 0..<15 {
            sink.append(line)
            sink.flush()
        }

        let backupSize = try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? Int
        let currentSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(backupSize == 1_000, "rotation happens once the file reaches the limit")
        #expect(currentSize == 500, "writing continues in a fresh file")
    }
}
