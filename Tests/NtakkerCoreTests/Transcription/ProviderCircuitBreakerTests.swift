import Foundation
import Testing
@testable import NtakkerCore

/// F15 + EVAL-2026-10-16 TR-10 (plan-023 T1). `#expect` cannot call a
/// mutating member, so each transition is recorded into a local first.
@Suite("ProviderCircuitBreaker")
struct ProviderCircuitBreakerTests {

    private let t0 = ContinuousClock.now

    private func breaker() -> ProviderCircuitBreaker {
        ProviderCircuitBreaker(failureThreshold: 5, cooldown: .seconds(60))
    }

    @Test("opens after the threshold and blocks calls during the cooldown")
    func opensAtThreshold() {
        var b = breaker()
        for _ in 0..<4 {
            let r = b.recordFailure(configurationError: false, at: t0)
            #expect(r == .none)
        }
        let opened = b.recordFailure(configurationError: false, at: t0)
        #expect(opened == .opened)
        let duringCooldown = b.allowsCall(at: t0.advanced(by: .seconds(59)))
        #expect(!duringCooldown)
        let afterCooldown = b.allowsCall(at: t0.advanced(by: .seconds(60)))
        #expect(afterCooldown)
    }

    @Test("a failed half-open probe re-opens at once (TR-10)")
    func failedProbeReopens() {
        var b = breaker()
        for _ in 0..<5 { _ = b.recordFailure(configurationError: false, at: t0) }
        let later = t0.advanced(by: .seconds(61))
        let probe = b.allowsCall(at: later)
        #expect(probe)
        let r = b.recordFailure(configurationError: false, at: later)
        #expect(r == .reopened, "one failure after the cooldown, not five, must re-open")
        let blocked = b.allowsCall(at: later.advanced(by: .seconds(30)))
        #expect(!blocked)
    }

    @Test("a successful half-open probe closes the circuit")
    func successfulProbeCloses() {
        var b = breaker()
        for _ in 0..<5 { _ = b.recordFailure(configurationError: false, at: t0) }
        let later = t0.advanced(by: .seconds(61))
        _ = b.allowsCall(at: later)
        b.recordSuccess()
        // Back to needing the full threshold.
        for _ in 0..<4 {
            let r = b.recordFailure(configurationError: false, at: later)
            #expect(r == .none)
        }
        let r = b.recordFailure(configurationError: false, at: later)
        #expect(r == .opened)
    }

    @Test("a configuration error trips it for good")
    func configurationErrorTrips() {
        var b = breaker()
        let tripped = b.recordFailure(configurationError: true, at: t0)
        #expect(tripped == .trippedPermanently)
        let allowed = b.allowsCall(at: t0.advanced(by: .seconds(3_600)))
        #expect(!allowed)
        let after = b.recordFailure(configurationError: false, at: t0)
        #expect(after == .none)
    }
}
