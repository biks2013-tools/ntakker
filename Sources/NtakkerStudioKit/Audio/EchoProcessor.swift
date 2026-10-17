// NtakkerStudioKit/Audio/EchoProcessor.swift — 2026-10-17.
//
// The studio's echo filter, used by the player and by the cleaned export:
//
//   mic, delayed reference ─► NLMS canceller ─► [residual suppressor] ─► strength mix ─► out
//
// Settings (all adjustable by the user):
//   * strength     — how much of the removed echo to take out (0…1);
//                    out = (1 − s)·mic + s·processed.
//   * suppression  — the second stage (`ResidualEchoSuppressor`): off,
//                    low or high. Adds `ResidualEchoSuppressor.latency`
//                    samples of delay when on.
//   * adaptation   — how fast the canceller learns: stable or fast.
// The echo delay (how far the reference is shifted) is applied by the
// caller when it reads the system track; see `EchoDelayEstimator`.

import Foundation
import NtakkerCore

public struct EchoFilterSettings: Sendable, Equatable, Codable {
    public enum Suppression: String, Sendable, Codable, CaseIterable { case off, low, high }
    public enum Adaptation: String, Sendable, Codable, CaseIterable { case stable, fast }

    public var strength: Double
    public var suppression: Suppression
    public var adaptation: Adaptation

    /// The behaviour of 0.2.0: full strength, no second stage, fast learning.
    public static let standard = EchoFilterSettings(strength: 1, suppression: .off, adaptation: .fast)

    public init(strength: Double, suppression: Suppression, adaptation: Adaptation) {
        self.strength = min(1, max(0, strength))
        self.suppression = suppression
        self.adaptation = adaptation
    }
}

public final class EchoProcessor {
    public private(set) var settings: EchoFilterSettings
    public let sampleRate: Double
    private var aec: SoftwareAECProcessor
    private var suppressor: ResidualEchoSuppressor?
    /// The mic delayed by the suppressor's latency, for the strength mix.
    private var dryDelay: [Float] = []

    public init(sampleRate: Double, settings: EchoFilterSettings) {
        self.sampleRate = sampleRate
        self.settings = settings
        self.aec = Self.makeCanceller(sampleRate: sampleRate, adaptation: settings.adaptation)
        configureSuppressor()
    }

    /// Delay the output adds on top of the input (0 without the second stage).
    public var latency: Int { suppressor?.latency ?? 0 }

    static func makeCanceller(sampleRate: Double, adaptation: EchoFilterSettings.Adaptation) -> SoftwareAECProcessor {
        switch adaptation {
        case .fast:
            return SoftwareAECProcessor(config: SoftwareAECProcessor.playbackConfiguration(sampleRate: sampleRate))
        case .stable:
            // Slower, steadier learning: a sixth of the step, smaller per-sample
            // moves. Holds up better when the room is noisy; re-learns more
            // slowly after the echo changes.
            return SoftwareAECProcessor(config: .init(
                filterLength: 4096, stepSize: 0.05, channels: 1, sampleRate: sampleRate,
                stepMax: 0.05, leakage: 1e-6
            ))
        }
    }

    private func configureSuppressor() {
        switch settings.suppression {
        case .off: suppressor = nil
        case .low: suppressor = ResidualEchoSuppressor(overSubtraction: 0.6, floor: 0.3)
        case .high: suppressor = ResidualEchoSuppressor(overSubtraction: 1.6, floor: 0.08)
        }
        dryDelay = [Float](repeating: 0, count: latency)
    }

    /// Apply new settings. A new adaptation speed starts the canceller
    /// afresh; the other settings take effect from the next block.
    public func update(_ new: EchoFilterSettings) {
        let old = settings
        settings = new
        if new.adaptation != old.adaptation {
            aec = Self.makeCanceller(sampleRate: sampleRate, adaptation: new.adaptation)
        }
        if new.suppression != old.suppression { configureSuppressor() }
    }

    /// After a seek: keep what was learnt about the echo path, clear the rest.
    public func resetTimeline() {
        aec.resetAlignedTimeline()
        suppressor?.reset()
        dryDelay = [Float](repeating: 0, count: latency)
    }

    /// After the reference delay changed: what was learnt no longer lines up.
    public func resetEchoPath() {
        aec.resetAlignedTimeline(clearingEchoPath: true)
        suppressor?.reset()
        dryDelay = [Float](repeating: 0, count: latency)
    }

    /// Filter one block. With `produceOutput: false` the canceller still
    /// learns (so switching the filter on is instant) but the second stage
    /// is skipped and the mic is returned unchanged.
    public func process(mic: [Float], reference: [Float], produceOutput: Bool = true) -> [Float] {
        let cleaned = aec.processAligned(mic: mic, reference: reference)
        guard produceOutput else { return mic }
        var processed = cleaned
        var dry = mic
        if let suppressor {
            let echo = zip(mic, cleaned).map { $0 - $1 }
            processed = suppressor.process(output: cleaned, echo: echo)
            // Delay the dry mic by the same latency.
            dryDelay += mic
            dry = Array(dryDelay.prefix(mic.count))
            dryDelay.removeFirst(mic.count)
        }
        let s = Float(settings.strength)
        if s >= 1 { return processed }
        return zip(dry, processed).map { (1 - s) * $0 + s * $1 }
    }
}
