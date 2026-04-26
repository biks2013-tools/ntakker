// MacrecCore/Mixing/BufferSummer.swift — see project-design.md §2.9 / §2.11.
//
// Phase F (plan-001) — pure-DSP element-wise sum of two non-interleaved
// Float32 stereo CMSampleBuffer / AVAudioPCMBuffer pairs. Drives the
// `mixed` track layout (see refined-request §FR-5 / §A-7): no AGC, no
// ducking, no echo cancellation — just straight summation, clamped to
// `[-1.0, +1.0]` to prevent clipping when both sources are at full
// scale simultaneously.
//
// Implementation notes:
//   * We use Accelerate's `vDSP_vadd` and `vDSP_vclip` for the hot path —
//     the inputs are Float32 non-interleaved, which is exactly the
//     vector-API contract.
//   * Both inputs MUST share the same ASBD (sample rate, channel count,
//     format flags) and the same frame count. Mismatch is a programmer
//     error (the aligner trims to a common window before invoking the
//     summer); we surface it as `MacrecError.ioError` so the caller can
//     log + abort cleanly.
//   * The CMSampleBuffer overload allocates a fresh CMBlockBuffer for
//     the result; it does not mutate either input. PTS / duration /
//     format description are inherited from `a`.

import Accelerate
import AVFoundation
import CoreMedia
import Foundation

public enum BufferSummer {

    // MARK: - AVAudioPCMBuffer overload (design §2.9)

    /// Pointwise float add of two non-interleaved Float32 stereo (or
    /// any matching-channel-count) buffers of identical `frameLength`.
    ///
    /// - Parameters:
    ///   - a: First input. Must be Float32 non-interleaved.
    ///   - b: Second input. Must match `a`'s format and `frameLength`.
    ///   - gainA: Per-source gain factor applied to `a` before the
    ///            sum. Default `1.0` (no AGC, per refined-request A-7).
    ///   - gainB: Per-source gain factor applied to `b`. Default `1.0`.
    ///
    /// - Returns: A newly allocated buffer with `frameLength == a.frameLength`,
    ///   each sample equal to `clamp(gainA*a + gainB*b, -1.0, +1.0)`.
    ///
    /// - Throws: `MacrecError.ioError` on format / frameLength mismatch
    ///   or allocation failure.
    public static func sum(
        _ a: AVAudioPCMBuffer,
        _ b: AVAudioPCMBuffer,
        gainA: Float = 1.0,
        gainB: Float = 1.0
    ) throws -> AVAudioPCMBuffer {
        // Format equality covers sample rate, channel count, format flags.
        guard a.format == b.format else {
            throw MacrecError.ioError(
                "BufferSummer: format mismatch (a=\(a.format), b=\(b.format))"
            )
        }
        guard a.frameLength == b.frameLength else {
            throw MacrecError.ioError(
                "BufferSummer: frame length mismatch (a=\(a.frameLength), b=\(b.frameLength))"
            )
        }
        guard a.format.commonFormat == .pcmFormatFloat32, !a.format.isInterleaved else {
            throw MacrecError.ioError(
                "BufferSummer: only Float32 non-interleaved is supported"
            )
        }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: a.frameCapacity) else {
            throw MacrecError.ioError("BufferSummer: failed to allocate output buffer")
        }
        outBuffer.frameLength = a.frameLength

        let frames = Int(a.frameLength)
        let channelCount = Int(a.format.channelCount)

        guard let aChannels = a.floatChannelData,
              let bChannels = b.floatChannelData,
              let outChannels = outBuffer.floatChannelData
        else {
            throw MacrecError.ioError("BufferSummer: floatChannelData unavailable")
        }

