// NtakkerStudioKit/Cutting/CutPlan.swift — plan-024 T4.
//
// The time ranges to remove from a recording, and the mapping from the
// original timeline to the cut one. Pure value type.

import Foundation
import NtakkerCore

public struct CutRange: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(start)-\(end)" }
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }
}

public struct CutPlan: Sendable, Equatable {
    /// Sorted, non-overlapping, clamped to `[0, duration]`, no empty ranges.
    public let ranges: [CutRange]
    /// Length of the original audio, in seconds.
    public let duration: Double

    public init(ranges: [CutRange], duration: Double) {
        self.duration = max(0, duration)
        let clamped = ranges
            .map { CutRange(start: max(0, min($0.start, duration)), end: max(0, min($0.end, duration))) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var merged: [CutRange] = []
        for r in clamped {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1] = CutRange(start: last.start, end: max(last.end, r.end))
            } else {
                merged.append(r)
            }
        }
        self.ranges = merged
    }

    public var removedDuration: Double { ranges.reduce(0) { $0 + $1.duration } }
    public var resultDuration: Double { duration - removedDuration }

    /// The ranges that are kept, in order.
    public var keptRanges: [CutRange] {
        var out: [CutRange] = []
        var cursor = 0.0
        for r in ranges {
            if r.start > cursor { out.append(CutRange(start: cursor, end: r.start)) }
            cursor = r.end
        }
        if duration > cursor { out.append(CutRange(start: cursor, end: duration)) }
        return out
    }

    /// Whether `t` falls inside a removed range (ends excluded).
    public func isRemoved(_ t: Double) -> Bool {
        ranges.contains { t > $0.start && t < $0.end }
    }

    /// Position of original time `t` on the cut timeline. A time inside
    /// a removed range maps to where that range was.
    public func map(_ t: Double) -> Double {
        var removed = 0.0
        for r in ranges {
            if t >= r.end {
                removed += r.duration
            } else if t > r.start {
                return r.start - removed
            } else {
                break
            }
        }
        return t - removed
    }
}

/// Re-times transcript lines onto a cut timeline.
public enum TranscriptRetimer {

    /// The minimum share of a line that must survive the cut for the
    /// line to be kept.
    public static let minimumKeptFraction = 0.5

    /// Map each entry onto the cut timeline. A line is dropped when
    /// less than `minimumKeptFraction` of it survives (a zero-length
    /// line is dropped when its start is removed). The kept lines get
    /// exact timestamps: `audioStart + new offset`.
    public static func retime(_ entries: [TranscriptEntry], plan: CutPlan, audioStart: Date) -> [TranscriptSegment] {
        entries.compactMap { entry in
            let length = entry.end - entry.start
            if length <= 0 {
                if plan.isRemoved(entry.start) { return nil }
            } else {
                let removed = plan.ranges.reduce(0.0) { acc, r in
                    acc + max(0, min(entry.end, r.end) - max(entry.start, r.start))
                }
                if (length - removed) / length < minimumKeptFraction { return nil }
            }
            let newStart = plan.map(entry.start)
            let newEnd = plan.map(entry.end)
            let s = entry.segment
            let timestamp = audioStart.addingTimeInterval(newStart)
            return TranscriptSegment(
                id: s.id,
                timestamp: timestamp,
                lastUpdated: timestamp,
                text: s.text,
                source: s.source,
                confidence: s.confidence,
                model: s.model,
                durationSec: s.durationSec == nil ? nil : max(0, newEnd - newStart),
                language: s.language,
                speaker: s.speaker
            )
        }
    }
}
