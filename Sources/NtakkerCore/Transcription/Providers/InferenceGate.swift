// NtakkerCore/Transcription/Providers/InferenceGate.swift
//
// FIFO async mutex for on-device inference engines that are not
// re-entrant (EVAL-2026-10-16 TR-1).
//
// `TranscriptionManager` allows up to `maxInFlightPerSource` (2)
// concurrent provider calls per source. The provider actors
// themselves do NOT serialise those calls: actor isolation is
// released at every `await`, so two `transcribe` calls can be
// suspended inside the engine at the same time. FluidAudio's
// `AsrManager` (plain `final class`, decoder state passed `inout`
// across awaits) and WhisperKit (`open class` mutating
// `currentTimings`) are not safe under that interleaving. This is
// guaranteed at cold start: every caller waiting on the model-load
// task resumes together.
//
// Usage — bracket the engine call. `release()` must run on every
// path; a `defer` cannot `await`, so use the explicit do/catch form:
//
//     await gate.acquire()
//     do { let r = try await work(); await gate.release(); return r }
//     catch { await gate.release(); throw error }

import Foundation

actor InferenceGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until the caller holds the gate. Callers are admitted
    /// in arrival order.
    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Ownership was handed over by `release()`; `busy` is still true.
    }

    /// Hands the gate to the next waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
