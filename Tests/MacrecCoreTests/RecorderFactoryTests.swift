// MacrecCoreTests/RecorderFactoryTests.swift — see project-design.md §2.10 / §7.4
//
// Phase G test coverage for `makeRecorder(options:logger:)`.
//
// Tests factory routing (m4a → M4ARecorder, wav → WAVRecorder,
// caf → CAFRecorder), validation paths (outputAlreadyExists,
// outputParentMissing, overwrite=true bypass).
//
// Note (R-17): On a CLT-only host `swift test` exits 0 without firing
// Swift Testing assertions. Build status is the primary pass/fail signal.

import AVFoundation
import Foundation
import Testing
@testable import MacrecCore

@Suite("RecorderFactory")
struct RecorderFactoryTests {

    // MARK: - Temp-dir fixture helpers

    /// Create a unique temp directory for a single test and remove it on deinit.
    /// Used as a lexically-scoped fixture via local let binding.
    private static func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderFactoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func removeTemp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Factory routing

    @Test("makeRecorder returns M4ARecorder for .m4a format")
    func factoryRouteM4A() throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out.m4a")
        let opts = RecordingOptions(output: output, format: .m4a)
        let recorder = try makeRecorder(options: opts)
        #expect(recorder is M4ARecorder)
    }

    @Test("makeRecorder returns WAVRecorder for .wav format")
    func factoryRouteWAV() throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out.wav")
        let opts = RecordingOptions(output: output, format: .wav)
        let recorder = try makeRecorder(options: opts)
        #expect(recorder is WAVRecorder)
    }

    @Test("makeRecorder returns CAFRecorder for .caf format")
    func factoryRouteCAF() throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("out.caf")
        let opts = RecordingOptions(output: output, format: .caf)
        let recorder = try makeRecorder(options: opts)
        #expect(recorder is CAFRecorder)
    }

    // MARK: - Validation: outputAlreadyExists

    @Test("makeRecorder throws outputAlreadyExists when file exists and overwrite=false")
    func throwsOutputAlreadyExists() throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("exists.m4a")
        // Create the file so it already exists.
        FileManager.default.createFile(atPath: output.path, contents: Data())

        let opts = RecordingOptions(output: output, format: .m4a, overwrite: false)
        do {
            _ = try makeRecorder(options: opts)
            #expect(Bool(false), "Expected outputAlreadyExists to be thrown but got no error")
        } catch let err as MacrecError {
            if case .outputAlreadyExists = err {
                // Correct error — test passes.
            } else {
                #expect(Bool(false), "Expected outputAlreadyExists, got \(err)")
            }
        }
    }

    @Test("makeRecorder does NOT throw when file exists and overwrite=true")
    func noThrowWhenOverwriteTrue() throws {
        let dir = try Self.makeTemp()
        defer { Self.removeTemp(dir) }

        let output = dir.appendingPathComponent("exists-overwrite.m4a")
        FileManager.default.createFile(atPath: output.path, contents: Data())

        let opts = RecordingOptions(output: output, format: .m4a, overwrite: true)
        // Should not throw.
        let recorder = try makeRecorder(options: opts)
        #expect(recorder is M4ARecorder)
    }

    // MARK: - Validation: outputParentMissing

    @Test("makeRecorder throws outputParentMissing when parent dir does not exist")
    func throwsOutputParentMissing() throws {
        // Use a path whose parent directory does not exist.
        let nonExistentParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)", isDirectory: true)
        let output = nonExistentParent.appendingPathComponent("out.m4a")

        let opts = RecordingOptions(output: output, format: .m4a)
        do {
            _ = try makeRecorder(options: opts)
            #expect(Bool(false), "Expected outputParentMissing to be thrown but got no error")
        } catch let err as MacrecError {
            if case .outputParentMissing = err {
                // Correct error — test passes.
            } else {
                #expect(Bool(false), "Expected outputParentMissing, got \(err)")
            }
        }
    }

    @Test("makeRecorder throws outputParentMissing even when overwrite=true and parent missing")
    func throwsOutputParentMissingOverwriteTrue() throws {
        let nonExistentParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent2-\(UUID().uuidString)", isDirectory: true)
        let output = nonExistentParent.appendingPathComponent("out.m4a")

        let opts = RecordingOptions(output: output, format: .m4a, overwrite: true)
        do {
            _ = try makeRecorder(options: opts)
            #expect(Bool(false), "Expected outputParentMissing, got no error")
        } catch let err as MacrecError {
            if case .outputParentMissing = err {
                // Correct.
            } else {
                #expect(Bool(false), "Expected outputParentMissing, got \(err)")
            }
        }
    }
}
