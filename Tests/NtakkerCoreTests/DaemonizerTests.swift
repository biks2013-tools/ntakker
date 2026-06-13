// NtakkerCoreTests/DaemonizerTests.swift — see plan-001 §K (FR-25)
// and project-design.md §14.2 / §11.11.
//
// Phase K finalization.
//
// Daemonization itself cannot be unit-tested in-process: a successful
// `Daemonizer.detach(_:)` terminates the parent with `_exit(0)`, which
// would also terminate the test runner. Real lifecycle coverage is
// performed end-to-end in Phase L (`test_scripts/e2e-detach-stop.sh`
// and `test_scripts/e2e-detach-orphan-check.sh`).
//
// These tests therefore assert only the surface-level invariants we
// can verify without forking:
//
//   * `Daemonizer.Options` round-trips its fields verbatim.
//   * `Daemonizer.Options(workingDirectory:)` defaults to "/" per the
//     design contract.
//   * `Daemonizer.detach(_:)` exists with the documented signature
//     (compile-time check via reference assignment).

import Foundation
import Testing
@testable import NtakkerCore

@Suite("Daemonizer")
struct DaemonizerTests {

    @Test("Options round-trips its fields")
    func optionsRoundTrip() {
        let pid = URL(fileURLWithPath: "/tmp/test.pid")
        let log = URL(fileURLWithPath: "/tmp/test.log")
        let cwd = URL(fileURLWithPath: "/var/tmp")

        let opts = Daemonizer.Options(
            pidFile: pid,
            logFile: log,
            workingDirectory: cwd
        )

        #expect(opts.pidFile == pid)
        #expect(opts.logFile == log)
        #expect(opts.workingDirectory == cwd)
    }

    @Test("Options.workingDirectory defaults to /")
    func optionsDefaultWorkingDirectoryIsRoot() {
        let opts = Daemonizer.Options(
            pidFile: URL(fileURLWithPath: "/tmp/x.pid"),
            logFile: URL(fileURLWithPath: "/tmp/x.log")
        )
        #expect(opts.workingDirectory == URL(fileURLWithPath: "/"))
    }

    @Test("Daemonizer.detach has the expected (Options) throws signature")
    func detachSignatureExists() {
        // Build-time existence check: a reference to the function
        // forces the compiler to verify its name and signature
        // without invoking it (which would terminate the test
        // runner).
        let ref: (Daemonizer.Options) throws -> Void = Daemonizer.detach
        _ = ref  // silence unused-let warning
    }
}
