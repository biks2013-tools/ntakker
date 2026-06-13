// NtakkerCoreTests/ToolAgentsBootstrapTests.swift — see project-design.md §2.2
// Phase B — Bootstrap + Config (AC-10)

import Foundation
import Testing
@testable import NtakkerCore

@Suite("ToolAgentsBootstrap")
struct ToolAgentsBootstrapTests {

    /// Creates a unique temp directory to act as a fake `$HOME`. The
    /// caller is responsible for cleanup via the returned closure.
    private func makeTempHome() -> (URL, () -> Void) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntakker-cli-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: nil
        )
        return (base, { try? FileManager.default.removeItem(at: base) })
    }

    private func mode(of path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let raw = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return raw.intValue & 0o777
    }

    @Test("ensure(toolName:rootDirectory:) creates the directory at 0700 with .env at 0600")
    func createsDirectoryAndSeedEnv() throws {
        let (root, cleanup) = makeTempHome()
        defer { cleanup() }

        let dir = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)

        #expect(dir.path == root.appendingPathComponent(".tool-agents").appendingPathComponent("ntakker-cli").path)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue == true)
        #expect(mode(of: dir.path) == 0o700)

        let envFile = dir.appendingPathComponent(".env")
        #expect(FileManager.default.fileExists(atPath: envFile.path))
        #expect(mode(of: envFile.path) == 0o600)
    }

    @Test("ensure is idempotent — calling twice does not error and preserves modes")
    func idempotent() throws {
        let (root, cleanup) = makeTempHome()
        defer { cleanup() }

        _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)
        // Mutate `.env` to verify second call does NOT overwrite it.
        let envFile = root
            .appendingPathComponent(".tool-agents")
            .appendingPathComponent("ntakker-cli")
            .appendingPathComponent(".env")
        try "USER_VALUE=preserved\n".write(to: envFile, atomically: true, encoding: .utf8)

        // Second invocation should be a no-op for content but still re-chmod.
        _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)

        let body = try String(contentsOf: envFile, encoding: .utf8)
        #expect(body.contains("USER_VALUE=preserved"))
        #expect(mode(of: envFile.path) == 0o600)
        #expect(mode(of: envFile.deletingLastPathComponent().path) == 0o700)
    }

    @Test("Removing the directory and re-running ensure recreates it (AC-10)")
    func recreatesAfterRemoval() throws {
        let (root, cleanup) = makeTempHome()
        defer { cleanup() }

        let dir = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)
        try FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        let dir2 = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)
        #expect(dir.path == dir2.path)
        #expect(FileManager.default.fileExists(atPath: dir2.path))
        #expect(mode(of: dir2.path) == 0o700)
        let envFile = dir2.appendingPathComponent(".env")
        #expect(FileManager.default.fileExists(atPath: envFile.path))
        #expect(mode(of: envFile.path) == 0o600)
    }

    @Test("ensure repairs an over-permissive directory mode")
    func repairsLooseDirectoryMode() throws {
        let (root, cleanup) = makeTempHome()
        defer { cleanup() }

        // Pre-create the directory at a deliberately loose 0755.
        let dir = root
            .appendingPathComponent(".tool-agents")
            .appendingPathComponent("ntakker-cli")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)
        #expect(mode(of: dir.path) == 0o700)
    }

    @Test("ensure repairs an over-permissive .env mode")
    func repairsLooseEnvMode() throws {
        let (root, cleanup) = makeTempHome()
        defer { cleanup() }

        _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)
        let envFile = root
            .appendingPathComponent(".tool-agents")
            .appendingPathComponent("ntakker-cli")
            .appendingPathComponent(".env")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: envFile.path
        )
        #expect(mode(of: envFile.path) == 0o644)

        _ = try ToolAgentsBootstrap.ensure(toolName: "ntakker-cli", rootDirectory: root)
        #expect(mode(of: envFile.path) == 0o600)
    }

    @Test("userEnvPath and localEnvPath produce consistent URLs")
    func helperPathsReturnExpectedURLs() {
        let userPath = ToolAgentsBootstrap.userEnvPath(toolName: "ntakker-cli")
        #expect(userPath.lastPathComponent == ".env")
        let localPath = ToolAgentsBootstrap.localEnvPath()
        #expect(localPath.lastPathComponent == ".env")
    }
}
