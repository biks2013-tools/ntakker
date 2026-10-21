// NtakkerStudioKit/Cutting/ChannelSilence.swift — 2026-10-21.
//
// Ranges of one channel (the mic or the system track of a split
// recording) to replace with silence — to take out a noise heard on one
// side only — and the gain that does it. Used while listening (the
// player silences them live) and by Export Copy (`AudioCutter`), so what
// is heard is what is written. Each silenced range fades out and back
// in over `fadeSeconds` at its edges, so there is no click.

import Foundation

public struct ChannelSilence: Sendable, Equatable {
    /// Sorted, non-overlapping ranges per channel.
    public private(set) var ranges: [AudioTrackRole: [CutRange]] = [:]

    public init() {}

    public var isEmpty: Bool { ranges.values.allSatisfy(\.isEmpty) }

    public func ranges(for role: AudioTrackRole) -> [CutRange] { ranges[role] ?? [] }

    /// Seconds silenced on `role`.
    public func silencedDuration(for role: AudioTrackRole) -> Double {
        ranges(for: role).reduce(0) { $0 + $1.duration }
    }

    /// Add `range` to `role`, merged with the ranges it touches and
    /// clamped to `[0, duration]`.
    public mutating func add(_ range: CutRange, to role: AudioTrackRole, duration: Double) {
        ranges[role] = CutPlan(ranges: ranges(for: role) + [range], duration: duration).ranges
    }

    public mutating func remove(_ range: CutRange, from role: AudioTrackRole) {
        ranges[role]?.removeAll { $0 == range }
    }

    public mutating func clear() { ranges = [:] }
}

public enum SilenceGain {
    /// Fade length at each edge of a silenced range.
    public static let fadeSeconds = 0.01

    /// The gain at file frame `frame`: 1 outside every range, 0 inside,
    /// ramping linearly over the first and last `fadeSeconds` of a range
    /// (shorter for a range under twice that).
    public static func gain(at frame: Int64, ranges: [CutRange], rate: Double) -> Float {
        for r in ranges {
            let s = r.start * rate, e = r.end * rate
            let f = Double(frame)
            guard f >= s, f < e else { continue }
            let fade = max(1, min(fadeSeconds * rate, (e - s) / 2))
            return Float(1 - min(1, min(f - s, e - f) / fade))
        }
        return 1
    }

    /// Apply the silencing to `frames` samples of one channel that start
    /// at file frame `startFrame`. Only the overlapping frames are
    /// touched.
    public static func apply(_ ranges: [CutRange], to samples: UnsafeMutablePointer<Float>,
                             frames: Int, startFrame: Int64, rate: Double) {
        guard frames > 0, !ranges.isEmpty else { return }
        let blockEnd = startFrame + Int64(frames)
        for r in ranges {
            let s = Int64((r.start * rate).rounded(.down)), e = Int64((r.end * rate).rounded(.up))
            let from = max(s, startFrame), to = min(e, blockEnd)
            guard to > from else { continue }
            for frame in from..<to {
                samples[Int(frame - startFrame)] *= gain(at: frame, ranges: [r], rate: rate)
            }
        }
    }

    /// Same, on per-channel arrays.
    public static func apply(_ ranges: [CutRange], to channels: inout [[Float]], startFrame: Int64, rate: Double) {
        guard !ranges.isEmpty else { return }
        for c in channels.indices {
            channels[c].withUnsafeMutableBufferPointer { p in
                guard let base = p.baseAddress else { return }
                apply(ranges, to: base, frames: p.count, startFrame: startFrame, rate: rate)
            }
        }
    }
}
