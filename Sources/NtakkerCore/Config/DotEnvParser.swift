// NtakkerCore/Config/DotEnvParser.swift — see project-design.md §2.3 / §5.3
// Phase B — Bootstrap + Config (FR-12, FR-14)

import Foundation

/// Pure parser for `.env`-style files.
///
/// Accepted syntax (project-design.md §5.3):
///   - `KEY=VALUE`                  → whitespace around `=` trimmed.
///   - `KEY="value with spaces"`    → one matched pair of `"` stripped.
///   - `KEY='value with spaces'`    → one matched pair of `'` stripped.
///   - `KEY=value # trailing`       → trailing `# ...` is dropped, but
///                                     ONLY for unquoted values.
///   - `# comment line`             → skipped.
///   - blank lines                  → skipped.
///
/// Behavior:
///   - Duplicate keys: last write wins.
///   - No `$VAR` interpolation in v1.
///   - No multi-line values (line endings split on `\n` and `\r\n`).
///
/// Errors:
///   - Lines without `=` or with an empty key throw
///     `NtakkerError.dotEnvParseError(path:line:reason:)`.
///   - Unterminated quoted values throw
///     `NtakkerError.dotEnvParseError(path:line:reason:)`.
//
// MARK: TODO(plan-001 §B - v2 — env-var interpolation)
public enum DotEnvParser {

    /// Strongly typed parse error surface for callers that want the
    /// raw `(line, reason)` pair without unwrapping a `NtakkerError`.
    /// Always carries a path string for parity with the design — empty
    /// when the input is a raw string with no on-disk origin.
    public struct ParseError: Error, Equatable, Sendable {
        public let line: Int
        public let reason: String
        public let path: String

        public init(line: Int, reason: String, path: String = "") {
            self.line = line
            self.reason = reason
            self.path = path
        }
    }

    /// Parses a `.env`-format string. Throws
    /// `NtakkerError.dotEnvParseError` on malformed input.
    public static func parse(_ contents: String) throws -> [String: String] {
        try parse(contents, path: "")
    }

    /// Parses a `.env`-format string and tags any thrown error with the
    /// supplied `path`. Used by `parseFile` to attribute the error to a
    /// specific on-disk file.
    public static func parse(_ contents: String, path: String) throws -> [String: String] {
        var result: [String: String] = [:]
        // Normalize CRLF → LF so the line counter matches what the user
        // sees in their editor.
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, raw) in lines.enumerated() {
            let lineNumber = idx + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }

            guard let eq = trimmed.firstIndex(of: "=") else {
                throw NtakkerError.dotEnvParseError(
                    path: path,
                    line: lineNumber,
                    reason: "missing '=' separator"
                )
            }

            let rawKey = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty else {
                throw NtakkerError.dotEnvParseError(
                    path: path,
                    line: lineNumber,
                    reason: "empty key"
                )
            }

            let afterEq = trimmed.index(after: eq)
            let rawValueSlice = trimmed[afterEq...]
            // Leading whitespace between `=` and the value is dropped.
            // Trailing whitespace handling depends on quoting (see below).
            let leadingTrimmed = String(rawValueSlice).drop(while: { $0 == " " || $0 == "\t" })

            let value: String
            if let first = leadingTrimmed.first, first == "\"" || first == "'" {
                // Quoted value. Search for the matching closing quote.
                let quote = first
                let body = leadingTrimmed.dropFirst()
                guard let closing = body.firstIndex(of: quote) else {
                    throw NtakkerError.dotEnvParseError(
                        path: path,
                        line: lineNumber,
                        reason: "unterminated \(quote == "\"" ? "double" : "single") quote"
                    )
                }
                value = String(body[..<closing])
                // Anything after the closing quote (other than whitespace
                // or a `#`-comment) is tolerated but not required to be
                // diagnosed in v1 — callers should stick to `KEY="v"` or
                // `KEY="v" # comment`.
            } else {
                // Unquoted value. A `#` introduces a trailing comment ONLY
                // when preceded by whitespace.
                let trailing = String(leadingTrimmed)
                var endIndex = trailing.endIndex
                var i = trailing.startIndex
                while i < trailing.endIndex {
                    let c = trailing[i]
                    if c == "#" {
                        // Trailing comment requires a whitespace lead-in.
                        // (At i == startIndex the line is "#..." which we
                        // already filtered above; defensively, treat that
                        // as a full-line comment too.)
                        if i == trailing.startIndex {
                            endIndex = i
                            break
                        }
                        let prev = trailing.index(before: i)
                        let prevC = trailing[prev]
                        if prevC == " " || prevC == "\t" {
                            endIndex = i
                            break
                        }
                    }
                    i = trailing.index(after: i)
                }
                value = String(trailing[..<endIndex])
                    .trimmingCharacters(in: .whitespaces)
            }

            result[String(rawKey)] = value
        }
        return result
    }

    /// Reads `url` and parses it. Returns an empty dictionary if the
    /// file does not exist (NOT an error — a missing user/local `.env`
    /// is the common case).
    public static func parseFile(at url: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let data: String
        do {
            data = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw NtakkerError.ioError(
                "failed to read .env at \(url.path): \(error.localizedDescription)"
            )
        }
        return try parse(data, path: url.path)
    }
}
