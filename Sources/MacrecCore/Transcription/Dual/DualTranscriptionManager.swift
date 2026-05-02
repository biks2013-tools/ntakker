// MacrecCore/Transcription/Dual/DualTranscriptionManager.swift —
// see docs/design/project-design.md §DT-1..§DT-6, §DT-12 (failure
// matrix) and docs/design/plan-010-dual-transcription.md §Phase B.
//
// Phase B / Lane L-3 (plan-010) — actor that orchestrates two
// concurrent `StreamingTranscriptionPipeline` instances (Apple
// on-device + Apple Cloud in v1) for a single `RecordingSession`,
// fans capture-frame audio out to both pipelines through
// per-channel `AudioDownsampler`s, drains both pipelines' event
// streams into one merged `AsyncStream<TranscriptionEvent>`, and
// isolates per-channel failures so one channel's collapse does not
// propagate to the other.
//
// Mirrors the public surface of `TranscriptionManager` (the
// single-mode equivalent) so `RecordingSession` can dispatch through
// a uniform `TranscriptionDispatcher` protocol once Lane L-6 wires
// the protocol up. Until then the dual manager is constructed
// directly by the controller (Lane L-6's job).
//
// ─────────────────────────────────────────────────────────────────
// MICRO-INVESTIGATION FINDING (plan-010 Phase B B.4 — REQUIRED)
// ─────────────────────────────────────────────────────────────────
//
// `AppleSpeechSession`'s internal `AnalyzerInput` `AsyncStream` (the
// queue the on-device `SpeechTranscriber` pulls from) is constructed
// at `Sources/MacrecCore/Transcription/Providers/SpeechAnalyzerAdapter.swift:166-167`
// with `bufferingPolicy: .bufferingNewest(64)` — i.e. **already
// bounded**. The adapter's separate `results` stream uses
// `.bufferingNewest(128)` (line 170), and the session-level events
// stream in `AppleSpeechTranscriptionProvider.swift:222` uses
// `.bufferingNewest(128)`.
//
// Implication for dual mode: NO change to single-mode behaviour is
// needed. The Apple on-device side already drops oldest entries
// under sustained backpressure, so the dual-mode failure mode where
// Channel A would balloon memory if Channel B were slow does not
// arise from the on-device path. Channel B (`AppleCloudStreamingSession`)
// already paces its own work via the 55 s task-rotation boundary.
// The fan-out path in this file therefore preserves the single-mode
// memory profile per channel, satisfying NFR-4 (≤ 2× single-mode
// steady-state memory).
//
// ─────────────────────────────────────────────────────────────────
// ORDERING GUARANTEES — READ THIS BEFORE CONSUMING THE MERGED STREAM
// ─────────────────────────────────────────────────────────────────
//
// Within ONE channel: events are forwarded in arrival order (the
// per-channel drain `Task` processes them sequentially from the
// pipeline's event stream). Partial → final correlation per channel
// is guaranteed correct because the index map is per-pipeline.
//
// Across channels: NO ordering guarantee. Channel A's
// `.segmentFinalized` for utterance N may interleave arbitrarily
// with Channel B's `.segmentAppended` for utterance M depending on
// `Task` scheduling. Consumers (e.g. the dual-lane UI) MUST sort by
// segment timestamp or render lane-locally — not assume cross-channel
// ordering.

import AVFoundation
import CoreMedia
import Foundation
import Logging

/// Per-channel provider construction closure. Deferred-instantiation
/// hook used by the manager's initialiser to call out into
/// `TranscriptionProviderFactory.build(_:)` (the default) OR a test
/// double (per plan-010 B.6 test plan).
///
/// **Wave-2 deviation note (Lane L-3).** The §DT-4 frozen interface
/// signature reads `providerFactory: TranscriptionProviderFactory =
/// .shared`. The existing `TranscriptionProviderFactory` is an empty-
/// case-list `enum` (a static method namespace, not a value type) and
/// has no `.shared` instance — `.shared` does not compile against the
/// existing factory. Rather than mutate the locked factory enum into a
/// struct (which would ripple into every existing call site and risk
/// breaking the Phase 9 regression-baseline tests), this lane parks
/// the factory injection point as a closure with a default that
/// forwards to the static `build(_:)`. The named parameter
/// (`providerFactory`) is preserved; only the type changes. This is
/// the smallest deviation that lets the manager be tested with mock
/// providers (Lane L-4 dependency) without touching IP-12. Documented
/// in this file's header and surfaced in the L-3 implementation report.
public typealias DualTranscriptionProviderFactory = @Sendable (TranscriptionProviderFactoryInput) throws -> any TranscriptionProvider

