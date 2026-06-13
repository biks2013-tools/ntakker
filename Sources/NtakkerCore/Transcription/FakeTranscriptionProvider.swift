// NtakkerCore/Transcription/FakeTranscriptionProvider.swift — see project-design.md §LT-3.3 / §LT-13
//
// Phase C (plan-004 rest-batch) — deterministic test-only provider, but
// living in PRODUCTION code (Sources/, NOT Tests/) so that BOTH the
// NtakkerCoreTests AND the NtakkerUITests targets can import it without the
// test-target circular-dependency that would otherwise force one target
// to depend on the other's test bundle. This placement is documented in
// design §LT-2.1 / §LT-13. DO NOT MOVE THIS FILE under `Tests/`.
//
// In the rest-batch model the fake just walks a script of canned strings:
// each call to `transcribe(samples:source:options:)` returns the next
// item from `script` (round-robin once exhausted). State is held inside
// an actor so concurrent callers from `TranscriptionManager` see the
// expected sequence without races.

import Foundation

/// In-process fake for tests. Returns canned text per source via a
/// pluggable closure; defaults to a deterministic round-robin pulled
/// from `script` (one item per call).
public actor FakeTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "fake"
    public nonisolated let displayName = "Fake"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.batch]

    private var script: [String]
    private var cursor: Int = 0
    public private(set) var receivedCallCount: Int = 0
    public private(set) var lastSamples: [Float] = []
    public private(set) var lastSource: SourceTag = .microphone

    public init(script: [String] = ["hello world"]) {
        self.script = script
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        receivedCallCount += 1
        lastSamples = samples
        lastSource = source
        guard !script.isEmpty else { return "" }
        let text = script[cursor % script.count]
        cursor += 1
        return text
    }

    /// `FakeTranscriptionProvider` is batch-only. Streaming callers
    /// should pick a streaming provider (Apple Speech in plan-005);
    /// any attempt to open a streaming session here surfaces a
    /// configuration-conflict error so the misconfiguration is loud.
    public nonisolated func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw NtakkerError.transcriptionConfigConflict(
            reason: "FakeTranscriptionProvider does not support streaming mode"
        )
    }

    public func setScript(_ s: [String]) {
        self.script = s
        self.cursor = 0
    }
}
