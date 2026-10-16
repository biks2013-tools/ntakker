// NtakkerCore/Encoding/WAVRecorder.swift — see project-design.md §2.10 / §7.5
// and `docs/research/avassetwriter-aac.md` §1.2, §6.2.
//
// Phase H (plan-001 Wave 3b) — `Recorder` conformance for `.wav` output.
//
// Pipeline:
//
//   AlignedFrame (Float32 non-interleaved, 48 kHz stereo CMSampleBuffer)
//       │
//       ├── layout=mixed       → BufferSummer.sum(system, mic)
//       ├── layout=stereoSplit → channel-pinned 2-channel buffer
//       └── layout=split       → mic & system written to separate files
//       │
//       ▼
//   AVAudioPCMBuffer (Float32, processing format)
//       │
//       ▼
//   AVAudioFile.write(from:) — AVAudioFile transcodes to the on-disk
//                              format declared in `outputSettings`
//                              (Int16 LE or Int24 LE per FR-7).
//
// Bit-depth handling: we let `AVAudioFile` perform the Float32 → Int16
// or Float32 → Int24 little-endian conversion via its `outputSettings`
// dictionary. This is the path explicitly endorsed by research §6.2:
// "AVAudioFile with `commonFormat: .pcmFormatFloat32` accepts Float32
// and converts to the on-disk format automatically." It avoids the
// hand-rolled vDSP_vfix16 / packed-Int24 conversion (the CMSampleBuffer
// → AVAudioPCMBuffer step is the only conversion we own here).
//
// 24-bit note: WAV's 24-bit PCM is `mBitsPerChannel = 24` with
// `kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked`.
// Per design §7.5 the same `outputSettings` dictionary works for both
// 16- and 24-bit (only `AVLinearPCMBitDepthKey` changes); AVAudioFile
// builds the right ASBD internally, so we do NOT need a manual
// `AudioStreamBasicDescription`. If a future macOS regresses
// `AVAudioFile`'s handling of 24-bit, the manual ASBD route lives
// behind `makeOutputFormat(...)` and can be swapped in there.
//
// AAC priming, `movieFragmentInterval`, and `shouldOptimizeForNetworkUse`
// are N/A for WAV (uncompressed PCM in a sequentially-written RIFF
// container — no encoder delay, no moov atom).

import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

public final class WAVRecorder: Recorder, @unchecked Sendable {

    // MARK: - Configuration (immutable)

    private let options: RecordingOptions
    private let logger: Logging.Logger
    /// Processing format fed to `AVAudioFile.write(from:)`: Float32
    /// non-interleaved, 48 kHz, stereo. Matches the post-aligner
    /// CMSampleBuffer contract (HostClockAligner → Float32/non-interleaved
    /// per `SilenceBufferFactory.makeFloat32FormatDescription`).
    private let processingFormat: AVAudioFormat

    // MARK: - Mutable state, confined to `writerQueue`

    private let writerQueue: DispatchQueue

    /// Mixed / stereo-split: single output file. Split-layout: nil here
    /// and the pair below is populated.
    private var primaryFile: AVAudioFile?

    /// Split-layout only.
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?

    /// Set by `finalize` so that double-finalize is a no-op (idempotency
    /// per `Recorder.finalize` contract).
    private var didFinalize: Bool = false

    /// Tracked so `start()` can be guarded against double invocation.
    private var didStart: Bool = false

    /// First write error from the async writer queue. `append` hops
    /// queues, so a failed `AVAudioFile.write` (disk full, volume
    /// removed) cannot be thrown to the producer directly. Before
    /// EVAL-2026-10-16 CAP-7 it was only logged — every ~100 ms — and
    /// `finalize` reported success on a truncated file. Now the next
    /// `append` and `finalize` rethrow it, so `RecordingSession` stops
    /// the recording and surfaces the error.
    private let latchedWriteError = OSAllocatedUnfairLock<Error?>(initialState: nil)

    // MARK: - Init

