// NtakkerCore/Encoding/M4ARecorder.swift — see project-design.md §2.10 / §7.4 / §7.7
// and `docs/research/avassetwriter-aac.md` §1.1 (m4a recipe), §3.2 (AAC
// priming auto-trim), §5 (SIGINT-safe finalization with timeout).
//
// Phase G (plan-001 Wave 3b) — AAC-LC m4a writer built on `AVAssetWriter`.
//
// Threading model (the contract that justifies `@unchecked Sendable`):
//   * All AVAssetWriter / AVAssetWriterInput interactions are confined to
//     a single private serial queue, `writerQueue`. The queue is owned
//     by the recorder; it is the only consumer of `writers[*]`,
//     `inputs[*]`, `pendingFrames`, `_lastAppendedEndPTS`, `state`, and
//     `_isFinalizing`. The aligner's serial queue calls into
//     `append(_:)` which trampolines onto `writerQueue` synchronously
//     (just to enqueue) and returns immediately.
//   * `requestMediaDataWhenReady` runs its callback on `writerQueue` —
//     so the drain loop is naturally serialized with `append(_:)`'s
//     enqueue path.
//   * `start()` and `finalize(timeout:)` are async — they await
//     internal `withCheckedContinuation` bridges to the dispatch world.
//
// Layout handling:
//   * `.mixed`        → 1 writer, stereo input. Each `append(_:)` calls
//                       `BufferSummer.sum(system, mic)`.
//   * `.stereoSplit`  → 1 writer, stereo input. Each `append(_:)` builds
//                       a stereo buffer where mic is on the configured
//                       channel and system on the other (downmixed to
//                       mono first if either is stereo).
//   * `.split`        → 2 writers (`<output>.system.m4a` and
//                       `<output>.mic.m4a`). `append(_:)` routes each
//                       sub-buffer to its own writer. Finalize aggregates.
//
// Per design §7.4 / research §1.1 the writer is built with:
//   * `AVAssetWriter(outputURL: …, fileType: .m4a)`.
//   * `shouldOptimizeForNetworkUse = true` — moves moov atom to front
//     for crash safety (AC-7).
//   * `movieFragmentInterval = CMTime(value: 2, timescale: 1)` — flush
//     a self-contained fragment every 2 s so a hard-killed file is
//     still playable (research §5.3 belt-and-braces).
//   * `outputSettings`: AAC-LC, 48 kHz, stereo, `options.bitrate` bps,
//     with an explicit `kAudioChannelLayoutTag_Stereo` `AVChannelLayoutKey`.
//   * Session start: `CMClockGetTime(CMClockGetHostTimeClock())` captured
//     at `start()` time (per research §2.3 "uptime PTS trap").
//
// Per research §3.2 we DO NOT touch
// `kCMSampleBufferAttachmentKey_TrimDurationAtStart` manually — when
// LPCM is fed into an AAC `outputSettings`, AVFoundation handles the
// 2112-frame priming pad and emits the correct `elst` + `iTunSMPB`
// metadata.

import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Logging

public final class M4ARecorder: Recorder, @unchecked Sendable {

    // MARK: - Per-writer state

    /// One AVAssetWriter + its sole audio input + its target URL. Split
    /// layout uses two of these; mixed / stereoSplit use one.
    private final class WriterUnit {
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        var pending: [CMSampleBuffer] = []
        /// Set to a non-nil value once `append` returns false or the
        /// writer's status flips out of `.writing`. Surfaced from the
        /// next `append` / `finalize`.
        var failure: Error?

        init(url: URL, writer: AVAssetWriter, input: AVAssetWriterInput) {
            self.url = url
            self.writer = writer
            self.input = input
        }
    }

    private enum Side {
        case system
        case mic
    }

    private enum LifecycleState {
        case idle
        case running
        case finalizing
        case completed
        case failed
    }

    // MARK: - Configuration

    private let options: RecordingOptions
    private let logger: Logger?

    // MARK: - Internal state (writerQueue-confined)

    private let writerQueue = DispatchQueue(label: "ntakker-cli.recorder.m4a.writer")

    /// Single-track writers: index 0 == only writer for mixed/stereoSplit.
    /// Split writers: keyed by `Side`.
    private var singleWriter: WriterUnit?
    private var systemWriter: WriterUnit?
    private var micWriter: WriterUnit?

