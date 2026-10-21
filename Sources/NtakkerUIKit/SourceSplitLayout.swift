// NtakkerUIKit/SourceSplitLayout.swift — 2026-10-21.
//
// Pure helpers for the source-split live transcript (System audio
// above, Microphone below): how the space is shared when the divider
// is dragged, and which line of one lane lines up with a moment in the
// other when the lanes scroll together. Kept out of SwiftUI so they
// are unit-testable.

import Foundation
import NtakkerCore

public enum SourceSplitLayout {

    /// The smallest share either lane keeps while both are expanded.
    public static let minFraction = 0.15
    /// The share the System lane gets by default (and on double-click).
    public static let defaultFraction = 0.5

    /// `fraction` kept within `minFraction ... 1 - minFraction`.
    public static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultFraction }
        return min(max(fraction, minFraction), 1 - minFraction)
    }

    /// The System lane's share after dragging the divider by
    /// `translation` points, starting from `start`, when the two lanes
    /// share `available` points.
    public static func fraction(start: Double, translation: Double, available: Double) -> Double {
        guard available > 0 else { return clamped(start) }
        return clamped(start + translation / available)
    }

    /// The line of `segments` (in time order) to show at the top of a
    /// lane when the other lane's top line started at `time`: the last
    /// one that started at or before it, else the first. `nil` when the
    /// lane is empty.
    public static func alignedSegmentID(in segments: [TranscriptSegment], at time: Date) -> UUID? {
        guard let first = segments.first else { return nil }
        return segments.last { $0.timestamp <= time }?.id ?? first.id
    }
}
