// NtakkerCore/Bootstrap/EnvFileStore.swift
//
// Round-trip-safe reader/writer for the per-tool `.env` file at
// `~/.tool-agents/<toolName>/.env`. Three responsibilities:
//
//   1. `loadIntoProcess(toolName:)` — parse the file once at app
//      startup and `setenv()` every KEY=VALUE pair into the current
//      process's environment so `ProcessInfo.processInfo.environment`
//      reflects the file contents. This is the missing piece that
//      makes the documented four-tier resolution chain
//      (shell env → ~/.tool-agents/.env → ./.env → CLI flags,
//      lowest to highest priority) actually work for `ntakker`,
//      which previously read only the shell environment. User-`.env`
//      values win over shell-exported values — we call
//      `setenv(..., overwrite=1)` so a saved credential in the
//      `.env` always takes effect over a stale shell export. This
//      matches the canonical chain order where the user `.env`
//      (tier 2) sits above the shell env (tier 1).
//
//   2. `read(toolName:key:)` — return the current value of a single
//      key from the on-disk file, or `nil` if absent.
//
//   3. `upsert(toolName:key:value:)` — write a single key, creating
//      or replacing the matching line in-place. All other lines
//      (comments, blank lines, unrelated keys) are preserved
//      verbatim. The file is re-chmod'd to 0600 after the write so a
//      manual edit at a wider mode is corrected on the next save.
//      The new value is also `setenv`'d into the running process so
//      callers reading from `ProcessInfo` immediately see the change
//      without an app restart.
//
// Parsing is delegated to `DotEnvParser`, the parser the CLI's
// `ConfigResolver` uses (EVAL-2026-06-12 A9, plan-023 T3). The store
// used to carry its own minimal parser that kept quotes, so
// `KEY="a b"` meant `a b` to the CLI and `"a b"` (quotes included) to
// the app, and it skipped malformed lines silently. Now both surfaces
// read the file identically, a malformed file is reported instead of
// ignored, and `upsert` quotes values that would otherwise be read
// back differently.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum EnvFileStore {

    // MARK: - Public API

    /// Load every `KEY=VALUE` from `~/.tool-agents/<toolName>/.env`
    /// into the running process's environment via `setenv`,
    /// **overriding any shell-exported value with the same key**.
    /// Missing file is a silent no-op — the bootstrap step seeds an
    /// empty file on first run, so a real "missing file" only happens
    /// if the user has physically removed it.
    ///
    /// Precedence note: `ConfigResolver` documents a four-tier chain
    /// where the user `.env` (this file) sits ABOVE the shell env
    /// (`cliOverrides > localEnv > userEnv > shellEnv`). The CLI
    /// honours that natively because the resolver reads each source
    /// separately. The UI, by contrast, reads `ProcessInfo` directly
    /// in many places and therefore needs `loadIntoProcess` to
    /// reflect the same precedence — the user's stored configuration
    /// must win over a stale shell-exported value, otherwise the
    /// Settings panel and the popover diverge (real bug observed
    /// 2026-04-29: shell-exported `AZURE_OPENAI_DEPLOYMENT=gpt-5.1`
    /// shadowed a freshly-saved `.env` value).
    ///
    /// - Throws: `NtakkerError.dotEnvParseError` / `.ioError` when the
    ///   file exists but cannot be read or parsed. Nothing is loaded in
    ///   that case — the same answer the CLI gives for the same file.
    @discardableResult
    public static func loadIntoProcess(toolName: String) throws -> [String: String] {
        let url = ToolAgentsBootstrap.userEnvPath(toolName: toolName)
        let parsed = try parse(at: url)
        for (k, v) in parsed {
            setenv(k, v, /*overwrite*/ 1)
        }
        return parsed
    }

    /// Snapshot the current value of `key` from the on-disk file
    /// (NOT from the process environment). `nil` if the key is
    /// missing OR the file does not exist OR the value is empty.
    public static func read(toolName: String, key: String) -> String? {
        let url = ToolAgentsBootstrap.userEnvPath(toolName: toolName)
        guard let parsed = try? parse(at: url) else { return nil }
        guard let v = parsed[key], !v.isEmpty else { return nil }
        return v
    }

    /// Write `key=value` to the file, replacing the existing line
    /// in-place if `key` already exists or appending a fresh line at
    /// the end otherwise. Preserves all other lines verbatim. Empty
    /// `value` removes the key entirely. Also `setenv`'s the new
    /// value into the running process (overwriting any prior value)
    /// so callers reading via `ProcessInfo` see the change without an
    /// app restart.
    ///
    /// - Throws: `NtakkerError.ioError` on filesystem failure (parent
    ///   directory missing, write denied, chmod failure).
    public static func upsert(
        toolName: String,
        key: String,
        value: String
    ) throws {
        let dir = try ToolAgentsBootstrap.ensure(toolName: toolName)
        let url = dir.appendingPathComponent(".env")

        let original: String
        if FileManager.default.fileExists(atPath: url.path) {
            original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        } else {
            original = ""
        }

        let updated = rewrite(source: original, key: key, value: try quoted(value))
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw NtakkerError.ioError(
                "failed to write \(url.path): \(error.localizedDescription)"
            )
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw NtakkerError.ioError(
                "failed to chmod 0600 on \(url.path): \(error.localizedDescription)"
            )
        }
        // Also push into the running process so the UI's next read
        // through `ProcessInfo.processInfo.environment[key]` returns
        // the new value without an app restart.
        if value.isEmpty {
            unsetenv(key)
        } else {
            setenv(key, value, /*overwrite*/ 1)
        }
    }

    // MARK: - Parsing helpers (internal — exposed for tests)

    /// Parse the file at `url` into a `[KEY: VALUE]` dictionary with
    /// `DotEnvParser`. Returns empty if the file is missing; throws if
    /// it exists but cannot be read or parsed.
    static func parse(at url: URL) throws -> [String: String] {
        try DotEnvParser.parseFile(at: url)
    }

    /// `value` as it must be written so `DotEnvParser` reads it back
    /// unchanged. Plain values are written as-is. A value with leading
    /// or trailing whitespace, a `#`, or a leading quote is wrapped in
    /// double quotes, or in single quotes when it contains a double
    /// quote. A value containing both quote kinds and needing quotes
    /// cannot be represented and throws.
    static func quoted(_ value: String) throws -> String {
        let needsQuotes = value != value.trimmingCharacters(in: .whitespaces)
            || value.contains("#")
            || value.first == "\"" || value.first == "'"
        guard needsQuotes else { return value }
        if !value.contains("\"") { return "\"\(value)\"" }
        if !value.contains("'") { return "'\(value)'" }
        throw NtakkerError.invalidConfigValue(
            key: "(.env value)",
            value: "<redacted>",
            expected: "a value without both single and double quotes (it needs quoting)"
        )
    }

    /// Pure-string transform: take the original file content and
    /// produce the updated content with `key` set to `value`. If
    /// `value` is empty, removes any existing line for `key`.
    /// Idempotent and order-preserving.
    static func rewrite(source: String, key: String, value: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var replaced = false
        let newLine = "\(key)=\(value)"

        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let lineKey = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            if lineKey == key {
                if value.isEmpty {
                    lines[i] = "" // mark for removal pass below
                } else {
                    lines[i] = newLine
                }
                replaced = true
                // Don't break — if the user has duplicate lines for the
                // same key, normalise to a single line by clearing the
                // duplicates.
                continue
            }
        }

        if !replaced && !value.isEmpty {
            // Append. Make sure there is exactly one blank line of
            // separation between any pre-existing content and the
            // new key.
            if !lines.last!.isEmpty {
                lines.append("")
            }
            lines.append(newLine)
        }

        // Collapse the "" markers that came from key-removal so the
        // file does not accumulate blank gaps.
        if value.isEmpty {
            var collapsed: [String] = []
            collapsed.reserveCapacity(lines.count)
            var prevBlank = false
            for line in lines {
                let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if isBlank && prevBlank { continue }
                collapsed.append(line)
                prevBlank = isBlank
            }
            lines = collapsed
        }

        // Always end with a newline. Without it a line appended later by
        // hand, or with `echo … >>`, is glued onto the last value
        // (2026-10-18: `NTAKKER_RECORDINGS_DIR=…/RecordingsNTAKKER_STUDIO_…`).
        var result = lines.joined(separator: "\n")
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