    public init(options: RecordingOptions, logger: Logging.Logger? = nil) {
        self.options = options
        self.logger = logger ?? LoggerFactory.make("ntakker-cli.recorder.wav")
        self.writerQueue = DispatchQueue(
            label: "ntakker-cli.recorder.wav.writer",
            qos: .userInitiated
        )

        // Float32 non-interleaved, channels=2, sampleRate=48 kHz —
        // the canonical post-aligner format. Force-unwrap is safe:
        // AVAudioFormat returns nil only for invalid combinations
        // and Float32/48k/stereo is always valid.
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(options.sampleRate),
            channels: 2,
            interleaved: false
        ) else {
            preconditionFailure(
                "WAVRecorder: failed to build Float32 processing format at \(options.sampleRate) Hz / 2 ch"
            )
        }
        self.processingFormat = fmt
    }

    // MARK: - Recorder protocol

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writerQueue.async { [self] in
                do {
                    try self._startSync()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func append(_ frame: AlignedFrame) throws {
        if let err = latchedWriteError.withLock({ $0 }) { throw err }
        // CMSampleBuffers are CF types with thread-safe retain semantics
        // (matching the AlignedFrame envelope's `@unchecked Sendable`).
        let pendingFrame = frame
        writerQueue.async { [self] in
            guard self.latchedWriteError.withLock({ $0 }) == nil else { return }
            do {
                try self._appendSync(pendingFrame)
            } catch {
                self.latchedWriteError.withLock { if $0 == nil { $0 = error } }
                self.logger.error(
                    "WAVRecorder: append failed (recording will stop): \(error.localizedDescription)"
                )
            }
        }
    }

    public func finalize(timeout: TimeInterval) async throws {
        // WAV finalize is effectively synchronous — `AVAudioFile` flushes
        // and closes the underlying file on dealloc (ARC). The `timeout`
        // parameter is honored only as an upper bound; we expect to
        // complete in microseconds.
        _ = timeout

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writerQueue.async { [self] in
                self._finalizeSync()
                if let err = self.latchedWriteError.withLock({ $0 }) {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            }
        }
    }

    // MARK: - start() implementation (writerQueue)

    private func _startSync() throws {
        guard !didStart else {
            throw NtakkerError.ioError("WAVRecorder.start(): already started")
        }
        didStart = true

        // 1. Validate the output path (the factory in Recorder.swift
        // does this too, but for `split` layout the factory only sees
        // the canonical `options.output` — we re-validate the per-side
        // sibling paths here).
        switch options.layout {
        case .mixed, .stereoSplit:
            try validateOutputPath(options.output, overwrite: options.overwrite)
        case .split:
            let (micURL, systemURL) = splitPaths(for: options.output)
            try validateOutputPath(micURL, overwrite: options.overwrite)
            try validateOutputPath(systemURL, overwrite: options.overwrite)
        }

        // 2. Build the on-disk-format settings dictionary (design §7.5).
        let settings = makeOutputSettings(bitDepth: options.bitDepth)

        // 3. Open the AVAudioFile(s).
        do {
            switch options.layout {
            case .mixed, .stereoSplit:
                primaryFile = try AVAudioFile(
                    forWriting: options.output,
                    settings: settings,
                    commonFormat: processingFormat.commonFormat,
                    interleaved: processingFormat.isInterleaved
                )
            case .split:
                let (micURL, systemURL) = splitPaths(for: options.output)
                micFile = try AVAudioFile(
                    forWriting: micURL,
                    settings: settings,
                    commonFormat: processingFormat.commonFormat,
                    interleaved: processingFormat.isInterleaved
                )
                systemFile = try AVAudioFile(
                    forWriting: systemURL,
                    settings: settings,
                    commonFormat: processingFormat.commonFormat,
                    interleaved: processingFormat.isInterleaved
                )
            }
        } catch {
            throw NtakkerError.writerFailedToStart(underlying: error)
        }

        logger.info(
            "WAVRecorder: opened \(options.output.path) (layout=\(options.layout.rawValue), bitDepth=\(options.bitDepth))"
        )
    }

    // MARK: - append() implementation (writerQueue)

    private func _appendSync(_ frame: AlignedFrame) throws {
        guard !didFinalize else { return }
        guard didStart else {
            throw NtakkerError.ioError("WAVRecorder.append: called before start()")
        }

        switch options.layout {
        case .mixed:
            try appendMixed(frame)
        case .stereoSplit:
            try appendStereoSplit(frame)
        case .split:
            try appendSplit(frame)
        }
    }

    private func appendMixed(_ frame: AlignedFrame) throws {
        // Sum mic + system; if exactly one is present BufferSummer
        // returns it untouched; if both are nil we have nothing to
        // write for this slice.
        guard let summed = try BufferSummer.sum(frame.systemBuffer, frame.micBuffer) else {
            return
        }
        let pcm = try pcmBuffer(from: summed, format: processingFormat)
        try writeOrLog(pcm, to: primaryFile, label: "primary")
    }

    private func appendStereoSplit(_ frame: AlignedFrame) throws {
        // Build a 2-channel buffer with mic on the configured channel
        // and system on the other. If a side is missing we treat its
        // channel as silent for this slice.
        let micCh = options.micChannel == .left ? 0 : 1
        let sysCh = 1 - micCh

        // Frame count: derived from whichever side is present; if both
        // are nil there's nothing to write.
        let micPCM = try frame.micBuffer.map { try pcmBuffer(from: $0, format: processingFormat) }
        let sysPCM = try frame.systemBuffer.map { try pcmBuffer(from: $0, format: processingFormat) }

        let frames: AVAudioFrameCount = {
            if let m = micPCM, let s = sysPCM {
                return min(m.frameLength, s.frameLength)
            }
            return micPCM?.frameLength ?? sysPCM?.frameLength ?? 0
        }()
        guard frames > 0 else { return }

        guard let stereo = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frames) else {
            throw NtakkerError.ioError("WAVRecorder: failed to allocate stereo-split buffer")
        }
        stereo.frameLength = frames

        guard let outChannels = stereo.floatChannelData else {
            throw NtakkerError.ioError("WAVRecorder: stereo-split buffer missing floatChannelData")
        }

        // Zero-fill (so a missing side stays silent).
        for c in 0..<Int(processingFormat.channelCount) {
            memset(outChannels[c], 0, Int(frames) * MemoryLayout<Float32>.size)
        }

        // Pin mic. Mic is 2 channels (post-aligner stereo); we average
        // its channels into a single channel before pinning, to avoid
        // either-channel bias when downmixing for stereo-split.
        if let mic = micPCM, let micChannels = mic.floatChannelData {
            downmixOrCopy(
                src: micChannels,
                srcChannelCount: Int(mic.format.channelCount),
                dst: outChannels[micCh],
                frameCount: Int(frames)
            )
        }

        // Pin system on the opposite channel (same downmix policy).
        if let sys = sysPCM, let sysChannels = sys.floatChannelData {
            downmixOrCopy(
                src: sysChannels,
                srcChannelCount: Int(sys.format.channelCount),
                dst: outChannels[sysCh],
                frameCount: Int(frames)
            )
        }

        try writeOrLog(stereo, to: primaryFile, label: "primary")
    }

    private func appendSplit(_ frame: AlignedFrame) throws {
        if let mic = frame.micBuffer {
            let pcm = try pcmBuffer(from: mic, format: processingFormat)
            try writeOrLog(pcm, to: micFile, label: "mic")
        }
        if let sys = frame.systemBuffer {
            let pcm = try pcmBuffer(from: sys, format: processingFormat)
            try writeOrLog(pcm, to: systemFile, label: "system")
        }
    }

    private func writeOrLog(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile?, label: String) throws {
        guard let f = file else {
            throw NtakkerError.ioError("WAVRecorder: \(label) file is nil")
        }
        do {
            try f.write(from: buffer)
        } catch {
            // Wrap as a finalization-class error — the protocol does not
            // have a dedicated "write failed mid-stream" case, and this
            // surfaces with the same exit code (1) as `finishWritingFailed`
            // / `ioError` per design §9.5.
            throw NtakkerError.finishWritingFailed(underlying: error)
        }
    }

    // MARK: - finalize() implementation (writerQueue)

    private func _finalizeSync() {
        guard !didFinalize else { return }
        didFinalize = true

        // Drop strong references; ARC closes each AVAudioFile
        // synchronously here (the file is bytes-on-disk, no async
        // encoder pipeline to flush).
        primaryFile = nil
        micFile = nil
        systemFile = nil

        logger.info("WAVRecorder: finalized \(options.output.path)")
    }

    // MARK: - Helpers

    /// Build the on-disk PCM settings dictionary (verbatim per design
    /// §7.5; values come from `RecordingOptions`).
    private func makeOutputSettings(bitDepth: Int) -> [String: Any] {
        return [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             Double(options.sampleRate),
            AVNumberOfChannelsKey:       2,
            AVLinearPCMBitDepthKey:      bitDepth,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,           // WAV = little-endian
            AVLinearPCMIsNonInterleaved: false,           // WAV = interleaved
        ]
    }

    /// Convert a Float32 non-interleaved CMSampleBuffer to an
    /// AVAudioPCMBuffer in the same processing format. The resulting
    /// PCM buffer can be passed straight to `AVAudioFile.write(from:)`
    /// — AVAudioFile will transcode to the on-disk integer format.
    private func pcmBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            throw NtakkerError.ioError("WAVRecorder: empty CMSampleBuffer (frames=0)")
        }

        // Validate ASBD against expectations (Float32 non-interleaved).
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            throw NtakkerError.ioError("WAVRecorder: CMSampleBuffer has no format description")
        }
        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, isNonInterleaved, asbd.mBitsPerChannel == 32 else {
            throw NtakkerError.ioError(
                "WAVRecorder: input must be Float32 non-interleaved (flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel))"
            )
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let formatToUse: AVAudioFormat
        if Int(format.channelCount) == channelCount,
           format.sampleRate == asbd.mSampleRate {
            formatToUse = format
        } else {
            // Fallback: build a matching format on the fly. This path
            // is a defense against a future aligner change; in v1 the
            // aligner always emits 48 kHz / 2 ch so the fast path
            // above is taken.
            guard let f = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
                throw NtakkerError.ioError("WAVRecorder: failed to build matching AVAudioFormat")
            }
            formatToUse = f
        }

        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: formatToUse,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NtakkerError.ioError("WAVRecorder: AVAudioPCMBuffer allocation failed")
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let dstChannels = pcm.floatChannelData else {
            throw NtakkerError.ioError("WAVRecorder: floatChannelData unavailable on output PCM")
        }

        // Read sample bytes out of the CMBlockBuffer. Float32 non-interleaved
        // layout is channel-major: channel 0 frames followed by channel 1
        // frames.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NtakkerError.ioError("WAVRecorder: CMSampleBuffer has no data buffer")
        }

        let bytesPerChannel = frameCount * MemoryLayout<Float32>.size
        for c in 0..<channelCount {
            let offset = c * bytesPerChannel
            let copyStatus = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: offset,
                dataLength: bytesPerChannel,
                destination: UnsafeMutableRawPointer(dstChannels[c])
            )
            guard copyStatus == kCMBlockBufferNoErr else {
                throw NtakkerError.ioError(
                    "WAVRecorder: CMBlockBufferCopyDataBytes failed (status=\(copyStatus), channel=\(c))"
                )
            }
        }
        return pcm
    }

    /// Mix-down `srcChannelCount` channels from `src` into the single
    /// destination channel `dst`, scaling by `1.0 / channelCount` to
    /// preserve headroom. When `srcChannelCount == 1` this is a plain
    /// memcpy.
    private func downmixOrCopy(
        src: UnsafePointer<UnsafeMutablePointer<Float>>,
        srcChannelCount: Int,
        dst: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        if srcChannelCount == 1 {
            memcpy(dst, src[0], frameCount * MemoryLayout<Float32>.size)
            return
        }
        // Sum all source channels into `dst` (zero-init by caller),
        // then scale by 1/channelCount.
        memcpy(dst, src[0], frameCount * MemoryLayout<Float32>.size)
        for c in 1..<srcChannelCount {
            vDSP_vadd(
                dst, 1,
                src[c], 1,
                dst, 1,
                vDSP_Length(frameCount)
            )
        }
        var scale: Float = 1.0 / Float(srcChannelCount)
        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
    }

    /// Path validation — the factory does this for `mixed` /
    /// `stereoSplit` output, but `split` layout's per-side paths
    /// are derived here.
    private func validateOutputPath(_ url: URL, overwrite: Bool) throws {
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir)
        guard parentExists, isDir.boolValue else {
            throw NtakkerError.outputParentMissing(url)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            guard overwrite else {
                throw NtakkerError.outputAlreadyExists(url)
            }
            // Honor `--overwrite`: remove the prior file so AVAudioFile
            // doesn't append/overlap.
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Split-layout file naming: `<basename>.mic.<ext>` and
    /// `<basename>.system.<ext>` siblings of `options.output`.
    /// e.g. `/tmp/rec.wav` → (`/tmp/rec.mic.wav`, `/tmp/rec.system.wav`).
    private func splitPaths(for output: URL) -> (mic: URL, system: URL) {
        let ext = output.pathExtension                     // "wav"
        let stem = output.deletingPathExtension()           // "/tmp/rec"
        let micURL = stem
            .appendingPathExtension("mic")
            .appendingPathExtension(ext)                    // "/tmp/rec.mic.wav"
        let systemURL = stem
            .appendingPathExtension("system")
            .appendingPathExtension(ext)                    // "/tmp/rec.system.wav"
        return (micURL, systemURL)
    }
}
