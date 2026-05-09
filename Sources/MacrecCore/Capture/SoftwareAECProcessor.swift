// MacrecCore/Capture/SoftwareAECProcessor.swift — plan-014 (v5)
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
//        refEnv += α(|x|² - refEnv)        (short-term ref power)
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
// loop. Capacity C is `2 · filterLength` (~170 ms at 48 kHz, with
// L=4096) — plenty of headroom for any plausible mic-vs-ref skew
// (typically < 30 ms).
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
        /// rest of the macrec pipeline normalises everything to 48
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

    /// Per-channel adaptive filter weights. `weights[ch]` is a
    /// contiguous Float array of length `filterLength`.
    private var weights: [[Float]]

    /// Per-channel reference ring buffer with the double-write trick.
    /// Each ring is `2 · ringCapacity` Float32s long, where
    /// `ringCapacity = 2 · filterLength`. Logical position `p` writes
    /// to both `ring[p % C]` and `ring[(p % C) + C]`.
    private var refRing: [[Float]]

    /// Capacity of the (un-mirrored) ring per channel = `2 ·
    /// filterLength`. The ring array itself is `2 · ringCapacity` long.
    private let ringCapacity: Int

    /// Per-channel logical index ONE PAST the most-recently-written
    /// reference sample. Equivalently, the next position to write to.
    /// Negative indicates "no reference data yet".
    private var refLastWriteEnd: [Int]

    /// PTS anchor — set on the very first `feedReference` call;
    /// shared across channels. Logical index 0 corresponds to host
    /// time `refAnchorPTS`. All later PTS-to-logical conversions key
    /// off this anchor.
    private var refAnchorPTS: CMTime?

    /// Per-channel envelopes — exponential moving averages of |x|²,
    /// |d|², |e|² respectively. Used by Layers A / B / C.
    private var refEnv: [Float]
    private var micEnv: [Float]
    private var resEnv: [Float]

    /// Per-channel running counter of consecutive samples with
    /// `resEnv > micEnv`. When it exceeds `divergenceResetSamples`,
    /// the weights are reset to zero. Reset to 0 every time the
    /// inequality fails.
    private var divergentSampleCount: [Int]

    /// Stats — used by tests / diagnostics. Reset only on `init`.
    private var stats = AECStatistics()

    /// Lock guarding all of the mutable state above. Held for the
    /// duration of a `processMic` call (one mic buffer at a time)
    /// and briefly during `feedReference`.
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())

    /// One-shot diagnostic flags — first reference buffer seen,
    /// first mic buffer processed.
    private let firstReferenceLogged = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let firstMicLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Constants derived from `config`. Computed once.
    private let envCoeff: Float                  // exp-MA coefficient α
    private let divergenceResetSamples: Int      // Layer C samples threshold

    // MARK: - Public surface

    /// Set by the orchestrator before `processMic` is invoked. Called
    /// on the SAME queue that delivered the mic buffer (the
    /// `macrec.capture.mic` `userInteractive` queue), with a
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
    }

    public func snapshotStatistics() -> AECStatistics {
        lock.withLockUnchecked { stats }
    }

    public init(config: Configuration = Configuration(), logger: Logging.Logger? = nil) {
        self.config = config
        self.logger = logger ?? LoggerFactory.make("macrec.aec")
        self.ringCapacity = config.filterLength * 2
        self.weights = Array(
            repeating: Array(repeating: 0, count: config.filterLength),
            count: config.channels
        )
        self.refRing = Array(
            repeating: Array(repeating: 0, count: ringCapacity * 2),
            count: config.channels
        )
        self.refLastWriteEnd = Array(repeating: 0, count: config.channels)
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
        guard let channels = extractFloat32Channels(
            from: buffer.buffer,
            channelCount: config.channels
        ) else {
            logger.warning("feedReference: failed to extract channels from CMSampleBuffer; dropping")
            return
        }
        let frameCount = channels.first?.count ?? 0
        guard frameCount > 0 else { return }

        let logFirstTime = firstReferenceLogged.withLock { logged -> Bool in
            guard !logged else { return false }
            logged = true
            return true
        }

        lock.withLockUnchecked {
            // Anchor on first arrival. Same anchor for all channels.
            if self.refAnchorPTS == nil {
                self.refAnchorPTS = pts
            }
            guard let anchor = self.refAnchorPTS else { return }

            // Logical index of the first sample in this buffer.
            let bufferStartLogical = self.logicalIndex(forPTS: pts, anchor: anchor)
            let C = self.ringCapacity

            self.stats.refBuffersReceived &+= 1

            for ch in 0..<min(self.config.channels, channels.count) {
                let samples = channels[ch]
                let lastEnd = self.refLastWriteEnd[ch]

                // Out-of-order / overlapping with already-written
                // data — drop, do not try to splice in.
                if bufferStartLogical < lastEnd {
                    self.stats.refBuffersDroppedOutOfOrder &+= 1
                    continue
                }

                // Gap between previous write end and this buffer's
                // start — zero-fill so a subsequent read doesn't
                // pick up stale data left over from a wrap.
                if bufferStartLogical > lastEnd {
                    let gap = bufferStartLogical - lastEnd
                    self.stats.refGapsZeroFilled &+= UInt64(gap)
                    self.refRing[ch].withUnsafeMutableBufferPointer { ringPtr in
                        var p = lastEnd
                        for _ in 0..<gap {
                            let primary = ((p % C) + C) % C
                            ringPtr[primary] = 0
                            ringPtr[primary + C] = 0
                            p += 1
                        }
                    }
                }

                self.refRing[ch].withUnsafeMutableBufferPointer { ringPtr in
                    samples.withUnsafeBufferPointer { srcPtr in
                        var p = bufferStartLogical
                        for i in 0..<frameCount {
                            let primary = ((p % C) + C) % C
                            ringPtr[primary] = srcPtr[i]
                            ringPtr[primary + C] = srcPtr[i]
                            p += 1
                        }
                    }
                }
                self.refLastWriteEnd[ch] = bufferStartLogical + frameCount
            }
        }

        if logFirstTime {
            logger.info(
                "SoftwareAECProcessor first reference: frames=\(frameCount) channels=\(channels.count) bufferStartPTS=\(CMTimeGetSeconds(pts))"
            )
        }
    }

    // MARK: - Mic processing (Layers A–E around the NLMS step)

    /// Process a microphone buffer through the NLMS filter and emit
    /// the cleaned result via `onCleanedMic`. Constructs a brand-new
    /// `CMSampleBuffer` carrying the cleaned audio with the same
    /// PTS / format as the input — preserves the host-clock alignment
    /// downstream consumers (`HostClockAligner`, the recorder)
    /// depend on.
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

        var cleaned: [[Float]] = Array(
            repeating: Array(repeating: 0, count: frameCount),
            count: config.channels
        )

        let logFirstTime = firstMicLogged.withLock { logged -> Bool in
            guard !logged else { return false }
            logged = true
            return true
        }

        lock.withLockUnchecked {
            // PTS anchor must be present (set by feedReference). If
            // mic arrived before any ref → passthrough — we have no
            // reference data to learn from.
            guard let anchor = self.refAnchorPTS else {
                for ch in 0..<min(self.config.channels, micChannels.count) {
                    let micCh = micChannels[ch]
                    micCh.withUnsafeBufferPointer { src in
                        cleaned[ch].withUnsafeMutableBufferPointer { dst in
                            for i in 0..<frameCount {
                                dst[i] = self.softLimit(src[i])
                            }
                        }
                    }
                }
                self.stats.samplesProcessed &+= UInt64(frameCount)
                self.stats.samplesPassedThrough &+= UInt64(frameCount)
                return
            }

            let micFirstLogical = self.logicalIndex(forPTS: pts, anchor: anchor)

            let L = self.config.filterLength
            let C = self.ringCapacity
            let mu = self.config.stepSize
            let reg = self.config.regularization
            let stepMaxAbs = self.config.stepMax
            let leak = self.config.leakage
            let leakRetain = 1 - leak
            let alpha = self.envCoeff
            let oneMinusAlpha = 1 - alpha
            let refActivityPower = self.config.referenceActivityRMSThreshold
                * self.config.referenceActivityRMSThreshold
                * Float(L)   // compare against ‖x‖² directly, not RMS
            let dtRatio = self.config.doubleTalkRatio
            let divergeLimit = self.divergenceResetSamples

            var passThroughInThisBuffer: UInt64 = 0
            var skippedRefSilence: UInt64 = 0
            var skippedDoubleTalk: UInt64 = 0
            var resetsInThisBuffer: UInt64 = 0

            for ch in 0..<min(self.config.channels, micChannels.count) {
                let micCh = micChannels[ch]

                self.weights[ch].withUnsafeMutableBufferPointer { wPtr in
                    self.refRing[ch].withUnsafeBufferPointer { ringPtr in
                        cleaned[ch].withUnsafeMutableBufferPointer { outPtr in
                            micCh.withUnsafeBufferPointer { dPtr in
                                let lastEnd = self.refLastWriteEnd[ch]
                                var refEnv = self.refEnv[ch]
                                var micEnv = self.micEnv[ch]
                                var resEnv = self.resEnv[ch]
                                var divCount = self.divergentSampleCount[ch]

                                for n in 0..<frameCount {
                                    let p = micFirstLogical + n

                                    // --- Window availability ---
                                    let haveWindow =
                                        (p >= L - 1) &&
                                        (p <= lastEnd - 1) &&
                                        (p >= lastEnd - C)
                                    if !haveWindow {
                                        // Pass mic through (still
                                        // soft-limited). No envelope
                                        // updates, no adaptation.
                                        outPtr[n] = self.softLimit(dPtr[n])
                                        passThroughInThisBuffer &+= 1
                                        continue
                                    }

                                    let phase = ((p + 1) % C + C) % C
                                    let window = ringPtr.baseAddress!.advanced(by: phase)

                                    // y_hat = w · x
                                    var yHat: Float = 0
                                    vDSP_dotpr(wPtr.baseAddress!, 1, window, 1, &yHat, vDSP_Length(L))

                                    // ‖x‖²
                                    var refPower: Float = 0
                                    vDSP_svesq(window, 1, &refPower, vDSP_Length(L))

                                    let d = dPtr[n]
                                    let dSq = d * d
                                    let e = d - yHat
                                    let eSq = e * e

                                    // --- Envelopes ---
                                    refEnv = oneMinusAlpha * refEnv + alpha * refPower
                                    micEnv = oneMinusAlpha * micEnv + alpha * dSq
                                    resEnv = oneMinusAlpha * resEnv + alpha * eSq

                                    // --- Soft-limit + write output ---
                                    outPtr[n] = self.softLimit(e)

                                    // --- Layer A: ref-silence gate ---
                                    if refEnv < refActivityPower {
                                        skippedRefSilence &+= 1
                                        divCount = 0
                                        continue
                                    }

                                    // --- Layer B: double-talk gate ---
                                    if micEnv > refEnv * dtRatio {
                                        skippedDoubleTalk &+= 1
                                        divCount = 0
                                        continue
                                    }

                                    // --- Layer C: divergence reset ---
                                    if resEnv > micEnv {
                                        divCount &+= 1
                                        if divCount >= divergeLimit {
                                            // Zero out weights — let
                                            // the filter rebuild from
                                            // scratch. Skip this
                                            // sample's update so the
                                            // reset is visible at the
                                            // next iteration.
                                            for i in 0..<L {
                                                wPtr[i] = 0
                                            }
                                            divCount = 0
                                            resetsInThisBuffer &+= 1
                                            continue
                                        }
                                    } else {
                                        divCount = 0
                                    }

                                    // --- Layer D: NLMS step (clamped + leakage) ---
                                    var step = mu * e / (refPower + reg)
                                    if step > stepMaxAbs { step = stepMaxAbs }
                                    else if step < -stepMaxAbs { step = -stepMaxAbs }

                                    var retain = leakRetain
                                    vDSP_vsmul(wPtr.baseAddress!, 1, &retain, wPtr.baseAddress!, 1, vDSP_Length(L))
                                    vDSP_vsma(window, 1, &step, wPtr.baseAddress!, 1, wPtr.baseAddress!, 1, vDSP_Length(L))
                                }

                                self.refEnv[ch] = refEnv
                                self.micEnv[ch] = micEnv
                                self.resEnv[ch] = resEnv
                                self.divergentSampleCount[ch] = divCount
                            }
                        }
                    }
                }
            }

            self.stats.samplesProcessed &+= UInt64(frameCount) * UInt64(self.config.channels)
            self.stats.samplesPassedThrough &+= passThroughInThisBuffer
            self.stats.updatesSkippedRefSilence &+= skippedRefSilence
            self.stats.updatesSkippedDoubleTalk &+= skippedDoubleTalk
            self.stats.divergenceResets &+= resetsInThisBuffer

            if resetsInThisBuffer > 0 {
                logger.info("AEC divergence reset fired \(resetsInThisBuffer) time(s) — weights re-zeroed (cumulative resets=\(self.stats.divergenceResets))")
            }
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
                "SoftwareAECProcessor first mic processed: frames=\(frameCount) channels=\(micChannels.count) micFirstPTS=\(CMTimeGetSeconds(pts))"
            )
        }

        onCleanedMic?(CaptureBuffer(source: .microphone, buffer: cleanedSampleBuffer))
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
                    for i in 0..<perChannel {
                        ch[i] = p[i * actualChannels + c]
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
