// NtakkerUITests/TestHelpers/RecordingControllerTestHelpers.swift —
// Shared test-only utilities used across the `NtakkerUITests` target.
//
// NOTE ON `private(set)` PROPERTIES:
// `RecordingController`'s observed properties (`transcriptSegments`,
// `transcriptionStatus`, `pendingDisclosure`, etc.) are declared
// `public private(set)`.  Even with `@testable import NtakkerUIKit`
// the `private(set)` restriction is NOT relaxed — `@testable` only
// upgrades `internal` declarations to `open`, it does not bypass
// `private(set)` access specifiers. Mutation must happen through the
// controller's public API (setOptions, clearTranscriptSegments, etc.)
// or through a live session/coordinator event stream.

import Foundation
@testable import NtakkerCore
@testable import NtakkerUIKit

// MARK: - Segment builder helpers

/// Create a `TranscriptSegment` with caller-supplied `model` field.
func makeSegment(
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
