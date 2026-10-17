import CoreMedia
import Foundation
import Testing
@testable import NtakkerCore

/// EVAL-2026-10-16 TR-14 / F1 (plan-022 T1): frames reach the
/// dispatcher in order, `finish()` waits for every buffered frame, and
/// a stalled dispatcher cannot grow the buffer without bound.
@Suite("TranscriptionFrameFeeder")
struct TranscriptionFrameFeederTests {

    private actor RecordingDispatcher: TranscriptionDispatcher {
        private(set) var received: [SourceTag: [Int64]] = [:]
        private let delay: Duration
        private var gate: CheckedContinuation<Void, Never>?
        private var gated: Bool

        init(delay: Duration = .zero, gated: Bool = false) {
            self.delay = delay
            self.gated = gated
        }

        func open() {
            gated = false
            gate?.resume()
            gate = nil
        }

        func start() async throws -> AsyncStream<TranscriptionEvent> { AsyncStream { $0.finish() } }
        func ingest(_ samples: [Float], from tag: SourceTag) async {}
        func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async {
            if gated {
                await withCheckedContinuation { gate = $0 }
            }
            if delay > .zero { try? await Task.sleep(for: delay) }
            received[tag, default: []].append(frame.pts.value)
        }
        func stop() async {}
        func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {}
        func currentMetrics() async -> TranscriptionMetrics { TranscriptionMetrics() }
    }

    private func frame(_ i: Int64) -> AlignedFrame {
        AlignedFrame(
            pts: CMTime(value: i, timescale: 10),
            duration: CMTime(value: 1, timescale: 10),
            systemBuffer: nil,
            micBuffer: nil
        )
    }

    @Test("frames arrive in order per source and finish() drains them all")
    func orderedAndDrained() async {
        let dispatcher = RecordingDispatcher(delay: .milliseconds(1))
        let feeder = TranscriptionFrameFeeder(dispatcher: dispatcher, sources: [.system, .microphone])
        for i in 0..<50 {
            feeder.feed(frame(Int64(i)), to: .system)
            feeder.feed(frame(Int64(i)), to: .microphone)
        }
        await feeder.finish()

        let received = await dispatcher.received
        #expect(received[.system] == Array(0..<50))
        #expect(received[.microphone] == Array(0..<50))
    }

    @Test("a stalled dispatcher drops the oldest frames beyond the capacity")
    func boundedUnderStall() async {
        let dispatcher = RecordingDispatcher(gated: true)
        let feeder = TranscriptionFrameFeeder(dispatcher: dispatcher, sources: [.system], capacity: 10)
        feeder.feed(frame(0), to: .system)
        // Let the consumer take frame 0 and block on the gate.
        try? await Task.sleep(for: .milliseconds(50))
        for i in 1...30 { feeder.feed(frame(Int64(i)), to: .system) }
        #expect(feeder.droppedFrames(for: .system) == 20)

        await dispatcher.open()
        await feeder.finish()
        let received = await dispatcher.received[.system] ?? []
        #expect(received == [0] + Array(21...30), "the newest 10 survive, in order")
    }

    @Test("a source without a lane is ignored")
    func unknownSourceIgnored() async {
        let dispatcher = RecordingDispatcher()
        let feeder = TranscriptionFrameFeeder(dispatcher: dispatcher, sources: [.system])
        feeder.feed(frame(1), to: .microphone)
        await feeder.finish()
        #expect(await dispatcher.received.isEmpty)
    }
}
