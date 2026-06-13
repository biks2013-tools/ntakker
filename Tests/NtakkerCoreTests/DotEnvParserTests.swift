// NtakkerCoreTests/DotEnvParserTests.swift — see project-design.md §2.3 / §5.3
// Phase B — Bootstrap + Config

import Foundation
import Testing
@testable import NtakkerCore

@Suite("DotEnvParser")
struct DotEnvParserTests {

    @Test("Plain KEY=value")
    func plainKeyValue() throws {
        let result = try DotEnvParser.parse("FOO=bar")
        #expect(result == ["FOO": "bar"])
    }

    @Test("Whitespace around key and value is trimmed")
    func whitespaceTrimmed() throws {
        let result = try DotEnvParser.parse("  FOO  =  bar  ")
        #expect(result["FOO"] == "bar")
    }

    @Test("Full-line `# comment` is skipped")
    func fullLineComment() throws {
        let src = """
        # This is a comment
        FOO=bar
        # Another
        """
        let result = try DotEnvParser.parse(src)
        #expect(result == ["FOO": "bar"])
    }

    @Test("Trailing `# comment` is stripped from unquoted values")
    func trailingCommentStripped() throws {
        let result = try DotEnvParser.parse("FOO=bar # this is ignored")
        #expect(result["FOO"] == "bar")
    }

    @Test("Hash NOT preceded by whitespace stays in unquoted value")
    func hashInValueKept() throws {
        let result = try DotEnvParser.parse("URL=http://example.com/page#section")
        #expect(result["URL"] == "http://example.com/page#section")
    }

    @Test("Double-quoted values keep internal spaces and hashes")
    func doubleQuoted() throws {
        let result = try DotEnvParser.parse(#"GREETING="hello world # not a comment""#)
        #expect(result["GREETING"] == "hello world # not a comment")
    }

    @Test("Single-quoted values keep internal spaces")
    func singleQuoted() throws {
        let result = try DotEnvParser.parse("NAME='alice bob'")
        #expect(result["NAME"] == "alice bob")
    }

    @Test("Blank lines are skipped")
    func blankLines() throws {
        let src = """

        FOO=bar


        BAZ=qux

        """
        let result = try DotEnvParser.parse(src)
        #expect(result == ["FOO": "bar", "BAZ": "qux"])
    }

    @Test("Empty value `KEY=` parses as empty string")
    func emptyValue() throws {
        let result = try DotEnvParser.parse("FOO=")
        #expect(result == ["FOO": ""])
    }

    @Test("Duplicate keys: last write wins")
    func duplicateLastWins() throws {
        let src = """
        FOO=first
        FOO=second
        FOO=third
        """
        let result = try DotEnvParser.parse(src)
        #expect(result == ["FOO": "third"])
    }

    @Test("Line without `=` throws")
    func malformedNoEquals() {
        #expect(throws: NtakkerError.self) {
            _ = try DotEnvParser.parse("not_a_pair_at_all")
        }
    }

    @Test("Empty key (`=value`) throws")
    func emptyKey() {
        #expect(throws: NtakkerError.self) {
            _ = try DotEnvParser.parse("=value")
        }
    }

    @Test("Unterminated double quote throws")
    func unterminatedDoubleQuote() {
        #expect(throws: NtakkerError.self) {
            _ = try DotEnvParser.parse(#"FOO="unterminated"#)
        }
    }

    @Test("Unterminated single quote throws")
    func unterminatedSingleQuote() {
        #expect(throws: NtakkerError.self) {
            _ = try DotEnvParser.parse("FOO='unterminated")
        }
    }

    @Test("CRLF line endings are normalized")
    func crlfLineEndings() throws {
        let src = "FOO=bar\r\nBAZ=qux\r\n"
        let result = try DotEnvParser.parse(src)
        #expect(result == ["FOO": "bar", "BAZ": "qux"])
    }

    @Test("Embedded `=` in value is preserved")
    func embeddedEquals() throws {
        let result = try DotEnvParser.parse("URL=https://example.com/?a=1&b=2")
        #expect(result["URL"] == "https://example.com/?a=1&b=2")
    }

    @Test("Indented comments are skipped")
    func indentedComment() throws {
        let src = """
            # indented comment
        FOO=bar
        """
        let result = try DotEnvParser.parse(src)
        #expect(result == ["FOO": "bar"])
    }

    @Test("parseFile returns empty dict if file does not exist")
    func parseFileMissing() throws {
        let url = URL(fileURLWithPath: "/tmp/ntakker-cli-defparser-does-not-exist-\(UUID().uuidString).env")
        let result = try DotEnvParser.parseFile(at: url)
        #expect(result.isEmpty)
    }

    @Test("parseFile reads and parses a real file")
    func parseFileReal() throws {
        let dir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("ntakker-cli-test-\(UUID().uuidString).env")
        let body = """
        # seed
        FOO=bar
        BAZ="hello world"
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try DotEnvParser.parseFile(at: url)
        #expect(result["FOO"] == "bar")
        #expect(result["BAZ"] == "hello world")
    }

    @Test("parseFile error tags the path in the thrown error")
    func parseFileErrorIncludesPath() throws {
        let dir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("ntakker-cli-bad-\(UUID().uuidString).env")
        try "garbage_no_equals".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try DotEnvParser.parseFile(at: url)
            Issue.record("expected throw")
        } catch let err as NtakkerError {
            if case let .dotEnvParseError(path, line, _) = err {
                #expect(path == url.path)
                #expect(line == 1)
            } else {
                Issue.record("expected .dotEnvParseError, got \(err)")
            }
        }
    }
}
