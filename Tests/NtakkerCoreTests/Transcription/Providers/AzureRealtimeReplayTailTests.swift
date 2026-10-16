import Foundation
import Testing
@testable import NtakkerCore

/// EVAL-2026-10-16 TR-13: a reconnect must replay only the audio Azure
/// never committed, not the whole ring.
@Suite("Azure realtime replay tail")
struct AzureRealtimeReplayTailTests {

    private let ring: [Int16] = Array(1...10)

    @Test("everything committed: only never-sent samples are replayed")
    func fullyCommitted() {
        let tail = AzureOpenAIRealtimeSession.uncommittedTail(
            ring: ring, sentOnConnection: 8, committedOnConnection: 8, unsentInRing: 2
        )
        #expect(tail == [9, 10])
    }

    @Test("uncommitted sent audio is replayed with the unsent tail")
    func partlyCommitted() {
        let tail = AzureOpenAIRealtimeSession.uncommittedTail(
            ring: ring, sentOnConnection: 8, committedOnConnection: 5, unsentInRing: 2
        )
        #expect(tail == [6, 7, 8, 9, 10])
    }

    @Test("nothing committed: the whole ring is replayed, never more")
    func nothingCommitted() {
        let tail = AzureOpenAIRealtimeSession.uncommittedTail(
            ring: ring, sentOnConnection: 1_000, committedOnConnection: 0, unsentInRing: 0
        )
        #expect(tail == ring)
    }

    @Test("a commit boundary past the send count replays nothing extra")
    func commitAheadOfSends() {
        let tail = AzureOpenAIRealtimeSession.uncommittedTail(
            ring: ring, sentOnConnection: 4, committedOnConnection: 6, unsentInRing: 0
        )
        #expect(tail.isEmpty)
    }
}
