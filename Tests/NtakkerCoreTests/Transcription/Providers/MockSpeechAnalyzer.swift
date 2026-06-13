// Tests/NtakkerCoreTests/Transcription/Providers/MockSpeechAnalyzer.swift
// — see docs/design/plan-005-apple-speech-streaming.md §"Phase B".
//
// Test double for `SpeechAnalyzerAdapter`. Used by every Phase D test
// (and any later phase test that drives `AppleSpeechTranscriptionProvider`)
// so the test suite never touches `Speech.framework` directly.
//
// Behaviour:
//   * `ingest(_:)` records the cumulative sample count in
//     `ingestedSampleCount`. Sample contents are intentionally NOT
//     retained — tests that need byte-level fidelity should add a
//     dedicated capture array on a subclass.
//   * `finalizeAndFinish()` flips `finalizeCalled` and closes the
//     `results` stream so any consumer awaiting `for await ...` exits.
//   * `push(_:)` is the test API for injecting canned
//     `TranscriptionResult` values into the stream — public so test
//     files in `NtakkerCoreTests` can call it directly.
//
// `@unchecked Sendable` because `NSLock` provides the synchronisation
// the compiler can't prove on its own.

import Foundation
@testable import NtakkerCore

public final class MockSpeechAnalyzer: SpeechAnalyzerAdapter, @unchecked Sendable {
    public let results: AsyncStream<TranscriptionResult>
    private let resultsContinuation: AsyncStream<TranscriptionResult>.Continuation
    private let lock = NSLock()
    private var _ingestedSampleCount: Int = 0
    private var _finalizeCalled: Bool = false

    public var ingestedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _ingestedSampleCount
    }

    public var finalizeCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _finalizeCalled
    }

    public init() {
        let (s, c) = AsyncStream<TranscriptionResult>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.results = s
        self.resultsContinuation = c
    }

    public func ingest(_ samples: [Float]) async {
        lock.lock()
        _ingestedSampleCount += samples.count
        lock.unlock()
    }

    public func finalizeAndFinish() async {
        lock.lock()
        _finalizeCalled = true
        lock.unlock()
        resultsContinuation.finish()
    }

    /// Test API: push a canned result into the stream. Tests typically
    /// call this from the same task that drives `ingest(_:)`.
    public func push(_ result: TranscriptionResult) {
        resultsContinuation.yield(result)
    }
}
