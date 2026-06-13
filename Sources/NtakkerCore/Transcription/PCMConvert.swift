// NtakkerCore/Transcription/PCMConvert.swift
//
// F32 + F4 (EVAL 2026-06-12) — the ONE place Float32 ↔ Int16 PCM
// conversion happens in the transcription subsystem.
//
// Before this file the conversion was implemented five times with
// three different scaling conventions (asymmetric Int16.min vs
// symmetric 32767 vs Int16.max), all as scalar per-sample loops on the
// hottest per-chunk path. This utility is vDSP-backed (vectorised) and
// pins ONE documented convention:
//
//   * Float → Int16: clamp to [-1, 1], scale by 32 767 (symmetric),
//     round to nearest. +1.0 → 32 767, -1.0 → -32 767. The symmetric
//     scale avoids the +1.0 overflow case entirely and keeps the
//     transform sign-symmetric (the ≤ 1 LSB difference vs the old
//     asymmetric variants is far below any STT provider's noise
//     floor).
//   * Int16 → Float: divide by 32 768 — the exact inverse Apple's own
//     converters use; Int16.min → -1.0, Int16.max → +0.99997.
//
// Layout: little-endian, which is the native byte order on every
// supported platform (arm64 / x86_64) — the `withUnsafeBytes` reads
// and writes below rely on that.

import Accelerate
import Foundation

/// vDSP-backed Float32 ↔ Int16 PCM conversion. Stateless.
public enum PCMConvert {

    /// Float32 `[-1, 1]` mono samples → little-endian Int16 bytes.
    /// Clamps, scales by 32 767, rounds to nearest.
    public static func floatToInt16LE(_ samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }
        let n = vDSP_Length(samples.count)

        // Clamp to [-1, 1] then scale to the symmetric Int16 range.
        var clamped = [Float](repeating: 0, count: samples.count)
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(samples, 1, &lo, &hi, &clamped, 1, n)
        var scale: Float = 32_767.0
        vDSP_vsmul(clamped, 1, &scale, &clamped, 1, n)

        var ints = [Int16](repeating: 0, count: samples.count)
        vDSP_vfixr16(clamped, 1, &ints, 1, n)

        return ints.withUnsafeBytes { Data($0) }
    }

    /// Little-endian Int16 bytes → Float32 `[-1, 1)` mono samples.
    /// Scales by 1/32 768. A trailing odd byte (malformed input) is
    /// ignored.
    public static func int16LEToFloat(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            vDSP_vflt16(base, 1, &floats, 1, vDSP_Length(count))
        }
        var scale: Float = 1.0 / 32_768.0
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
        return floats
    }

    /// Float32 `[-1, 1]` mono samples → Int16 values (same convention
    /// as `floatToInt16LE`, without the Data wrapper). Used by callers
    /// that fill an `AVAudioPCMBuffer`'s Int16 channel directly.
    public static func floatToInt16(_ samples: [Float]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        let n = vDSP_Length(samples.count)
        var clamped = [Float](repeating: 0, count: samples.count)
        var lo: Float = -1.0
        var hi: Float = 1.0
        vDSP_vclip(samples, 1, &lo, &hi, &clamped, 1, n)
        var scale: Float = 32_767.0
        vDSP_vsmul(clamped, 1, &scale, &clamped, 1, n)
        var ints = [Int16](repeating: 0, count: samples.count)
        vDSP_vfixr16(clamped, 1, &ints, 1, n)
        return ints
    }
}
