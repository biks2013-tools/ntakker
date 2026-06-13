// Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AudioRingBuffer.swift —
// plan-007 Phase A2 §A2.7 (reconnect-with-replay).
//
// Generic fixed-capacity FIFO of the last N samples. The realtime
// session keeps an `AudioRingBuffer<Int16>` sized at 5 s of 24 kHz
// PCM16 (= 120,000 samples) so that, on a WebSocket close (1006 etc.),
// the freshly-reopened session can replay the trailing audio that
// Azure never had a chance to commit.

import Foundation

/// Fixed-capacity ring buffer. New writes overwrite the oldest
/// samples once `capacity` is reached. `drain()` returns the buffer
/// in chronological order (oldest first) and resets the cursor.
struct AudioRingBuffer<Sample>: Sendable where Sample: Sendable {

    private var storage: [Sample]
    private var head: Int = 0
    private var count: Int = 0
    let capacity: Int

    init(capacity: Int, fill: Sample) {
        precondition(capacity > 0, "AudioRingBuffer capacity must be > 0")
        self.capacity = capacity
        self.storage = [Sample](repeating: fill, count: capacity)
    }

    /// Append `samples` to the buffer. Older samples are overwritten
    /// once `capacity` is exceeded.
    mutating func append(_ samples: [Sample]) {
        for sample in samples {
            storage[head] = sample
            head = (head + 1) % capacity
            if count < capacity { count += 1 }
        }
    }

    /// Return the buffer contents in chronological order (oldest
    /// first), then reset the cursor. Use this on reconnect to replay
    /// audio that was sent to the closed WebSocket.
    mutating func drain() -> [Sample] {
        let snapshot = currentContents()
        head = 0
        count = 0
        return snapshot
    }

    /// Read the buffer without resetting. Useful for tests / metrics.
    func snapshot() -> [Sample] {
        currentContents()
    }

    private func currentContents() -> [Sample] {
        guard count > 0 else { return [] }
        if count < capacity {
            // The buffer hasn't wrapped yet: storage[0..<head] holds
            // everything in chronological order.
            return Array(storage[0..<head])
        }
        // Wrapped: oldest at `head`, wrap around to `head - 1`.
        var out = [Sample]()
        out.reserveCapacity(capacity)
        out.append(contentsOf: storage[head..<capacity])
        out.append(contentsOf: storage[0..<head])
        return out
    }
}
