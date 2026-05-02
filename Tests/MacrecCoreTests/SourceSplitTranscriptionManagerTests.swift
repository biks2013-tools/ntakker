import Testing
import Foundation
import AVFoundation
import Logging
@testable import MacrecCore

@Suite("SourceSplitTranscriptionManager basic surface (Phase C1)")
struct SourceSplitTranscriptionManagerTests {

    /// Construct two NoOp-backed children for routing tests. The
    /// children never call `start()` here — we only exercise the
    /// routing surface, so the inner state never advances past init.
    private func makeChildren() throws -> (TranscriptionManager, TranscriptionManager) {
        let opts = TranscriptionOptions(
            providerId: "none",
            apiKey: nil,
            modelId: nil,
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let downsampler = try AudioDownsampler(inputFormat: inputFormat)
        let logger = Logger(label: "test")
        let sys = TranscriptionManager(
            provider: NoOpTranscriptionProvider(),
            source: .system,
            options: opts,
            downsampler: downsampler,
            sidecarWriter: nil,
            logger: logger
        )
        let mic = TranscriptionManager(
            provider: NoOpTranscriptionProvider(),
            source: .mic,
            options: opts,
            downsampler: downsampler,
            sidecarWriter: nil,
            logger: logger
        )
        return (sys, mic)
    }

    @Test("conforms to TranscriptionDispatcher")
    func conformsToProtocol() throws {
        let (sys, mic) = try makeChildren()
        let mgr = SourceSplitTranscriptionManager(systemManager: sys, microphoneManager: mic)
        #expect((mgr as Any) is any TranscriptionDispatcher)
    }

    @Test("ingest routes by SourceTag — system goes to system manager")
    func ingestRoutesSystem() async throws {
        let (sys, mic) = try makeChildren()
        let mgr = SourceSplitTranscriptionManager(systemManager: sys, microphoneManager: mic)
        await mgr.ingest([1.0, 2.0], from: .system)
        let counts = await mgr.testInternalIngestCounts()
        #expect(counts.system == 1)
        #expect(counts.microphone == 0)
    }

    @Test("ingest routes by SourceTag — microphone goes to microphone manager")
    func ingestRoutesMicrophone() async throws {
        let (sys, mic) = try makeChildren()
        let mgr = SourceSplitTranscriptionManager(systemManager: sys, microphoneManager: mic)
        await mgr.ingest([1.0], from: .microphone)
        let counts = await mgr.testInternalIngestCounts()
        #expect(counts.system == 0)
        #expect(counts.microphone == 1)
    }
}

@Suite("TranscriptionMetrics.merge (Phase C1)")
struct TranscriptionMetricsMergeTests {

    @Test("merges counters by sum, lastRttMs by max")
    func merge() {
        var a = TranscriptionMetrics()
        a.chunksSent = 3; a.billableSeconds = 1.5; a.errorCount = 1; a.bufferOverflowCount = 0; a.lastRttMs = 100
        var b = TranscriptionMetrics()
        b.chunksSent = 5; b.billableSeconds = 2.0; b.errorCount = 2; b.bufferOverflowCount = 1; b.lastRttMs = 250
        let m = TranscriptionMetrics.merge([a, b])
        #expect(m.chunksSent == 8)
        #expect(m.billableSeconds == 3.5)
        #expect(m.errorCount == 3)
        #expect(m.bufferOverflowCount == 1)
        #expect(m.lastRttMs == 250)
    }

    @Test("empty list returns zero-valued metrics")
    func mergeEmpty() {
        let m = TranscriptionMetrics.merge([])
        #expect(m.chunksSent == 0)
        #expect(m.billableSeconds == 0)
        #expect(m.lastRttMs == 0)
    }
}
