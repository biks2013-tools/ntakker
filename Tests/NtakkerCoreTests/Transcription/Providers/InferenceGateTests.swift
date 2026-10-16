import Foundation
import Testing
@testable import NtakkerCore

/// Records how many critical sections run at once (EVAL-2026-10-16 TR-1).
private actor ConcurrencyProbe {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) {
        current += 1
        peak = max(peak, current)
        order.append(id)
    }

    func exit() { current -= 1 }
}

@Suite("InferenceGate")
struct InferenceGateTests {

    @Test("never admits two callers at once, even across suspension points")
    func mutualExclusion() async {
        let gate = InferenceGate()
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await probe.enter(id)
                    // Suspend inside the critical section, as an engine
                    // call does — this is where actor isolation alone
                    // would let a second caller in.
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    await probe.exit()
                    await gate.release()
                }
            }
        }

        #expect(await probe.peak == 1)
        #expect(await probe.order.count == 8)
        #expect(await probe.current == 0)
    }

    @Test("a freed gate is immediately re-acquirable")
    func reacquire() async {
        let gate = InferenceGate()
        await gate.acquire()
        await gate.release()
        await gate.acquire()
        await gate.release()
    }
}
