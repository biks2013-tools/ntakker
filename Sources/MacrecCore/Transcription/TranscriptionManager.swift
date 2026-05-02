// MacrecCore/Transcription/TranscriptionManager.swift — see
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

    // MARK: - Init

    public init(
        provider: any TranscriptionProvider,
        source: TranscriptionSource,
        options: TranscriptionOptions,
        downsampler: AudioDownsampler,
        sidecarWriter: TranscriptSidecarWriter?,
        logger: Logger
    ) {
        self.provider = provider
        self.source = source
        self.options = options
        self.downsampler = downsampler
        self.sidecarWriter = sidecarWriter
        self.logger = logger

        let streamingSelected = provider.supportedModes.contains(.streaming)
        self.isStreaming = streamingSelected
        if streamingSelected {
            if #available(macOS 26.0, *) {
                self.streamingPipeline = StreamingTranscriptionPipeline(
                    provider: provider,
                    source: source,
                    options: options,
                    sidecarWriter: sidecarWriter,
                    logger: logger
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
            buffers[tag] = SourceBuffer(source: tag)
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

        processTask = Task { [weak self] in
            await self?.processLoop()
        }

        return stream
    }

    /// Append already-downsampled 16 kHz Float32 mono samples to the
    /// per-source buffer. Fire-and-forget: returns immediately; the
    /// provider call is dispatched off the next process-loop tick.
    public func ingest(_ samples: [Float], from tag: SourceTag) {
        if isStreaming {
            if #available(macOS 26.0, *) {
                Task { [streamingPipeline] in
                    await streamingPipeline?.ingest(samples, from: tag)
                }
                return
            }
        }
        guard let buf = buffers[tag], !stopped else { return }
        Task { await buf.append(samples) }
    }

    /// Convenience for callers that have an `AlignedFrame` from the
    /// existing `HostClockAligner` tap. Picks the per-source sub-buffer
    /// matching `tag`, downsamples 48 kHz → 16 kHz, normalises Int16
    /// bytes back to Float32 [-1, 1], and forwards to `ingest(_:from:)`.
    public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) {
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
        let floats = Self.int16BytesToFloat(int16Data)
        self.ingest(floats, from: tag)
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
        let nextPath = SidecarPathBuilder.sidecarURL(
            forRecording: toAudioURL,
            format: format
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

        // Final drain of all buffers.
        for (tag, buf) in buffers {
            if let samples = await buf.drain(final: true) {
                if TranscriptSanitizer.peak(samples) >= TranscriptSanitizer.silenceThreshold {
                    await runProviderCall(samples: samples, source: tag, isFinal: true)
                }
            }
        }

        // Wait for outstanding tasks up to stopDrainSeconds.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.stopDrainSeconds))
        for tasks in inFlight.values {
            for t in tasks {
                if ContinuousClock.now < deadline {
                    await t.value
                } else {
                    t.cancel()
                }
            }
        }

        await sidecarWriter?.close()
        eventsContinuation?.finish()
        eventsContinuation = nil
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
            for (tag, buf) in buffers {
                guard let samples = await buf.drain(final: false) else { continue }
                let p = TranscriptSanitizer.peak(samples)
                guard p >= TranscriptSanitizer.silenceThreshold else { continue }
                await spawnProviderCall(samples: samples, source: tag)
            }
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
            let cleaned = TranscriptSanitizer.clean(raw)
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
        } catch {
            metrics.errorCount += 1
            eventsContinuation?.yield(.error(detail: error.localizedDescription))
            logger.warning("provider call failed: \(error.localizedDescription)")
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

    /// Convert `Data` of little-endian Int16 samples (the output of
    /// `AudioDownsampler.convert(_:)`) into `[Float]` in `[-1, 1]`.
    private static func int16BytesToFloat(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / 32_768.0
            for i in 0..<count {
                floats[i] = Float(base[i]) * scale
            }
        }
        return floats
    }
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
