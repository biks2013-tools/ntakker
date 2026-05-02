// MacrecCoreTests/Transcription/Dual/DualTranscriptionManagerFailureIsolationTests.swift —
// see project-design.md §DT-12 (failure matrix), plan-010-dual-transcription.md
// §Phase B / Lane L-3 (FR-4, NFR-2, AC-4)
//
// HIGHEST PRIORITY — Phase 7 Fix 2 (drain Task rewrite):
//   The Phase 7 fix added the error-translation arm inside `makeDrainTask`
//   that converts per-channel `.error(detail:)` events into
//   `.dualChannelError(channel:detail:)`. Without this test, regression
//   of that fix would silently break:
//     FR-4 — failure isolation (one channel's error does not kill the other)
//     NFR-2 — the merged stream remains open on single-channel failure
//     AC-4  — the error event carries the correct channel tag
//
// Three assertions per the reviewer's specification:
//   (a) The merged stream emits `.dualChannelError(channel:detail:)` with
//       the correct channel tag when that channel's pipeline errors.
//   (b) The OTHER channel keeps emitting events normally after the error.
//   (c) The merged stream does NOT finish on error — only `stop()` finishes it.
//
// Test infrastructure — fake streaming provider:
//   `FakeStreamingTranscriptionProvider` and `FakeStreamingSession` are
//   defined in this file. `FakeTranscriptionProvider` (in production Sources/)
//   is batch-only and deliberately throws on `openStreamingSession`. The
//   `DualTranscriptionManager` depends on `StreamingTranscriptionPipeline`,
//   which requires providers that support `.streaming` mode. We therefore
//   build a minimal fake that:
//     - Reports `supportedModes = [.streaming]`
//     - Returns a controllable `FakeStreamingSession` from `openStreamingSession`
//     - Allows the test to push events (including errors) into the session
//       via the `FakeStreamingSession.push(_:)` / `fail(detail:)` API
//
// IMPORTANT — `DualTranscriptionManager` builds its pipelines internally
//   via the `providerFactory` injection point (see the public `init`).
//   The factory closure receives a `TranscriptionProviderFactoryInput` and
//   returns `any TranscriptionProvider`. Tests inject a closure that
//   dispatches on `providerId` to return the correct fake for each channel.

import AVFoundation
import Foundation
import Logging
import Testing
@testable import MacrecCore

// MARK: - Test fakes

/// A controllable streaming session for unit tests.
///
/// `push(_:)` enqueues a canned `StreamingTranscriptionEvent` into the
/// session's event stream; `fail(detail:)` injects an `.error` event
/// (the same shape the real pipeline emits on provider failure).
/// `close()` finishes the stream — the `StreamingTranscriptionPipeline`'s
/// drain task exits when the stream closes, which allows `stop()` to
/// complete without hanging.
actor FakeStreamingSession: StreamingTranscriptionSession {

    private let (stream, continuation) = AsyncStream<StreamingTranscriptionEvent>.makeStream(
        of: StreamingTranscriptionEvent.self,
        bufferingPolicy: .unbounded
    )

    nonisolated var events: AsyncStream<StreamingTranscriptionEvent> { stream }

    func ingest(_ samples: [Float]) async {
        // No-op for these tests — event injection is via push/fail.
    }

    func finish() async {
        continuation.finish()
    }

    /// Inject an event directly into the session stream.
    func push(_ event: StreamingTranscriptionEvent) {
        continuation.yield(event)
    }

    /// Inject an `.error(detail:)` event to simulate a provider failure.
    func fail(detail: String) {
        continuation.yield(.error(detail: detail))
    }
}

/// Minimal streaming provider whose `openStreamingSession` returns
/// the pre-created `FakeStreamingSession` injected at construction.
///
/// `supportedModes` includes `.streaming` so `StreamingTranscriptionPipeline`
/// calls `openStreamingSession` (not `transcribe`).
actor FakeStreamingTranscriptionProvider: TranscriptionProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportedModes: Set<TranscriptionMode> = [.streaming]

    private let session: FakeStreamingSession

    init(id: String, session: FakeStreamingSession) {
        self.id = id
        self.displayName = "Fake Streaming (\(id))"
        self.session = session
    }

    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // Not used — streaming-only provider.
        throw MacrecError.transcriptionConfigConflict(reason: "batch not supported by FakeStreamingTranscriptionProvider")
    }

    nonisolated func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        return session
    }
}

