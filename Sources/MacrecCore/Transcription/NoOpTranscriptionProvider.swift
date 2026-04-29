// MacrecCore/Transcription/NoOpTranscriptionProvider.swift — see project-design.md §LT-3 / §LT-2
//
// Phase C (plan-004 rest-batch) — concrete provider used when
// `--transcribe none` (the default, FR-45). Returns the empty string for
// every call and performs no I/O.
//
// Phase A (plan-005) — re-conformed to the extended provider protocol:
// declares `supportedModes = [.batch]` and provides an
// `openStreamingSession(...)` that returns a no-op streaming session.
// The no-op streaming session yields zero events and finishes
// immediately, so any caller that opens it gets a clean drained stream.

import Foundation

/// Default provider for `--transcribe none`. Returns "" for every
/// call and does no I/O.
public struct NoOpTranscriptionProvider: TranscriptionProvider {
    public let id = "none"
    public let displayName = "None"
    public let supportedModes: Set<TranscriptionMode> = [.batch]

    public init() {}

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        ""
    }

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        NoOpStreamingSession()
    }
}

/// No-op streaming session: emits no events and finishes immediately.
/// Used by `NoOpTranscriptionProvider` so any caller that opens a
/// streaming session gets a cleanly-drained empty stream.
private struct NoOpStreamingSession: StreamingTranscriptionSession {
    var events: AsyncStream<StreamingTranscriptionEvent> {
        AsyncStream { cont in cont.finish() }
    }
    func ingest(_ samples: [Float]) async {}
    func finish() async {}
}
