// NtakkerCore/Encoding/CAFRecorder.swift — see project-design.md §2.10 / §7.6
// and `docs/research/avassetwriter-aac.md` §1.3, §6.3.
//
// Phase H (plan-001 Wave 3b) — `Recorder` conformance for `.caf` output.
//
// Format-selection policy (v1):
//
//   The `.caf` container can carry many codecs; v1 supports PCM only
//   (per design §2.10 — `bitDepth: Int = 24` default — and §7.6 which
//   pins big-endian Linear PCM). AAC-in-CAF is intentionally OUT OF
//   SCOPE for v1: research §6.3 ("AVAssetWriter for AAC-CAF if required
//   (not in our v1 scope)") and the absence of a CAF AAC `outputSettings`
//   block in design §7 confirm this. Users who want AAC should choose
//   `--format m4a` (the recommended path for broad compatibility).
//
//   The Phase H dispatch prompt suggested "default to AAC when no
//   --bit-depth is passed", but `RecordingOptions.bitDepth` is a
//   non-optional `Int` with a hard-coded default of 16, so there is no
//   way at this layer to distinguish "user explicitly set 16" from
//   "user accepted the default". Implementing AAC-CAF would also
//   require its own AVAssetWriter wiring + priming-pad handling
//   parallel to M4ARecorder, doubling the surface for a feature with
//   no v1 customer use case. The deviation is documented in this
//   header so the Code Reviewer can audit it.
//
// Pipeline (mirrors `WAVRecorder`):
//
//   AlignedFrame (Float32 non-interleaved 48 kHz stereo CMSampleBuffer)
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
//                              big-endian Int16/Int24 PCM declared in
//                              `outputSettings`. Per research §6.3
//                              "24-bit PCM is cleanly supported (unlike
//                               WAV where float-to-int conversion has
//                               known CoreAudio bugs)".
//
// Bit-depth handling: same auto-conversion path as `WAVRecorder` —
// `AVAudioFile` performs Float32 → Int16/Int24 conversion based on
// `AVLinearPCMBitDepthKey`. The big-endian flag is the only on-disk
// difference from WAV (CAF is big-endian by default; design §7.6).

import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import Logging

public final class CAFRecorder: Recorder, @unchecked Sendable {

    // MARK: - Configuration (immutable)

    private let options: RecordingOptions
    private let logger: Logging.Logger
    /// Float32 non-interleaved processing format (matches the
    /// post-aligner CMSampleBuffer contract).
    private let processingFormat: AVAudioFormat

    // MARK: - Mutable state, confined to `writerQueue`

    private let writerQueue: DispatchQueue

    private var primaryFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?

    private var didFinalize: Bool = false
    private var didStart: Bool = false

    // MARK: - Init

    public init(options: RecordingOptions, logger: Logging.Logger? = nil) {
        self.options = options
        self.logger = logger ?? LoggerFactory.make("ntakker-cli.recorder.caf")
        self.writerQueue = DispatchQueue(
            label: "ntakker-cli.recorder.caf.writer",
            qos: .userInitiated
        )

        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(options.sampleRate),
            channels: 2,
            interleaved: false
        ) else {
            preconditionFailure(
                "CAFRecorder: failed to build Float32 processing format at \(options.sampleRate) Hz / 2 ch"
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
        let pendingFrame = frame
        writerQueue.async { [self] in
            do {
                try self._appendSync(pendingFrame)
            } catch {
                self.logger.error(
                    "CAFRecorder: append failed: \(error.localizedDescription)"
                )
            }
        }
    }

    public func finalize(timeout: TimeInterval) async throws {
        // CAF PCM finalize is effectively synchronous — `AVAudioFile`
        // flushes the `pakt` chunk and closes the file on dealloc;
        // no priming/encoder pipeline to drain.
        _ = timeout

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writerQueue.async { [self] in
                self._finalizeSync()
                cont.resume()
            }
        }
    }

    // MARK: - start() implementation (writerQueue)