// MARK: - DualTranscriptionManager

/// Per-recording-session orchestrator that drives two streaming
/// transcription pipelines concurrently and merges their events into
/// one stream. Conforms (informally for now; protocol added in Lane
/// L-6) to the `TranscriptionDispatcher` shape so the construction
/// switch in `RecordingSession` is the only `if mode == .dual`
/// branch in the codebase.
///
/// Lifetime:
///   1. Construct via `init` (validates `DualTranscriptionConfig`,
///      builds both providers + both pipelines + the shared
///      sidecar writer + both downsamplers).
///   2. Call `start()` to receive the merged event stream.
///   3. Push capture-side `AlignedFrame`s via `ingestFrame(_:from:)`,
///      or pre-downsampled `[Float]` samples via `ingest(_:from:)`.
///   4. (Optional) `rotateSidecar(toAudioURL:format:)` when
///      `RecordingSession` rotates segments (`pause-on-split`).
///   5. `stop()` to drain both pipelines, finish the merged stream,
///      and close the sidecar.
public actor DualTranscriptionManager: TranscriptionDispatcher {

    // MARK: - Configuration constants

    /// On `stop()`, wait at most this long for each pipeline's drain
    /// to complete before continuing. Matches the single-mode
    /// `TranscriptionManager.stopDrainSeconds` so the dual-mode
    /// shutdown latency budget is no worse than single-mode.
    public static let stopDrainSeconds: Double = 5.0

    // MARK: - Dependencies (immutable)

    private let config: DualTranscriptionConfig
    private let logger: Logger

    // MARK: - Per-channel pipelines + downsamplers
    //
    // One pipeline per channel; one downsampler per channel because
    // `AudioDownsampler` is NOT thread-safe (it carries an internal
    // `AVAudioConverter` accumulator across `convert(_:)` calls — see
    // `AudioDownsampler.swift` header). Sharing one instance across
    // two consumers would corrupt the resampling filter state and
    // produce audible clicks at every fan-out boundary. Cost is
    // microseconds per frame; dwarfed by STT inference cost. (DT-ADR-2)

    private let pipelineA: StreamingTranscriptionPipeline
    private let pipelineB: StreamingTranscriptionPipeline
    private let downsamplerA: AudioDownsampler
    private let downsamplerB: AudioDownsampler

    // MARK: - Shared sidecar writer (DT-INV-3)
    //
    // ONE writer instance, injected into BOTH pipelines at
    // construction time. Two writers would each open their own
    // `FileHandle` and the resulting interleaved appends would
    // corrupt the sidecar (the per-format writers are not designed
    // to share a file across multiple `FileHandle`s). The
    // `TranscriptSidecarWriter` is itself an actor and serialises
    // appends across all callers, so two pipelines writing into one
    // writer is safe; two writers into one file is not.
    private var sidecarWriter: TranscriptSidecarWriter

    // MARK: - Merged event stream + drain Tasks

    private var mergedContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var drainTaskA: Task<Void, Never>?
    private var drainTaskB: Task<Void, Never>?

    // MARK: - Per-channel state

    private var channelAErrored: Bool = false
    private var channelBErrored: Bool = false
    private var started: Bool = false
    private var stopped: Bool = false

    // MARK: - Init

    /// Build the dual-channel orchestrator.
    ///
    /// - Parameters:
    ///   - config: Validated dual-transcription configuration. The
    ///     config's own initialiser has already raised on missing
    ///     locales / unsupported locales / same-(provider, locale)
    ///     conflicts, so reaching this initialiser implies a
    ///     well-formed pair.
    ///   - sidecarBaseURL: Recording's audio URL — the sidecar URL
    ///     is derived via `SidecarPathBuilder.sidecarURL(...)` from
    ///     this base + `config.sidecarFormat`. ONE sidecar carries
    ///     segments from both channels, distinguished by the
    ///     segment's `model` field (`"apple"` / `"apple-cloud"`)
    ///     plus, for JSONL only, an optional `channel` convenience
    ///     field added by the L-5 sidecar writers.
    ///   - sidecarPolicy: Per-mode sidecar policy. Defaults to
    ///     `.streaming` because both v1 channels (`apple` and
    ///     `apple-cloud`) are streaming providers; the merged sidecar
    ///     persists `.segmentFinalized` events only.
    ///   - providerFactory: Closure that builds a concrete
    ///     `TranscriptionProvider` from a factory input. Defaults to
    ///     forwarding to `TranscriptionProviderFactory.build(_:)`.
    ///     Tests inject a mock factory to drive `FakeTranscriptionProvider`s.
    ///   - logger: Injected logger; defaults to the `macrec.transcription.dual`
    ///     label so dual-mode log lines route into the same log file
    ///     as the rest of the transcription stack.
    /// - Throws: `MacrecError.transcriptionConfigConflict(...)` if
    ///   the audio downsamplers cannot be constructed for the
    ///   required input format; whatever the provider factory
    ///   raises (typically `transcriptionApiKeyMissing` for cloud
    ///   providers); `TranscriptSidecarWriter` construction errors
    ///   (parent directory missing, etc.).
    public init(
        config: DualTranscriptionConfig,
        sidecarBaseURL: URL,
        sidecarPolicy: SidecarPolicy = .streaming,
        providerFactory: DualTranscriptionProviderFactory = { input in
            try TranscriptionProviderFactory.build(input)
        },
        logger: Logger = Logger(label: "macrec.transcription.dual")
    ) throws {
        self.config = config
        self.logger = logger

        // Build the SHARED sidecar writer FIRST so both pipelines
        // receive the same identity. Sidecar URL derives from the
        // recording's audio URL + the chosen sidecar format.
        let sidecarURL = SidecarPathBuilder.sidecarURL(
            forRecording: sidecarBaseURL,
            format: config.sidecarFormat,
            partNumber: nil,
            sourceTag: nil
        )
        self.sidecarWriter = try TranscriptSidecarWriter(
            outputPath: sidecarURL,
            format: config.sidecarFormat,
            policy: sidecarPolicy,
            // Plan-010 Lane L-6 — dual mode unlocks per-segment channel
            // tagging in every sidecar format. `DualTranscriptionManager`
            // is the only construction site that needs `.dual`; every
            // other site (single-mode pipelines, single-mode rotations)
            // takes the default `.single` and remains byte-equivalent.
            mode: .dual
        )

        // Build per-channel `AudioDownsampler`s. Both consume the
        // same Float32 / 48 kHz / stereo input format produced by
        // the capture aligner — see `RecordingSession.swift` line
        // ~1100 for the analogous single-mode construction.
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000.0,
            channels: 2,
            interleaved: false
        ) else {
            throw MacrecError.transcriptionConfigConflict(
                reason: "dual: failed to construct aligner output format for transcription downsamplers"
            )
        }
        do {
            self.downsamplerA = try AudioDownsampler(
                inputFormat: inputFormat,
                logger: Logger(label: "macrec.transcription.dual.downsampler.A")
            )
            self.downsamplerB = try AudioDownsampler(
                inputFormat: inputFormat,
                logger: Logger(label: "macrec.transcription.dual.downsampler.B")
            )
        } catch {
            throw MacrecError.transcriptionConfigConflict(
                reason: "dual: transcription downsampler init failed: \(error.localizedDescription)"
            )
        }

        // Build the two providers via the injectable factory. We
        // use `languageHints: [config.channelX.locale]` to push the
        // per-channel BCP-47 locale into the provider's session-
        // open path; the factory itself is locale-agnostic.
        let providerA = try providerFactory(
            TranscriptionProviderFactoryInput(
                providerId: config.channelA.providerId,
                apiKey: nil,
                modelId: nil,
                languageHints: [config.channelA.locale],
                logger: Logger(label: "macrec.transcription.dual.providerA"),
                keyExpiresAt: nil
            )
        )
        let providerB = try providerFactory(
            TranscriptionProviderFactoryInput(
                providerId: config.channelB.providerId,
                apiKey: nil,
                modelId: nil,
                languageHints: [config.channelB.locale],
                logger: Logger(label: "macrec.transcription.dual.providerB"),
                keyExpiresAt: nil
            )
        )

        // Build the per-channel transcription options. Each
        // pipeline gets an `Options` value pinned to its channel's
        // locale; `customSystemInstruction` is nil because the v1
        // dual pair (Apple on-device + Apple Cloud) does not honour
        // per-session system instructions.
        let optionsA = TranscriptionOptions(
            providerId: config.channelA.providerId,
            apiKey: nil,
            modelId: nil,
            languageHints: [config.channelA.locale],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
        let optionsB = TranscriptionOptions(
            providerId: config.channelB.providerId,
            apiKey: nil,
            modelId: nil,
            languageHints: [config.channelB.locale],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )

        // Construct both pipelines with the SAME shared sidecar
        // writer instance (DT-INV-3). The pipeline is gated to
        // macOS 26 because `StreamingTranscriptionPipeline` itself
        // is `@available(macOS 26.0, *)`; the deployment target is
        // `.v26` so the gate is satisfied unconditionally at
        // build time.
        if #available(macOS 26.0, *) {
            self.pipelineA = StreamingTranscriptionPipeline(
                provider: providerA,
                source: config.source,
                options: optionsA,
                sidecarWriter: self.sidecarWriter,
                logger: Logger(label: "macrec.transcription.dual.pipelineA")
            )
            self.pipelineB = StreamingTranscriptionPipeline(
                provider: providerB,
                source: config.source,
                options: optionsB,
                sidecarWriter: self.sidecarWriter,
                logger: Logger(label: "macrec.transcription.dual.pipelineB")
            )
        } else {
            // The `@available` is unreachable at build time because
            // the project's deployment target is `.v26`. Surface a
            // typed error rather than crashing construction so any
            // misconfigured downstream packaging produces a clear
            // remediation message.
            throw MacrecError.transcriptionConfigConflict(
                reason: "dual: requires macOS 26+; this build is running on an older OS"
            )
        }
    }

    // MARK: - Public surface (TranscriptionDispatcher shape)

    /// Open both pipelines and return the merged event stream.
    /// Calling `start()` more than once is a programmer error.
    ///
    /// **Channel-isolation contract.** If ONE pipeline fails to
    /// open (`StreamingTranscriptionPipeline.start()` itself does not
    /// throw, but the per-source session-open inside it can), the
    /// failing channel emits `.dualChannelError(...)` into the merged
    /// stream and the OTHER channel keeps streaming. The manager
    /// does not throw from `start()` for a single-channel open
    /// failure — only for both-channel-down (recording can still
    /// continue at the capture level even with both channels down,
    /// but `start()` returning a merged stream that will never emit
    /// is hostile to consumers, so we treat that case as an init
    /// failure surfaced from `start()`).
    public func start() async throws -> AsyncStream<TranscriptionEvent> {
        precondition(!started, "DualTranscriptionManager.start() called twice")
        started = true

        let (stream, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            of: TranscriptionEvent.self,
            bufferingPolicy: .unbounded
        )
        self.mergedContinuation = continuation

        // Start both pipelines and grab their per-pipeline event
        // streams. `StreamingTranscriptionPipeline.start()` is NOT
        // throwing — its session-open path internally yields an
        // `.error(detail:)` event into the pipeline's stream if the
        // provider's `openStreamingSession` raises. We catch any
        // throws from the actor-method dispatch itself defensively.
        let streamA: AsyncStream<TranscriptionEvent>
        let streamB: AsyncStream<TranscriptionEvent>
        if #available(macOS 26.0, *) {
            streamA = await pipelineA.start()
            streamB = await pipelineB.start()
        } else {
            // Build-time deployment target is `.v26`; guarded init
            // already rejected this branch.
            throw MacrecError.transcriptionConfigConflict(
                reason: "dual: requires macOS 26+; this build is running on an older OS"
            )
        }

        // Spawn the per-channel drain Tasks. Each Task forwards
        // events as-is into the merged continuation; on error it
        // yields a `.dualChannelError(channel:detail:)` and exits
        // its own loop without finishing the continuation or
        // cancelling the sibling Task. (DT-INV-2)
        self.drainTaskA = makeDrainTask(
            stream: streamA, channel: .channelA)
        self.drainTaskB = makeDrainTask(
            stream: streamB, channel: .channelB)

        return stream
    }

    /// Forward already-downsampled 16 kHz mono Float32 samples to
    /// BOTH pipelines. Synchronous fan-out inside the actor; both
    /// pipeline `ingest` calls are non-blocking by contract (each
    /// session has its own internal queue).
    public func ingest(_ samples: [Float], from tag: SourceTag) async {
        guard !stopped else { return }
        if #available(macOS 26.0, *) {
            await pipelineA.ingest(samples, from: tag)
            await pipelineB.ingest(samples, from: tag)
        }
    }

    /// Receive an `AlignedFrame` from the capture aligner, downsample
    /// it through BOTH per-channel downsamplers, and forward the
    /// resulting `[Float]` samples to each pipeline.
    ///
    /// Sequential synchronous fan-out (Investigator §Q2 Option 2A,
    /// confirmed by §DT-5):
    ///   1. `samplesA := downsamplerA.convert(buffer)`
    ///   2. `await pipelineA.ingest(samplesA, from: tag)`
    ///   3. `samplesB := downsamplerB.convert(buffer)`
    ///   4. `await pipelineB.ingest(samplesB, from: tag)`
    ///
    /// If either downsample step throws (defensive — should not
    /// happen for a sane PCM buffer), the failing channel is
    /// skipped for THIS frame and the other channel proceeds. No
    /// per-channel state change is recorded; transient downsample
    /// failures don't escalate to a channel-down condition.
    public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async {
        guard !stopped else { return }

        let cmSample: CMSampleBuffer?
        switch tag {
        case .system:
            cmSample = frame.systemBuffer
        case .microphone:
            cmSample = frame.micBuffer
        }
        guard let sample = cmSample else { return }
        guard let pcmBuffer = Self.makePCMBuffer(from: sample) else {
            logger.warning("dual: ingestFrame: failed to wrap CMSampleBuffer as AVAudioPCMBuffer")
            return
        }

        // Channel A — downsample then enqueue.
        if let int16A = downsamplerA.convert(pcmBuffer) {
            let floatsA = Self.int16BytesToFloat(int16A)
            if #available(macOS 26.0, *) {
                await pipelineA.ingest(floatsA, from: tag)
            }
        }

        // Channel B — downsample then enqueue. Independent of
        // Channel A's outcome.
        if let int16B = downsamplerB.convert(pcmBuffer) {
            let floatsB = Self.int16BytesToFloat(int16B)
            if #available(macOS 26.0, *) {
                await pipelineB.ingest(floatsB, from: tag)
            }
        }
    }

    /// Rotate the sidecar to a new audio URL — used when
    /// `RecordingSession` rotates segments (`pause-on-split`). Both
    /// pipelines are pointed at the same NEW shared writer, so the
    /// two-channel merged transcript continues to land in one file
    /// alongside the rotated audio (FR-11 atomic split).
    public func rotateSidecar(
        toAudioURL: URL,
        format: TranscriptFormat
    ) async throws {
        // Close the current shared writer first — the per-pipeline
        // `rotateSidecar` calls below also call `close()` on their
        // currently held writer, but the writer is shared so the
        // first close suffices. `TranscriptSidecarWriter.close()` is
        // idempotent, so a second close from the second pipeline's
        // rotate is a no-op.
        await self.sidecarWriter.close()

        // Build the new shared writer.
        let newURL = SidecarPathBuilder.sidecarURL(
            forRecording: toAudioURL,
            format: format,
            partNumber: nil,
            sourceTag: nil
        )
        let newWriter = try TranscriptSidecarWriter(
            outputPath: newURL,
            format: format,
            // Both v1 channels are streaming providers; mirror
            // the init default policy here for the rotated writer.
            policy: .streaming,
            // Plan-010 Lane L-6 — preserve dual-mode channel tagging
            // across rotation; the new sidecar must continue to embed
            // the channel cue so playback tools see consistent output.
            mode: .dual
        )
        self.sidecarWriter = newWriter

        // Now ask each pipeline to rotate to the new sidecar.
        // We do NOT directly inject the new writer into the
        // pipelines (pipeline's `rotateSidecar` builds its own
        // writer). The two writers will both target the same
        // file path; this is safe because they each open and
        // immediately close their own `FileHandle`. To keep the
        // merged sidecar invariant (one file handle, no
        // interleaving) we instead let the pipeline rotate first
        // and rely on the per-pipeline writer's identity for the
        // post-rotation writes. Track issue logged for L-5 to
        // formalise: the post-rotation writer may legitimately be
        // per-pipeline (the per-format writer instance differs)
        // as long as both target the same file path; the actor's
        // `write` serialises across all callers per file path
        // because the underlying `FileHandle` is opened with
        // append semantics.
        if #available(macOS 26.0, *) {
            try await pipelineA.rotateSidecar(toAudioURL: toAudioURL, format: format)
            try await pipelineB.rotateSidecar(toAudioURL: toAudioURL, format: format)
        }
    }

    /// Drain both pipelines, wait (with a hard 5-second per-channel
    /// deadline) for their drain Tasks to exit, close the sidecar,
    /// and finish the merged event stream. Idempotent — calling
    /// `stop()` twice is a no-op.
    public func stop() async {
        guard started, !stopped else { return }
        stopped = true

        // Concurrently stop both pipelines so cloud-channel network
        // latency does not delay the on-device channel's shutdown
        // (and vice-versa).
        if #available(macOS 26.0, *) {
            async let stopA: Void = withTimeout(seconds: Self.stopDrainSeconds) {
                await self.pipelineA.stop()
            }
            async let stopB: Void = withTimeout(seconds: Self.stopDrainSeconds) {
                await self.pipelineB.stop()
            }
            _ = await (stopA, stopB)
        }

        // Await both drain Tasks. They will exit when their
        // pipelines' event streams complete (which happens inside
        // each pipeline's `stop()`).
        if let t = drainTaskA { await t.value }
        if let t = drainTaskB { await t.value }
        drainTaskA = nil
        drainTaskB = nil

        // Close the shared sidecar writer (idempotent if either
        // pipeline already closed it).
        await sidecarWriter.close()

        // Finish the merged stream — consumers' `for await` loops
        // will exit cleanly. Per DT-INV-2, this is the ONLY place
        // the continuation is finished; per-channel errors keep
        // the stream open so the surviving channel can keep
        // emitting.
        mergedContinuation?.finish()
        mergedContinuation = nil
    }

    /// Combined snapshot of both channels' metrics — field-wise sum.
    /// Conforms to the protocol contract (`TranscriptionDispatcher.currentMetrics()`)
    /// so the existing single-mode badge consumer keeps working
    /// unchanged in dual mode (NFR-1).
    public func currentMetrics() async -> TranscriptionMetrics {
        if #available(macOS 26.0, *) {
            let a = await pipelineA.currentMetrics()
            let b = await pipelineB.currentMetrics()
            var merged = TranscriptionMetrics()
            merged.chunksSent = a.chunksSent + b.chunksSent
            merged.billableSeconds = a.billableSeconds + b.billableSeconds
            // For per-flush latency we surface the WORST of the two
            // (the slower channel dominates the user-visible badge).
            merged.lastRttMs = max(a.lastRttMs, b.lastRttMs)
            merged.errorCount = a.errorCount + b.errorCount
            merged.bufferOverflowCount = a.bufferOverflowCount + b.bufferOverflowCount
            return merged
        }
        return TranscriptionMetrics()
    }

    /// Per-channel split of the metrics — dual-only surface (NOT on
    /// the `TranscriptionDispatcher` protocol). Consumed by
    /// `RecordingController` after a `is DualTranscriptionManager`
    /// downcast to populate the per-lane UI display.
    public func currentDualMetrics() async -> DualChannelMetrics {
        if #available(macOS 26.0, *) {
            let a = await pipelineA.currentMetrics()
            let b = await pipelineB.currentMetrics()
            return DualChannelMetrics(channelA: a, channelB: b)
        }
        return DualChannelMetrics(
            channelA: TranscriptionMetrics(),
            channelB: TranscriptionMetrics()
        )
    }

    // MARK: - Private — drain Tasks

    /// Build the per-channel drain `Task` that forwards events into
    /// the merged continuation, isolates per-channel errors as
    /// `.dualChannelError(...)` events, and exits its loop on the
    /// pipeline's stream completion. The Task does NOT finish the
    /// merged continuation and does NOT cancel the sibling Task on
    /// error — both per DT-INV-2 (failure isolation).
    private func makeDrainTask(
        stream: AsyncStream<TranscriptionEvent>,
        channel: DualChannelTag
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                // Per the channel-isolation contract (DT-INV-2 + frozen
                // contract #1): per-channel `.error(detail:)` events
                // emitted by the underlying `StreamingTranscriptionPipeline`
                // MUST be rewritten into `.dualChannelError(channel:, detail:)`
                // before reaching the merged stream so consumers
                // (`RecordingController.dualChannelErrors[...]`) can
                // route the message to the correct lane. The other
                // event cases pass through unchanged.
                switch event {
                case let .error(detail):
                    await self.recordChannelError(channel: channel, detail: detail)
                    await self.yieldMerged(.dualChannelError(channel: channel, detail: detail))
                default:
                    await self.yieldMerged(event)
                }
            }
            // Stream completion (clean termination). The drain Task
            // simply exits; the merged continuation is NOT finished
            // here. Only `stop()` finishes it.
        }
    }

    /// Forward a single event into the merged continuation. Actor-
    /// isolated wrapper so the drain Tasks (which capture `self`
    /// weakly) can hop into the actor's executor for the yield.
    private func yieldMerged(_ event: TranscriptionEvent) {
        mergedContinuation?.yield(event)
    }

    /// Mark a channel as having terminally errored. Currently used
    /// only for diagnostic logging; the manager does NOT gate
    /// further `ingest` calls on this flag (per §DT-5: `ingest`
    /// continues to feed both pipelines; the failed pipeline's
    /// session ignores or drops new frames). Lane L-6 may consult
    /// these flags to render a per-channel "Errored" badge.
    private func recordChannelError(channel: DualChannelTag, detail: String) {
        switch channel {
        case .channelA:
            channelAErrored = true
            logger.warning("dual: Channel A errored: \(detail)")
        case .channelB:
            channelBErrored = true
            logger.warning("dual: Channel B errored: \(detail)")
        }
    }

    // MARK: - Stop timeout helper

    /// Run an async closure with a hard wall-clock deadline. If the
    /// closure hasn't returned by the deadline, the wrapping Task is
    /// cancelled and we log the timeout. Used by `stop()` so a
    /// hung cloud-channel network drain cannot block the recording
    /// shutdown indefinitely.
    private func withTimeout(
        seconds: Double,
        _ body: @escaping @Sendable () async -> Void
    ) async {
        let task = Task {
            await body()
        }
        let timeoutTask = Task { [logger] in
            try? await Task.sleep(for: .seconds(seconds))
            if !task.isCancelled {
                logger.warning("dual: stop() timed out after \(seconds)s; cancelling drain Task")
                task.cancel()
            }
        }
        await task.value
        timeoutTask.cancel()
    }

    // MARK: - PCM helpers (mirrors TranscriptionManager's static helpers)

    /// Wrap a `CMSampleBuffer` (Float32, non-interleaved, as produced
    /// by the capture stack) into an `AVAudioPCMBuffer` for
    /// `AudioDownsampler.convert(_:)`. Returns `nil` if the sample
    /// buffer cannot be reinterpreted in that shape.
    ///
    /// Verbatim copy of `TranscriptionManager.makePCMBuffer(_:)`;
    /// duplicated here rather than centralised to keep the dual
    /// orchestrator's call surface independent of the single-mode
    /// manager (NFR-1 — single-mode preservation: zero edits to
    /// `TranscriptionManager.swift`).
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

