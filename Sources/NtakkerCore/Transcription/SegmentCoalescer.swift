import Foundation

public struct SegmentCoalescer: Sendable {

    public static let coalesceWindowSeconds: TimeInterval = 12

    public private(set) var segments: [TranscriptSegment] = []

    public init() {}

    public enum MergeResult: Sendable, Equatable {
        case appended(index: Int)
        case created(index: Int)
    }

    public mutating func merge(
        text: String,
        source: SourceTag,
        at: Date
    ) -> MergeResult {
        let lastEndsSentence: Bool
        if let last = segments.last, let lastChar = last.text.last {
            lastEndsSentence = ".!?…".contains(lastChar)
        } else {
            lastEndsSentence = false
        }

        if let last = segments.last,
           last.source == source,
           !lastEndsSentence,
           at.timeIntervalSince(last.lastUpdated) < Self.coalesceWindowSeconds
        {
            let combined = (last.text + " " + text)
                .replacingOccurrences(of: "  ", with: " ")
            segments[segments.count - 1] = TranscriptSegment(
                id: last.id,
                timestamp: last.timestamp,
                lastUpdated: at,
                text: combined,
                source: last.source,
                confidence: last.confidence,
                model: last.model,
                durationSec: last.durationSec
            )
            return .appended(index: segments.count - 1)
        } else {
            let seg = TranscriptSegment(
                timestamp: at,
                text: text,
                source: source
            )
            segments.append(seg)
            return .created(index: segments.count - 1)
        }
    }

    public mutating func reset() {
        segments.removeAll()
    }
}
