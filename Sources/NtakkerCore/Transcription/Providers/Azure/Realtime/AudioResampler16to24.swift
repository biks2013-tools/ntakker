// Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AudioResampler16to24.swift —
// plan-007 Phase A2 §A2.5.
//
// 16 kHz Float32 → 24 kHz Int16 little-endian resampler used by the
// realtime session before each `input_audio_buffer.append`. Built on
// `AVAudioConverter` to keep the implementation Foundation-only and
// avoid a SwiftPM dependency on a DSP library.
//
// Pinning rationale: research §A2.5 + RT-RISK-2 — set
// `sampleRateConverterQuality = .max` and `primeMethod = .normal` so
// the converter avoids audible artefacts that would degrade WER on
// the 24 kHz output. The default settings produce visible aliasing
// above 8 kHz that the wire-schema research §6 specifically warns
// against.

import Foundation
import AVFoundation

/// Stateless 16 kHz Float → 24 kHz Int16 LE resampler. Each
/// `resample(_:)` call configures a fresh `AVAudioConverter` so the
/// helper is `Sendable`-clean. The throughput cost is negligible
/// (resampler init is microseconds for a 100 ms chunk).
struct AudioResampler16to24: Sendable {

    /// 16 kHz mono Float32 PCM input format.
    private static let inputFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            // Should never happen — Float32 mono 16 kHz is always supported.
            fatalError("AudioResampler16to24: cannot create 16 kHz Float32 input format")
        }
        return fmt
    }()

    /// 24 kHz mono Int16 LE PCM output format (matches Azure realtime
    /// `input_audio_format = "pcm16"`).
    private static let outputFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("AudioResampler16to24: cannot create 24 kHz Int16 output format")
        }
        return fmt
    }()

    init() {}

    /// Resample `samples` (16 kHz Float32) to 24 kHz Int16 little-endian
    /// raw bytes. Returns `Data` ready for base64 encoding inside
    /// `input_audio_buffer.append`.
    ///
    /// Returns `nil` only on `AVAudioConverter` allocation failure
    /// (extremely rare; treated as a soft error so the session can
    /// emit a `.error(...)` event without crashing).
    func resample(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return Data() }

        guard let converter = AVAudioConverter(
            from: Self.inputFormat,
            to: Self.outputFormat
        ) else {
            return nil
        }
        converter.sampleRateConverterQuality = .max
        converter.primeMethod = .normal

        // Wrap the input samples in an AVAudioPCMBuffer.
        let inFrameCount = AVAudioFrameCount(samples.count)
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.inputFormat,
            frameCapacity: inFrameCount
        ), let inChannel = inBuffer.floatChannelData?[0] else {
            return nil
        }
        inBuffer.frameLength = inFrameCount
        for i in 0..<samples.count {
            inChannel[i] = samples[i]
        }

        // The output buffer needs ~1.5x the input frame count
        // (24/16 = 1.5). Round up + a small headroom.
        let outFrameCapacity = AVAudioFrameCount(
            (Double(samples.count) * 24_000.0 / 16_000.0).rounded(.up) + 32
        )
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: outFrameCapacity
        ) else {
            return nil
        }

        var consumed = false
        var convertError: NSError?
        let status = converter.convert(
            to: outBuffer,
            error: &convertError
        ) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, convertError == nil else {
            return nil
        }

        let outFrames = Int(outBuffer.frameLength)
        guard let outChannel = outBuffer.int16ChannelData?[0], outFrames > 0 else {
            return Data()
        }

        // Pack as little-endian raw bytes. On Apple Silicon the host
        // byte order is little-endian, so a direct memcpy is correct.
        var bytes = Data(count: outFrames * MemoryLayout<Int16>.size)
        bytes.withUnsafeMutableBytes { rawBuf in
            guard let dest = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<outFrames {
                dest[i] = outChannel[i]
            }
        }
        return bytes
    }
}
