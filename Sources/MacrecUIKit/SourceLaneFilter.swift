// MacrecUIKit/SourceLaneFilter.swift — pure filtering helper for
// the source-split live transcript panel. Lives in MacrecUIKit so
// it's unit-testable without spinning up SwiftUI. Plan-012 Phase C5.

import Foundation
import MacrecCore

public enum SourceLaneFilter {
    /// Filter `segments` to those whose `source` matches the given tag.
    /// Used by `SourceLane` (in macrec-ui) when `filter != nil`.
    public static func segments(
        _ segments: [TranscriptSegment],
        for source: SourceTag
    ) -> [TranscriptSegment] {
        segments.filter { $0.source == source }
    }
}