    /// END time (PTS + duration) of the latest buffer appended to any
    /// input. Used as `endSession(atSourceTime:)` in
    /// `finalize(timeout:)`. `nil` until the first `append(_:)` lands.
    /// Using the START PTS here trimmed the final ~100 ms frame from
    /// every file and every split seam (EVAL-2026-10-16 CAP-5).
    private var _lastAppendedEndPTS: CMTime?

    /// Host-clock session start captured in `start()`. Used as the
    /// fallback `endSession` PTS if no frames were appended.
    private var _sessionStart: CMTime?

    private var state: LifecycleState = .idle

    // MARK: - Init

    public init(options: RecordingOptions, logger: Logger? = nil) {
        self.options = options
        self.logger = logger ?? LoggerFactory.make("ntakker-cli.recorder.m4a")
    }

    // MARK: - Recorder protocol

    public func start() async throws {
        try await runOnWriterQueue { [self] in
            try self.startOnQueue()
        }
    }

    public func append(_ frame: AlignedFrame) throws {
        // We surface any encoder failure that was captured asynchronously
        // by the requestMediaDataWhenReady drain loop. This is checked
        // synchronously up front so the orchestrator can react fast.
        var firstFailure: Error?
        writerQueue.sync {
            if let err = self.singleWriter?.failure ?? self.systemWriter?.failure ?? self.micWriter?.failure {
                firstFailure = err
            }
        }
        if let firstFailure {
            throw NtakkerError.finishWritingFailed(underlying: firstFailure)
        }

        // Build per-layout buffers OFF the writer queue (DSP work) — we
        // then synchronously enqueue onto the writer queue.
        switch options.layout {
        case .mixed:
            let combined = try buildMixed(frame: frame)
            if let combined {
                writerQueue.async { [self] in
                    self.enqueue(buffer: combined, on: .single)
                }
            }

        case .stereoSplit:
            let combined = try buildStereoSplit(frame: frame)
            if let combined {
                writerQueue.async { [self] in
                    self.enqueue(buffer: combined, on: .single)
                }
            }

        case .split:
            if let sys = frame.systemBuffer {
                writerQueue.async { [self] in
                    self.enqueue(buffer: sys, on: .systemSide)
                }
            }
            if let mic = frame.micBuffer {
                writerQueue.async { [self] in
                    self.enqueue(buffer: mic, on: .micSide)
                }
            }
        }
    }

    public func finalize(timeout: TimeInterval) async throws {
        // Decide whether to even run finalization; idempotent.
        let shouldRun: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            writerQueue.async { [self] in
                switch self.state {
                case .idle:
                    // Never started — nothing to do.
                    self.state = .completed
                    cont.resume(returning: false)
                case .completed, .failed, .finalizing:
                    cont.resume(returning: false)
                case .running:
                    self.state = .finalizing
                    cont.resume(returning: true)
                }
            }
        }
        guard shouldRun else { return }

        // Mark inputs finished and schedule endSession on the writer queue.
        // Then await each writer's finishWriting via withTimeout.
        let units: [WriterUnit] = await withCheckedContinuation { (cont: CheckedContinuation<[WriterUnit], Never>) in
            writerQueue.async { [self] in
                let endPTS = self._lastAppendedEndPTS ?? self._sessionStart ?? CMClockGetTime(CMClockGetHostTimeClock())

                var collected: [WriterUnit] = []
                if let u = self.singleWriter { collected.append(u) }
                if let u = self.systemWriter { collected.append(u) }
                if let u = self.micWriter { collected.append(u) }

                for unit in collected {
                    // CAP-8 (EVAL 2026-10-16): buffers still queued in
                    // `pending` were silently dropped by markAsFinished().
                    self.flushPending(unit: unit, timeout: min(timeout, 2))
                    // Mark finished and end session — these MUST run on the
                    // writer queue per research §5.4 (no concurrent append).
                    unit.input.markAsFinished()
                    if unit.writer.status == .writing {
                        unit.writer.endSession(atSourceTime: endPTS)
                    }
                }

                cont.resume(returning: collected)
            }
        }

