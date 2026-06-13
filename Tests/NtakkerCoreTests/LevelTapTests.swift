// NtakkerCoreTests/LevelTapTests.swift
//
// Phase A (plan-002 §3) — `levelTap` property tests for
// `SCKitSystemAudioSource` and `AVMicrophoneSource` (FR-43,
// project-design §15.3.3).
//
// The tap fires synchronously from `handleAudioBuffer` on the same
// `userInteractive` capture queue that delivers `onSampleBuffer`,
// AFTER the primary forward. End-to-end exercise of that path
// requires either a live SCStream / AVCaptureSession (which need TCC
// grants and a real audio device — not available in the unit-test
// runner) or a synthetic buffer driven through the private
// `handleAudioBuffer` entry point (also not exposed). What we CAN
// verify in a unit test:
//
//   1. The property exists on both concrete classes with the right
//      signature.
//   2. Assignment and read-back round-trip cleanly.
//   3. The closure carries a `CaptureBuffer` (NOT a raw
//      `CMSampleBuffer`) — the design contract.
//   4. The default value is `nil` — opt-in only; CLI is unaffected.
//
// Live behavior (tap fires per buffer; tap fires AFTER `onSampleBuffer`)
// is verified by the integration-level test plane — see plan-002
// Phase K acceptance for AC-UI-12 (level-meter visible cadence).
//
// Per R-22 / R-17 these tests compile but cannot be trusted on the dev
// host.

import Foundation
import Testing
@testable import NtakkerCore

@Suite("levelTap")
struct LevelTapTests {

    // MARK: - SCKitSystemAudioSource

    @available(macOS 14.0, *)
    @Test("SCKitSystemAudioSource exposes a levelTap of type ((CaptureBuffer) -> Void)?")
    func systemAudioLevelTapType() {
        let source = SCKitSystemAudioSource(
            sampleRate: 48_000,
            channelCount: 2
        )
        // Default is nil — opt-in only, CLI unaffected.
        #expect(source.levelTap == nil)

        // Assignment compiles; the closure shape is `(CaptureBuffer) -> Void`.
        var fired = 0
        source.levelTap = { buffer in
            #expect(buffer.source == .system || buffer.source == .microphone)
            fired += 1
        }
        #expect(source.levelTap != nil)

        // Clearing the tap should also work.
        source.levelTap = nil
        #expect(source.levelTap == nil)
        #expect(fired == 0)  // never invoked — no live capture.
    }

    // MARK: - AVMicrophoneSource

    @Test("AVMicrophoneSource exposes a levelTap of type ((CaptureBuffer) -> Void)?")
    func microphoneLevelTapType() {
        let source = AVMicrophoneSource(
            deviceIdentifier: nil,
            targetSampleRate: 48_000,
            targetChannelCount: 2
        )
        #expect(source.levelTap == nil)

        var fired = 0
        source.levelTap = { buffer in
            #expect(buffer.source == .system || buffer.source == .microphone)
            fired += 1
        }
        #expect(source.levelTap != nil)

        source.levelTap = nil
        #expect(source.levelTap == nil)
        #expect(fired == 0)
    }

    // MARK: - Independence from `onSampleBuffer`

    /// Setting `levelTap` must not perturb `onSampleBuffer`. They are
    /// independent properties, and the design contract is that the tap
    /// fires AFTER the primary forward.
    @available(macOS 14.0, *)
    @Test("levelTap and onSampleBuffer are independent properties")
    func independentProperties() {
        let source = SCKitSystemAudioSource()
        var primaryCalls = 0
        var tapCalls = 0

        source.onSampleBuffer = { _ in primaryCalls += 1 }
        source.levelTap = { _ in tapCalls += 1 }

        #expect(source.onSampleBuffer != nil)
        #expect(source.levelTap != nil)

        // Reassigning one does not affect the other.
        source.levelTap = nil
        #expect(source.onSampleBuffer != nil)
        #expect(source.levelTap == nil)
        #expect(primaryCalls == 0)
        #expect(tapCalls == 0)
    }
}
