// NtakkerCore/Capture/SoftwareAECProcessor.swift — plan-014 (v5)
//
// Stable software acoustic echo canceller. See
// `docs/design/plan-014-aec-stability.md` for the full rationale and
// the v3 / v4 history (also captured below in `// History`).
//
// v5 algorithm (per-channel NLMS with safeguards). For each mic sample
// in a buffer:
//
//   1. Read the desired reference window x using **PTS-derived** logical
//      indexing (Layer F): the window for mic sample at host time t
//      ends at the reference logical position that corresponds to t,
//      not at "the latest N reference samples received". This makes
//      the algorithm robust to mismatched buffer cadences between
//      ScreenCaptureKit and AVCaptureSession.
//
//   2. Compute y_hat = w · x and the running envelopes:
//        refEnv += α(mean(|x|²) - refEnv)  (short-term ref power)
//        micEnv += α(|d|² - micEnv)        (short-term mic power)
//      where α corresponds to a ~20 ms time constant.
//
//   3. e = d - y_hat. Update resEnv with the same time constant.
//
//   4. Soft-limit e at the knee/ceiling and write to the output buffer
//      (Layer E). The output is always limited regardless of whether
//      the gates below allow adaptation.
//
//   5. Adaptation gate (Layers A + B + C):
//        - Layer A — refRMS = √refEnv must exceed `refActivityRMSThreshold`.
//          No reference signal → no echo → skip.
//        - Layer B — micEnv ≤ refEnv · doubleTalkRatio. When mic
//          dominates ref, the user is talking and there is no real
//          echo to learn → skip.
//        - Layer C — if resEnv > micEnv has held for at least
//          `divergenceResetSamples` samples, the filter is making
//          things worse than no filter at all → reset weights to 0
//          and skip.
//
//   6. Layer D — calmer step. The NLMS update is
//        step = clamp(μ · e / (refPower + reg), ±stepMax)
//        w := (1 - leak) · w + step · x
//      with μ=0.01, reg=1e-2, stepMax=1e-3 — an order of magnitude
//      slower than v3/v4 and with a per-sample magnitude cap so a
//      single bad sample cannot blow up the weights.
//
// All hot-loop math runs through Accelerate `vDSP_dotpr`, `vDSP_svesq`,
// `vDSP_vsmul`, `vDSP_vsma`. The reference ring uses the existing
// "double-write" trick (every sample written to both `ring[p % C]`
// and `ring[(p % C) + C]`) so any L-sample window can be read
// contiguously without wrap-around branching inside the per-sample
// loop. Capacity C is `4 · filterLength` (~340 ms at 48 kHz, with
// L=4096): the window (L samples) plus a mic buffer plus the
// reference's lead over the mic (typically < 30 ms) fit with room
// to spare.
//
// Public-method threading: `feedReference` is invoked from the
// SCStream audio queue, `processMic` from the AVCaptureSession audio
// queue. Internal state is guarded by an `OSAllocatedUnfairLock`.
// `processMic` calls `onCleanedMic` synchronously on the SAME queue
// that delivered the mic buffer, matching the existing
// `AudioSource.onSampleBuffer` contract.
//
// History.
//   v1 — hand-rolled AudioBufferList layout for the cleaned-mic
//        CMSampleBuffer; tripped over `mNumberBuffers` offset.
//   v2 — Swift wrapper `AudioBufferList.allocate(maximumBuffers:)`;
//        still failed with kCMSampleBufferError_RequiredParameterMissing.
//   v3 — CMBlockBuffer-direct wrap for the cleaned mic buffer (kept
//        in v4/v5). NLMS reference window did not advance per sample
//        in the inner loop → catastrophic divergence (peaks at +10
//        dBFS). See plan-013 §11.
//   v4 — per-sample window slide + leakage + hard clip at 0.99.
//        Reduced peaks to ~ +3.7 dBFS (still bad — divergence not
//        eliminated, AAC MDCT rang on hard-clipped square-wave
//        residuals). See plan-013 §11 (last paragraph).
//   v5 — this file. Full stability rewrite per plan-014.

import Foundation
import CoreMedia
import Accelerate
import Logging
import struct os.OSAllocatedUnfairLock

