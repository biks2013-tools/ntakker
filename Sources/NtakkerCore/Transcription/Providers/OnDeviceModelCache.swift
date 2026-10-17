// NtakkerCore/Transcription/Providers/OnDeviceModelCache.swift
//
// EVAL-2026-10-16 TR-11 (+ EVAL-2026-06-12 F28 / F29), plan-022 T5:
// process-wide cache for loaded on-device inference engines.
//
// WhisperKit large-v3 (626 MB) and Parakeet TDT v3 (~600 MB) used to be
// loaded, and compiled for the Neural Engine, inside the first
// `transcribe` call of every recording — twice in
// `--transcribe-source both` mode, because each child manager builds
// its own provider. In the menu-bar app, where recordings follow one
// another in one process, that is seconds of lost audio and a second
// copy of the model per recording.
//
// The cache keeps one loaded engine per key, shared by every provider
// that asks for it, together with the `InferenceGate` that serialises
// calls into it (the engines are not re-entrant, so two providers
// sharing one engine must share its gate too). Concurrent first
// callers share one load. An entry nobody has used for `idleEviction`
// is dropped; a provider still holding the engine keeps it alive until
// it is released itself.

import Foundation

/// A loaded engine plus the gate every caller must hold while using it.
public final class CachedInferenceEngine<Engine>: @unchecked Sendable {
    public let engine: Engine
    let gate = InferenceGate()

    init(engine: Engine) {
        self.engine = engine
    }
}

public actor OnDeviceModelCache {

    public static let shared = OnDeviceModelCache()

    /// How long an unused engine stays loaded.
    public static let defaultIdleEviction: Duration = .seconds(600)

    private struct Entry {
        var value: (any Sendable)?
        var loading: Task<any Sendable, Error>?
        var lastUsed: ContinuousClock.Instant
    }

    private let idleEviction: Duration
    private let clock = ContinuousClock()
    private var entries: [String: Entry] = [:]
    private var janitor: Task<Void, Never>?

    public init(idleEviction: Duration = OnDeviceModelCache.defaultIdleEviction) {
        self.idleEviction = idleEviction
    }

    /// The cached engine for `key`, loading it with `load` if needed.
    /// Concurrent callers for the same key share one load. A failed
    /// load is not cached; the next caller retries.
    public func engine<Engine>(
        for key: String,
        load: @escaping @Sendable () async throws -> Engine
    ) async throws -> CachedInferenceEngine<Engine> {
        if let value = entries[key]?.value as? CachedInferenceEngine<Engine> {
            entries[key]?.lastUsed = clock.now
            return value
        }
        let task: Task<any Sendable, Error>
        if let loading = entries[key]?.loading {
            task = loading
        } else {
            task = Task { CachedInferenceEngine(engine: try await load()) as any Sendable }
            entries[key] = Entry(value: nil, loading: task, lastUsed: clock.now)
        }
        do {
            let loaded = try await task.value
            guard let value = loaded as? CachedInferenceEngine<Engine> else {
                preconditionFailure("OnDeviceModelCache: key '\(key)' was loaded as a different engine type")
            }
            if entries[key]?.loading != nil {
                entries[key] = Entry(value: value, loading: nil, lastUsed: clock.now)
                scheduleJanitor()
            }
            return value
        } catch {
            if entries[key]?.value == nil { entries[key] = nil }
            throw error
        }
    }

    /// Mark `key` as used now, postponing its eviction. Providers call
    /// this per transcription so a long recording never loses its model.
    public func touch(_ key: String) {
        entries[key]?.lastUsed = clock.now
    }

    /// Keys currently holding a loaded engine (for tests and logging).
    public func loadedKeys() -> [String] {
        entries.compactMap { $0.value.value == nil ? nil : $0.key }.sorted()
    }

    /// Drop every entry idle for at least `idleEviction`.
    public func evictIdle() {
        let now = clock.now
        for (key, entry) in entries where entry.value != nil && now - entry.lastUsed >= idleEviction {
            entries[key] = nil
        }
    }

    private func scheduleJanitor() {
        guard janitor == nil else { return }
        let interval = max(idleEviction / 4, .milliseconds(10))
        janitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                if await self.sweep() { return }
            }
        }
    }

    /// Evict idle entries; returns true (and retires the janitor) when
    /// nothing loaded is left.
    private func sweep() -> Bool {
        evictIdle()
        if entries.values.contains(where: { $0.value != nil || $0.loading != nil }) { return false }
        janitor = nil
        return true
    }
}
