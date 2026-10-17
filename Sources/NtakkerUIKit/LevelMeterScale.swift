// NtakkerUIKit/LevelMeterScale.swift — EVAL-2026-10-16 M1 / UI-5
// (plan-022 T3).
//
// Maps the linear peak / RMS magnitudes carried by `LevelSample` onto
// a perceptual 0...1 display scale, and quantises them so the
// publisher can skip samples that would not change what is drawn.
//
// Linear RMS makes quiet room noise and normal speech look alike: speech
// sits around 0.03–0.1 linear, which is 3–10 % of a linear bar. On a
// dBFS scale with a −60 dB floor the same speech fills about half to
// two thirds of the bar, and silence stays at the bottom.

import Foundation

public enum LevelMeterScale {

    /// Levels at or below this many dBFS draw as empty.
    public static let floorDB: Float = -60

    /// Distinct display steps; 1/48 of a 14 pt bar is below a pixel.
    public static let displaySteps = 48

    /// Linear magnitude → 0...1 on a dBFS scale with a `floorDB` floor.
    public static func normalized(_ linear: Float) -> Double {
        guard linear > 0, linear.isFinite else { return 0 }
        let db = 20 * log10(linear)
        return Double(max(0, min(1, (db - floorDB) / -floorDB)))
    }

    /// `normalized` rounded to one of `displaySteps` steps.
    public static func step(_ linear: Float) -> Int {
        Int((normalized(linear) * Double(displaySteps)).rounded())
    }

    /// Identity of what a merged sample would draw. Two samples with
    /// the same key render identically, so the second can be skipped.
    public struct DisplayKey: Equatable, Sendable {
        let systemRMS: Int?
        let systemPeak: Int?
        let micRMS: Int?
        let micPeak: Int?
    }

    public static func displayKey(_ sample: MergedLevelSample) -> DisplayKey {
        DisplayKey(
            systemRMS: sample.system.map { step($0.rms) },
            systemPeak: sample.system.map { step($0.peak) },
            micRMS: sample.mic.map { step($0.rms) },
            micPeak: sample.mic.map { step($0.peak) }
        )
    }
}