public final class SoftwareAECProcessor: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        // ---- Filter shape ----

        /// Filter length in samples per channel. 4096 taps at 48 kHz =
        /// ~85 ms — covers typical laptop acoustic-echo paths plus
        /// CoreAudio output latency.
        public let filterLength: Int

        /// NLMS step size (`μ`). 0.01 by default in v5 — an order of
        /// magnitude slower than v3/v4's 0.1 to make divergence
        /// effectively impossible inside any single buffer.
        public let stepSize: Float

        /// Numerical regularisation added to the reference power
        /// before normalising. Bumped to 1e-2 in v5 (was 1e-6 in v3,
        /// 1e-3 in v4) so that a near-silent reference cannot turn
        /// the step into a five-orders-of-magnitude amplification.
        public let regularization: Float

        /// Number of channels. Each channel runs an independent
        /// NLMS filter; cross-channel echo is not modelled.
        public let channels: Int

        /// Sample rate. Both inputs MUST be sample-rate-matched (the
        /// rest of the ntakker-cli pipeline normalises everything to 48
        /// kHz; this processor inherits that invariant).
        public let sampleRate: Double

        // ---- Layer D — step magnitude cap + leakage ----

        /// Per-sample step-magnitude clamp: the NLMS update along the
        /// reference vector is bounded so that `‖step‖∞ ≤ stepMax`.
        /// 1e-3 means "no single sample can move any weight by more
        /// than 0.001 in either direction" — enough headroom for a
        /// real echo to converge over seconds, but enough discipline
        /// that no transient spike can blow the filter up.
        public let stepMax: Float

        /// Per-sample weight leakage `(1 - leak)` factor. 1e-5 ≈ ~2 s
        /// time-constant at 48 kHz — slow enough not to hurt
        /// convergence on a real echo, fast enough to bleed off
        /// stray energy.
        public let leakage: Float

        // ---- Layers A / B / C — gating ----

        /// Layer A — minimum reference RMS for adaptation. Linear
        /// amplitude. 3e-3 ≈ -50 dBFS — well below normal reference
        /// levels (-15 to -25 dBFS) so the gate only kicks in during
        /// genuine system silence.
        public let referenceActivityRMSThreshold: Float

        /// Layer B — double-talk ratio. Adaptation freezes when
        /// `micEnv > refEnv * doubleTalkRatio`. 4.0 means "skip when
        /// the mic is more than 12 dB above the ref" — a reliable
        /// sign that the user is talking and there is no real echo
        /// to learn from this sample.
        public let doubleTalkRatio: Float

        /// Layer C — sustained-violation duration before the
        /// divergence reset fires. 0.05 s = 50 ms. Long enough to
        /// reject a single noisy sample, short enough that a real
        /// runaway is contained before it reaches audible levels.
        public let divergenceResetHoldSec: Double

        /// Envelope time constant in seconds. Used for refEnv,
        /// micEnv, resEnv. 0.02 = 20 ms — fast enough to track
        /// sentence-level dynamics, slow enough to ignore single
        /// samples.
        public let envelopeTimeConstantSec: Double

        // ---- Layer E — soft limiter ----

        /// Soft-limit ceiling: |output| never exceeds this value.
        /// Default 0.95 — ~ -0.45 dBFS, with enough headroom under 1.0
        /// that even AAC's MDCT overshoot can't push the decoded
        /// output past 0 dBFS.
        public let limiterCeiling: Float

        /// Soft-limit knee: below this amplitude the output is
        /// pass-through; between knee and ceiling, a smooth quadratic
        /// roll-off applies. 0.7 ≈ -3 dBFS keeps normal speech
        /// untouched.
        public let limiterKnee: Float

        public init(
            filterLength: Int = 4096,
            stepSize: Float = 0.01,
            regularization: Float = 1e-2,
            channels: Int = 2,
            sampleRate: Double = 48_000,
            stepMax: Float = 1e-3,
            leakage: Float = 1e-5,
            referenceActivityRMSThreshold: Float = 3e-3,
            doubleTalkRatio: Float = 4.0,
            divergenceResetHoldSec: Double = 0.05,
            envelopeTimeConstantSec: Double = 0.02,
            limiterCeiling: Float = 0.95,
            limiterKnee: Float = 0.7
        ) {
            precondition(filterLength > 0, "filterLength must be > 0")
            precondition(stepSize > 0 && stepSize < 2, "stepSize must be in (0, 2)")
            precondition(regularization > 0, "regularization must be > 0")
            precondition(channels >= 1, "channels must be >= 1")
            precondition(stepMax > 0, "stepMax must be > 0")
            precondition(leakage >= 0 && leakage < 1, "leakage must be in [0, 1)")
            precondition(referenceActivityRMSThreshold >= 0, "ref-activity threshold must be >= 0")
            precondition(doubleTalkRatio > 0, "doubleTalkRatio must be > 0")
            precondition(divergenceResetHoldSec >= 0, "divergence hold must be >= 0")
            precondition(envelopeTimeConstantSec > 0, "envelope tc must be > 0")
            precondition(limiterCeiling > 0 && limiterCeiling <= 1, "limiterCeiling must be in (0, 1]")
            precondition(limiterKnee >= 0 && limiterKnee < limiterCeiling, "limiterKnee must be in [0, limiterCeiling)")
            self.filterLength = filterLength
            self.stepSize = stepSize
            self.regularization = regularization
            self.channels = channels
            self.sampleRate = sampleRate
            self.stepMax = stepMax
            self.leakage = leakage
            self.referenceActivityRMSThreshold = referenceActivityRMSThreshold
            self.doubleTalkRatio = doubleTalkRatio
            self.divergenceResetHoldSec = divergenceResetHoldSec
            self.envelopeTimeConstantSec = envelopeTimeConstantSec
            self.limiterCeiling = limiterCeiling
            self.limiterKnee = limiterKnee
        }
    }

    // MARK: - State

    private let config: Configuration
    private let logger: Logging.Logger

    // ---- Reference side: written by `feedReference` (SCStream queue),
    // ---- read by `processMic` (mic queue). Guarded by `refLock`.

    /// Reference ring buffers with the double-write trick. One ring per
    /// channel, plus — when `channels > 1` — one more at index
    /// `channels` holding the mean of the channels (the mono reference
    /// used for an upmixed mono mic, CAP-6). Each ring is
    /// `2 · ringCapacity` Float32s long; logical position `p` writes to
    /// both `ring[p % C]` and `ring[(p % C) + C]`, so any span of up to
    /// `C` samples can be read with one contiguous copy.
    private var refRing: [[Float]]

    /// Capacity of the (un-mirrored) ring per channel = `4 ·
    /// filterLength`. The ring array itself is `2 · ringCapacity` long.
    /// A mic buffer needs the `filterLength - 1` samples before it plus
    /// its own span, and the reference may lead the mic by tens of ms,
    /// so `2 · filterLength` left too little headroom once the window
    /// was corrected to end at the mic sample (EVAL 2026-10-16).
    private let ringCapacity: Int

    /// Per-ring logical index ONE PAST the most-recently-written
    /// reference sample. Equivalently, the next position to write to.
    private var refLastWriteEnd: [Int]

    /// PTS anchor — set on the very first `feedReference` call;
    /// shared across channels. Logical index 0 corresponds to host
    /// time `refAnchorPTS`. All later PTS-to-logical conversions key
    /// off this anchor.
    private var refAnchorPTS: CMTime?

    /// Reference-side counters.
    private var refStats = AECStatistics()

    /// CAP-11 (EVAL 2026-10-16): held only while the reference ring is
    /// written or a span of it is copied out — never for the NLMS
    /// loop — so the SCStream audio thread no longer waits 2–4 ms
    /// behind a mic buffer.
    private let refLock = OSAllocatedUnfairLock<Void>(initialState: ())

    // ---- Filter side: owned by `processMic`, which runs serially on
    // ---- the mic queue. Guarded by `filterLock`, which only
    // ---- `snapshotStatistics` contends for.

    /// Per-filter adaptive weights. Filter `f` serves mic channel `f`;
    /// in mono mode only filter 0 runs. Each is `filterLength` long.
    private var weights: [[Float]]

    /// Per-filter envelopes — exponential moving averages of |x|²,
    /// |d|², |e|² respectively. Used by Layers A / B / C.
    private var refEnv: [Float]
    private var micEnv: [Float]
    private var resEnv: [Float]

    /// Per-filter running counter of consecutive samples with
    /// `resEnv > micEnv`. When it exceeds `divergenceResetSamples`,
    /// the weights are reset to zero. Reset to 0 every time the
    /// inequality fails.
    private var divergentSampleCount: [Int]

    /// Mic-side counters.
    private var micStats = AECStatistics()

    /// C2 (EVAL 2026-06-12): reusable per-channel output scratch for
    /// the cleaned signal. `processMic` runs serially on the single mic
    /// capture queue, so reusing one buffer across calls is race-free
    /// and removes a fresh 2-D `[[Float]]` allocation (~400 KB/s) from
    /// the hot path. Grown on demand; never shrunk. The move-out /
    /// move-back dance in `processMic` keeps it uniquely referenced so
    /// the per-sample writes stay in-place (no copy-on-write).
    private var cleanedScratch: [[Float]] = []

    /// CAP-11: per-filter linear copy of the reference span one mic
    /// buffer needs (`filterLength - 1 + frameCount` samples), taken
    /// under `refLock` and read by the NLMS loop without it. Same
    /// move-out / move-back reuse as `cleanedScratch`.
    private var refSpanScratch: [[Float]] = []

    private let filterLock = OSAllocatedUnfairLock<Void>(initialState: ())

    /// One-shot diagnostic flags — first reference buffer seen,
    /// first mic buffer processed.
    private let firstReferenceLogged = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let firstMicLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Constants derived from `config`. Computed once.
    private let envCoeff: Float                  // exp-MA coefficient α
    private let divergenceResetSamples: Int      // Layer C samples threshold

    /// CAP-3: the window energy is updated incrementally per sample
    /// (add the entering sample², subtract the leaving one) and
    /// recomputed exactly this often to bound Float drift.
    private static let energyRecomputeInterval = 512

    // MARK: - Public surface

    /// Set by the orchestrator before `processMic` is invoked. Called
    /// on the SAME queue that delivered the mic buffer (the
    /// `ntakker-cli.capture.mic` `userInteractive` queue), with a
    /// `CaptureBuffer(source: .microphone, …)` carrying a freshly
    /// constructed CMSampleBuffer of the cleaned signal.
    public var onCleanedMic: ((CaptureBuffer) -> Void)?

    /// Snapshot of run-time statistics. Useful for tests, logging,
    /// and the level-meter UI.
    public struct AECStatistics: Sendable {
        public var samplesProcessed: UInt64 = 0
        public var samplesPassedThrough: UInt64 = 0   // ref window unavailable
        public var updatesSkippedRefSilence: UInt64 = 0  // Layer A
        public var updatesSkippedDoubleTalk: UInt64 = 0  // Layer B
        public var divergenceResets: UInt64 = 0          // Layer C
        public var refBuffersReceived: UInt64 = 0
        public var refBuffersDroppedOutOfOrder: UInt64 = 0
        public var refGapsZeroFilled: UInt64 = 0
        /// Mic buffers processed with one filter because every mic
        /// channel carried the same samples (an upmixed mono mic).
        public var monoMicBuffers: UInt64 = 0
    }

    public func snapshotStatistics() -> AECStatistics {
        var out = filterLock.withLockUnchecked { micStats }
        let ref = refLock.withLockUnchecked { refStats }
        out.refBuffersReceived = ref.refBuffersReceived
        out.refBuffersDroppedOutOfOrder = ref.refBuffersDroppedOutOfOrder
        out.refGapsZeroFilled = ref.refGapsZeroFilled
        return out
    }

    public init(config: Configuration = Configuration(), logger: Logging.Logger? = nil) {
        self.config = config
        self.logger = logger ?? LoggerFactory.make("ntakker-cli.aec")
        self.ringCapacity = config.filterLength * 4
        let rings = config.channels > 1 ? config.channels + 1 : 1
        self.weights = Array(
            repeating: Array(repeating: 0, count: config.filterLength),
            count: config.channels
        )
        self.refRing = Array(
            repeating: Array(repeating: 0, count: ringCapacity * 2),
            count: rings
        )
        self.refLastWriteEnd = Array(repeating: 0, count: rings)
        self.refEnv = Array(repeating: 0, count: config.channels)
        self.micEnv = Array(repeating: 0, count: config.channels)
        self.resEnv = Array(repeating: 0, count: config.channels)
        self.divergentSampleCount = Array(repeating: 0, count: config.channels)

        // 1-pole exp-MA: α = 1 - exp(-T/τ) where T = 1/sr, τ = tc.
        let alpha = Float(1.0 - exp(-1.0 / (config.sampleRate * config.envelopeTimeConstantSec)))
        self.envCoeff = alpha

        self.divergenceResetSamples = max(1, Int(config.divergenceResetHoldSec * config.sampleRate))

        self.logger.info(
            """
            SoftwareAECProcessor v5 (plan-014: PTS-aligned NLMS + ref-activity gate \
            + double-talk detector + divergence reset + soft limiter) initialised: \
            filterLength=\(config.filterLength) (~\(Int(Double(config.filterLength) / config.sampleRate * 1000)) ms) \
            μ=\(config.stepSize) reg=\(config.regularization) stepMax=\(config.stepMax) leak=\(config.leakage) \
            refActivityRMS=\(config.referenceActivityRMSThreshold) doubleTalkRatio=\(config.doubleTalkRatio) \
            divergenceHold=\(Int(config.divergenceResetHoldSec * 1000)) ms envelopeTC=\(Int(config.envelopeTimeConstantSec * 1000)) ms \
            limiterKnee=\(config.limiterKnee) limiterCeiling=\(config.limiterCeiling) \
            channels=\(config.channels) sampleRate=\(config.sampleRate) ringCapacity=\(ringCapacity)
            """
        )
    }

    // MARK: - Reference ingest (Layer F — PTS-aligned)

    /// Feed a system-audio reference buffer. Writes the buffer's
    /// samples into the ring at logical positions derived from the
    /// buffer's PTS. The buffer's `presentationTimeStamp` is expected
    /// to live in the host-clock domain (per `CaptureBuffer`'s
    /// contract — see `CaptureBuffer.swift`).
    public func feedReference(_ buffer: CaptureBuffer) {
        guard buffer.source == .system else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer.buffer)
        guard CMTIME_IS_VALID(pts) else {
            logger.warning("feedReference: invalid PTS; dropping")
            return
        }
        guard var channels = extractFloat32Channels(
            from: buffer.buffer,
            channelCount: config.channels
        ) else {
            logger.warning("feedReference: failed to extract channels from CMSampleBuffer; dropping")
            return
        }
        let frameCount = channels.first?.count ?? 0
        guard frameCount > 0 else { return }

        // CAP-6: the mono reference (mean of the channels) for an
        // upmixed mono mic. Computed outside the lock.
        if config.channels > 1 {
            var mono = [Float](repeating: 0, count: frameCount)
            for ch in channels { vDSP_vadd(mono, 1, ch, 1, &mono, 1, vDSP_Length(frameCount)) }
            var scale = 1 / Float(channels.count)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameCount))
            channels.append(mono)
        }

        let logFirstTime = firstReferenceLogged.withLock { logged -> Bool in
            guard !logged else { return false }
            logged = true
            return true
        }

        refLock.withLockUnchecked {
            // Anchor on first arrival. Same anchor for all channels.
            if self.refAnchorPTS == nil {
                self.refAnchorPTS = pts
            }
            guard let anchor = self.refAnchorPTS else { return }

            // Logical index of the first sample in this buffer.
            let bufferStartLogical = self.logicalIndex(forPTS: pts, anchor: anchor)

            self.refStats.refBuffersReceived &+= 1

            for r in 0..<min(self.refRing.count, channels.count) {
                let lastEnd = self.refLastWriteEnd[r]

                // Out-of-order / overlapping with already-written
                // data — drop, do not try to splice in.
                if bufferStartLogical < lastEnd {
                    if r == 0 { self.refStats.refBuffersDroppedOutOfOrder &+= 1 }
                    continue
                }

                // Gap between previous write end and this buffer's
                // start — zero-fill so a subsequent read doesn't
                // pick up stale data left over from a wrap.
                if bufferStartLogical > lastEnd {
                    let gap = bufferStartLogical - lastEnd
                    if r == 0 { self.refStats.refGapsZeroFilled &+= UInt64(gap) }
                    self.writeRing(r, zerosAt: lastEnd, count: gap)
                }

                channels[r].withUnsafeBufferPointer { src in
                    self.writeRing(r, from: src.baseAddress!, count: frameCount, at: bufferStartLogical)
                }
                self.refLastWriteEnd[r] = bufferStartLogical + frameCount
            }
        }

        if logFirstTime {
            logger.info(
                "SoftwareAECProcessor first reference: frames=\(frameCount) channels=\(config.channels) bufferStartPTS=\(CMTimeGetSeconds(pts))"
            )
        }
    }

    /// Write `count` samples at logical position `logical` into ring
    /// `r`, both halves of the mirror, with at most four `memcpy`s.
    /// Only the last `ringCapacity` samples can survive, so a longer
    /// run is trimmed to its tail. Caller holds `refLock`.
    private func writeRing(_ r: Int, from src: UnsafePointer<Float>, count: Int, at logical: Int) {
        let C = ringCapacity
        let skip = max(0, count - C)
        var remaining = count - skip
        var srcPos = skip
        var p = logical + skip
        refRing[r].withUnsafeMutableBufferPointer { ring in
            let base = ring.baseAddress!
            while remaining > 0 {
                let idx = ((p % C) + C) % C
                let n = min(remaining, C - idx)
                memcpy(base + idx, src + srcPos, n * MemoryLayout<Float>.size)
                memcpy(base + idx + C, src + srcPos, n * MemoryLayout<Float>.size)
                remaining -= n
                srcPos += n
                p += n
            }
        }
    }

    /// Zero `count` samples at logical position `logical` in ring `r`.
    /// Caller holds `refLock`.
    private func writeRing(_ r: Int, zerosAt logical: Int, count: Int) {
        let C = ringCapacity
        var remaining = min(count, C)
        var p = logical + (count - remaining)
        refRing[r].withUnsafeMutableBufferPointer { ring in
            let base = ring.baseAddress!
            while remaining > 0 {
                let idx = ((p % C) + C) % C
                let n = min(remaining, C - idx)
                vDSP_vclr(base + idx, 1, vDSP_Length(n))
                vDSP_vclr(base + idx + C, 1, vDSP_Length(n))
                remaining -= n
                p += n
            }
        }
    }

    // MARK: - Mic processing (Layers A–E around the NLMS step)

    /// Process a microphone buffer through the NLMS filter and emit
    /// the cleaned result via `onCleanedMic`. Constructs a brand-new
    /// `CMSampleBuffer` carrying the cleaned audio with the same
    /// PTS / format as the input — preserves the host-clock alignment
    /// downstream consumers (`HostClockAligner`, the recorder)
    /// depend on.
    ///
    /// The reference window for mic sample `p` is the `filterLength`
    /// reference samples ENDING at `p` (logical `p - L + 1 … p`) — the
    /// audio that can have produced an echo in that mic sample. (Before
    /// EVAL-2026-10-16 the window started at `p + 1`, so it read either
    /// future reference samples or ones `L … 2L` old, and the filter
    /// could not converge on a real echo.)
    public func processMic(_ buffer: CaptureBuffer) {
        guard buffer.source == .microphone else {
            onCleanedMic?(buffer)
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer.buffer)
        guard CMTIME_IS_VALID(pts) else {
            logger.warning("processMic: invalid PTS; forwarding original")
            onCleanedMic?(buffer)
            return
        }
        guard let micChannels = extractFloat32Channels(
            from: buffer.buffer,
            channelCount: config.channels
        ) else {
            logger.warning("processMic: failed to extract channels; forwarding original")
            onCleanedMic?(buffer)
            return
        }
        let frameCount = micChannels.first?.count ?? 0
        guard frameCount > 0 else {
            onCleanedMic?(buffer)
            return
        }

        let L = config.filterLength
        let C = ringCapacity
        let spanLength = L - 1 + frameCount

        // CAP-6: CoreAudio upmixes a mono mic by duplicating it, so
        // every channel carries the same samples. One filter against
        // the mono reference then does the work of `channels` filters.
        let monoMic = config.channels > 1 && micChannels.count == config.channels
            && micChannels.dropFirst().allSatisfy { Self.sameSamples($0, micChannels[0], count: frameCount) }
        let filterCount = monoMic ? 1 : min(config.channels, micChannels.count)

        // C2 (EVAL 2026-06-12): reuse the output scratch instead of
        // allocating a fresh 2-D array per buffer. Moving it out of
        // `self` (leaving `cleanedScratch` empty) makes `cleaned`
        // uniquely referenced, so every `cleaned[ch]` write below stays
        // in-place; the `defer` returns it for the next call. Every
        // element in `0..<frameCount` is written before it is read by
        // `makeCleanedSampleBuffer`, so a larger reused buffer carrying
        // stale tail samples is harmless.
        var cleaned = cleanedScratch
        cleanedScratch = []
        var span = refSpanScratch
        refSpanScratch = []
        defer {
            cleanedScratch = cleaned
            refSpanScratch = span
        }
        Self.ensure(&cleaned, count: config.channels, length: frameCount)
        Self.ensure(&span, count: filterCount, length: spanLength)

        let logFirstTime = firstMicLogged.withLock { logged -> Bool in
            guard !logged else { return false }
            logged = true
            return true
        }

        // ---- CAP-11: copy the reference span under the lock, then
        // ---- release it before the NLMS loop.
        //
        // `span[f][j]` holds reference logical `spanStart + j`. Samples
        // outside the ring's retained range are not copied; `available`
        // is the half-open logical range that was.
        var micFirstLogical = 0
        var available = [Range<Int>](repeating: 0..<0, count: filterCount)
        let anchored: Bool = refLock.withLockUnchecked {
            guard let anchor = self.refAnchorPTS else { return false }
            micFirstLogical = self.logicalIndex(forPTS: pts, anchor: anchor)
            let spanStart = micFirstLogical - L + 1
            for f in 0..<filterCount {
                let r = monoMic ? self.config.channels : f
                let lastEnd = self.refLastWriteEnd[r]
                let lo = max(spanStart, lastEnd - C, 0)
                let hi = min(micFirstLogical + frameCount, lastEnd)
                guard hi > lo else { continue }
                available[f] = lo..<hi
                self.refRing[r].withUnsafeBufferPointer { ring in
                    span[f].withUnsafeMutableBufferPointer { dst in
                        memcpy(dst.baseAddress! + (lo - spanStart),
                               ring.baseAddress! + (lo % C),
                               (hi - lo) * MemoryLayout<Float>.size)
                    }
                }
            }
            return true
        }

        filterLock.withLockUnchecked {
            // PTS anchor must be present (set by feedReference). If
            // mic arrived before any ref → passthrough — we have no
            // reference data to learn from.
            guard anchored else {
                for ch in 0..<min(self.config.channels, micChannels.count) {
                    micChannels[ch].withUnsafeBufferPointer { src in
                        cleaned[ch].withUnsafeMutableBufferPointer { dst in
                            for i in 0..<frameCount {
                                dst[i] = self.softLimit(src[i])
                            }
                        }
                    }
                }
                self.micStats.samplesProcessed &+= UInt64(frameCount)
                self.micStats.samplesPassedThrough &+= UInt64(frameCount)
                return
            }

            for f in 0..<filterCount {
                let counts = self.runFilter(
                    f,
                    mic: micChannels[f],
                    reference: span[f],
                    available: available[f],
                    micFirstLogical: micFirstLogical,
                    frameCount: frameCount,
                    output: &cleaned[f]
                )
                self.micStats.samplesPassedThrough &+= counts.passThrough
                self.micStats.updatesSkippedRefSilence &+= counts.skippedRefSilence
                self.micStats.updatesSkippedDoubleTalk &+= counts.skippedDoubleTalk
                self.micStats.divergenceResets &+= counts.resets
                if counts.resets > 0 {
                    self.logger.info("AEC divergence reset fired \(counts.resets) time(s) — weights re-zeroed (cumulative resets=\(self.micStats.divergenceResets))")
                }
            }
            if monoMic {
                self.micStats.monoMicBuffers &+= 1
                let first = cleaned[0]
                for ch in 1..<self.config.channels {
                    cleaned[ch].withUnsafeMutableBufferPointer { dst in
                        first.withUnsafeBufferPointer { src in
                            _ = memcpy(dst.baseAddress!, src.baseAddress!, frameCount * MemoryLayout<Float>.size)
                        }
                    }
                }
            }
            self.micStats.samplesProcessed &+= UInt64(frameCount) * UInt64(self.config.channels)
        }

        // Re-package the cleaned samples as a fresh CMSampleBuffer.
        guard let cleanedSampleBuffer = makeCleanedSampleBuffer(
            from: cleaned,
            template: buffer.buffer,
            frameCount: frameCount
        ) else {
            logger.warning("processMic: failed to wrap cleaned samples into CMSampleBuffer; forwarding original")
            onCleanedMic?(buffer)
            return
        }

        if logFirstTime {
            logger.info(
                "SoftwareAECProcessor first mic processed: frames=\(frameCount) channels=\(micChannels.count) mono=\(monoMic) micFirstPTS=\(CMTimeGetSeconds(pts))"
            )
        }

        onCleanedMic?(CaptureBuffer(source: .microphone, buffer: cleanedSampleBuffer))
    }

    private struct FilterCounts {
        var passThrough: UInt64 = 0
        var skippedRefSilence: UInt64 = 0
        var skippedDoubleTalk: UInt64 = 0
        var resets: UInt64 = 0
    }

    /// Run filter `f` over one mic buffer. `reference[j]` is reference
    /// logical `micFirstLogical - L + 1 + j`; `available` is the range
    /// of logical positions actually copied into it. Caller holds
    /// `filterLock`.
    ///
    /// CAP-3: per sample this is two vector passes over the taps — the
    /// `vDSP_dotpr` for ŷ and one fused `vDSP_vsmsma` for leakage plus
    /// update (`w = (1 - leak)·w + step·x`) — instead of four (dotpr,
    /// svesq, vsmul, vsma). The window energy `‖x‖²` is kept as a
    /// running sum.
    private func runFilter(
        _ f: Int,
        mic: [Float],
        reference: [Float],
        available: Range<Int>,
        micFirstLogical: Int,
        frameCount: Int,
        output: inout [Float]
    ) -> FilterCounts {
        let L = config.filterLength
        let mu = config.stepSize
        let reg = config.regularization
        let stepMaxAbs = config.stepMax
        var retain = 1 - config.leakage
        let alpha = envCoeff
        let oneMinusAlpha = 1 - alpha
        let invL = 1 / Float(L)
        // Gate envelopes live on per-sample mean-power scale.
        // `refPower` below is the full L-sample window energy and
        // remains the correct NLMS denominator, but comparing that
        // directly to `d*d` makes the reference side about `L`
        // times larger (~36 dB for L=4096). That disables the
        // double-talk detector in exactly the case it must catch:
        // local speech over system playback.
        let refActivityPower = config.referenceActivityRMSThreshold
            * config.referenceActivityRMSThreshold
        let dtRatio = config.doubleTalkRatio
        let divergeLimit = divergenceResetSamples

        var counts = FilterCounts()
        var refEnv = self.refEnv[f]
        var micEnv = self.micEnv[f]
        var resEnv = self.resEnv[f]
        var divCount = divergentSampleCount[f]

        weights[f].withUnsafeMutableBufferPointer { wBuf in
            reference.withUnsafeBufferPointer { xBuf in
                output.withUnsafeMutableBufferPointer { outPtr in
                    mic.withUnsafeBufferPointer { dPtr in
                        let w = wBuf.baseAddress!
                        let xBase = xBuf.baseAddress!
                        var refPower: Float = 0
                        var powerValid = false
                        var sinceRecompute = 0

                        for n in 0..<frameCount {
                            let p = micFirstLogical + n

                            // --- Window availability ---
                            // The whole window p-L+1 … p must have been
                            // copied out of the ring.
                            guard p - L + 1 >= available.lowerBound, p < available.upperBound else {
                                // Pass mic through (still soft-limited).
                                // No envelope updates, no adaptation.
                                outPtr[n] = self.softLimit(dPtr[n])
                                counts.passThrough &+= 1
                                powerValid = false
                                continue
                            }
                            let window = xBase + n

                            // ‖x‖², incrementally: the window gained
                            // x[L-1] and lost the sample before x[0].
                            if powerValid && sinceRecompute < Self.energyRecomputeInterval {
                                let entering = window[L - 1]
                                let leaving = window[-1]
                                refPower += entering * entering - leaving * leaving
                                if refPower < 0 { refPower = 0 }
                                sinceRecompute += 1
                            } else {
                                vDSP_svesq(window, 1, &refPower, vDSP_Length(L))
                                powerValid = true
                                sinceRecompute = 0
                            }
                            let refMeanPower = refPower * invL

                            // y_hat = w · x
                            var yHat: Float = 0
                            vDSP_dotpr(w, 1, window, 1, &yHat, vDSP_Length(L))

                            let d = dPtr[n]
                            let e = d - yHat

                            // --- Envelopes ---
                            refEnv = oneMinusAlpha * refEnv + alpha * refMeanPower
                            micEnv = oneMinusAlpha * micEnv + alpha * (d * d)
                            resEnv = oneMinusAlpha * resEnv + alpha * (e * e)

                            // --- Soft-limit + write output ---
                            outPtr[n] = self.softLimit(e)

                            // --- Layer A: ref-silence gate ---
                            if refEnv < refActivityPower {
                                counts.skippedRefSilence &+= 1
                                divCount = 0
                                continue
                            }

                            // --- Layer B: double-talk gate ---
                            if micEnv > refEnv * dtRatio {
                                counts.skippedDoubleTalk &+= 1
                                divCount = 0
                                continue
                            }

                            // --- Layer C: divergence reset ---
                            if resEnv > micEnv {
                                divCount &+= 1
                                if divCount >= divergeLimit {
                                    // Zero out weights — let the filter
                                    // rebuild from scratch. Skip this
                                    // sample's update so the reset is
                                    // visible at the next iteration.
                                    vDSP_vclr(w, 1, vDSP_Length(L))
                                    divCount = 0
                                    counts.resets &+= 1
                                    continue
                                }
                            } else {
                                divCount = 0
                            }

                            // --- Layer D: NLMS step (clamped + leakage) ---
                            var step = mu * e / (refPower + reg)
                            if step > stepMaxAbs { step = stepMaxAbs }
                            else if step < -stepMaxAbs { step = -stepMaxAbs }

                            // w = (1 - leak)·w + step·x, one pass.
                            vDSP_vsmsma(w, 1, &retain, window, 1, &step, w, 1, vDSP_Length(L))
                        }
                    }
                }
            }
        }

        self.refEnv[f] = refEnv
        self.micEnv[f] = micEnv
        self.resEnv[f] = resEnv
        divergentSampleCount[f] = divCount
        return counts
    }

    /// Whether the first `count` samples of `a` and `b` are identical.
    private static func sameSamples(_ a: [Float], _ b: [Float], count: Int) -> Bool {
        a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                memcmp(ra.baseAddress!, rb.baseAddress!, count * MemoryLayout<Float>.size) == 0
            }
        }
    }

    /// Make `buffers` hold `count` arrays of at least `length` floats.
    private static func ensure(_ buffers: inout [[Float]], count: Int, length: Int) {
        if buffers.count < count {
            buffers.append(contentsOf: Array(repeating: [], count: count - buffers.count))
        }
        for i in 0..<count where buffers[i].count < length {
            buffers[i] = [Float](repeating: 0, count: length)
        }
    }

    // MARK: - Soft limiter (Layer E)

    /// Tanh-style soft limiter with explicit knee + ceiling. Below
    /// the knee → identity. Between knee and ceiling → smooth quadratic
    /// roll-off (`y = knee + range · (1 - (1-t)²)`). Above the ceiling
    /// → ±ceiling. Output is bounded to ±ceiling at all times.
    @inline(__always)
    private func softLimit(_ x: Float) -> Float {
        let knee = config.limiterKnee
        let ceiling = config.limiterCeiling
        let absX = abs(x)
        if absX <= knee {
            return x
        }
        if absX >= ceiling {
            return x >= 0 ? ceiling : -ceiling
        }
        let range = ceiling - knee
        let t = (absX - knee) / range          // 0..1
        let oneMinusT = 1 - t
        let mapped = knee + range * (1 - oneMinusT * oneMinusT)
        return x >= 0 ? mapped : -mapped
    }

    // MARK: - PTS arithmetic

    /// Convert `pts` to a logical sample index relative to `anchor`.
    /// Both PTSs live in the host clock; the conversion is
    /// `round((pts - anchor).seconds · sampleRate)`. Tolerates small
    /// negative deltas (mic arriving slightly before the ref anchor)
    /// by returning a negative index — callers treat negative as
    /// "no ref available".
    @inline(__always)
    private func logicalIndex(forPTS pts: CMTime, anchor: CMTime) -> Int {
        let delta = CMTimeSubtract(pts, anchor)
        let seconds = CMTimeGetSeconds(delta)
        guard seconds.isFinite else { return 0 }
        return Int((seconds * config.sampleRate).rounded())
    }

    // MARK: - CMSampleBuffer helpers

    /// Extract float32 PCM samples per channel from a non-interleaved
    /// CMSampleBuffer. Returns one `[Float]` per channel; nil on
    /// failure. Pads with empty/zero channels if the source has
    /// fewer channels than requested.
    private func extractFloat32Channels(
        from sampleBuffer: CMSampleBuffer,
        channelCount: Int
    ) -> [[Float]]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else {
            return nil
        }
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let actualChannels = Int(asbd.mChannelsPerFrame)
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else { return nil }

        let listPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sizeNeeded)
        defer { listPtr.deallocate() }
        var blockBuffer: CMBlockBuffer?
        status = listPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPtr,
                bufferListSize: sizeNeeded,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == noErr else { return nil }

        var result: [[Float]] = []
        listPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            if isNonInterleaved {
                for i in 0..<min(channelCount, abl.count) {
                    let buf = abl[i]
                    guard let mData = buf.mData else {
                        result.append([Float](repeating: 0, count: frameCount))
                        continue
                    }
                    let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                    let p = mData.assumingMemoryBound(to: Float.self)
                    var ch = [Float](repeating: 0, count: count)
                    _ = ch.withUnsafeMutableBufferPointer { dst in
                        memcpy(dst.baseAddress!, p, Int(buf.mDataByteSize))
                    }
                    result.append(ch)
                }
                while result.count < channelCount {
                    result.append([Float](repeating: 0, count: frameCount))
                }
            } else {
                guard let buf = abl.first,
                      let mData = buf.mData else {
                    return
                }
                let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let p = mData.assumingMemoryBound(to: Float.self)
                let perChannel = totalFloats / actualChannels
                for c in 0..<min(channelCount, actualChannels) {
                    var ch = [Float](repeating: 0, count: perChannel)
                    // C8 (EVAL 2026-06-12): vDSP strided gather
                    // deinterleaves channel `c` in one vectorised call
                    // instead of the scalar per-sample copy. (This
                    // interleaved branch is rarely taken — the canonical
                    // capture format is non-interleaved.)
                    ch.withUnsafeMutableBufferPointer { dst in
                        vDSP_vadd(p.advanced(by: c), vDSP_Stride(actualChannels),
                                  dst.baseAddress!, 1,
                                  dst.baseAddress!, 1,
                                  vDSP_Length(perChannel))
                    }
                    result.append(ch)
                }
                while result.count < channelCount {
                    result.append([Float](repeating: 0, count: perChannel))
                }
            }
        }
        return result
    }

    /// Build a fresh CMSampleBuffer from per-channel cleaned samples.
    /// Same approach as v3/v4: use `CMBlockBufferCreateWithMemoryBlock`
    /// to avoid the AudioBufferList sharp edges on macOS 26. The
    /// inherited non-interleaved ASBD tells CoreMedia how to interpret
    /// the layout `[ch0 samples][ch1 samples]…`.
    private func makeCleanedSampleBuffer(
        from cleaned: [[Float]],
        template: CMSampleBuffer,
        frameCount: Int
    ) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(template) else {
            logger.warning("makeCleanedSampleBuffer: template has no format description")
            return nil
        }
        let channelCount = cleaned.count
        let bytesPerChannel = frameCount * MemoryLayout<Float>.size
        let totalBytes = channelCount * bytesPerChannel
        guard channelCount > 0, totalBytes > 0 else {
            logger.warning("makeCleanedSampleBuffer: nothing to wrap (channels=\(channelCount), totalBytes=\(totalBytes))")
            return nil
        }

        guard let memBlock = malloc(totalBytes) else {
            logger.warning("makeCleanedSampleBuffer: malloc(\(totalBytes)) failed")
            return nil
        }
        var memBlockReleased = false
        defer {
            if !memBlockReleased { free(memBlock) }
        }
        for ch in 0..<channelCount {
            _ = cleaned[ch].withUnsafeBufferPointer { src in
                memcpy(memBlock.advanced(by: ch * bytesPerChannel),
                       src.baseAddress!,
                       bytesPerChannel)
            }
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memBlock,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let bb = blockBuffer else {
            logger.warning("makeCleanedSampleBuffer: CMBlockBufferCreateWithMemoryBlock failed (status=\(blockStatus), totalBytes=\(totalBytes))")
            return nil
        }
        memBlockReleased = true

        let pts = CMSampleBufferGetPresentationTimeStamp(template)
        let duration = CMSampleBufferGetDuration(template)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(template)
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sb = sampleBuffer else {
            logger.warning("makeCleanedSampleBuffer: CMSampleBufferCreate failed (status=\(createStatus), totalBytes=\(totalBytes), channels=\(channelCount), frameCount=\(frameCount))")
            return nil
        }
        return sb
    }
}
