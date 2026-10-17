import Foundation
import Testing
import struct os.OSAllocatedUnfairLock
@testable import NtakkerCore

/// EVAL-2026-10-16 TR-11 / F29 (plan-022 T5): one load per key per
/// process, shared engine and gate, failures not cached, idle eviction.
@Suite("OnDeviceModelCache")
struct OnDeviceModelCacheTests {

    private final class Engine: @unchecked Sendable {}

    private struct LoadFailed: Error {}

    @Test("concurrent callers share one load and one engine")
    func concurrentCallersShareOneLoad() async throws {
        let cache = OnDeviceModelCache()
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let load: @Sendable () async throws -> Engine = {
            loads.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return Engine()
        }
        async let a = cache.engine(for: "m", load: load)
        async let b = cache.engine(for: "m", load: load)
        let (ea, eb) = try await (a, b)
        let ec = try await cache.engine(for: "m", load: load)

        #expect(loads.withLock { $0 } == 1)
        #expect(ea === eb && eb === ec, "every caller gets the same cached engine")
        #expect(ea.gate === ec.gate, "callers sharing an engine share its gate")
    }

    @Test("different keys load separately")
    func keysAreIndependent() async throws {
        let cache = OnDeviceModelCache()
        let a = try await cache.engine(for: "a") { Engine() }
        let b = try await cache.engine(for: "b") { Engine() }
        #expect(a !== b)
        #expect(await cache.loadedKeys() == ["a", "b"])
    }

    @Test("a failed load is not cached")
    func failureIsRetried() async throws {
        let cache = OnDeviceModelCache()
        await #expect(throws: LoadFailed.self) {
            _ = try await cache.engine(for: "m") { () async throws -> Engine in throw LoadFailed() }
        }
        #expect(await cache.loadedKeys().isEmpty)
        _ = try await cache.engine(for: "m") { Engine() }
        #expect(await cache.loadedKeys() == ["m"])
    }

    @Test("an idle engine is evicted; a touched one is kept")
    func idleEviction() async throws {
        let cache = OnDeviceModelCache(idleEviction: .milliseconds(200))
        _ = try await cache.engine(for: "idle") { Engine() }
        _ = try await cache.engine(for: "busy") { Engine() }
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(60))
            await cache.touch("busy")
        }
        #expect(await cache.loadedKeys() == ["busy"])
    }
}
