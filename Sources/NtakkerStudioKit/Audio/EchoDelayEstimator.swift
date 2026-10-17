// NtakkerStudioKit/Audio/EchoDelayEstimator.swift — echo filter, 2026-10-17.
//
// How long after the system audio its echo reaches the microphone. On
// real recordings this is 110–135 ms (output latency + room), longer
// than the echo filter's 85 ms window, so the player delays the system
// reference by the estimate (minus a margin) before filtering.
//
// Method: 1 ms RMS envelopes of both tracks over a stretch of the
// recording, mean removed, cross-correlated over 0…`maxLagMs`. Envelopes
// make this cheap (two minutes of audio is 120 000 points) and robust to
// the echo's colouring.

import Accelerate
import AVFoundation
import Foundation

public enum EchoDelayEstimator {
    public static let maxLagMs = 500
    /// The reference is delayed by the estimate minus this, so the echo
    /// path sits inside the filter's 85 ms window with room before it.
    public static let referenceMargin = 0.02

    /// Lag (seconds) at which the mic envelope best matches the system
    /// envelope; positive = mic later. `nil` when there is no usable
    /// correlation (e.g. a silent track).
    public static func estimate(mic: [Float], system: [Float]) -> Double? {
        let n = min(mic.count, system.count)
        guard n > maxLagMs * 4 else { return nil }
        func centred(_ x: [Float]) -> [Float] {
            let m = x.prefix(n).reduce(0, +) / Float(n)
            return x.prefix(n).map { $0 - m }
        }
        let m = centred(mic), s = centred(system)
        var best = (lag: 0, c: -Float.infinity)
        var zero: Float = 0
        s.withUnsafeBufferPointer { sp in
            m.withUnsafeBufferPointer { mp in
                for lag in 0...maxLagMs {
                    var c: Float = 0
                    vDSP_dotpr(sp.baseAddress!, 1, mp.baseAddress! + lag, 1, &c, vDSP_Length(n - lag))
                    if lag == 0 { zero = c }
                    if c > best.c { best = (lag, c) }
                }
            }
        }
        guard best.c > 0, best.c >= zero else { return nil }
        return Double(best.lag) / 1000
    }

    /// 1 ms RMS envelope of channel 0 of `url`, from `start` for `seconds`.
    public static func envelope(of url: URL, start: Double, seconds: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let rate = f.processingFormat.sampleRate
        let hop = max(1, Int(rate / 1000))
        let from = AVAudioFramePosition(start * rate)
        guard from < f.length else { return [] }
        f.framePosition = from
        let n = AVAudioFrameCount(min(AVAudioFramePosition(seconds * rate), f.length - from))
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n) else { return [] }
        try f.read(into: b, frameCount: n)
        let d = b.floatChannelData![0]
        return stride(from: 0, to: Int(b.frameLength) - hop, by: hop).map { s in
            var e: Float = 0
            for i in s..<(s + hop) { e += d[i] * d[i] }
            return (e / Float(hop)).squareRoot()
        }
    }

    /// Estimate the echo delay of a split recording from two minutes of
    /// audio a quarter of the way in (past the introductions).
    public static func estimate(micURL: URL, systemURL: URL, duration: Double) throws -> Double? {
        let length = min(120, duration)
        let start = max(0, min(duration * 0.25, duration - length))
        return estimate(mic: try envelope(of: micURL, start: start, seconds: length),
                        system: try envelope(of: systemURL, start: start, seconds: length))
    }
}
