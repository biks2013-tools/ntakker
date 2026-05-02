// MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift
//
// Phase F (plan-004 §"Phase F — Sidecar writers", Task F.7) — actor
// that owns one per-format sidecar writer and dispatches the
// transcription events that produce sidecar lines (`.segmentAppended`
// and `.segmentUpdated`).
//
// Lifecycle:
//
//   init(outputPath:format:)  ← actor + per-format writer constructed
//                                 (the per-format writer opens its own
//                                  `FileHandle(forUpdating:)`).
//     ↓
//   write(event)              ← may be called many times; safe per-format
//                                 errors are caught and logged.
//     ↓
//   close()                   ← idempotent; subsequent calls are no-ops.
//
// Phase E established the public surface used by the manager:
//
//   * `init(outputPath:format:) throws`
//   * `func write(_ event: TranscriptionEvent) async`   (NOT throws —
//     the manager calls `await sidecarWriter?.write(event)` with no
//     `try`, so per-format-writer errors must be caught here and
//     converted to log warnings.)
//   * `func close() async`
//
// Once `close()` has been called, further `write(event)` calls are
// silently ignored. This matches the design's "best-effort
// persistence — never block the recording" requirement.

import Foundation
import Logging

/// Per-mode sidecar persistence policy.
///
/// Plan-005 Phase F introduced this so the writer can switch between
/// the batch pipeline (which produces `.segmentAppended` /
/// `.segmentUpdated` over the lifetime of an utterance — the sidecar
/// MUST persist both, with id-keyed in-place rewrite) and the
/// streaming pipeline (which produces noisy partials but only the
/// final `.segmentFinalized` event represents the canonical
/// transcript line — the sidecar MUST persist only the final).
///
/// Mixing modes inside a single writer instance is a programmer
/// error; the writer is constructed for one policy and the policy
/// drives the dispatch in `write(_:)`.
public enum SidecarPolicy: Sendable, Equatable {
    /// Batch pipeline: persist `.segmentAppended` (new line at EOF) and
    /// `.segmentUpdated` (rewrite in place via the per-format writer's
    /// id-keyed byte index). `.segmentFinalized` is ignored on this
    /// path — the batch pipeline never emits it.
    case batch

    /// Streaming pipeline: persist `.segmentFinalized` only (one
    /// `appendSegment(_:)` per utterance). `.segmentAppended` and
    /// `.segmentUpdated` are UI-only events on this path; the writer
    /// must NOT persist them.
    case streaming
}

