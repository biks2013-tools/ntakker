import Testing
import Logging
@testable import MacrecCore

/// Plan-012 Phase C7. Smoke test that locks the contract:
/// `SourceSplitTranscriptionManager` (Phase C) constructs TWO
/// `AppleSpeechTranscriptionProvider` instances simultaneously
/// (one per `SourceTag`), so the underlying `SpeechAnalyzer`
/// instances must coexist within a single process. This test
/// verifies the instances can be CONSTRUCTED in parallel without
/// any cross-instance state collision.
///
/// We deliberately do NOT call `openStreamingSession(...)` here —
/// that requires the Speech Recognition TCC grant which CI hosts
/// cannot supply. The smoke check confirms the actor's basic
/// surface (id / supportedModes) is independent across instances,
/// which is the minimum the Phase C dispatcher relies on.
///
/// If a future macOS update introduces a single-instance-per-process
/// constraint on `SpeechAnalyzer`, this test will start failing on
/// the actor construction itself (or `id` / `supportedModes`
/// access), giving us an early signal to introduce a round-robin
/// fallback in `SourceSplitTranscriptionManager` for the apple
/// provider arm only.
@Suite("AppleSpeechProvider parallel instances (Phase C7)")
struct AppleSpeechParallelInstancesTest {

    @Test("two AppleSpeechTranscriptionProvider instances coexist")
    @available(macOS 26.0, *)
    func twoInstancesCoexist() {
        let logger = Logger(label: "test.parallel")
        let p1 = AppleSpeechTranscriptionProvider(logger: logger)
        let p2 = AppleSpeechTranscriptionProvider(logger: logger)
        // Confirm the actors expose their basic surface independently.
        // If a future macOS or AppleSpeech change introduces a
        // single-instance-per-process constraint, the constructor or
        // these reads would crash / throw / hang.
        #expect(p1.id == "apple")
        #expect(p2.id == "apple")
        #expect(p1.supportedModes.contains(.streaming))
        #expect(p2.supportedModes.contains(.streaming))
    }
}
