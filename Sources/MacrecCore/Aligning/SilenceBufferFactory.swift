// MacrecCore/Aligning/SilenceBufferFactory.swift — see project-design.md §2.9
// and `docs/research/avassetwriter-aac.md` §4.3.
//
// Phase F (plan-001) — synthesizes silent `CMSampleBuffer`s in the
// pipeline canonical format (Float32, non-interleaved) used by the
// aligner to fill gaps when one source stalls.
//
// Two entry points are exposed:
//
//   * `make(pts:sampleRate:channelCount:frameCount:)` — the shape the
//     aligner uses internally. Builds its own `AudioStreamBasicDescription`
//     and `CMAudioFormatDescription` from primitives. Caller-controlled
//     inputs guarantee correctness, so any `OSStatus != noErr` is a
//     programming error and we crash via `fatalError` rather than
//     throwing (the production call site cannot recover anyway).
//
//   * `makeSilence(startPTS:duration:formatDescription:sampleRate:)` —
//     the design §2.9 signature, kept so downstream phases (G, H, I, J)
//     can synthesize silence using an existing format description without
//     re-deriving the ASBD. Throws `MacrecError.ioError` on bad inputs
//     or Core Media failures.

import CoreAudio
import CoreMedia
import Foundation

public enum SilenceBufferFactory {

    // MARK: - Primary (Phase F internal) API

    /// Synthesize a Float32 non-interleaved silent `CMSampleBuffer`
    /// with `frameCount` frames of zeros at `sampleRate` / `channelCount`.
    ///
    /// The output buffer is indistinguishable in shape from a
    /// `FakeAudioSource` `silence`-mode emission: same ASBD flags
    /// (`kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
    /// kAudioFormatFlagIsNonInterleaved`), same `bytesPerFrame`, same
    /// constant-size sample-buffer convention (`sampleSizeEntryCount: 0`).
    ///
    /// - Parameters:
    ///   - pts: The presentation timestamp for the buffer's first sample
    ///     (host-clock domain).
    ///   - sampleRate: Audio sample rate in Hz. Must be > 0.
    ///   - channelCount: Number of audio channels. Must be >= 1.
    ///   - frameCount: Number of audio frames in the buffer. Must be > 0.
    ///
    /// - Returns: A ready-to-append `CMSampleBuffer`.
    ///
    /// - Important: This function crashes on Core Media failures because
    ///   the inputs are caller-controlled and any failure indicates a
    ///   programming error. The aligner cannot recover anyway.
    public static func make(
        pts: CMTime,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int
    ) -> CMSampleBuffer {
        precondition(sampleRate > 0, "SilenceBufferFactory.make: sampleRate must be > 0")
        precondition(channelCount >= 1, "SilenceBufferFactory.make: channelCount must be >= 1")
        precondition(frameCount > 0, "SilenceBufferFactory.make: frameCount must be > 0")

        let formatDescription = makeFloat32FormatDescription(
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        do {
            return try makeBuffer(
                startPTS: pts,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleRate: sampleRate,
                formatDescription: formatDescription
            )
        } catch {
            assertionFailure("SilenceBufferFactory.make: synthesis failed: \(error)")
            fatalError("SilenceBufferFactory.make: synthesis failed: \(error)")
        }
    }

    // MARK: - Design §2.9 signature (used by downstream phases)

    /// Build a silence buffer covering `duration` against a pre-existing
    /// format description. Used by gap-handling code paths that already
    /// know the source's CMAudioFormatDescription (e.g. to round-trip
    /// the same ASBD flags as the live source).
    ///
    /// - Throws: `MacrecError.ioError` if `duration` resolves to zero
    ///   frames, if the format description is not non-interleaved
    ///   Float32, or if Core Media returns a non-zero `OSStatus`.
    public static func makeSilence(
        startPTS: CMTime,
        duration: CMTime,
        formatDescription: CMAudioFormatDescription,
        sampleRate: Double = 48_000
    ) throws -> CMSampleBuffer {
        guard sampleRate > 0 else {
            throw MacrecError.ioError("SilenceBufferFactory: sampleRate must be > 0")
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw MacrecError.ioError("SilenceBufferFactory: duration must be a positive finite CMTime")
        }

        let frameCount = Int((durationSeconds * sampleRate).rounded())
        guard frameCount > 0 else {
            throw MacrecError.ioError("SilenceBufferFactory: duration rounds to zero frames at \(sampleRate) Hz")
        }

        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw MacrecError.ioError("SilenceBufferFactory: format description has no ASBD")
        }
        let asbd = asbdPtr.pointee

        // Validate Float32 non-interleaved per the pipeline canonical format.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, isNonInterleaved, asbd.mBitsPerChannel == 32 else {
            throw MacrecError.ioError(
                "SilenceBufferFactory: format must be Float32 non-interleaved (got flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel))"
            )
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        guard channelCount >= 1 else {
            throw MacrecError.ioError("SilenceBufferFactory: channel count must be >= 1")
        }

        return try makeBuffer(
            startPTS: startPTS,
            frameCount: frameCount,
            channelCount: channelCount,
            sampleRate: sampleRate,
            formatDescription: formatDescription
        )
    }

    // MARK: - Shared core

    /// Allocate a zeroed CMBlockBuffer + wrap into a CMSampleBuffer.
    /// Throws `MacrecError.ioError` on any Core Media failure.
    private static func makeBuffer(
        startPTS: CMTime,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let bytesPerSample = MemoryLayout<Float32>.size
        let totalBytes = bytesPerSample * frameCount * channelCount

        // 1. Allocate the underlying CMBlockBuffer.
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
            throw MacrecError.ioError(
                "SilenceBufferFactory: CMBlockBufferCreateWithMemoryBlock failed (status=\(bbStatus))"
            )
        }

        // 2. Zero-fill (silence). `CMBlockBufferFillDataBytes` is the
        //    canonical zero API per `docs/research/avassetwriter-aac.md`
        //    §4.3.
        let fillStatus = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: bb,
            offsetIntoDestination: 0,
            dataLength: totalBytes
        )
        guard fillStatus == kCMBlockBufferNoErr else {
            throw MacrecError.ioError(
                "SilenceBufferFactory: CMBlockBufferFillDataBytes failed (status=\(fillStatus))"
            )
        }

        // 3. Timing. For non-interleaved LPCM the per-sample duration
        //    is one tick at `sampleRate` and CoreMedia multiplies by
        //    `numSamples` internally. Matches `FakeAudioSource`.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: startPTS,
            decodeTimeStamp: .invalid
        )

        // 4. Wrap into a CMSampleBuffer. Constant per-sample size is
        //    encoded in the format description, so we pass
        //    `sampleSizeEntryCount: 0` / `sampleSizeArray: nil`.
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw MacrecError.ioError(
                "SilenceBufferFactory: CMSampleBufferCreate failed (status=\(sbStatus))"
            )
        }
        return sb
    }

    /// Build the canonical Float32 non-interleaved `CMAudioFormatDescription`
    /// matching what `FakeAudioSource` emits.
    internal static func makeFloat32FormatDescription(
        sampleRate: Double,
        channelCount: Int
    ) -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            assertionFailure(
                "SilenceBufferFactory.makeFloat32FormatDescription: CMAudioFormatDescriptionCreate failed (status=\(status))"
            )
            fatalError(
                "SilenceBufferFactory.makeFloat32FormatDescription: CMAudioFormatDescriptionCreate failed (status=\(status))"
            )
        }
        return fmt
    }
}
