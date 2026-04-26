// MacrecCoreTests/PermissionDetectionTests.swift
// Reference: project-design.md §2.6 / §2.7 / §8
//
// These are smoke tests: the underlying APIs (CGPreflight*, AVCaptureDevice,
// CoreAudio HAL) are C-level and cannot be mocked at the call site, so we
// assert only that the wrappers return well-typed values and never crash.
// The four-by-four (screen × mic) state-matrix coverage requested by §8.3
// belongs to the future `StubPermissionGate` test plane and is out of scope
// here (PermissionGate in this Wave 2 implementation is a struct, not a
// protocol — see deviation note in PermissionGate.swift).

import Foundation
import Testing
@testable import MacrecCore

@Suite("PermissionDetection")
struct PermissionDetectionTests {

    // MARK: ScreenRecordingPermission

    @Test("ScreenRecordingPermission.current() returns a documented state")
    func screenRecordingCurrentReturnsKnownState() {
        let state = ScreenRecordingPermission.current()
        #expect(
            state == .notDetermined
                || state == .denied
                || state == .authorized
        )
    }

    // MARK: MicrophonePermission

    @Test("MicrophonePermission.current() returns a documented state")
    func microphoneCurrentReturnsKnownState() {
        let state = MicrophonePermission.current()
        #expect(
            state == .notDetermined
                || state == .denied
                || state == .restricted
                || state == .authorized
        )
    }

    // MARK: PermissionGate

    @Test("PermissionGate.snapshot() returns the same values as the wrappers")
    func snapshotMatchesWrappers() async {
        let gate = PermissionGate()
        let snap = await gate.snapshot()
        #expect(snap.screenRecording == ScreenRecordingPermission.current())
        #expect(snap.microphone == MicrophonePermission.current())
    }

    @Test("PermissionGate.Snapshot.bothAuthorized is true only when both are authorized")
    func bothAuthorizedFlag() {
        #expect(
            PermissionGate.Snapshot(
                screenRecording: .authorized,
                microphone: .authorized
            ).bothAuthorized
        )
        #expect(
            !PermissionGate.Snapshot(
                screenRecording: .denied,
                microphone: .authorized
            ).bothAuthorized
        )
        #expect(
            !PermissionGate.Snapshot(
                screenRecording: .authorized,
                microphone: .denied
            ).bothAuthorized
        )
        #expect(
            !PermissionGate.Snapshot(
                screenRecording: .notDetermined,
                microphone: .restricted
            ).bothAuthorized
        )
    }

    // MARK: AudioDeviceEnumerator
    //
    // On a real Mac there is always at least one input device (the built-in
    // microphone). On a CI runner without an audio device this assertion may
    // fail; if and when CI is wired up, gate this with an env-var skip.

    @Test("AudioDeviceEnumerator.listInputs() returns at least one device")
    func listInputsIsNonEmptyOnRealHardware() throws {
        let devices = try AudioDeviceEnumerator.listInputs()
        #expect(!devices.isEmpty, "no input devices found — running on CI without audio?")
        for device in devices {
            #expect(!device.name.isEmpty, "device \(device.uid) has empty name")
            #expect(!device.uid.isEmpty, "device \(device.name) has empty uid")
            #expect(device.channelCount > 0, "device \(device.name) reports 0 input channels")
            #expect(
                device.sampleRateRange.lowerBound > 0,
                "device \(device.name) reports non-positive lower sample rate"
            )
            #expect(
                device.sampleRateRange.upperBound >= device.sampleRateRange.lowerBound,
                "device \(device.name) reports inverted sample-rate range"
            )
        }
    }

    @Test("AudioDeviceEnumerator.find returns nil for an impossible query")
    func findReturnsNilForUnknownQuery() throws {
        let result = try AudioDeviceEnumerator.find(
            byNameOrUID: "this-device-does-not-exist-\(UUID().uuidString)"
        )
        #expect(result == nil)
    }

    @Test("AudioDeviceEnumerator.find resolves a known device by UID round-trip")
    func findResolvesByUid() throws {
        let devices = try AudioDeviceEnumerator.listInputs()
        guard let first = devices.first else {
            // No hardware → silently pass; the listInputs test above already
            // surfaced the situation.
            return
        }
        let resolved = try AudioDeviceEnumerator.find(byNameOrUID: first.uid)
        #expect(resolved == first)
    }
}
