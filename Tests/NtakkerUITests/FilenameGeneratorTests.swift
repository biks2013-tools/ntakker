// NtakkerUITests/FilenameGeneratorTests.swift — see plan-002 §3 Phase D.
//
// Golden-string tests against fixed dates and basic collision-avoidance
// coverage. The DateFormatter under test is locked to `en_US_POSIX`
// and the user's current time zone, so we compute the expected golden
// from the SAME formatter (rather than hard-coding a UTC string) — the
// tests are deterministic regardless of the host's TZ.
//
// R-22: the dev host's `swift test` exits 0 silently. These tests are
// authored for compile-only verification of the API surface.

import Foundation
import Testing
@testable import NtakkerUIKit
@testable import NtakkerCore

@Suite("FilenameGenerator")
struct FilenameGeneratorTests {

    /// Build the expected basename for `now` using the same formatter
    /// the SUT uses, so the test does not assume a specific time zone.
    private func expectedBasename(for now: Date) -> String {
        "recording-\(FilenameGenerator.formatter.string(from: now))"
    }

    @Test("default(now:) returns recording-<formatted-basename> with no extension")
    func defaultBasenameShape() {
        // Arbitrary fixed instant — the assertion uses the same
        // formatter, so the absolute value of the Date does not
        // matter.
        let fixed = Date(timeIntervalSince1970: 1_745_654_400) // 2026-04-26 10:00:00 UTC
        let basename = FilenameGenerator.default(now: fixed)
        #expect(basename == expectedBasename(for: fixed))
        #expect(!basename.contains("."))
        #expect(basename.hasPrefix("recording-"))
    }

    @Test("filename(now:format:) appends the format's raw value as extension")
    func filenameAppendsExtension() {
        let fixed = Date(timeIntervalSince1970: 1_745_654_400)
        let m4a = FilenameGenerator.filename(now: fixed, format: .m4a)
        let wav = FilenameGenerator.filename(now: fixed, format: .wav)
        let caf = FilenameGenerator.filename(now: fixed, format: .caf)
        #expect(m4a == "\(expectedBasename(for: fixed)).m4a")
        #expect(wav == "\(expectedBasename(for: fixed)).wav")
        #expect(caf == "\(expectedBasename(for: fixed)).caf")
    }

    @Test("formatter is en_US_POSIX with yyyy-MM-dd-HH-mm pattern")
    func formatterContract() {
        #expect(FilenameGenerator.formatter.locale.identifier == "en_US_POSIX")
        #expect(FilenameGenerator.formatter.dateFormat == "yyyy-MM-dd-HH-mm")
    }

    @Test("unique(_:) returns the proposed URL when it does not exist")
    func uniqueReturnsProposedWhenAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("filename-gen-\(UUID().uuidString).m4a")
        let resolved = try FilenameGenerator.unique(tmp)
        #expect(resolved == tmp)
    }

    @Test("unique(_:) appends -1 when the proposed URL exists")
    func uniqueAppendsSuffixOnCollision() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fg-collide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let original = tmpRoot.appendingPathComponent("recording.m4a")
        FileManager.default.createFile(atPath: original.path, contents: Data())

        let resolved = try FilenameGenerator.unique(original)
        #expect(resolved.lastPathComponent == "recording-1.m4a")
    }

    @Test("unique(_:) walks 1..N until an unused URL is found")
    func uniqueWalksMultipleCollisions() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fg-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let original = tmpRoot.appendingPathComponent("recording.m4a")
        FileManager.default.createFile(atPath: original.path, contents: Data())
        FileManager.default.createFile(
            atPath: tmpRoot.appendingPathComponent("recording-1.m4a").path,
            contents: Data()
        )
        FileManager.default.createFile(
            atPath: tmpRoot.appendingPathComponent("recording-2.m4a").path,
            contents: Data()
        )

        let resolved = try FilenameGenerator.unique(original)
        #expect(resolved.lastPathComponent == "recording-3.m4a")
    }
}
