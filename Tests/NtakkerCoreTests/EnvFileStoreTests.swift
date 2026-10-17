import Foundation
import Testing
@testable import NtakkerCore

/// EVAL-2026-06-12 A9 (plan-023 T3): the app's `.env` store reads the
/// file exactly as the CLI's `DotEnvParser` does.
@Suite("EnvFileStore")
struct EnvFileStoreTests {

    private func file(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("envstore-\(UUID().uuidString).env")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("quoted values lose their quotes, as in the CLI")
    func quotesStripped() throws {
        let url = try file("A=\"value with spaces\"\nB='single'\nC=plain # comment\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try EnvFileStore.parse(at: url)
        #expect(parsed == ["A": "value with spaces", "B": "single", "C": "plain"])
        #expect(parsed == (try DotEnvParser.parseFile(at: url)))
    }

    @Test("a malformed file throws instead of loading silently")
    func malformedThrows() throws {
        let url = try file("GOOD=1\nthis line has no equals sign\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: NtakkerError.self) { try EnvFileStore.parse(at: url) }
    }

    @Test("values are quoted on write only when needed, and read back unchanged")
    func quotingRoundTrips() throws {
        let values = ["plain", "has space inside", " leading", "trailing ", "a # b", "\"starts with quote", "it's"]
        for value in values {
            let line = "K=\(try EnvFileStore.quoted(value))"
            #expect(try DotEnvParser.parse(line)["K"] == value, "round trip of \(value.debugDescription) via \(line)")
        }
        #expect(try EnvFileStore.quoted("plain") == "plain")
        #expect(throws: NtakkerError.self) { try EnvFileStore.quoted(" both \" and ' ") }
    }
}
