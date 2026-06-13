// NtakkerCoreTests/PidFileTests.swift — see plan-001 §J/§K (FR-25/FR-27/FR-28)
// Phase J finalization (2026-04-26).
//
// Tests the on-disk PID file primitives in `PidFile`. All tests use
// per-test temp directories so they can run in parallel without
// interfering with each other or with the user's real
// `~/.tool-agents/ntakker-cli/ntakker-cli.pid`.
//
// `isAlive(pid:)` is verified against the test process's own PID
// (must be alive) and against a deliberately implausible high PID
// (overwhelmingly likely to be unused on any typical macOS system).

import Foundation
import Testing
@testable import NtakkerCore

@Suite("PidFile")
struct PidFileTests {

    // MARK: - Temp-dir helpers

    /// Creates a unique temp directory and returns its URL plus a
    /// cleanup closure. The closure is safe to call multiple times.
    private func makeTempDir() -> (URL, () -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntakker-cli-pidfile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Reads the POSIX permissions bits of `path`, masked to the
    /// canonical 0o777 range.
    private func mode(of path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let raw = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return raw.intValue & 0o777
    }

    // MARK: - Tests

    @Test("write then read round-trips the PID")
    func writeReadRoundTrip() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir.appendingPathComponent("ntakker-cli.pid")
        try PidFile.write(at: url, pid: 12345)

        let observed = try PidFile.read(at: url)
        #expect(observed == 12345)
    }

    @Test("read of a missing file returns nil")
    func readMissingReturnsNil() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir.appendingPathComponent("does-not-exist.pid")
        let observed = try PidFile.read(at: url)
        #expect(observed == nil)
    }

    @Test("read of an invalid-content file throws")
    func readInvalidThrows() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir.appendingPathComponent("malformed.pid")
        try "not-a-number\n".write(to: url, atomically: true, encoding: .utf8)

        var threw = false
        do {
            _ = try PidFile.read(at: url)
        } catch let err as NtakkerError {
            threw = true
            switch err {
            case .ioError:
                break  // expected
            default:
                Issue.record("expected NtakkerError.ioError, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(threw)
    }

    @Test("remove is idempotent — calling twice on the same path does not error")
    func removeIdempotent() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir.appendingPathComponent("ntakker-cli.pid")
        try PidFile.write(at: url, pid: 999)
        #expect(FileManager.default.fileExists(atPath: url.path))

        PidFile.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // Second call must not throw and must remain a no-op.
        PidFile.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("isAlive(currentPid) returns true")
    func isAliveCurrentProcess() throws {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let alive = try PidFile.isAlive(pid: myPid)
        #expect(alive == true)
    }

    @Test("isAlive(implausibleHighPid) returns false")
    func isAliveImplausibleReturnsFalse() throws {
        // 999_999 is well above any typical macOS PID (the kernel
        // wraps PIDs around 99_999 by default, and even tuned-up
        // systems rarely exceed 200_000). Choosing a value outside
        // that window minimises the chance of a flake.
        let alive = try PidFile.isAlive(pid: 999_999)
        #expect(alive == false)
    }

    @Test("after write, file mode is 0600")
    func writeSetsMode0600() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir.appendingPathComponent("ntakker-cli.pid")
        try PidFile.write(at: url, pid: 7777)

        #expect(mode(of: url.path) == 0o600)
    }

    @Test("write overwrites an existing file")
    func writeOverwrites() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir.appendingPathComponent("ntakker-cli.pid")
        try PidFile.write(at: url, pid: 100)
        try PidFile.write(at: url, pid: 200)

        let observed = try PidFile.read(at: url)
        #expect(observed == 200)
        #expect(mode(of: url.path) == 0o600)
    }

    @Test("write fails cleanly when parent directory is missing")
    func writeFailsWhenParentMissing() throws {
        let (dir, cleanup) = makeTempDir()
        defer { cleanup() }

        let url = dir
            .appendingPathComponent("definitely-does-not-exist", isDirectory: true)
            .appendingPathComponent("ntakker-cli.pid")

        var threw = false
        do {
            try PidFile.write(at: url, pid: 1)
        } catch let err as NtakkerError {
            threw = true
            switch err {
            case .pidFileWriteFailed:
                break  // expected
            default:
                Issue.record("expected NtakkerError.pidFileWriteFailed, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(threw)
    }
}
