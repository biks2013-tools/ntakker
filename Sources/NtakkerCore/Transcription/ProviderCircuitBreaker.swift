// NtakkerCore/Transcription/ProviderCircuitBreaker.swift
//
// F15 (EVAL 2026-06-12) circuit breaker for batch provider calls, with
// the EVAL-2026-10-16 TR-10 half-open fix (plan-023 T1). Pure state, so
// the transitions are unit-testable without the manager's 2 s loop.
//
// Without a breaker, a dead provider (revoked key, sustained outage)
// was re-called every ~2.5 s per source for the entire recording. The
// breaker opens for `cooldown` after `failureThreshold` consecutive
// failures, then lets calls through half-open: one success closes it,
// one failure re-opens it at once. (Before TR-10 the counter simply
// restarted at 0, so every cooldown let 5 more doomed calls through.)
// A configuration-class error trips it for the rest of the session.

import Foundation

struct ProviderCircuitBreaker {

    enum Transition: Equatable {
        case none
        /// Threshold reached: calls pause for the cooldown.
        case opened
        /// A half-open probe failed: paused for another cooldown.
        case reopened
        /// A configuration-class error: no more calls this session.
        case trippedPermanently
    }

    let failureThreshold: Int
    let cooldown: Duration

    private(set) var consecutiveFailures = 0
    private(set) var openUntil: ContinuousClock.Instant?
    private(set) var halfOpen = false
    private(set) var trippedPermanently = false

    init(failureThreshold: Int, cooldown: Duration) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
    }

    /// Whether a call may go out at `now`. The first call after a
    /// cooldown moves the breaker to half-open.
    mutating func allowsCall(at now: ContinuousClock.Instant) -> Bool {
        if trippedPermanently { return false }
        if let until = openUntil {
            guard now >= until else { return false }
            openUntil = nil
            halfOpen = true
        }
        return true
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
        halfOpen = false
    }

    mutating func recordFailure(configurationError: Bool, at now: ContinuousClock.Instant) -> Transition {
        guard !trippedPermanently else { return .none }
        if configurationError {
            trippedPermanently = true
            return .trippedPermanently
        }
        consecutiveFailures += 1
        if halfOpen {
            halfOpen = false
            consecutiveFailures = 0
            openUntil = now.advanced(by: cooldown)
            return .reopened
        }
        if consecutiveFailures >= failureThreshold, openUntil == nil {
            consecutiveFailures = 0
            openUntil = now.advanced(by: cooldown)
            return .opened
        }
        return .none
    }
}
