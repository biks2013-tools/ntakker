// MacrecCore/Bootstrap/ToolAgentsBootstrap.swift — see project-design.md §2.2
// Phase B — Bootstrap + Config (FR-13, AC-10)

import Foundation

/// Materializes the `~/.tool-agents/<toolName>/` directory at mode `0700`
/// and seeds an empty `.env` file at mode `0600`. Idempotent — safe to
/// call on every CLI invocation.
public enum ToolAgentsBootstrap {

    /// Default content of the seed `.env` file. Intentionally minimal so
    /// the user notices it is meant to be edited.
    private static let seedEnvContents = """
    # macrec environment overrides
    # Format: KEY=value
    """

    /// Ensures `~/.tool-agents/<toolName>/` exists at mode `0700` and
    /// contains an `.env` file at mode `0600`. Returns the directory URL.
    ///
    /// - Parameter toolName: e.g. `"macrec"`.
    /// - Returns: The fully-resolved directory URL.
    /// - Throws: `MacrecError.ioError` on filesystem failure.
    @discardableResult
    public static func ensure(toolName: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return try ensure(toolName: toolName, rootDirectory: home)
    }

    /// Test-friendly variant that uses an injected root directory in
    /// place of `$HOME`. Callers in production should use
    /// `ensure(toolName:)`.
    ///
    /// - Parameters:
    ///   - toolName: e.g. `"macrec"`.
    ///   - rootDirectory: the directory under which `.tool-agents/` is
    ///     materialized. In production this is the user's home; in tests
    ///     this is a `URL(fileURLWithPath: NSTemporaryDirectory())`-derived
    ///     temp directory.
    @discardableResult
    public static func ensure(toolName: String, rootDirectory: URL) throws -> URL {
        let toolAgents = rootDirectory.appendingPathComponent(".tool-agents", isDirectory: true)
        let dir = toolAgents.appendingPathComponent(toolName, isDirectory: true)
        try ensureDirectory(at: dir)
        try ensureSeedEnv(in: dir)
        return dir
    }

    /// Convenience: path to the per-user `.env` for `toolName`. Does NOT
    /// touch the filesystem — call `ensure` first if you need it to exist.
    public static func userEnvPath(toolName: String) -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".tool-agents", isDirectory: true)
            .appendingPathComponent(toolName, isDirectory: true)
            .appendingPathComponent(".env")
    }

    /// Convenience: `./.env` resolved against the current working
    /// directory.
    public static func localEnvPath() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env")
    }

    // MARK: - Internals

    private static func ensureDirectory(at url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)

        if !exists {
            do {
                try fm.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MacrecError.ioError(
                    "failed to create \(url.path): \(error.localizedDescription)"
                )
            }
        } else if !isDir.boolValue {
            throw MacrecError.ioError(
                "path exists but is not a directory: \(url.path)"
            )
        }

        // Defensive re-chmod: APFS / iCloud-backed homes occasionally
        // ignore the create-time `posixPermissions` attribute (see
        // plan-001 risk note for Phase B).
        do {
            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } catch {
            throw MacrecError.ioError(
                "failed to chmod 0700 on \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private static func ensureSeedEnv(in dir: URL) throws {
        let fm = FileManager.default
        let envFile = dir.appendingPathComponent(".env")
        if !fm.fileExists(atPath: envFile.path) {
            do {
                let data = Data(seedEnvContents.utf8)
                let created = fm.createFile(
                    atPath: envFile.path,
                    contents: data,
                    attributes: [.posixPermissions: 0o600]
                )
                guard created else {
                    throw MacrecError.ioError(
                        "failed to create seed .env at \(envFile.path)"
                    )
                }
            }
        }
        // Defensive re-chmod regardless of whether we just created the
        // file or it was already present.
        do {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: envFile.path
            )
        } catch {
            throw MacrecError.ioError(
                "failed to chmod 0600 on \(envFile.path): \(error.localizedDescription)"
            )
        }
    }
}