    private func _startSync() throws {
        guard !didStart else {
            throw NtakkerError.ioError("CAFRecorder.start(): already started")
        }
        didStart = true

        switch options.layout {
        case .mixed, .stereoSplit:
            try validateOutputPath(options.output, overwrite: options.overwrite)
        case .split:
            let (micURL, systemURL) = splitPaths(for: options.output)
            try validateOutputPath(micURL, overwrite: options.overwrite)
            try validateOutputPath(systemURL, overwrite: options.overwrite)
        }

        let settings = makeOutputSettings(bitDepth: options.bitDepth)

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
            "CAFRecorder: opened \(options.output.path) (layout=\(options.layout.rawValue), bitDepth=\(options.bitDepth))"
        )
    }

    // MARK: - append() implementation (writerQueue)

    private func _appendSync(_ frame: AlignedFrame) throws {
        guard !didFinalize else { return }
        guard didStart else {
            throw NtakkerError.ioError("CAFRecorder.append: called before start()")
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
        guard let summed = try BufferSummer.sum(frame.systemBuffer, frame.micBuffer) else {
            return
        }
        let pcm = try pcmBuffer(from: summed, format: processingFormat)
        try writeOrLog(pcm, to: primaryFile, label: "primary")
    }

    private func appendStereoSplit(_ frame: AlignedFrame) throws {
        let micCh = options.micChannel == .left ? 0 : 1
        let sysCh = 1 - micCh

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
            throw NtakkerError.ioError("CAFRecorder: failed to allocate stereo-split buffer")
        }
        stereo.frameLength = frames

        guard let outChannels = stereo.floatChannelData else {
            throw NtakkerError.ioError("CAFRecorder: stereo-split buffer missing floatChannelData")
        }
        for c in 0..<Int(processingFormat.channelCount) {
            memset(outChannels[c], 0, Int(frames) * MemoryLayout<Float32>.size)
        }

        if let mic = micPCM, let micChannels = mic.floatChannelData {
            downmixOrCopy(
                src: micChannels,
                srcChannelCount: Int(mic.format.channelCount),
                dst: outChannels[micCh],
                frameCount: Int(frames)
            )
        }

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
            throw NtakkerError.ioError("CAFRecorder: \(label) file is nil")
        }
        do {
            try f.write(from: buffer)
        } catch {
            throw NtakkerError.finishWritingFailed(underlying: error)
        }
    }

    // MARK: - finalize() implementation (writerQueue)

    private func _finalizeSync() {
        guard !didFinalize else { return }
        didFinalize = true

        primaryFile = nil
        micFile = nil
        systemFile = nil

        logger.info("CAFRecorder: finalized \(options.output.path)")
    }

    // MARK: - Helpers

    /// Build the on-disk PCM settings dictionary (verbatim per design
    /// §7.6 — big-endian Linear PCM at the configured bit depth).
    private func makeOutputSettings(bitDepth: Int) -> [String: Any] {
        return [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             Double(options.sampleRate),
            AVNumberOfChannelsKey:       2,
            AVLinearPCMBitDepthKey:      bitDepth,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   true,           // CAF = big-endian
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Convert a Float32 non-interleaved CMSampleBuffer to an
    /// AVAudioPCMBuffer matching `format`. Identical to WAVRecorder's
    /// conversion — kept as a private member here to avoid cross-file
    /// shared state during Wave 3b (the only file the prompt allows
    /// us to write is this one).
    private func pcmBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            throw NtakkerError.ioError("CAFRecorder: empty CMSampleBuffer (frames=0)")
        }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            throw NtakkerError.ioError("CAFRecorder: CMSampleBuffer has no format description")
        }
        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, isNonInterleaved, asbd.mBitsPerChannel == 32 else {
            throw NtakkerError.ioError(
                "CAFRecorder: input must be Float32 non-interleaved (flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel))"
            )
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let formatToUse: AVAudioFormat
        if Int(format.channelCount) == channelCount,
           format.sampleRate == asbd.mSampleRate {
            formatToUse = format
        } else {
            guard let f = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
                throw NtakkerError.ioError("CAFRecorder: failed to build matching AVAudioFormat")
            }
            formatToUse = f
        }

        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: formatToUse,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw NtakkerError.ioError("CAFRecorder: AVAudioPCMBuffer allocation failed")
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let dstChannels = pcm.floatChannelData else {
            throw NtakkerError.ioError("CAFRecorder: floatChannelData unavailable on output PCM")
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NtakkerError.ioError("CAFRecorder: CMSampleBuffer has no data buffer")
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
                    "CAFRecorder: CMBlockBufferCopyDataBytes failed (status=\(copyStatus), channel=\(c))"
                )
            }
        }
        return pcm
    }

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
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Split-layout file naming: `<basename>.mic.<ext>` and
    /// `<basename>.system.<ext>` siblings of `options.output`.
    /// e.g. `/tmp/rec.caf` → (`/tmp/rec.mic.caf`, `/tmp/rec.system.caf`).
    private func splitPaths(for output: URL) -> (mic: URL, system: URL) {
        let ext = output.pathExtension                     // "caf"
        let stem = output.deletingPathExtension()           // "/tmp/rec"
        let micURL = stem
            .appendingPathExtension("mic")
            .appendingPathExtension(ext)                    // "/tmp/rec.mic.caf"
        let systemURL = stem
            .appendingPathExtension("system")
            .appendingPathExtension(ext)                    // "/tmp/rec.system.caf"
        return (micURL, systemURL)
    }
}
