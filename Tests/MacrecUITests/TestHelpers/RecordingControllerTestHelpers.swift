// MacrecUITests/TestHelpers/RecordingControllerTestHelpers.swift —
// Shared test-only utilities used across the `MacrecUITests` target.
//
// NOTE ON `private(set)` PROPERTIES:
// `RecordingController`'s observed properties (`transcriptSegments`,
// `transcriptionStatus`, `pendingDisclosure`, etc.) are declared
// `public private(set)`.  Even with `@testable import MacrecUIKit`
// the `private(set)` restriction is NOT relaxed — `@testable` only
// upgrades `internal` declarations to `open`, it does not bypass
// `private(set)` access specifiers. Mutation must happen through the
// controller's public API (setOptions, clearTranscriptSegments, etc.)
// or through a live session/coordinator event stream.
//
// Tests that need to verify segment-routing logic do so by exercising
// the pure-logic helpers (DualSidecarLabel, DualLocaleSets, etc.)
// directly, rather than feeding events into a live controller.

import Foundation
@testable import MacrecCore
@testable import MacrecUIKit

// MARK: - Segment builder helpers

/// Create a `TranscriptSegment` with caller-supplied `model` field.
/// Convenience used across dual-transcription UI tests.
func makeDualSegment(
    text: String = "hello",
    model: String?,
    language: String? = "en-US",
    source: SourceTag = .system,
    durationSec: Double? = nil
) -> TranscriptSegment {
    TranscriptSegment(
        id: UUID(),
        timestamp: Date(),
        lastUpdated: Date(),
        text: text,
        source: source,
        model: model,
        durationSec: durationSec,
        language: language
    )
}

/// Filter a segment array using the same predicate that
/// `DualLiveTranscriptView.channelASegments` uses in production.
func filterChannelA(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
    segments.filter {
        DualSidecarLabel.channelTag(forModel: $0.model) == .channelA
    }
}

/// Filter a segment array using the same predicate that
/// `DualLiveTranscriptView.channelBSegments` uses in production.
func filterChannelB(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
    segments.filter {
        DualSidecarLabel.channelTag(forModel: $0.model) == .channelB
    }
}
