// MacrecUIKit/LevelSample.swift — see project-design.md §15.7 and
// plan-002-toolbar-ui.md §3 Phase D (FR-43).
//
// Pure value type carried on the level-meter `AsyncStream`. One sample
// per source per coalesced 30 Hz tick. Both peak and RMS are reported in
// linear (0..1) magnitude — the consumer applies any dB conversion or
// clamping (see `LevelMeterTap` for the dB floor / clamp policy when it
// fills these fields).
//
// `Sendable` because the sample crosses isolation domains:
//   capture queue (where `LevelMeterTap.extractLevels` produces it)
//     →
//   `LevelMeterPublisher`'s coalescing task
//     →
//   `RecordingController` (`@MainActor`).
//
// Equatable is hand-rolled: `Float` equality is exact, which is what
// tests want when asserting "the same sample I yielded came out the
// other end".

import Foundation

/// Source attribution for a level-meter sample. Mirrors
/// `MacrecCore.CaptureSourceTag` but lives in `MacrecUIKit` so it does
/// not leak the engine's capture-buffer envelope into the UI's stream
/// type. The coordinator translates `CaptureSourceTag → LevelSample.Source`
/// at the tap boundary.
public enum LevelSampleSource: String, Sendable, Equatable, CaseIterable {
    /// System-audio capture source.
    case system
    /// Microphone capture source.
    case mic
}

/// One coalesced peak/RMS sample produced by `LevelMeterTap` for a
/// single source. The consumer interprets `peak` and `rms` either in
/// linear magnitude (0..1) or in dB (depending on what
/// `LevelMeterTap.extractLevels` was instructed to compute — see that
/// type's documentation for the locked policy).
public struct LevelSample: Sendable, Equatable {
    /// Peak magnitude over the buffer that produced this sample.
    public let peak: Float
    /// Root-mean-square magnitude over the buffer that produced this
    /// sample.
    public let rms: Float
    /// Wall-clock time the sample was extracted at, expressed as a
    /// `TimeInterval` from the Unix epoch. Using `TimeInterval` rather
    /// than `ContinuousClock.Instant` because tests need to compare
    /// timestamps deterministically.
    public let timestamp: TimeInterval
    /// Which source produced the buffer.
    public let source: LevelSampleSource

    public init(
        peak: Float,
        rms: Float,
        timestamp: TimeInterval,
        source: LevelSampleSource
    ) {
        self.peak = peak
        self.rms = rms
        self.timestamp = timestamp
        self.source = source
    }
}

/// Pair of the most-recent `LevelSample`s — one per source — emitted by
/// `LevelMeterPublisher` on its coalesced 30 Hz tick. Either field may
/// be `nil` if no sample for that source has been observed yet (e.g.
/// the system source is still warming up while the mic is already
/// emitting).
public struct MergedLevelSample: Sendable, Equatable {
    public let system: LevelSample?
    public let mic: LevelSample?
    /// Wall-clock time the merged sample was published.
    public let timestamp: TimeInterval

    public init(
        system: LevelSample? = nil,
        mic: LevelSample? = nil,
        timestamp: TimeInterval
    ) {
        self.system = system
        self.mic = mic
        self.timestamp = timestamp
    }
}
