// NtakkerCore/Transcription/TranscriptionFrameFeeder.swift
//
// EVAL-2026-10-16 TR-14 / F1 (plan-022 T1): ordered, bounded fan-out
// from the aligner's synchronous live tap into the async dispatcher.
//
// The tap used to spawn one `Task` per frame per source. Those Tasks
// run in no particular order, nothing bounds how many pile up behind
// a stalled dispatcher (~46 MB/min on a network stall), and teardown
// could call `dispatcher.stop()` before the last ones had ingested.
//
// The feeder keeps one bounded `AsyncStream` per source with a single
// serial consumer, so frames reach the dispatcher in capture order.
// `finish()` closes the streams and waits until every buffered frame
// has been ingested; the caller stops the dispatcher after that.

import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

public final class TranscriptionFrameFeeder: Sendable {

    /// Frames buffered per source before the oldest is dropped. The
    /// aligner emits 100 ms frames, so 300 is 30 s of audio — far more
    /// than a healthy dispatcher ever queues, small enough that a
    /// stalled one cannot grow memory without bound.
    public static let defaultCapacity = 300

    private struct Lane: Sendable {
        let continuation: AsyncStream<AlignedFrame>.Continuation
        let consumer: Task<Void, Never>
    }

    private let lanes: [SourceTag: Lane]
    private let dropped = OSAllocatedUnfairLock<[SourceTag: Int]>(initialState: [:])
    private let logger: Logger

    /// - Parameters:
    ///   - dispatcher: receives every frame, in order, per source.
    ///   - sources: one lane per tag; each lane calls
    ///     `ingestFrame(_:from:)` with its own tag.
    ///   - capacity: frames buffered per lane before the oldest drops.
    public init(
        dispatcher: any TranscriptionDispatcher,
        sources: [SourceTag],
        capacity: Int = TranscriptionFrameFeeder.defaultCapacity,
        logger: Logger = LoggerFactory.make("ntakker-cli.transcription.feeder")
    ) {
        self.logger = logger
        var lanes: [SourceTag: Lane] = [:]
        for tag in sources where lanes[tag] == nil {
            let (stream, continuation) = AsyncStream<AlignedFrame>.makeStream(
                bufferingPolicy: .bufferingNewest(capacity)
            )
            let consumer = Task {
                for await frame in stream {
                    await dispatcher.ingestFrame(frame, from: tag)
                }
            }
            lanes[tag] = Lane(continuation: continuation, consumer: consumer)
        }
        self.lanes = lanes
    }

    /// Enqueue a frame for `tag`. Synchronous and non-blocking; safe to
    /// call from the aligner's emission thread. A full lane drops its
    /// oldest frame.
    public func feed(_ frame: AlignedFrame, to tag: SourceTag) {
        guard let lane = lanes[tag] else { return }
        if case .dropped = lane.continuation.yield(frame) {
            let total = dropped.withLock { counts -> Int in
                counts[tag, default: 0] += 1
                return counts[tag]!
            }
            // First drop, then once per ~10 s of dropped audio.
            if total == 1 || total.isMultiple(of: 100) {
                logger.warning("transcription feeder: dispatcher is behind; dropped \(total) frame(s) for \(tag.rawValue)")
            }
        }
    }

    /// Frames dropped so far for `tag` because its lane was full.
    public func droppedFrames(for tag: SourceTag) -> Int {
        dropped.withLock { $0[tag, default: 0] }
    }

    /// Close every lane and wait until each consumer has ingested the
    /// frames already buffered. Frames fed after this are ignored.
    public func finish() async {
        for lane in lanes.values { lane.continuation.finish() }
        for lane in lanes.values { _ = await lane.consumer.value }
    }
}
