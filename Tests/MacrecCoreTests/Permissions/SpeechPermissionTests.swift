// MacrecCoreTests/Permissions/SpeechPermissionTests.swift
// Reference: plan-005-apple-speech-streaming.md §"Phase C — Task C.3"
//
// Smoke test: the underlying `SFSpeechRecognizer.authorizationStatus()` is
// a system call we cannot mock, so the only thing we can assert at unit-
// test time is that the wrapper returns one of the four documented
// `State` values and never crashes. End-to-end coverage of the
// "permission denied -> EX_CONFIG (78)" path lives in the Phase I
// e2e-transcription-permission-denied.sh script.

import Foundation
import Testing
@testable import MacrecCore

@Suite("SpeechPermission")
struct SpeechPermissionTests {
    @Test("currentStatus returns one of the four states")
    func currentStatusValid() {
        let s = SpeechPermission.current()
        let valid: [SpeechPermission.State] = [.notDetermined, .denied, .restricted, .authorized]
        #expect(valid.contains(s))
    }
}
