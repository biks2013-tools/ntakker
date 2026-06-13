// NtakkerUIKit/LevelMeterPublisher.swift — see project-design.md §15.7
// and plan-002-toolbar-ui.md §3 Phase D (FR-43).
//
// Façade owning per-source `LevelMeterTap`s (mic + system) and
// publishing a merged `AsyncStream<MergedLevelSample>` for the UI to
// consume. The merger keeps the most-recent sample for each source in
// a tiny ring buffer of capacity 2 (overwrite-oldest semantics) and
// emits a coalesced `MergedLevelSample` at 30 Hz so SwiftUI does not
// thrash on per-source ticks.
//
// Threading:
//   * `handleSystem(_:)` and `handleMic(_:)` are invoked on the
//     engine's capture queues. Each forwards into the respective
//     `LevelMeterTap.ingest(_:)`, which is allocation-free.
//   * The merging loop runs in an internal `Task` that consumes both
//     taps' streams concurrently. It is not isolated to any actor;
//     the `MergedLevelSample.AsyncStream.Continuation` is the only
//     mutable state and is thread-safe.
//
// The publisher's lifecycle matches `RecordingController`'s — it is
// created once when a session starts and torn down when `stop()`
// completes. `finish()` cancels the merging task and finishes the
// merged stream so all `for await` consumers unblock.

import AVFoundation
import CoreMedia
import Foundation
import Logging
// Import only the symbol we need so `Logger` keeps resolving to
// swift-log's `Logger`. (`import os` would shadow it via `os.Logger`.)
import struct os.OSAllocatedUnfairLock

/// Owns per-source `LevelMeterTap`s and re-publishes a merged
/// `AsyncStream<MergedLevelSample>` at 30 Hz.
public final class LevelMeterPublisher: @unchecked Sendable {

    /// Per-source taps, one for mic + one for system. Public so
    /// `RecordingController` can wire `source.levelTap = { [weak self]
    /// in self?.publisher.handleX($0) }` directly into the engine
    /// closures.
    public let micTap: LevelMeterTap
    public let systemTap: LevelMeterTap

    /// Merged 30 Hz stream of `MergedLevelSample`s. Each emission
    /// carries the most-recent sample for each source (or `nil` if
    /// that source has not produced one yet).
    public let stream: AsyncStream<MergedLevelSample>

    /// 30 Hz publication interval — matches the per-source
    /// `LevelMeterTap.coalescingIntervalSeconds`.
    public let publishIntervalSeconds: TimeInterval = 1.0 / 30.0

    private let continuation: AsyncStream<MergedLevelSample>.Continuation
    private let logger: Logger

    /// Lock-protected most-recent samples per source. The merging loop
    /// reads under this lock; the per-source consumer tasks write
    /// under it. `OSAllocatedUnfairLock` is the async-safe, scoped-
    /// locking primitive recommended by the strict-concurrency model
    /// (`NSLock.lock/unlock` are unavailable from async contexts in
    /// Swift 6).
    private struct LatestSamples {
        var system: LevelSample?
        var mic: LevelSample?
    }
    private let latest = OSAllocatedUnfairLock<LatestSamples>(
        initialState: LatestSamples()
    )

    /// Tasks consuming each per-source tap's stream and the merging-
    /// publisher tick task. Cancelled on `finish()`.
    private var systemConsumerTask: Task<Void, Never>?
    private var micConsumerTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?

    /// Construct the publisher with the supplied per-source tap formats.
    /// Both taps are allocated up front so the engine's capture queues
    /// can call `handleSystem` / `handleMic` immediately.
    ///
    /// - Parameters:
    ///   - micFormat: `AVAudioFormat` of the mic source's sample
    ///     buffers (Float32 non-interleaved).
    ///   - systemFormat: `AVAudioFormat` of the system source's sample
    ///     buffers (Float32 non-interleaved).
    ///   - logger: Component-scoped logger
    ///     (label `ntakker-cli.ui.levelMeter`).
    public init(
        micFormat: AVAudioFormat,
        systemFormat: AVAudioFormat,
        logger: Logger
    ) throws {
        self.logger = logger
        self.micTap = try LevelMeterTap(source: .mic, format: micFormat)
        self.systemTap = try LevelMeterTap(source: .system, format: systemFormat)
        let pair = AsyncStream.makeStream(
            of: MergedLevelSample.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
        startConsumerTasks()
        startPublishLoop()
    }

    deinit {
        finish()
    }

    /// Forward a system-source `CMSampleBuffer` into the system tap.
    /// Wired into `SCKitSystemAudioSource.levelTap` by
    /// `RecordingController` at session start.
    public func handleSystem(_ sampleBuffer: CMSampleBuffer) {
        systemTap.ingest(sampleBuffer)
    }

    /// Forward a mic-source `CMSampleBuffer` into the mic tap. Wired
    /// into `AVMicrophoneSource.levelTap` by `RecordingController` at
    /// session start.
    public func handleMic(_ sampleBuffer: CMSampleBuffer) {
        micTap.ingest(sampleBuffer)
    }

    /// Cancel all internal tasks and finish the merged stream.
    /// Idempotent — safe to call from `deinit` and from the
    /// controller's teardown.
    public func finish() {
        systemConsumerTask?.cancel()
        systemConsumerTask = nil
        micConsumerTask?.cancel()
        micConsumerTask = nil
        publishTask?.cancel()
        publishTask = nil
        continuation.finish()
    }

    // MARK: - Internals

    /// Start two background tasks, each consuming one per-source tap
    /// stream and updating the lock-protected `latest*` slot. The
    /// publisher tick task picks up whichever pair is freshest.
    private func startConsumerTasks() {
        let systemStream = systemTap.stream
        let micStream = micTap.stream

        systemConsumerTask = Task { [weak self] in
            for await sample in systemStream {
                guard let self else { return }
                if Task.isCancelled { return }
                self.latest.withLock { $0.system = sample }
            }
        }

        micConsumerTask = Task { [weak self] in
            for await sample in micStream {
                guard let self else { return }
                if Task.isCancelled { return }
                self.latest.withLock { $0.mic = sample }
            }
        }
    }

    /// Start the 30 Hz publication tick. On every tick, snapshot the
    /// `latest*` slots under the lock and yield a `MergedLevelSample`.
    private func startPublishLoop() {
        let intervalNs = UInt64(publishIntervalSeconds * 1_000_000_000)
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                guard let self else { return }
                let snapshot = self.latest.withLock { $0 }
                let merged = MergedLevelSample(
                    system: snapshot.system,
                    mic: snapshot.mic,
                    timestamp: Date().timeIntervalSince1970
                )
                self.continuation.yield(merged)
            }
        }
    }
}
