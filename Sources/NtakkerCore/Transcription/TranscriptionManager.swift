// NtakkerCore/Transcription/TranscriptionManager.swift — see
// docs/design/plan-004-rest-batch-transcription.md §"Phase E".
//
// Phase E (plan-004) — per-session orchestrator that buffers per-source
// audio, batch-flushes to a `TranscriptionProvider`, sanitises results,
// coalesces segments, and emits `TranscriptionEvent`s consumed by the UI
// and the sidecar writer.
//
// The manager is an actor so that all internal state — the per-source
// `SourceBuffer` map, the `SegmentCoalescer`, the in-flight task queues,
// the metrics struct, the optional sidecar writer reference — is
// serialised through one isolation domain. Public ingest methods are
// fire-and-forget: they enqueue work onto the buffers and return without
// awaiting the provider call.

import AVFoundation
import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

/// Per-session orchestrator that buffers per-source audio, batch-flushes
/// to a `TranscriptionProvider`, sanitises results, coalesces segments,
/// and emits `TranscriptionEvent`s consumed by both UI and sidecar
/// writers.
///
/// Plan-010 Phase C / Lane L-4 — conforms to `TranscriptionDispatcher`
/// so `RecordingSession` can hold a single `(any TranscriptionDispatcher)?`
/// dispatcher and route every transcription operation through the
/// protocol regardless of single- vs dual-mode (see project-design
/// §DT-4). The protocol was extracted from this manager's existing
/// public surface, so the conformance is a single-line declaration —
/// no method-body changes are needed.
public actor TranscriptionManager: TranscriptionDispatcher {

    // MARK: - Configuration

    /// Target chunk duration handed to `SourceBuffer` (matches that
    /// type's default — 2.5 s @ 16 kHz mono Float32).
    public static let chunkSeconds: Double = 2.5

    /// Period of the background drain loop. The loop wakes once every
    /// `processLoopSeconds`, pulls whatever each `SourceBuffer` has
    /// accumulated above its `minSamples` watermark, and dispatches a
    /// provider call.
    public static let processLoopSeconds: Double = 2.0

    /// On `stop()`, wait at most this long for outstanding provider
    /// calls to complete before cancelling. Guarantees `stop()` returns
    /// in bounded time even if the network is unreachable.
    public static let stopDrainSeconds: Double = 5.0

    /// Cap on concurrent provider calls per source. Two is the
    /// rest-batch v1 design choice — high enough to overlap network
    /// latency with the next chunk, low enough to bound the worst-case
    /// memory footprint of the in-flight buffers.
    public static let maxInFlightPerSource: Int = 2

    // MARK: - Dependencies

    private let provider: any TranscriptionProvider
    private let source: TranscriptionSource
    private let options: TranscriptionOptions
    private var sidecarWriter: TranscriptSidecarWriter?
    private let downsampler: AudioDownsampler
    private let logger: Logger

    /// Per-source sidecar infix (`.system` / `.microphone`) carried so
    /// `rotateSidecar(...)` reproduces the same tagged path the initial
    /// writer was opened with. Without this, the two child managers of
    /// `SourceSplitTranscriptionManager` would both rotate onto the
    /// SAME untagged path and truncate each other's sidecar (EVAL
    /// 2026-06-12 finding F24). `nil` for single-source / mixed
    /// recordings — byte-equivalent legacy naming.
    private let sidecarSourceTag: SourceTag?

    // MARK: - Pipeline selection (plan-005 Phase E)
    //
    // Two pipelines coexist on this manager:
    //   * The batch pipeline (plan-004) — `buffers`, `coalescer`,
    //     `inFlight`, `processTask`, `runProviderCall`, etc. — drives
    //     REST/batch providers (`gemini`, `noop`, `fake`).
    //   * The streaming pipeline (plan-005, in `StreamingTranscriptionPipeline`)
    //     drives streaming providers (`apple`).
    //
    // Selection is fixed at construction time based on the provider's
    // `supportedModes`. When `isStreaming == true`, every public method
    // delegates to `streamingPipeline!`; the batch state is left
    // untouched so the rest-batch path keeps working unchanged.

    private let isStreaming: Bool
    private var streamingPipeline: StreamingTranscriptionPipeline?

    // MARK: - State

    private var buffers: [SourceTag: SourceBuffer] = [:]
    private var coalescer = SegmentCoalescer()
    private var inFlight: [SourceTag: [Task<Void, Never>]] = [:]
    private var processTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var started: Bool = false
    private var stopped: Bool = false
    private var disclosureFired: Bool = false
    private var metrics = TranscriptionMetrics()

    // MARK: - Circuit breaker (F15, EVAL 2026-06-12)
    //
    // Without this, a dead provider (revoked key, sustained outage) was
    // re-called every ~2.5 s per source for the entire recording — a
    // 3-hour session fired thousands of doomed HTTPS requests, each
    // yielding its own `.error` event. The breaker pauses provider
    // calls for `circuitCooldownSeconds` after
    // `circuitFailureThreshold` consecutive failures (one degraded
    // event, then silence), lets a single probe through per cooldown,
    // and trips permanently on configuration-class errors that no
    // retry can fix.
    // The transitions live in `ProviderCircuitBreaker` (TR-10).
    private var circuit = ProviderCircuitBreaker(
        failureThreshold: TranscriptionManager.circuitFailureThreshold,
        cooldown: .seconds(TranscriptionManager.circuitCooldownSeconds)
    )
    public static let circuitFailureThreshold = 5
    public static let circuitCooldownSeconds: Double = 60

    // MARK: - Init

    public init(
        provider: any TranscriptionProvider,
        source: TranscriptionSource,
        options: TranscriptionOptions,
        downsampler: AudioDownsampler,
        sidecarWriter: TranscriptSidecarWriter?,
        logger: Logger,
        sidecarSourceTag: SourceTag? = nil
    ) {
        self.provider = provider
        self.source = source
        self.options = options
        self.downsampler = downsampler
        self.sidecarWriter = sidecarWriter
        self.logger = logger
        self.sidecarSourceTag = sidecarSourceTag

        let streamingSelected = provider.supportedModes.contains(.streaming)
        self.isStreaming = streamingSelected
        if streamingSelected {
            if #available(macOS 26.0, *) {
                self.streamingPipeline = StreamingTranscriptionPipeline(
                    provider: provider,
                    source: source,
                    options: options,
                    sidecarWriter: sidecarWriter,
                    logger: logger,
                    sidecarSourceTag: sidecarSourceTag
                )
            } else {
                // Deployment target is .v26 so this branch is
                // unreachable in practice; defer the hard error to
                // start() rather than crashing construction.
                self.streamingPipeline = nil
            }
        } else {
            self.streamingPipeline = nil
        }
    }

    // MARK: - Public surface

    /// Begin orchestration. Returns the event stream the caller must
    /// consume to receive segment / metric / disclosure / error events.
    /// Calling `start()` more than once on the same instance is a
    /// programmer error.
    public func start() async -> AsyncStream<TranscriptionEvent> {
        precondition(!started, "TranscriptionManager.start() called twice")
        started = true

        if isStreaming {
            if #available(macOS 26.0, *) {
                return await streamingPipeline!.start()
            }
        }
        return startBatchPipeline()
    }

    /// Original plan-004 batch-pipeline `start()` body, extracted so the
    /// streaming branch in `start()` can early-return cleanly.
    private func startBatchPipeline() -> AsyncStream<TranscriptionEvent> {
        for tag in source.activeSourceTags() {
            buffers[tag] = SourceBuffer(source: tag, policy: provider.chunkPolicy)
            inFlight[tag] = []
        }

        let (stream, cont) = AsyncStream.makeStream(
            of: TranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.eventsContinuation = cont

        if !disclosureFired && provider.id != "none" {
            disclosureFired = true
            cont.yield(.privacyDisclosure(providerDisplayName: provider.displayName))
        }

        // F28 / TR-11: start loading an on-device model now instead of
        // inside the first chunk's call. A failure here is only logged;
        // the first `transcribe` retries the load and reports it.
        let provider = self.provider
        let logger = self.logger
        Task {
            do {
                try await provider.prepare()
            } catch {
                logger.warning("provider warm-up failed (the first chunk will retry): \(error.localizedDescription)")
            }
        }

        processTask = Task { [weak self] in
            await self?.processLoop()
        }

        return stream
    }

    /// Append already-downsampled 16 kHz Float32 mono samples to the
    /// per-source buffer. The provider call is still dispatched off the
    /// next process-loop tick — but the buffer append itself is awaited
    /// inline rather than spawned as a fire-and-forget `Task`.
    ///
    /// EVAL 2026-06-12 (partial F1 + lost-final-sample fix): the old
    /// `Task { await buf.append(samples) }` returned before the append
    /// landed, so (a) the LAST ingest before `stop()` could be drained
    /// away before it was buffered — the final samples silently lost —
    /// and (b) two concurrent ingests raced on the `SourceBuffer` actor
    /// with no ordering guarantee. Awaiting inline removes both: the
    /// manager actor submits appends to the `SourceBuffer` actor in
    /// call order (FIFO), and a caller that `await`s `ingest` knows the
    /// samples are buffered when it returns.
    public func ingest(_ samples: [Float], from tag: SourceTag) async {
        if isStreaming {
            if #available(macOS 26.0, *) {
                await streamingPipeline?.ingest(samples, from: tag)
                return
            }
        }
        guard let buf = buffers[tag], !stopped else { return }
        await buf.append(samples)
    }

    /// Convenience for callers that have an `AlignedFrame` from the
    /// existing `HostClockAligner` tap. Picks the per-source sub-buffer
    /// matching `tag`, downsamples 48 kHz → 16 kHz, normalises Int16
    /// bytes back to Float32 [-1, 1], and forwards to `ingest(_:from:)`.
    public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async {
        let cmSample: CMSampleBuffer?
        switch tag {
        case .system:
            cmSample = frame.systemBuffer
        case .microphone:
            cmSample = frame.micBuffer
        }
        guard let sample = cmSample else { return }
        guard let pcmBuffer = Self.makePCMBuffer(from: sample) else {
            logger.warning("ingestFrame: failed to wrap CMSampleBuffer as AVAudioPCMBuffer")
            return
        }
        guard let int16Data = downsampler.convert(pcmBuffer) else { return }
        let floats = PCMConvert.int16LEToFloat(int16Data)
        await self.ingest(floats, from: tag)
    }

    /// Replace the current sidecar writer with one targeting a new
    /// audio URL — used when `RecordingSession` rotates segments
    /// (`pause-on-split`) and the in-flight transcript needs to follow
    /// the audio file. Closes the existing writer first; resets the
    /// coalescer so the new sidecar starts segment indexing at zero.
    public func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {
        if isStreaming {
            if #available(macOS 26.0, *) {
                try await streamingPipeline!.rotateSidecar(
                    toAudioURL: toAudioURL, format: format)
                return
            }
        }
        await sidecarWriter?.close()
        // F24: reproduce the same per-source tagged path the initial
        // writer used — in `--transcribe-source both` mode each child
        // manager must rotate onto ITS OWN `.system.` / `.microphone.`
        // sidecar, not the shared untagged path.
        let nextPath = SidecarPathBuilder.sidecarURL(
            forRecording: toAudioURL,
            format: format,
            sourceTag: sidecarSourceTag
        )
        // Plan-005 Phase F: this branch handles the batch pipeline's
        // sidecar rotation (the streaming branch above delegates to
        // `StreamingTranscriptionPipeline.rotateSidecar`). The batch
        // pipeline persists `.segmentAppended` + `.segmentUpdated`
        // events with id-keyed in-place rewrite, so it constructs the
        // writer with the `.batch` policy.
        sidecarWriter = try TranscriptSidecarWriter(
            outputPath: nextPath,
            format: format,
            policy: .batch
        )
        coalescer.reset()
    }

    /// Drain remaining buffered audio, wait (with a hard deadline) for
    /// outstanding provider calls, close the sidecar, and finish the
    /// event stream. Idempotent.
    public func stop() async {
        guard started, !stopped else { return }
        if isStreaming {
            if #available(macOS 26.0, *) {
                stopped = true
                await streamingPipeline!.stop()
                return
            }
        }
        stopped = true
        processTask?.cancel()
        processTask = nil

        // F18 (EVAL 2026-06-12): ONE deadline covers the whole drain —
        // final-drain provider calls AND outstanding in-flight tasks.
        // Every await below is raced against the remaining budget so a
        // hung HTTPS call (provider timeouts run 30–120 s) can never
        // wedge stop(); past the deadline the work is cancelled. The
        // sidecar close + events-stream finish then ALWAYS run.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.stopDrainSeconds))

        // Final drain of all buffers. F15: skipped when the circuit is
        // open — the provider is known-dead and the calls would only
        // burn the stop budget.
        for (tag, buf) in buffers {
            guard providerCircuitAllowsCall() else { break }
            if let samples = await buf.drain(final: true) {
                if TranscriptSanitizer.peak(samples) >= TranscriptSanitizer.silenceThreshold {
                    let finalCall = Task { [weak self] in
                        guard let self else { return }
                        await self.runProviderCall(samples: samples, source: tag, isFinal: true)
                    }
                    if await Self.awaitValue(of: finalCall, until: deadline) == false {
                        logger.warning("stop(): final-drain provider call for \(tag.rawValue) exceeded the \(Self.stopDrainSeconds)s stop budget — cancelled")
                    }
                }
            }
        }

        // Wait for outstanding tasks up to the same deadline; cancel
        // whatever has not completed by then.
        for tasks in inFlight.values {
            for t in tasks {
                _ = await Self.awaitValue(of: t, until: deadline)
            }
        }

        await sidecarWriter?.close()
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    /// Await `task.value`, giving up at `deadline`. Returns `true` when
    /// the task completed in time; cancels it and returns `false`
    /// otherwise (F18).
    ///
    /// TR-9 (EVAL 2026-10-16): this used to race inside
    /// `withTaskGroup`, but a task group only returns once EVERY child
    /// has finished — including the one awaiting `task.value`. For work
    /// that ignores cancellation (CoreML inference, a model load in
    /// progress) the "deadline" therefore never applied. Race on a
    /// single-shot continuation instead, as
    /// `RecordingSession.withTranscriptionTeardownTimeout` does: the
    /// losing waiter is simply left behind and ends with the task.
    static func awaitValue(
        of task: Task<Void, Never>,
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else {
            task.cancel()
            return false
        }
        let completedInTime: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { cont.resume(returning: value) }
            }
            let timer = Task {
                try? await Task.sleep(for: remaining)
                resume(false)
            }
            Task {
                await task.value
                resume(true)      // resume first: cancelling the timer
                timer.cancel()    // makes it call resume(false) early
            }
        }
        if !completedInTime { task.cancel() }
        return completedInTime
    }

    /// Snapshot of the current metrics — read by the UI and by the
    /// `RecordingSession` summary line at `stop()` time. `async` so the
    /// streaming-pipeline branch can hop into the pipeline actor for
    /// its snapshot without forcing the call site into a sync hop.
    public func currentMetrics() async -> TranscriptionMetrics {
        if isStreaming {
            if #available(macOS 26.0, *) {
                return await streamingPipeline!.currentMetrics()
            }
        }
        return metrics
    }

    // MARK: - Private

    private func processLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.processLoopSeconds))
            // F15: while the circuit is open, leave the buffers alone
            // (their own overflow policy bounds memory) instead of
            // draining audio into doomed provider calls.
            guard providerCircuitAllowsCall() else { continue }
            for (tag, buf) in buffers {
                guard let samples = await buf.drain(final: false) else { continue }
                let p = TranscriptSanitizer.peak(samples)
                guard p >= TranscriptSanitizer.silenceThreshold else { continue }
                await spawnProviderCall(samples: samples, source: tag)
            }
        }
    }

    /// F15: true when the provider may be called. A finished cooldown
    /// moves the breaker half-open (TR-10).
    private func providerCircuitAllowsCall() -> Bool {
        circuit.allowsCall(at: .now)
    }

    /// F15: classify errors no retry can fix — these trip the breaker
    /// permanently for the remainder of the session.
    private static func isConfigClassError(_ error: Error) -> Bool {
        guard let ntakkerError = error as? NtakkerError else { return false }
        switch ntakkerError {
        case .transcriptionApiKeyMissing,
             .transcriptionConfigConflict,
             .transcriptionPermissionDenied:
            return true
        default:
            return false
        }
    }

    private func spawnProviderCall(samples: [Float], source: SourceTag) async {
        var queue = inFlight[source] ?? []
        queue = queue.filter { !$0.isCancelled }
        while queue.count >= Self.maxInFlightPerSource {
            let head = queue.removeFirst()
            // Re-publish the pruned queue so concurrent `inFlight`
            // reads see a coherent state during the await.
            inFlight[source] = queue
            await head.value
            // Refresh after the await — another spawn may have appended
            // while we were suspended.
            queue = (inFlight[source] ?? []).filter { !$0.isCancelled }
        }
        let t = Task { [weak self] in
            guard let self else { return }
            await self.runProviderCall(samples: samples, source: source, isFinal: false)
        }
        queue.append(t)
        inFlight[source] = queue
    }

    private func runProviderCall(samples: [Float], source: SourceTag, isFinal: Bool) async {
        let started = Date()
        let durationSec = Double(samples.count) / 16_000.0
        do {
            let raw = try await provider.transcribe(
                samples: samples,
                source: source,
                options: options
            )
            // TR-7: pass the chunk level so a clearly voiced "yeah" /
            // "ok" survives while the same word on a near-silent chunk is
            // still treated as a hallucination.
            let cleaned = TranscriptSanitizer.clean(raw, chunkPeak: TranscriptSanitizer.peak(samples))
            metrics.chunksSent += 1
            metrics.billableSeconds += durationSec
            metrics.lastRttMs = Int(Date().timeIntervalSince(started) * 1_000)
            eventsContinuation?.yield(.metricsTick(metrics: metrics))

            guard !cleaned.isEmpty else { return }

            let result = coalescer.merge(text: cleaned, source: source, at: Date())
            switch result {
            case .appended(let idx):
                let seg = coalescer.segments[idx]
                let event: TranscriptionEvent = .segmentUpdated(index: idx, segment: seg)
                eventsContinuation?.yield(event)
                await sidecarWriter?.write(event)
            case .created(let idx):
                let seg = coalescer.segments[idx]
                let event: TranscriptionEvent = .segmentAppended(index: idx, segment: seg)
                eventsContinuation?.yield(event)
                await sidecarWriter?.write(event)
            }
            // F15: a successful round-trip closes the breaker.
            circuit.recordSuccess()
        } catch {
            metrics.errorCount += 1
            eventsContinuation?.yield(.error(detail: error.localizedDescription))
            logger.warning("provider call failed: \(error.localizedDescription)")

            // F15: escalate repeated failures instead of hammering a
            // dead provider for the rest of the recording.
            switch circuit.recordFailure(configurationError: Self.isConfigClassError(error), at: .now) {
            case .trippedPermanently:
                eventsContinuation?.yield(.error(detail: "transcription disabled for the remainder of the recording — provider configuration error: \(error.localizedDescription)"))
                logger.error("transcription circuit tripped permanently (configuration-class error)")
            case .opened:
                eventsContinuation?.yield(.error(detail: "transcription degraded — pausing provider calls for \(Int(Self.circuitCooldownSeconds)) s after \(Self.circuitFailureThreshold) consecutive failures"))
                logger.warning("transcription circuit opened for \(Self.circuitCooldownSeconds)s")
            case .reopened:
                // TR-10: the probe failed. No new degraded event — the
                // first one still stands.
                logger.warning("transcription circuit re-opened for \(Self.circuitCooldownSeconds)s after a failed probe")
            case .none:
                break
            }
        }
    }

    // MARK: - PCM helpers

    /// Wrap a `CMSampleBuffer` (Float32, non-interleaved, as produced
    /// by the capture stack) into an `AVAudioPCMBuffer` for
    /// `AudioDownsampler.convert(_:)`. Returns `nil` if the sample
    /// buffer cannot be reinterpreted in that shape.
    private static func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var streamDesc = asbd.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &streamDesc) else {
            return nil
        }
        let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard numFrames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: numFrames)
        else { return nil }
        pcm.frameLength = numFrames

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        // Non-interleaved Float32: per-channel pointers.
        guard let channelData = pcm.floatChannelData else { return nil }
        let channelCount = Int(avFormat.channelCount)
        let bytesPerChannel = Int(numFrames) * MemoryLayout<Float>.size
        for ch in 0..<channelCount {
            let src = dataPointer.advanced(by: ch * bytesPerChannel)
            memcpy(channelData[ch], src, bytesPerChannel)
        }
        return pcm
    }

    // F32 (EVAL 2026-06-12): the former scalar `int16BytesToFloat`
    // helper moved to the shared vDSP-backed `PCMConvert` utility.
}

// MARK: - TranscriptionSource → SourceTag routing

extension TranscriptionSource {
    /// Which `SourceTag` buffers this routing should produce. Mirrors
    /// the convention `TranscriptionDriver` already uses for `.mixed`
    /// (single chunk labelled `.system`, since the post-aligner mixed
    /// signal is materialised on the system side of the bus).
    /// `internal` (rather than `fileprivate`) since plan-005 Phase E so
    /// `StreamingTranscriptionPipeline` (a sibling file in the same
    /// module) can route per-source ingests off this same mapping.
    internal func activeSourceTags() -> [SourceTag] {
        switch self {
        case .system:
            return [.system]
        case .mic:
            return [.microphone]
        case .mixed:
            return [.system]
        case .both:
            return [.system, .microphone]
        }
    }
}