        // Race finishWriting against the timeout, per writer.
        do {
            try await withTimeout(timeout) {
                await withTaskGroup(of: Void.self) { group in
                    for unit in units {
                        group.addTask {
                            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                unit.writer.finishWriting {
                                    cont.resume()
                                }
                            }
                        }
                    }
                }
            }
        } catch is TimeoutError {
            // Capture the current state under the queue, then throw.
            self.logger?.error("M4ARecorder.finalize: finishWriting timeout after \(timeout)s")
            await self.markFailedOnQueue()
            throw NtakkerError.writerFinalizationTimeout(self.options.output)
        }

        // Inspect each writer's status.
        var firstError: Error?
        for unit in units {
            switch unit.writer.status {
            case .completed:
                continue
            case .failed:
                firstError = firstError ?? unit.writer.error ?? NSError(
                    domain: "M4ARecorder",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "writer reported .failed without an underlying error"]
                )
            default:
                firstError = firstError ?? NSError(
                    domain: "M4ARecorder",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "writer ended in unexpected status \(unit.writer.status.rawValue)"]
                )
            }
        }

        if let firstError {
            await self.markFailedOnQueue()
            throw NtakkerError.finishWritingFailed(underlying: firstError)
        }

        await self.markCompletedOnQueue()
        self.logger?.info("M4ARecorder.finalize: completed (\(units.count) writer(s))")
    }

    // MARK: - State transitions (writerQueue-confined)

    private func markFailedOnQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerQueue.async { [self] in
                self.state = .failed
                cont.resume()
            }
        }
    }

    private func markCompletedOnQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerQueue.async { [self] in
                self.state = .completed
                cont.resume()
            }
        }
    }

    // MARK: - start() implementation (runs on writerQueue)

    private enum WriterTarget {
        case single
        case systemSide
        case micSide
    }

    private func startOnQueue() throws {
        precondition(state == .idle, "M4ARecorder.start() called twice")

        // Per research §2.3: capture host-clock NOW; never anchor session
        // start to a buffer's raw PTS (which on macOS is host uptime).
        let sessionStart = CMClockGetTime(CMClockGetHostTimeClock())
        _sessionStart = sessionStart

        switch options.layout {
        case .mixed, .stereoSplit:
            let unit = try buildWriter(at: options.output, sessionStart: sessionStart, label: "single")
            singleWriter = unit
            installDrainHandler(on: unit, target: .single)

        case .split:
            // Validate + materialize sibling paths.
            let systemURL = sidecarURL(base: options.output, side: "system")
            let micURL = sidecarURL(base: options.output, side: "mic")
            try preflightSidePath(systemURL)
            try preflightSidePath(micURL)

            let sysUnit = try buildWriter(at: systemURL, sessionStart: sessionStart, label: "system")
            let micUnit = try buildWriter(at: micURL, sessionStart: sessionStart, label: "mic")
            systemWriter = sysUnit
            micWriter = micUnit
            installDrainHandler(on: sysUnit, target: .systemSide)
            installDrainHandler(on: micUnit, target: .micSide)
        }

        state = .running
        logger?.info("M4ARecorder.start: layout=\(options.layout.rawValue) sessionStart=\(sessionStart.seconds)s")
    }

    private func sidecarURL(base: URL, side: String) -> URL {
        // For `split` we need two outputs. Convention: insert `.<side>`
        // before the file extension (e.g. `out.m4a` → `out.system.m4a`).
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let dir = base.deletingLastPathComponent()
        return dir.appendingPathComponent("\(stem).\(side).\(ext)")
    }

    private func preflightSidePath(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard options.overwrite else {
                throw NtakkerError.outputAlreadyExists(url)
            }
        }
    }

    private func buildWriter(at url: URL, sessionStart: CMTime, label: String) throws -> WriterUnit {
        // If the file exists at this point, the factory has already told
        // us `overwrite` is true; remove it so AVAssetWriter doesn't
        // refuse construction.
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw NtakkerError.writerFailedToStart(underlying: error)
            }
        }

        // 1. Channel layout (explicit kAudioChannelLayoutTag_Stereo per design §7.4).
        var channelLayout = AudioChannelLayout()
        memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(
            bytes: &channelLayout,
            count: MemoryLayout<AudioChannelLayout>.size
        )

        // 2. AAC outputSettings — verbatim from research §1.1 / design §7.4.
        let outputSettings: [String: Any] = [
            AVFormatIDKey:          Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:        options.sampleRate,
            AVNumberOfChannelsKey:  2,
            AVEncoderBitRateKey:    options.bitrate,
            AVChannelLayoutKey:     layoutData
        ]

        // 3. Writer.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw NtakkerError.writerFailedToStart(underlying: error)
        }
        writer.shouldOptimizeForNetworkUse = true                       // FR-21 / AC-7
        writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)   // FR-21 / research §5.3

        // 4. Input.
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NtakkerError.writerFailedToStart(
                underlying: NSError(
                    domain: "M4ARecorder",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "writer cannot accept audio input for \(label)"]
                )
            )
        }
        writer.add(input)

        // 5. Lifecycle: startWriting → startSession.
        guard writer.startWriting() else {
            let underlying = writer.error ?? NSError(
                domain: "M4ARecorder",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "startWriting() returned false (\(label))"]
            )
            throw NtakkerError.writerFailedToStart(underlying: underlying)
        }
        writer.startSession(atSourceTime: sessionStart)

        return WriterUnit(url: url, writer: writer, input: input)
    }

    // MARK: - append() helpers

    /// Build the buffer for `.mixed`: pointwise sum of the two
    /// sub-buffers, with `BufferSummer` handling clamping. Returns nil
    /// if there is nothing to append (both sides nil).
    private func buildMixed(frame: AlignedFrame) throws -> CMSampleBuffer? {
        do {
            return try BufferSummer.sum(frame.systemBuffer, frame.micBuffer)
        } catch {
            throw NtakkerError.ioError("M4ARecorder.buildMixed: \(error.localizedDescription)")
        }
    }

    /// Build the buffer for `.stereoSplit`: a non-interleaved stereo
    /// Float32 buffer where the mic occupies `options.micChannel` and
    /// the system audio the opposite channel.
    ///
    /// If either source delivers a multichannel buffer, this method
    /// downmixes it to mono first by averaging across channels (so the
    /// resulting mono is the simple sum/N of the input channels — no
    /// AGC, no panning compensation, per A-7).
    private func buildStereoSplit(frame: AlignedFrame) throws -> CMSampleBuffer? {
        // Treat a missing side as silence — the aligner usually gap-fills
        // upstream, but this keeps the recorder defensive.
        guard let mic = frame.micBuffer ?? frame.systemBuffer else {
            // Both nil → nothing to write.
            return nil
        }
        // Determine common parameters (sample rate, frame count) from
        // whichever side is present.
        let referenceForFmt = frame.micBuffer ?? frame.systemBuffer
        guard let referenceForFmt,
              let fmtDesc = CMSampleBufferGetFormatDescription(referenceForFmt),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            throw NtakkerError.ioError("M4ARecorder.buildStereoSplit: missing format description")
        }
        _ = mic  // silence unused warning when both sides are non-nil
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate
        let frameCount = CMSampleBufferGetNumSamples(referenceForFmt)
        guard frameCount > 0 else { return nil }

        // Derive mono samples for each side. Missing sides → array of
        // zeros (silence) of `frameCount`.
        let micMono = try monoSamples(from: frame.micBuffer, frameCount: frameCount)
        let sysMono = try monoSamples(from: frame.systemBuffer, frameCount: frameCount)

        // Pack into a non-interleaved stereo CMSampleBuffer. Channel 0
        // is "left", channel 1 is "right". `options.micChannel` selects
        // which one carries the mic.
        let micOnLeft = (options.micChannel == .left)
        let leftSamples  = micOnLeft ? micMono : sysMono
        let rightSamples = micOnLeft ? sysMono : micMono

        let pts = CMSampleBufferGetPresentationTimeStamp(referenceForFmt)
        return try makeStereoBuffer(
            left: leftSamples,
            right: rightSamples,
            frameCount: frameCount,
            sampleRate: sampleRate,
            pts: pts
        )
    }

    /// Read a CMSampleBuffer's Float32 non-interleaved samples and
    /// downmix to mono by averaging channels. Returns `frameCount`
    /// zeros if `buffer` is nil.
    private func monoSamples(from buffer: CMSampleBuffer?, frameCount: Int) throws -> [Float32] {
        guard let buffer else {
            return [Float32](repeating: 0, count: frameCount)
        }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(buffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            throw NtakkerError.ioError("M4ARecorder.monoSamples: missing format description")
        }
        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, isNonInterleaved, asbd.mBitsPerChannel == 32 else {
            throw NtakkerError.ioError(
                "M4ARecorder.monoSamples: only Float32 non-interleaved is supported (flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel))"
            )
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let bufferFrames = CMSampleBufferGetNumSamples(buffer)
        guard bufferFrames == frameCount else {
            throw NtakkerError.ioError(
                "M4ARecorder.monoSamples: frame-count mismatch (got=\(bufferFrames), expected=\(frameCount))"
            )
        }

        guard let bb = CMSampleBufferGetDataBuffer(buffer) else {
            throw NtakkerError.ioError("M4ARecorder.monoSamples: CMSampleBuffer has no data buffer")
        }
        let totalBytes = frameCount * channelCount * MemoryLayout<Float32>.size
        var raw = [Float32](repeating: 0, count: frameCount * channelCount)
        let status = raw.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                bb,
                atOffset: 0,
                dataLength: totalBytes,
                destination: UnsafeMutableRawPointer(base)
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw NtakkerError.ioError(
                "M4ARecorder.monoSamples: CMBlockBufferCopyDataBytes failed (status=\(status))"
            )
        }

        if channelCount == 1 {
            return raw
        }
        // Non-interleaved layout: [ch0_f0..ch0_fN-1, ch1_f0..ch1_fN-1, ...].
        var mono = [Float32](repeating: 0, count: frameCount)
        for c in 0..<channelCount {
            let offset = c * frameCount
            for i in 0..<frameCount {
                mono[i] += raw[offset + i]
            }
        }
        let scale = Float32(1.0 / Double(channelCount))
        for i in 0..<frameCount {
            mono[i] *= scale
        }
        return mono
    }

    /// Allocate a non-interleaved Float32 stereo CMSampleBuffer with
    /// the given mono samples on each channel.
    private func makeStereoBuffer(
        left: [Float32],
        right: [Float32],
        frameCount: Int,
        sampleRate: Double,
        pts: CMTime
    ) throws -> CMSampleBuffer {
        precondition(left.count == frameCount && right.count == frameCount,
                     "makeStereoBuffer: channel-sample length mismatch")

        let bytesPerSample = MemoryLayout<Float32>.size
        let bytesPerChannel = frameCount * bytesPerSample
        let totalBytes = bytesPerChannel * 2

        // Allocate an empty CMBlockBuffer.
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            throw NtakkerError.ioError(
                "M4ARecorder.makeStereoBuffer: CMBlockBufferCreateWithMemoryBlock failed (status=\(bbStatus))"
            )
        }

        // Copy left then right (non-interleaved layout).
        var copyStatus: OSStatus = noErr
        copyStatus = left.withUnsafeBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: UnsafeRawPointer(base),
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: bytesPerChannel
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw NtakkerError.ioError(
                "M4ARecorder.makeStereoBuffer: left-channel copy failed (status=\(copyStatus))"
            )
        }
        copyStatus = right.withUnsafeBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: UnsafeRawPointer(base),
                blockBuffer: bb,
                offsetIntoDestination: bytesPerChannel,
                dataLength: bytesPerChannel
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw NtakkerError.ioError(
                "M4ARecorder.makeStereoBuffer: right-channel copy failed (status=\(copyStatus))"
            )
        }

        // Build a Float32 non-interleaved stereo format description.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(bytesPerSample),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var fmtDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmtDesc
        )
        guard fmtStatus == noErr, let fmt = fmtDesc else {
            throw NtakkerError.ioError(
                "M4ARecorder.makeStereoBuffer: CMAudioFormatDescriptionCreate failed (status=\(fmtStatus))"
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw NtakkerError.ioError(
                "M4ARecorder.makeStereoBuffer: CMSampleBufferCreate failed (status=\(sbStatus))"
            )
        }
        return sb
    }

    // MARK: - Drain loop

    private func enqueue(buffer: CMSampleBuffer, on target: WriterTarget) {
        // writerQueue-confined.
        guard state == .running else { return }
        guard let unit = unit(for: target) else { return }

        unit.pending.append(buffer)
        let bufferEnd = Self.endTime(of: buffer)
        // Keep the latest end across the split-layout writers.
        if _lastAppendedEndPTS.map({ CMTimeCompare(bufferEnd, $0) > 0 }) ?? true {
            _lastAppendedEndPTS = bufferEnd
        }
        // No need to poke the input — its requestMediaDataWhenReady
        // callback will pull as soon as it's hungry. When it's already
        // ready (the common live-capture case) we still drain inline so
        // that buffers don't queue up unnecessarily.
        drain(unit: unit)
    }

    /// PTS + duration. Audio buffers built in this project carry a
    /// per-sample duration, for which `CMSampleBufferGetDuration`
    /// returns the whole-buffer duration; fall back to
    /// frames / sampleRate if a buffer arrives without timing.
    private static func endTime(of buffer: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        var duration = CMSampleBufferGetDuration(buffer)
        if !duration.isValid || duration.isIndefinite,
           let fmt = CMSampleBufferGetFormatDescription(buffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
           asbd.mSampleRate > 0 {
            duration = CMTime(
                value: CMTimeValue(CMSampleBufferGetNumSamples(buffer)),
                timescale: CMTimeScale(asbd.mSampleRate)
            )
        }
        guard duration.isValid, !duration.isIndefinite else { return pts }
        return CMTimeAdd(pts, duration)
    }

    private func unit(for target: WriterTarget) -> WriterUnit? {
        switch target {
        case .single:     return singleWriter
        case .systemSide: return systemWriter
        case .micSide:    return micWriter
        }
    }

    /// Finalize-time drain: append every still-pending buffer before
    /// `markAsFinished()`. Runs on `writerQueue`, which is exactly where
    /// `requestMediaDataWhenReady` would deliver its callback — so it
    /// cannot wait for that callback and polls `isReadyForMoreMediaData`
    /// instead, bounded by `timeout`.
    private func flushPending(unit: WriterUnit, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !unit.pending.isEmpty, unit.failure == nil, unit.writer.status == .writing {
            drain(unit: unit)
            if unit.pending.isEmpty || Date() >= deadline { break }
            usleep(2_000)
        }
        if !unit.pending.isEmpty {
            logger?.warning(
                "M4ARecorder.finalize: dropping \(unit.pending.count) pending buffer(s) for \(unit.url.lastPathComponent) (writer not ready within \(timeout)s)"
            )
        }
    }

    /// Pull pending buffers and call `input.append` while the input is
    /// hungry. Runs on `writerQueue`.
    private func drain(unit: WriterUnit) {
        while unit.input.isReadyForMoreMediaData, !unit.pending.isEmpty {
            let buf = unit.pending.removeFirst()
            if !unit.input.append(buf) {
                let err = unit.writer.error ?? NSError(
                    domain: "M4ARecorder",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: "AVAssetWriterInput.append returned false"]
                )
                unit.failure = err
                logger?.error("M4ARecorder.drain: append failed for \(unit.url.lastPathComponent): \(err.localizedDescription)")
                // Stop draining; subsequent appends will surface the failure.
                return
            }
        }
    }

    private func installDrainHandler(on unit: WriterUnit, target: WriterTarget) {
        // The handler runs on writerQueue. Per Apple's docs this can be
        // invoked many times across the input's lifetime; we simply
        // attempt to drain whatever's pending.
        unit.input.requestMediaDataWhenReady(on: writerQueue) { [weak self, weak unit] in
            guard let self, let unit else { return }
            self.drain(unit: unit)
        }
    }

    // MARK: - Async helpers

    /// Trampoline: run `body` on `writerQueue` and bridge errors back
    /// into the async world.
    private func runOnWriterQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            writerQueue.async {
                do {
                    cont.resume(returning: try body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Race `operation` against a real-time timeout. If `operation`
    /// finishes first, returns its value. If the timeout fires first,
    /// throws `TimeoutError`.
    ///
    /// Note: we cannot cancel the AVAssetWriter's `finishWriting`
    /// completion — the OS holds that callback and will fire it
    /// eventually. The orchestrator's exit logic must be prepared for
    /// the temp file to materialize after the timeout.
    private func withTimeout<T>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                let value = await operation()
                return value
            }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                return nil
            }
            // First task to return wins.
            for try await value in group {
                if let value {
                    group.cancelAll()
                    return value
                } else {
                    group.cancelAll()
                    throw TimeoutError()
                }
            }
            throw TimeoutError()
        }
    }
}

// MARK: - Internal error sentinel

/// Sentinel used internally by `M4ARecorder.withTimeout` to signal that
/// the timeout branch won the race.
private struct TimeoutError: Error {}
