// MacrecCore/Bootstrap/EnvFileStore.swift
//
// Round-trip-safe reader/writer for the per-tool `.env` file at
// `~/.tool-agents/<toolName>/.env`. Three responsibilities:
//
//   1. `loadIntoProcess(toolName:)` — parse the file once at app
//      startup and `setenv()` every KEY=VALUE pair into the current
//      process's environment so `ProcessInfo.processInfo.environment`
//      reflects the file contents. This is the missing piece that
//      makes the documented four-tier resolution chain
//      (shell env → ~/.tool-agents/.env → ./.env → CLI flags)
//      actually work for `macrec-ui`, which previously read only
//      the shell environment. Existing shell-set values win — we
//      only `setenv` keys that are not already present in the
//      process environment.
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
// The parse is intentionally minimal: `KEY=VALUE` per line, optional
// surrounding whitespace, comments start with `#`. No quoting, no
// multi-line values, no `${VAR}` expansion. Matches what the project's
// docs show as the on-disk shape (see `~/.tool-agents/macrec-ui/.env`
// header comment).

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum EnvFileStore {

    // MARK: - Public API

    /// Load every `KEY=VALUE` from `~/.tool-agents/<toolName>/.env`
    /// into the running process's environment via `setenv`. Existing
    /// values in the shell environment win; we only set keys that are
    /// not already present (the four-tier chain places the shell at
    /// the top of the priority order). Missing file is a silent
    /// no-op — the bootstrap step seeds an empty file on first run,
    /// so a real "missing file" only happens if the user has
    /// physically removed it.
    @discardableResult
    public static func loadIntoProcess(toolName: String) -> [String: String] {
        let url = ToolAgentsBootstrap.userEnvPath(toolName: toolName)
        guard let parsed = try? parse(at: url) else {
            return [:]
        }
        let existing = ProcessInfo.processInfo.environment
        for (k, v) in parsed where existing[k] == nil {
            setenv(k, v, /*overwrite*/ 0)
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
    /// - Throws: `MacrecError.ioError` on filesystem failure (parent
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

        let updated = rewrite(source: original, key: key, value: value)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MacrecError.ioError(
                "failed to write \(url.path): \(error.localizedDescription)"
            )
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw MacrecError.ioError(
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

    /// Parse the file at `url` into a `[KEY: VALUE]` dictionary.
    /// Throws if the file exists but cannot be read; returns empty if
    /// the file is missing.
    static func parse(at url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            out[key] = value
        }
        return out
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

        return lines.joined(separator: "\n")
    }
}