        for c in 0..<channelCount {
            sumChannel(
                src1: aChannels[c],
                src2: bChannels[c],
                dst: outChannels[c],
                count: frames,
                gainA: gainA,
                gainB: gainB
            )
        }
        return outBuffer
    }

    // MARK: - CMSampleBuffer overloads

    /// User-prompt CMSampleBuffer overload: nil-tolerant, format-agnostic.
    ///
    /// - If both inputs are nil → returns nil.
    /// - If exactly one input is nil → returns the other untouched
    ///   (the caller wants a passthrough on missing data).
    /// - Otherwise sums element-wise, clamping to `[-1.0, +1.0]`.
    ///
    /// - Throws: `MacrecError.ioError` on format / frame-count mismatch
    ///   or Core Media allocation failure.
    public static func sum(
        _ a: CMSampleBuffer?,
        _ b: CMSampleBuffer?
    ) throws -> CMSampleBuffer? {
        switch (a, b) {
        case (nil, nil):
            return nil
        case let (someA?, nil):
            return someA
        case let (nil, someB?):
            return someB
        case let (someA?, someB?):
            guard let fmt = CMSampleBufferGetFormatDescription(someA) else {
                throw MacrecError.ioError("BufferSummer: input a has no format description")
            }
            return try sum(someA, someB, formatDescription: fmt)
        }
    }

    /// Design §2.9 CMSampleBuffer overload. Both inputs are required;
    /// the caller passes the format description explicitly so it can
    /// be reused without re-deriving it from `a`.
    public static func sum(
        _ a: CMSampleBuffer,
        _ b: CMSampleBuffer,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        // Validate matching ASBDs.
        guard let asbdA = CMAudioFormatDescriptionGetStreamBasicDescription(
            CMSampleBufferGetFormatDescription(a) ?? formatDescription
        ),
              let asbdB = CMAudioFormatDescriptionGetStreamBasicDescription(
                CMSampleBufferGetFormatDescription(b) ?? formatDescription
              )
        else {
            throw MacrecError.ioError("BufferSummer: failed to read input ASBDs")
        }
        guard asbdsEqual(asbdA.pointee, asbdB.pointee) else {
            throw MacrecError.ioError(
                "BufferSummer: format mismatch between inputs (a.sampleRate=\(asbdA.pointee.mSampleRate) ch=\(asbdA.pointee.mChannelsPerFrame) flags=\(asbdA.pointee.mFormatFlags); b.sampleRate=\(asbdB.pointee.mSampleRate) ch=\(asbdB.pointee.mChannelsPerFrame) flags=\(asbdB.pointee.mFormatFlags))"
            )
        }

        let asbd = asbdA.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, isNonInterleaved, asbd.mBitsPerChannel == 32 else {
            throw MacrecError.ioError(
                "BufferSummer: only Float32 non-interleaved is supported (flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel))"
            )
        }

        let frameCountA = CMSampleBufferGetNumSamples(a)
        let frameCountB = CMSampleBufferGetNumSamples(b)
        guard frameCountA == frameCountB else {
            throw MacrecError.ioError(
                "BufferSummer: frame-count mismatch (a=\(frameCountA), b=\(frameCountB))"
            )
        }
        let frameCount = frameCountA
        guard frameCount > 0 else {
            throw MacrecError.ioError("BufferSummer: empty inputs (frameCount = 0)")
        }
        let channelCount = Int(asbd.mChannelsPerFrame)

        // Read input bytes via copyToContiguous + UnsafeMutableRawPointer.
        let bytesPerSample = MemoryLayout<Float32>.size
        let bytesPerChannel = frameCount * bytesPerSample
        let totalBytes = bytesPerChannel * channelCount

        var srcA = [Float32](repeating: 0, count: frameCount * channelCount)
        var srcB = [Float32](repeating: 0, count: frameCount * channelCount)
        try readFloat32Samples(into: &srcA, from: a, totalBytes: totalBytes)
        try readFloat32Samples(into: &srcB, from: b, totalBytes: totalBytes)

        var out = [Float32](repeating: 0, count: frameCount * channelCount)
        for c in 0..<channelCount {
            let offset = c * frameCount
            srcA.withUnsafeMutableBufferPointer { aPtr in
                srcB.withUnsafeMutableBufferPointer { bPtr in
                    out.withUnsafeMutableBufferPointer { oPtr in
                        sumChannel(
                            src1: aPtr.baseAddress!.advanced(by: offset),
                            src2: bPtr.baseAddress!.advanced(by: offset),
                            dst: oPtr.baseAddress!.advanced(by: offset),
                            count: frameCount,
                            gainA: 1.0,
                            gainB: 1.0
                        )
                    }
                }
            }
        }

        // Allocate output CMBlockBuffer.
        var outBlock: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &outBlock
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = outBlock else {
            throw MacrecError.ioError(
                "BufferSummer: CMBlockBufferCreateWithMemoryBlock failed (status=\(bbStatus))"
            )
        }
        let copyStatus = out.withUnsafeBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: UnsafeRawPointer(base),
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw MacrecError.ioError(
                "BufferSummer: CMBlockBufferReplaceDataBytes failed (status=\(copyStatus))"
            )
        }

        // Inherit timing from `a`.
        let pts = CMSampleBufferGetPresentationTimeStamp(a)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
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
                "BufferSummer: CMSampleBufferCreate failed (status=\(sbStatus))"
            )
        }
        return sb
    }

    // MARK: - Internals

    /// Sum one channel's worth of Float32 samples into `dst`,
    /// applying `gainA` / `gainB` and clamping to [-1, +1].
    /// Uses Accelerate where the gains are 1.0 (the common case);
    /// falls back to a manual loop when scaling is required.
    private static func sumChannel(
        src1: UnsafePointer<Float32>,
        src2: UnsafePointer<Float32>,
        dst: UnsafeMutablePointer<Float32>,
        count: Int,
        gainA: Float,
        gainB: Float
    ) {
        if gainA == 1.0 && gainB == 1.0 {
            // Hot path: vDSP_vadd for the sum, vDSP_vclip for the clamp.
            vDSP_vadd(src1, 1, src2, 1, dst, 1, vDSP_Length(count))
        } else {
            for i in 0..<count {
                dst[i] = src1[i] * gainA + src2[i] * gainB
            }
        }
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(dst, 1, &lo, &hi, dst, 1, vDSP_Length(count))
    }

    /// Read the entire Float32-sample payload of a CMSampleBuffer
    /// into a contiguous Swift array. Supports non-contiguous block
    /// buffers via `CMBlockBufferCopyDataBytes`.
    private static func readFloat32Samples(
        into dest: inout [Float32],
        from sampleBuffer: CMSampleBuffer,
        totalBytes: Int
    ) throws {
        guard let bb = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw MacrecError.ioError("BufferSummer: CMSampleBuffer has no data buffer")
        }
        let copyStatus = dest.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                bb,
                atOffset: 0,
                dataLength: totalBytes,
                destination: UnsafeMutableRawPointer(base)
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw MacrecError.ioError(
                "BufferSummer: CMBlockBufferCopyDataBytes failed (status=\(copyStatus))"
            )
        }
    }

    private static func asbdsEqual(
        _ x: AudioStreamBasicDescription,
        _ y: AudioStreamBasicDescription
    ) -> Bool {
        return x.mSampleRate == y.mSampleRate
            && x.mFormatID == y.mFormatID
            && x.mFormatFlags == y.mFormatFlags
            && x.mBytesPerPacket == y.mBytesPerPacket
            && x.mFramesPerPacket == y.mFramesPerPacket
            && x.mBytesPerFrame == y.mBytesPerFrame
            && x.mChannelsPerFrame == y.mChannelsPerFrame
            && x.mBitsPerChannel == y.mBitsPerChannel
    }
}
