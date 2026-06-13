// NtakkerCore/Encoding/Recorder.swift — see project-design.md §2.10 / §7.4 / §7.7
// and `docs/research/avassetwriter-aac.md` §1.1, §5.
//
// Phase G (plan-001 Wave 3b) — Recorder protocol + factory.
//
// The protocol shape here follows the Phase G dispatch prompt: an
// `async` lifecycle (`start()` / `finalize(timeout:)`) that consumes
// `AlignedFrame` values produced by `HostClockAligner`, with the
// recorder owning the per-layout routing (mixed / split / stereo-split)
// and the AAC priming-pad handling done by AVFoundation under the hood.
//
// The legacy CMSampleBuffer/callback signatures defined for Phases H/I
// in the design doc are preserved as protocol default implementations
// so that the still-stub `WAVRecorder` and `CAFRecorder` (Phase H,
// authored in parallel) keep compiling. Phase H's coder will replace
// those defaults with real `start()`/`append(_:)`/`finalize(timeout:)`
// implementations; until then the factory below routes only
// `format == .m4a` and throws a clear "deferred to Phase H" error for
// `.wav` / `.caf`.

import AVFoundation
import CoreMedia
import Foundation
import Logging

// MARK: - Recorder protocol

/// Output writer abstraction used by `RecordingSession` to persist
/// aligned frames to a `.m4a`, `.wav`, or `.caf` file.
///
/// The protocol is `Sendable` because conforming types confine all
/// mutable state to a private serial writer queue. They are also
/// `AnyObject` (reference types) so the orchestrator can hold a single
/// recorder across the lifetime of a recording session.
public protocol Recorder: AnyObject, Sendable {
    /// Open the underlying writer and begin a session. Throws
    /// `NtakkerError.writerFailedToStart` if the writer cannot be
    /// initialized (typically a permissions, disk-space, or path
    /// validation failure that escaped `makeRecorder`'s pre-flight
    /// checks).
    ///
    /// Must be called exactly once before the first `append(_:)`.
    func start() async throws

    /// Append one aligned frame produced by `HostClockAligner`. The
    /// recorder is responsible for honoring the configured
    /// `TrackLayout`:
    ///
    ///   * `.mixed`         — sum mic + system into a single stereo
    ///                        track.
    ///   * `.stereoSplit`   — produce a stereo track where the mic
    ///                        occupies the configured channel and the
    ///                        system audio the other.
    ///   * `.split`         — write mic and system to separate sibling
    ///                        files.
    ///
    /// Thread-safe: callable from the aligner's serial queue (or any
    /// other thread). Implementations enqueue work onto their private
    /// writer queue.
    func append(_ frame: AlignedFrame) throws

    /// Finalize and close the writer. Idempotent — repeated calls are
    /// no-ops. Awaits up to `timeout` for `finishWriting` to complete.
    ///
    /// On timeout: throws `NtakkerError.writerFinalizationTimeout` and
    /// leaves the partial file on disk (the `movieFragmentInterval`
    /// guarantees it stays playable in VLC/ffmpeg per AC-7).
    ///
    /// On AVAssetWriter failure: throws
    /// `NtakkerError.finishWritingFailed`.
    func finalize(timeout: TimeInterval) async throws
}

// MARK: - Legacy default implementations (Phase H bridge)
//
// The Phase H stubs (`WAVRecorder`, `CAFRecorder`) currently expose the
// design §2.10 callback-based API surface and have not yet been
// rewritten to the Phase G shape. The default implementations below let
// them keep conforming until Phase H lands its real code; they each
// surface a clear "not implemented" error rather than silently no-op'ing.

extension Recorder {
    /// Legacy default — Phase H will override.
    public func start() async throws {
        throw NtakkerError.ioError("Recorder.start(): not implemented for this recorder (Phase H pending)")
    }

    /// Legacy default — Phase H will override.
    public func append(_ frame: AlignedFrame) throws {
        _ = frame
        throw NtakkerError.ioError("Recorder.append(_:): not implemented for this recorder (Phase H pending)")
    }

    /// Legacy default — Phase H will override.
    public func finalize(timeout: TimeInterval) async throws {
        _ = timeout
        throw NtakkerError.ioError("Recorder.finalize(timeout:): not implemented for this recorder (Phase H pending)")
    }
}

// MARK: - Factory

/// Build a `Recorder` for the configured format / layout.
///
/// Pre-flight validation (per design §2.10 + FR-15):
///   1. The output's parent directory must exist (we never create it
///      automatically — the user controls placement).
///   2. The output file must not already exist unless
///      `options.overwrite == true`.
///
/// On `.m4a`: returns a fully-initialized `M4ARecorder` (writer not
/// yet started — the caller must `await recorder.start()`).
///
/// On `.wav`: returns a fully-initialized `WAVRecorder` (Phase H).
///
/// On `.caf`: returns a fully-initialized `CAFRecorder` (Phase H).
///
/// - Throws:
///   - `NtakkerError.outputParentMissing` if the output's parent
///     directory does not exist.
///   - `NtakkerError.outputAlreadyExists` if the output file is present
///     and `overwrite` is false.
public func makeRecorder(options: RecordingOptions, logger: Logger? = nil) throws -> Recorder {
    // 1. Pre-flight validation (shared across formats).
    let parent = options.output.deletingLastPathComponent()
    var isDir: ObjCBool = false
    let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir)
    guard parentExists, isDir.boolValue else {
        throw NtakkerError.outputParentMissing(options.output)
    }

    if FileManager.default.fileExists(atPath: options.output.path) {
        guard options.overwrite else {
            throw NtakkerError.outputAlreadyExists(options.output)
        }
        // Caller asked us to replace it; deletion is performed by the
        // recorder's `start()` (so the user-visible side effect is
        // coupled to the actual writer lifecycle, not to construction).
    }

    // For `split` layout we also need to validate the second path
    // (mic.<ext> alongside the user-specified output, which we treat as
    // the system path). Phase J wires the second path explicitly; the
    // M4ARecorder does the per-side validation in `start()`.

    // 2. Route by format.
    switch options.format {
    case .m4a:
        return M4ARecorder(options: options, logger: logger)

    case .wav:
        return WAVRecorder(options: options, logger: logger)

    case .caf:
        return CAFRecorder(options: options, logger: logger)
    }
}