/// Serial writer for one transcript sidecar file. Pluggable per
/// format; converts I/O errors into log warnings so the recording is
/// never blocked or crashed by sidecar trouble.
public actor TranscriptSidecarWriter {

    // MARK: - Public surface

    /// Open the sidecar file at `outputPath` for writing and prepare
    /// the format-specific writer. Throws if the path cannot be made
    /// writable (parent directory missing OR creation failed; or the
    /// per-format writer's `FileHandle` opening failed).
    ///
    /// - Parameters:
    ///   - outputPath: The destination file URL. Caller derives this
    ///     via `SidecarPathBuilder.sidecarURL(...)`.
    ///   - format: The format whose writer should be invoked for every
    ///     segment-producing event.
    ///   - policy: Per-mode sidecar policy (see `SidecarPolicy`). The
    ///     batch pipeline uses `.batch` (persist appended + updated
    ///     segments via id-keyed in-place rewrite); the streaming
    ///     pipeline uses `.streaming` (persist only finalized
    ///     segments). The policy is fixed for the lifetime of the
    ///     writer — rotating the sidecar (`rotateSidecar(...)`) is the
    ///     standard way to change it mid-session, but in practice the
    ///     pipeline that owns the writer never changes.
    public init(outputPath: URL,
                format: TranscriptFormat,
                policy: SidecarPolicy,
                mode: LiveTranscriptionMode = .single) throws {
        self.outputPath = outputPath
        self.format = format
        self.policy = policy
        self.mode = mode
        self.logger = Logger(label: "macrec.transcription.sidecar")

        // Make sure the parent directory exists — the per-format writer
        // calls `FileManager.createFile(atPath:)` which silently fails
        // if the parent doesn't exist. We surface that as a typed
        // error rather than a "broken state on the very first write".
        try Self.ensureParentDirectory(of: outputPath)

        do {
            self.formatWriter = try Self.makeFormatWriter(for: format,
                                                          url: outputPath,
                                                          mode: mode)
        } catch {
            throw TranscriptSidecarWriterError.cannotOpenForWriting(
                path: outputPath,
                underlying: error
            )
        }
        self.state = .open
    }

    /// Append one event to the sidecar. Best-effort: if the underlying
    /// write fails, the error is logged and the writer transitions to
    /// `.broken` — subsequent calls are dropped.
    ///
    /// Per-mode dispatch (plan-005 Phase F):
    ///   * `.batch`     — `.segmentAppended` + `.segmentUpdated` produce
    ///                    sidecar output; `.segmentFinalized` is ignored
    ///                    (the batch pipeline never emits it).
    ///   * `.streaming` — `.segmentFinalized` produces sidecar output
    ///                    via `appendSegment(_:)` (one line per finalised
    ///                    utterance); `.segmentAppended` and
    ///                    `.segmentUpdated` are UI-only events on this
    ///                    path and are NOT persisted.
    ///
    /// `.privacyDisclosure`, `.metricsTick`, and `.error` are no-ops on
    /// both paths — the UI consumes them via the events stream.
    public func write(_ event: TranscriptionEvent) async {
        guard case .open = state else {
            return
        }
        do {
            switch policy {
            case .batch:
                switch event {
                case let .segmentAppended(_, segment):
                    try formatWriter.appendSegment(segment)
                case let .segmentUpdated(_, segment):
                    try formatWriter.updateSegment(segment)
                case .segmentFinalized:
                    // Batch pipeline never emits `.segmentFinalized`;
                    // even if it did, it's not part of the batch
                    // sidecar contract.
                    return
                case .privacyDisclosure, .metricsTick, .error, .dualChannelError:
                    // Plan-010 Phase B / L-3: `.dualChannelError` is a
                    // dual-mode merged-stream event (per-channel error
                    // tag) and is not persisted into the sidecar — the
                    // sidecar carries transcript content, not orchestration
                    // diagnostics. Lane L-5 may revisit if the error
                    // surfaces as a NOTE/comment line per format.
                    return
                }
            case .streaming:
                switch event {
                case let .segmentFinalized(_, segment):
                    try formatWriter.appendSegment(segment)
                case .segmentAppended, .segmentUpdated:
                    // UI-only events on the streaming path; partials
                    // never reach the sidecar.
                    return
                case .privacyDisclosure, .metricsTick, .error, .dualChannelError:
                    // Plan-010 Phase B / L-3: see batch-policy arm above.
                    return
                }
            }
        } catch {
            logger.warning(
                """
                transcript sidecar write failed; entering broken state. \
                file=\(outputPath.path) error=\(String(reflecting: error))
                """
            )
            state = .broken
        }
    }

    /// Flush + close the format writer's file handle. Idempotent.
    /// After this returns the writer accepts no further writes.
    public func close() async {
        // Allow `close()` to run on an already-broken writer — we
        // still want to release the underlying file descriptor even
        // if a mid-session write disabled the writer.
        if case .closed = state {
            return
        }
        do {
            try formatWriter.close()
        } catch {
            logger.warning(
                """
                transcript sidecar close failed. \
                file=\(outputPath.path) error=\(String(reflecting: error))
                """
            )
        }
        state = .closed
    }

    /// Diagnostic: returns whether the writer has accepted/rejected
    /// further writes. Used by the unit tests to assert post-close
    /// behaviour.
    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    // MARK: - State

    private enum State {
        case open
        case broken
        case closed
    }

    private let outputPath: URL
    private let format: TranscriptFormat
    private let policy: SidecarPolicy
    private let mode: LiveTranscriptionMode
    private let formatWriter: any TranscriptFormatWriter
    private let logger: Logger
    private var state: State

    // MARK: - Helpers

    /// Build the per-format writer. Each writer opens its own
    /// `FileHandle(forUpdating:)` against `url` inside `init`.
    ///
    /// The `mode` parameter is plumbed through to every per-format
    /// writer (plan-010 Lane L-6) so they can branch on single vs
    /// dual transcription mode when rendering segments. In `.single`
    /// mode every writer's output is byte-equivalent to the
    /// pre-plan-010 layout; in `.dual` mode each writer adds a
    /// channel-tagging cue per its format spec (see design §DT-7).
    private static func makeFormatWriter(for format: TranscriptFormat,
                                         url: URL,
                                         mode: LiveTranscriptionMode) throws -> any TranscriptFormatWriter {
        switch format {
        case .jsonl:
            return try JSONLTranscriptWriter(url: url, mode: mode)
        case .srt:
            return try SRTTranscriptWriter(url: url, mode: mode)
        case .vtt:
            return try VTTTranscriptWriter(url: url, mode: mode)
        case .txt:
            return try TXTTranscriptWriter(url: url, mode: mode)
        }
    }

    /// Ensure the parent directory of `url` exists. No fallback —
    /// failure to create the directory surfaces to the caller.
    private static func ensureParentDirectory(of url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}

// MARK: - Errors

/// Errors thrown by `TranscriptSidecarWriter.init`. Per the project
/// convention these have no fallback path: a non-writable sidecar
/// destination is a configuration error and surfaces to the caller.
public enum TranscriptSidecarWriterError: Error, CustomStringConvertible {

    /// `FileManager.createFile(atPath:...)` returned `false`. The most
    /// common cause is parent-directory permissions or a path that
    /// resolves to a directory rather than a regular-file location.
    case cannotCreateFile(path: URL)

    /// The per-format writer's `init` threw — typically because the
    /// file exists but cannot be opened for writing. The underlying
    /// error is preserved so callers can distinguish permission
    /// denials from quota exhaustion etc.
    case cannotOpenForWriting(path: URL, underlying: Error)

    public var description: String {
        switch self {
        case let .cannotCreateFile(path):
            return "cannot create transcript sidecar at \(path.path)"
        case let .cannotOpenForWriting(path, underlying):
            return """
                cannot open transcript sidecar at \(path.path) for writing: \
                \(String(reflecting: underlying))
                """
        }
    }
}