// MARK: - DualTranscriptionManager failure-isolation tests

@Suite("DualTranscriptionManager — failure isolation (Phase 7 Fix 2 / FR-4 / NFR-2 / AC-4)")
struct DualTranscriptionManagerFailureIsolationTests {

    // MARK: - Fixtures

    /// Minimal valid dual config that uses the FIRST available locale from
    /// each locale set on this machine, so tests run correctly regardless
    /// of which Speech language data packages are installed.
    ///
    /// Channel A locale: first locale from `DualLocaleSets.channelASupportedLocales`
    ///   (uses `Locale.identifier` underscore format per macOS convention).
    /// Channel B locale: first Channel B locale that DIFFERS from the Channel A
    ///   locale (or the second Channel B locale if the first matches).
    ///
    /// If either locale set is empty the caller catches
    /// `MacrecError.transcriptionConfigConflict` and records an Issue.
    private static func makeConfig() throws -> DualTranscriptionConfig {
        let channelALocales = DualLocaleSets.channelASupportedLocales
        let channelBLocales = DualLocaleSets.channelBSupportedLocales

        // Pick the first available Channel A locale.
        guard let localeA = channelALocales.first else {
            throw MacrecError.transcriptionConfigurationMissing(
                field: "DualLocaleSets.channelASupportedLocales is empty on this host (no Speech data?)"
            )
        }
        let localeAId = localeA.identifier

        // Pick a Channel B locale that differs from Channel A. We need a
        // different locale (not necessarily Greek) to avoid Guard 5 firing.
        guard let localeB = channelBLocales.first(where: { $0.identifier != localeAId })
                         ?? channelBLocales.first else {
            throw MacrecError.transcriptionConfigurationMissing(
                field: "DualLocaleSets.channelBSupportedLocales is empty on this host (no Speech data?)"
            )
        }
        let localeBId = localeB.identifier

        return try DualTranscriptionConfig(
            channelA: ChannelConfig(
                providerId: "fake-a",
                locale: localeAId,
                displayName: "Fake A"
            ),
            channelB: ChannelConfig(
                providerId: "fake-b",
                locale: localeBId,
                displayName: "Fake B"
            ),
            source: .mic,
            sidecarFormat: .jsonl
        )
    }

    /// Temporary directory URL for sidecar output (tests never write
    /// meaningful content — the sidecar writer just needs a valid path).
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrec-dual-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeLogger() -> Logger {
        Logger(label: "test.dual.isolation")
    }

    // MARK: - Assertion (a) + (b): error event carries correct channel tag; other channel keeps emitting

