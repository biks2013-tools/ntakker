// MacrecCoreTests/Transcription/TranscriptionManagerTests.swift
//
// Phase E (plan-004 rest-batch) — unit tests for `TranscriptionManager`.
// Acceptance criteria handed to this phase:
//   1. The manager emits `.privacyDisclosure` exactly once on `start()`
//      when the provider is non-`none`.
//   2. Ingesting enough samples (≥ `SourceBuffer.minSamples`) and then
//      stopping the manager produces a `.segmentAppended` event whose
//      text matches the script returned by `FakeTranscriptionProvider`.
//
// Both tests use `FakeTranscriptionProvider` and `sidecarWriter: nil` so
// the unit under test is the orchestration only — no network, no disk.

import AVFoundation
import Foundation
import Logging
import Testing
@testable import MacrecCore

@Suite("TranscriptionManager")
struct TranscriptionManagerTests {

    // MARK: - Fixtures

    private static func makeOptions() -> TranscriptionOptions {
        TranscriptionOptions(
            providerId: "fake",
            apiKey: nil,
            modelId: nil,
            languageHints: [],
            customSystemInstruction: nil,
            keyExpiresAt: nil
        )
    }

    /// Build a real `AudioDownsampler` against the canonical
    /// 48 kHz / mono / non-interleaved Float32 input format. The tests
    /// never actually call `ingestFrame(_:from:)` — they use the
    /// `[Float]` `ingest(_:from:)` path — but the manager's init
    /// requires a non-nil downsampler.
    private static func makeDownsampler() throws -> AudioDownsampler {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        return try AudioDownsampler(inputFormat: inputFormat)
    }

    private static func makeLogger() -> Logger {
        Logger(label: "test.transcription.manager")
    }

    // MARK: - Tests

    @Test("emits privacy disclosure on first start with non-none provider")
    func emitsDisclosure() async throws {
        let provider = FakeTranscriptionProvider(script: ["hello"])
        let downsampler = try Self.makeDownsampler()
        let manager = TranscriptionManager(
            provider: provider,
            source: .mic,
            options: Self.makeOptions(),
            downsampler: downsampler,
            sidecarWriter: nil,
            logger: Self.makeLogger()
        )

        let stream = await manager.start()

        // Drain in the background, collecting events into an array
        // until the stream finishes (manager.stop() closes it).
        let collector = Task<[TranscriptionEvent], Never> {
            var collected: [TranscriptionEvent] = []
            for await ev in stream {
                collected.append(ev)
            }
            return collected
        }

        // The disclosure is yielded synchronously from start(); a
        // small sleep gives the collector task a chance to receive it
        // before we stop.
        try? await Task.sleep(for: .milliseconds(50))
        await manager.stop()

        let events = await collector.value
        let sawDisclosure = events.contains { event in
            if case .privacyDisclosure(let name) = event {
                return name == provider.displayName
            }
            return false
        }
        #expect(sawDisclosure)
    }

    @Test("ingesting enough samples produces a segmentAppended event")
    func ingestProducesSegment() async throws {
        let provider = FakeTranscriptionProvider(script: ["hello world"])
        let downsampler = try Self.makeDownsampler()
        let manager = TranscriptionManager(
            provider: provider,
            source: .mic,
            options: Self.makeOptions(),
            downsampler: downsampler,
            sidecarWriter: nil,
            logger: Self.makeLogger()
        )

        let stream = await manager.start()

        let collector = Task<[TranscriptionEvent], Never> {
            var collected: [TranscriptionEvent] = []
            for await ev in stream {
                collected.append(ev)
            }
            return collected
        }

        // Push enough 16 kHz samples to clear the SourceBuffer.minSamples
        // threshold (6 400 frames). Use a constant level above the
        // sanitiser's silenceThreshold (0.01) so the chunk is not
        // dropped as silence.
        let samples = Array(repeating: Float(0.2), count: 8_000)
        await manager.ingest(samples, from: .microphone)

        // stop() does a final drain on each buffer and awaits any
        // outstanding provider call before closing the event stream.
        // After it returns, the collector will see all events emitted
        // up to that point.
        await manager.stop()

        let events = await collector.value
        let sawAppended = events.contains { event in
            if case .segmentAppended(_, let segment) = event {
                return segment.text == "hello world" && segment.source == .microphone
            }
            return false
        }
        #expect(sawAppended)
    }
}
