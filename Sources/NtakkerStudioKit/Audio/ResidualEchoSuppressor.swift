// NtakkerStudioKit/Audio/ResidualEchoSuppressor.swift — 2026-10-17.
//
// Second stage of the echo filter. The NLMS canceller removes the part of
// the echo it can model as a linear filter of the system audio; what is
// left (room reverb past the filter's reach, loudspeaker distortion)
// still follows the echo the canceller estimated. This stage turns each
// frequency down in proportion to how much of it is that estimated echo:
//
//   gain(f) = max(floor, 1 − overSubtraction · S_echo(f) / S_out(f))
//
// on 512-sample frames (10.7 ms at 48 kHz), hop 256, √Hann windows for
// analysis and synthesis (perfect reconstruction at 50 % overlap). Powers
// and gains are smoothed over time so the gain does not flutter ("musical
// noise"). Latency: `frameSize` samples; the output of `process` is the
// input delayed by that much.

import Accelerate
import Foundation

public final class ResidualEchoSuppressor {
    public static let frameSize = 512
    public static let hop = 256
    public var latency: Int { Self.frameSize }

    public let overSubtraction: Float
    public let floor: Float

    private let n = ResidualEchoSuppressor.frameSize
    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    // Sliding analysis buffers (last `n` samples) and their fill.
    private var outBuf: [Float]
    private var echoBuf: [Float]
    private var pending = 0
    // Overlap-add accumulator and the samples ready to hand out.
    private var accum: [Float]
    private var ready: [Float] = []
    // Smoothed per-bin powers and gains.
    private var sOut: [Float]
    private var sEcho: [Float]
    private var gain: [Float]

    /// - Parameters:
    ///   - overSubtraction: how hard the estimated echo is subtracted.
    ///   - floor: the lowest gain a frequency is turned down to.
    public init(overSubtraction: Float, floor: Float) {
        self.overSubtraction = overSubtraction
        self.floor = floor
        let size = Self.frameSize
        window = (0..<size).map { i in sqrtf(0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(size))) }
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        outBuf = [Float](repeating: 0, count: n)
        echoBuf = [Float](repeating: 0, count: n)
        accum = [Float](repeating: 0, count: n)
        sOut = [Float](repeating: 0, count: n)
        sEcho = [Float](repeating: 0, count: n)
        gain = [Float](repeating: 1, count: n)
        ready = [Float](repeating: 0, count: n - Self.hop)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Clear all state (after a seek).
    public func reset() {
        for i in 0..<n { outBuf[i] = 0; echoBuf[i] = 0; accum[i] = 0; sOut[i] = 0; sEcho[i] = 0; gain[i] = 1 }
        pending = 0
        ready = [Float](repeating: 0, count: n - Self.hop)
    }

    /// Suppress the residual echo in `output` (the canceller's output),
    /// given `echo` (the echo it estimated, mic − output). Returns the
    /// same number of samples, delayed by `latency`.
    public func process(output: [Float], echo: [Float]) -> [Float] {
        let count = min(output.count, echo.count)
        var i = 0
        while i < count {
            let take = min(Self.hop - pending, count - i)
            // Shift in `take` new samples.
            outBuf.withUnsafeMutableBufferPointer { b in
                _ = memmove(b.baseAddress!, b.baseAddress! + take, (n - take) * MemoryLayout<Float>.size)
            }
            echoBuf.withUnsafeMutableBufferPointer { b in
                _ = memmove(b.baseAddress!, b.baseAddress! + take, (n - take) * MemoryLayout<Float>.size)
            }
            for k in 0..<take {
                outBuf[n - take + k] = output[i + k]
                echoBuf[n - take + k] = echo[i + k]
            }
            pending += take
            i += take
            if pending == Self.hop {
                runFrame()
                pending = 0
            }
        }
        // Hand out exactly `count` samples.
        let out = Array(ready.prefix(count))
        ready.removeFirst(min(count, ready.count))
        return out + [Float](repeating: 0, count: count - out.count)
    }

    private func runFrame() {
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        var er = [Float](repeating: 0, count: n), ei = [Float](repeating: 0, count: n)
        let zero = [Float](repeating: 0, count: n)
        var xo = [Float](repeating: 0, count: n), xe = [Float](repeating: 0, count: n)
        vDSP_vmul(outBuf, 1, window, 1, &xo, 1, vDSP_Length(n))
        vDSP_vmul(echoBuf, 1, window, 1, &xe, 1, vDSP_Length(n))
        vDSP_DFT_Execute(forward, xo, zero, &re, &im)
        vDSP_DFT_Execute(forward, xe, zero, &er, &ei)

        let a: Float = 0.6          // power smoothing
        let release: Float = 0.5    // gain smoothing
        for k in 0..<n {
            let po = re[k] * re[k] + im[k] * im[k]
            let pe = er[k] * er[k] + ei[k] * ei[k]
            sOut[k] = a * sOut[k] + (1 - a) * po
            sEcho[k] = a * sEcho[k] + (1 - a) * pe
            let g = max(floor, 1 - overSubtraction * sEcho[k] / (sOut[k] + 1e-9))
            gain[k] = release * gain[k] + (1 - release) * min(1, g)
            re[k] *= gain[k]
            im[k] *= gain[k]
        }
        var tr = [Float](repeating: 0, count: n), ti = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(inverse, re, im, &tr, &ti)
        var scale = 1 / Float(n)
        vDSP_vsmul(tr, 1, &scale, &tr, 1, vDSP_Length(n))
        vDSP_vmul(tr, 1, window, 1, &tr, 1, vDSP_Length(n))
        vDSP_vadd(accum, 1, tr, 1, &accum, 1, vDSP_Length(n))
        // The first hop of the accumulator is complete.
        ready.append(contentsOf: accum.prefix(Self.hop))
        accum.withUnsafeMutableBufferPointer { b in
            _ = memmove(b.baseAddress!, b.baseAddress! + Self.hop, (n - Self.hop) * MemoryLayout<Float>.size)
            for k in (n - Self.hop)..<n { b[k] = 0 }
        }
    }
}