    @Test("(a) Error on Channel A → merged stream emits .dualChannelError(channel: .channelA, ...) with correct tag")
    func channelAErrorEmitsDualChannelErrorWithCorrectTag() async throws {
        let sessionA = FakeStreamingSession()
        let sessionB = FakeStreamingSession()

        let config: DualTranscriptionConfig
        do {
            config = try Self.makeConfig()
        } catch let err as MacrecError {
            Issue.record("Config init failed (likely missing Speech entitlement): \(err)")
            return
        }

        let tempDir = try Self.makeTempDir()
        let sidecarBase = tempDir.appendingPathComponent("test.m4a")

        let manager = try DualTranscriptionManager(
            config: config,
            sidecarBaseURL: sidecarBase,
            providerFactory: { input in
                if input.providerId == "fake-a" {
                    return FakeStreamingTranscriptionProvider(id: "fake-a", session: sessionA)
                } else {
                    return FakeStreamingTranscriptionProvider(id: "fake-b", session: sessionB)
                }
            },
            logger: Self.makeLogger()
        )

        let mergedStream = try await manager.start()

        // Collect events in the background.
        let collectorTask = Task<[TranscriptionEvent], Never> {
            var events: [TranscriptionEvent] = []
            for await ev in mergedStream {
                events.append(ev)
                // Collect up to 5 events then stop; we don't want this
                // to run forever waiting for stop().
                if events.count >= 5 { break }
            }
            return events
        }

        // Allow the pipeline's session-open Task and drain Task to attach.
        try await Task.sleep(for: .milliseconds(150))

        // Inject an error into Channel A's session.
        await sessionA.fail(detail: "channel A provider crashed")

        // Give the drain task time to translate the error and emit it.
        try await Task.sleep(for: .milliseconds(100))

        // Stop the manager so the collector finishes.
        await manager.stop()
        await sessionA.finish()
        await sessionB.finish()

        let collected = await collectorTask.value

        // Assertion (a): at least one .dualChannelError with .channelA tag.
        let dualErrors = collected.compactMap { event -> (DualChannelTag, String)? in
            if case let .dualChannelError(channel, detail) = event {
                return (channel, detail)
            }
            return nil
        }
        #expect(!dualErrors.isEmpty,
                "Merged stream must emit at least one .dualChannelError event; got: \(collected.map { "\($0)" })")

        if let (tag, detail) = dualErrors.first {
            #expect(tag == .channelA,
                    "The .dualChannelError must carry .channelA tag; got: .\(tag)")
            #expect(detail.contains("channel A provider crashed"),
                    "The detail must contain the original error message; got: '\(detail)'")
        }
    }

    @Test("(a) Error on Channel B → merged stream emits .dualChannelError(channel: .channelB, ...) with correct tag")
    func channelBErrorEmitsDualChannelErrorWithCorrectTag() async throws {
        let sessionA = FakeStreamingSession()
        let sessionB = FakeStreamingSession()

        let config: DualTranscriptionConfig
        do {
            config = try Self.makeConfig()
        } catch let err as MacrecError {
            Issue.record("Config init failed (likely missing Speech entitlement): \(err)")
            return
        }

        let tempDir = try Self.makeTempDir()
        let sidecarBase = tempDir.appendingPathComponent("test.m4a")

        let manager = try DualTranscriptionManager(
            config: config,
            sidecarBaseURL: sidecarBase,
            providerFactory: { input in
                if input.providerId == "fake-a" {
                    return FakeStreamingTranscriptionProvider(id: "fake-a", session: sessionA)
                } else {
                    return FakeStreamingTranscriptionProvider(id: "fake-b", session: sessionB)
                }
            },
            logger: Self.makeLogger()
        )

        let mergedStream = try await manager.start()

        let collectorTask = Task<[TranscriptionEvent], Never> {
            var events: [TranscriptionEvent] = []
            for await ev in mergedStream {
                events.append(ev)
                if events.count >= 5 { break }
            }
            return events
        }

        try await Task.sleep(for: .milliseconds(150))

        // Inject an error into Channel B.
        await sessionB.fail(detail: "channel B network dropped")

        try await Task.sleep(for: .milliseconds(100))

        await manager.stop()
        await sessionA.finish()
        await sessionB.finish()

        let collected = await collectorTask.value

        let dualErrors = collected.compactMap { event -> (DualChannelTag, String)? in
            if case let .dualChannelError(channel, detail) = event {
                return (channel, detail)
            }
            return nil
        }
        #expect(!dualErrors.isEmpty,
                "Merged stream must emit at least one .dualChannelError event; got: \(collected.map { "\($0)" })")

        if let (tag, detail) = dualErrors.first {
            #expect(tag == .channelB,
                    "The .dualChannelError must carry .channelB tag; got: .\(tag)")
            #expect(detail.contains("channel B network dropped"),
                    "The detail must contain the original error message; got: '\(detail)'")
        }
    }

    @Test("(b) Channel A error: Channel B continues to emit events after Channel A errors")
    func channelBContinuesAfterChannelAErrors() async throws {
        let sessionA = FakeStreamingSession()
        let sessionB = FakeStreamingSession()

        let config: DualTranscriptionConfig
        do {
            config = try Self.makeConfig()
        } catch let err as MacrecError {
            Issue.record("Config init failed (likely missing Speech entitlement): \(err)")
            return
        }

        let tempDir = try Self.makeTempDir()
        let sidecarBase = tempDir.appendingPathComponent("test.m4a")

        let manager = try DualTranscriptionManager(
            config: config,
            sidecarBaseURL: sidecarBase,
            providerFactory: { input in
                if input.providerId == "fake-a" {
                    return FakeStreamingTranscriptionProvider(id: "fake-a", session: sessionA)
                } else {
                    return FakeStreamingTranscriptionProvider(id: "fake-b", session: sessionB)
                }
            },
            logger: Self.makeLogger()
        )

        let mergedStream = try await manager.start()

        // Collect all events until the collector task is cancelled.
        let collectorTask = Task<[TranscriptionEvent], Never> {
            var events: [TranscriptionEvent] = []
            for await ev in mergedStream {
                events.append(ev)
                if events.count >= 10 { break }
            }
            return events
        }

        try await Task.sleep(for: .milliseconds(150))

        // Step 1: Error Channel A.
        await sessionA.fail(detail: "channel A is done")
        await sessionA.finish()  // Close Channel A's session stream cleanly.

        try await Task.sleep(for: .milliseconds(100))

        // Step 2: Channel B emits a partial AFTER Channel A has errored.
        let utteranceId = UUID()
        await sessionB.push(.partial(utteranceId: utteranceId, text: "gamma", confidence: 0.6, speaker: nil))
        await sessionB.push(.final(
            utteranceId: utteranceId,
            text: "gamma delta",
            confidence: 0.9,
            range: Date()...Date(),
            language: "el-GR",
            speaker: nil
        ))

        try await Task.sleep(for: .milliseconds(100))

        await manager.stop()
        await sessionB.finish()

        let collected = await collectorTask.value

        // Assertion (b): at least one non-error event from Channel B after
        // the Channel A error. We look for .segmentAppended or .segmentFinalized.
        let hadChannelAError = collected.contains { ev in
            if case let .dualChannelError(ch, _) = ev { return ch == .channelA }
            return false
        }
        #expect(hadChannelAError,
                "Must see .dualChannelError(.channelA); got: \(collected.map { "\($0)" })")

        // After the error, Channel B's events should flow through.
        let channelBEvents = collected.filter { ev in
            switch ev {
            case .segmentAppended, .segmentUpdated, .segmentFinalized:
                return true
            default:
                return false
            }
        }
        #expect(!channelBEvents.isEmpty,
                "Channel B must keep emitting segment events after Channel A errors; got: \(collected.map { "\($0)" })")
    }

    // MARK: - Assertion (c): merged stream does NOT finish on error

    @Test("(c) Error on Channel A does NOT finish the merged stream — stream stays open")
    func mergedStreamRemainsOpenAfterSingleChannelError() async throws {
        let sessionA = FakeStreamingSession()
        let sessionB = FakeStreamingSession()

        let config: DualTranscriptionConfig
        do {
            config = try Self.makeConfig()
        } catch let err as MacrecError {
            Issue.record("Config init failed (likely missing Speech entitlement): \(err)")
            return
        }

        let tempDir = try Self.makeTempDir()
        let sidecarBase = tempDir.appendingPathComponent("test.m4a")

        let manager = try DualTranscriptionManager(
            config: config,
            sidecarBaseURL: sidecarBase,
            providerFactory: { input in
                if input.providerId == "fake-a" {
                    return FakeStreamingTranscriptionProvider(id: "fake-a", session: sessionA)
                } else {
                    return FakeStreamingTranscriptionProvider(id: "fake-b", session: sessionB)
                }
            },
            logger: Self.makeLogger()
        )

        let mergedStream = try await manager.start()

        // Use a flag to detect premature stream completion.
        let streamFinishedEarlyFlag = ActorFlag()

        let observerTask = Task<Void, Never> {
            for await _ in mergedStream {
                // Drain events; when the loop exits the stream has finished.
            }
            // If we reach here before stop() was called, stream finished early.
            await streamFinishedEarlyFlag.set()
        }

        try await Task.sleep(for: .milliseconds(150))

        // Error Channel A and close its session.
        await sessionA.fail(detail: "channel A crashed")
        await sessionA.finish()

        // Wait a generous 300 ms. If the merged stream finished because of
        // Channel A's error, the flag would be set by now.
        try await Task.sleep(for: .milliseconds(300))

        let flagBeforeStop = await streamFinishedEarlyFlag.isSet
        #expect(!flagBeforeStop,
                "Merged stream must NOT finish when only Channel A errors; stream finished early (DT-INV-2 violation)")

        // Now actually stop the manager — the stream SHOULD finish after stop().
        await manager.stop()
        await sessionB.finish()

        // Give the observer task time to drain post-stop.
        try await Task.sleep(for: .milliseconds(100))
        observerTask.cancel()
    }

    // MARK: - Error does not cancel sibling drain Task

    @Test("Channel A error: Channel B drain Task keeps running — manager does not cancel sibling")
    func channelBDrainTaskNotCancelledOnChannelAError() async throws {
        let sessionA = FakeStreamingSession()
        let sessionB = FakeStreamingSession()

        let config: DualTranscriptionConfig
        do {
            config = try Self.makeConfig()
        } catch let err as MacrecError {
            Issue.record("Config init failed (likely missing Speech entitlement): \(err)")
            return
        }

        let tempDir = try Self.makeTempDir()
        let sidecarBase = tempDir.appendingPathComponent("test.m4a")

        let manager = try DualTranscriptionManager(
            config: config,
            sidecarBaseURL: sidecarBase,
            providerFactory: { input in
                if input.providerId == "fake-a" {
                    return FakeStreamingTranscriptionProvider(id: "fake-a", session: sessionA)
                } else {
                    return FakeStreamingTranscriptionProvider(id: "fake-b", session: sessionB)
                }
            },
            logger: Self.makeLogger()
        )

        let mergedStream = try await manager.start()

        var collectedEvents: [TranscriptionEvent] = []
        let collectorTask = Task<Void, Never> {
            for await ev in mergedStream {
                collectedEvents.append(ev)
                if collectedEvents.count >= 8 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(150))

        // Channel A errors and its stream closes.
        await sessionA.fail(detail: "A gone")
        await sessionA.finish()

        try await Task.sleep(for: .milliseconds(100))

        // Push multiple Channel B events AFTER Channel A fully closed.
        let id1 = UUID()
        await sessionB.push(.partial(utteranceId: id1, text: "alpha", confidence: 0.5, speaker: nil))
        await sessionB.push(.final(utteranceId: id1, text: "alpha beta", confidence: 0.9,
                                   range: Date()...Date(), language: "el-GR", speaker: nil))
        let id2 = UUID()
        await sessionB.push(.partial(utteranceId: id2, text: "gamma", confidence: 0.4, speaker: nil))
        await sessionB.push(.final(utteranceId: id2, text: "gamma delta", confidence: 0.85,
                                   range: Date()...Date(), language: "el-GR", speaker: nil))

        try await Task.sleep(for: .milliseconds(150))

        await manager.stop()
        await sessionB.finish()
        await collectorTask.value

        // Channel B's events should appear in the merged stream.
        let segmentEvents = collectedEvents.filter { ev in
            switch ev {
            case .segmentAppended, .segmentUpdated, .segmentFinalized:
                return true
            default:
                return false
            }
        }
        // We pushed 2 partial + 2 final into Channel B's session.
        // After the pipeline translates them we expect at least 2
        // segment events (some may merge as updated/finalized pairs).
        #expect(segmentEvents.count >= 2,
                "Must see >= 2 segment events from Channel B; got \(segmentEvents.count): \(collectedEvents.map { "\($0)" })")
    }
}

// MARK: - ActorFlag helper

/// Concurrency-safe boolean flag used by the stream-stays-open test.
private actor ActorFlag {
    private(set) var isSet: Bool = false
    func set() { isSet = true }
}
