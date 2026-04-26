// MacrecCoreTests/MacrecErrorTests.swift — see project-design.md §2.1, §9.5
//
// Phase G (plan-001) — unit tests for MacrecError's locked exit codes,
// locked stderr messages, remediation strings, LocalizedError conformance,
// and the `printToStderr()` smoke test. Every case in the enum is covered.

import Foundation
import Testing
@testable import MacrecCore

// MARK: - Helpers

/// Return a stub Error suitable for cases that wrap an underlying Error.
private struct StubError: Error, LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { self.errorDescription = msg }
}

// MARK: - Suite

@Suite("MacrecError")
struct MacrecErrorTests {

    // MARK: - Exit codes (design §9.5 — LOCKED table)

    @Test("missingRequiredConfig exits 78 (EX_CONFIG)")
    func exitCodeMissingRequiredConfig() {
        let e = MacrecError.missingRequiredConfig(key: "OUTPUT_PATH", sourcesChecked: ["env"])
        #expect(e.exitCode == 78)
    }

    @Test("micDeviceNotFound exits 78 (EX_CONFIG)")
    func exitCodeMicDeviceNotFound() {
        #expect(MacrecError.micDeviceNotFound("Built-in Microphone").exitCode == 78)
    }

    @Test("alreadyRecording exits 78 (EX_CONFIG)")
    func exitCodeAlreadyRecording() {
        #expect(MacrecError.alreadyRecording(pid: 999, pidFilePath: "/tmp/x.pid").exitCode == 78)
    }

    @Test("noActiveRecording exits 78 (EX_CONFIG)")
    func exitCodeNoActiveRecording() {
        #expect(MacrecError.noActiveRecording(pidFilePath: "/tmp/x.pid").exitCode == 78)
    }

    @Test("invalidConfigValue exits 64 (EX_USAGE)")
    func exitCodeInvalidConfigValue() {
        #expect(MacrecError.invalidConfigValue(key: "FORMAT", value: "flac", expected: "m4a|wav|caf").exitCode == 64)
    }

    @Test("dotEnvParseError exits 64 (EX_USAGE)")
    func exitCodeDotEnvParseError() {
        #expect(MacrecError.dotEnvParseError(path: "/tmp/a.env", line: 3, reason: "bad syntax").exitCode == 64)
    }

    @Test("outputParentMissing exits 66 (EX_NOINPUT)")
    func exitCodeOutputParentMissing() {
        let url = URL(fileURLWithPath: "/nonexistent/dir/out.m4a")
        #expect(MacrecError.outputParentMissing(url).exitCode == 66)
    }

    @Test("outputAlreadyExists exits 66 (EX_NOINPUT)")
    func exitCodeOutputAlreadyExists() {
        #expect(MacrecError.outputAlreadyExists(URL(fileURLWithPath: "/tmp/out.m4a")).exitCode == 66)
    }

    @Test("pidFileWriteFailed exits 66 (EX_NOINPUT)")
    func exitCodePidFileWriteFailed() {
        #expect(MacrecError.pidFileWriteFailed(path: "/tmp/p.pid", reason: "EPERM").exitCode == 66)
    }

    @Test("screenRecordingPermissionNotDetermined exits 75 (EX_TEMPFAIL)")
    func exitCodeScreenRecordingPermissionNotDetermined() {
        #expect(MacrecError.screenRecordingPermissionNotDetermined.exitCode == 75)
    }

    @Test("microphonePermissionNotDetermined exits 75 (EX_TEMPFAIL)")
    func exitCodeMicrophonePermissionNotDetermined() {
        #expect(MacrecError.microphonePermissionNotDetermined.exitCode == 75)
    }

    @Test("staleRecording exits 75 (EX_TEMPFAIL)")
    func exitCodeStaleRecording() {
        #expect(MacrecError.staleRecording(pid: 1234, pidFilePath: "/tmp/x.pid").exitCode == 75)
    }

    @Test("screenRecordingPermissionDenied exits 77 (EX_NOPERM)")
    func exitCodeScreenRecordingPermissionDenied() {
        #expect(MacrecError.screenRecordingPermissionDenied.exitCode == 77)
    }

    @Test("microphonePermissionDenied exits 77 (EX_NOPERM)")
    func exitCodeMicrophonePermissionDenied() {
        #expect(MacrecError.microphonePermissionDenied.exitCode == 77)
    }

    @Test("microphonePermissionRestricted exits 77 (EX_NOPERM)")
    func exitCodeMicrophonePermissionRestricted() {
        #expect(MacrecError.microphonePermissionRestricted.exitCode == 77)
    }

    @Test("noInputDevicesAvailable exits 70 (EX_SOFTWARE)")
    func exitCodeNoInputDevicesAvailable() {
        #expect(MacrecError.noInputDevicesAvailable.exitCode == 70)
    }

    @Test("scStreamFailedToStart exits 70 (EX_SOFTWARE)")
    func exitCodeScStreamFailedToStart() {
        #expect(MacrecError.scStreamFailedToStart(underlying: StubError("x")).exitCode == 70)
    }

    @Test("scStreamSilentStopExceeded exits 70 (EX_SOFTWARE)")
    func exitCodeScStreamSilentStopExceeded() {
        #expect(MacrecError.scStreamSilentStopExceeded(restartCount: 3).exitCode == 70)
    }

    @Test("avCaptureFailedToStart exits 70 (EX_SOFTWARE)")
    func exitCodeAvCaptureFailedToStart() {
        #expect(MacrecError.avCaptureFailedToStart(underlying: StubError("y")).exitCode == 70)
    }

    @Test("writerFailedToStart exits 70 (EX_SOFTWARE)")
    func exitCodeWriterFailedToStart() {
        #expect(MacrecError.writerFailedToStart(underlying: StubError("z")).exitCode == 70)
    }

    @Test("stopTimeout exits 70 (EX_SOFTWARE)")
    func exitCodeStopTimeout() {
        #expect(MacrecError.stopTimeout(pid: 42, seconds: 35).exitCode == 70)
    }

    @Test("writerFinalizationTimeout exits 2")
    func exitCodeWriterFinalizationTimeout() {
        #expect(MacrecError.writerFinalizationTimeout(URL(fileURLWithPath: "/tmp/o.m4a")).exitCode == 2)
    }

    @Test("finishWritingFailed exits 1")
    func exitCodeFinishWritingFailed() {
        #expect(MacrecError.finishWritingFailed(underlying: StubError("w")).exitCode == 1)
    }

    @Test("ioError exits 1")
    func exitCodeIoError() {
        #expect(MacrecError.ioError("disk full").exitCode == 1)
    }

    @Test("unknown exits 1")
    func exitCodeUnknown() {
        #expect(MacrecError.unknown("???").exitCode == 1)
    }

    // MARK: - description / errorDescription non-empty (all cases)

    @Test("description is non-empty for every enum case")
    func descriptionNonEmpty() {
        let cases: [MacrecError] = [
            .missingRequiredConfig(key: "K", sourcesChecked: ["env", "~/.env"]),
            .invalidConfigValue(key: "FORMAT", value: "flac", expected: "m4a|wav|caf"),
            .dotEnvParseError(path: "/tmp/a.env", line: 1, reason: "bad"),
            .outputParentMissing(URL(fileURLWithPath: "/tmp/dir/out.m4a")),
            .outputAlreadyExists(URL(fileURLWithPath: "/tmp/out.m4a")),
            .screenRecordingPermissionDenied,
            .screenRecordingPermissionNotDetermined,
            .microphonePermissionDenied,
            .microphonePermissionNotDetermined,
            .microphonePermissionRestricted,
            .noInputDevicesAvailable,
            .micDeviceNotFound("Built-in"),
            .scStreamFailedToStart(underlying: StubError("x")),
            .scStreamSilentStopExceeded(restartCount: 2),
            .avCaptureFailedToStart(underlying: StubError("y")),
            .writerFailedToStart(underlying: StubError("z")),
            .writerFinalizationTimeout(URL(fileURLWithPath: "/tmp/out.m4a")),
            .finishWritingFailed(underlying: StubError("w")),
            .noActiveRecording(pidFilePath: "/tmp/x.pid"),
            .staleRecording(pid: 1234, pidFilePath: "/tmp/x.pid"),
            .stopTimeout(pid: 99, seconds: 35),
            .alreadyRecording(pid: 1234, pidFilePath: "/tmp/x.pid"),
            .pidFileWriteFailed(path: "/tmp/p.pid", reason: "EPERM"),
            .ioError("something"),
            .unknown("weird"),
        ]
        for c in cases {
            #expect(!c.description.isEmpty, "description empty for \(c)")
            #expect(c.errorDescription != nil, "errorDescription nil for \(c)")
            #expect(!(c.errorDescription ?? "").isEmpty, "errorDescription empty for \(c)")
        }
    }

    // MARK: - recoverySuggestion non-empty (all cases)

    @Test("recoverySuggestion is non-empty for every enum case")
    func recoverySuggestionNonEmpty() {
        let cases: [MacrecError] = [
            .missingRequiredConfig(key: "K", sourcesChecked: ["env"]),
            .invalidConfigValue(key: "FORMAT", value: "flac", expected: "m4a|wav|caf"),
            .dotEnvParseError(path: "/tmp/a.env", line: 1, reason: "bad"),
            .outputParentMissing(URL(fileURLWithPath: "/tmp/dir/out.m4a")),
            .outputAlreadyExists(URL(fileURLWithPath: "/tmp/out.m4a")),
            .screenRecordingPermissionDenied,
            .screenRecordingPermissionNotDetermined,
            .microphonePermissionDenied,
            .microphonePermissionNotDetermined,
            .microphonePermissionRestricted,
            .noInputDevicesAvailable,
            .micDeviceNotFound("Built-in"),
            .scStreamFailedToStart(underlying: StubError("x")),
            .scStreamSilentStopExceeded(restartCount: 2),
            .avCaptureFailedToStart(underlying: StubError("y")),
            .writerFailedToStart(underlying: StubError("z")),
            .writerFinalizationTimeout(URL(fileURLWithPath: "/tmp/out.m4a")),
            .finishWritingFailed(underlying: StubError("w")),
            .noActiveRecording(pidFilePath: "/tmp/x.pid"),
            .staleRecording(pid: 1234, pidFilePath: "/tmp/x.pid"),
            .stopTimeout(pid: 99, seconds: 35),
            .alreadyRecording(pid: 1234, pidFilePath: "/tmp/x.pid"),
            .pidFileWriteFailed(path: "/tmp/p.pid", reason: "EPERM"),
            .ioError("something"),
            .unknown("weird"),
        ]
        for c in cases {
            let rs = c.recoverySuggestion
            #expect(rs != nil, "recoverySuggestion nil for \(c)")
            #expect(!(rs ?? "").isEmpty, "recoverySuggestion empty for \(c)")
        }
    }

    // MARK: - Associated-value interpolation in description

    @Test("alreadyRecording description interpolates pid and pidFilePath")
    func alreadyRecordingInterpolation() {
        let e = MacrecError.alreadyRecording(pid: 1234, pidFilePath: "/tmp/x.pid")
        #expect(e.description.contains("1234"))
        #expect(e.description.contains("/tmp/x.pid"))
    }

    @Test("staleRecording description interpolates pid and pidFilePath")
    func staleRecordingInterpolation() {
        let e = MacrecError.staleRecording(pid: 5678, pidFilePath: "/var/run/m.pid")
        #expect(e.description.contains("5678"))
        #expect(e.description.contains("/var/run/m.pid"))
    }

    @Test("noActiveRecording description contains pidFilePath")
    func noActiveRecordingInterpolation() {
        let e = MacrecError.noActiveRecording(pidFilePath: "/home/user/macrec.pid")
        #expect(e.description.contains("/home/user/macrec.pid"))
    }

    @Test("stopTimeout description contains pid and seconds")
    func stopTimeoutInterpolation() {
        let e = MacrecError.stopTimeout(pid: 42, seconds: 35)
        #expect(e.description.contains("42"))
        #expect(e.description.contains("35"))
    }

    @Test("missingRequiredConfig description contains the key name")
    func missingRequiredConfigInterpolation() {
        let e = MacrecError.missingRequiredConfig(key: "OUTPUT_PATH", sourcesChecked: ["env", "~/.env"])
        #expect(e.description.contains("OUTPUT_PATH"))
    }

    @Test("dotEnvParseError description contains path and line number")
    func dotEnvParseErrorInterpolation() {
        let e = MacrecError.dotEnvParseError(path: "/tmp/a.env", line: 7, reason: "garbage")
        #expect(e.description.contains("/tmp/a.env"))
        #expect(e.description.contains("7"))
    }

    @Test("micDeviceNotFound description contains the identifier")
    func micDeviceNotFoundInterpolation() {
        let e = MacrecError.micDeviceNotFound("AppleMicrophoneUID123")
        #expect(e.description.contains("AppleMicrophoneUID123"))
    }

    @Test("scStreamSilentStopExceeded description contains restart count")
    func scStreamSilentStopExceededInterpolation() {
        let e = MacrecError.scStreamSilentStopExceeded(restartCount: 9)
        #expect(e.description.contains("9"))
    }

    @Test("writerFinalizationTimeout description contains the url path")
    func writerFinalizationTimeoutInterpolation() {
        let url = URL(fileURLWithPath: "/recordings/session.m4a")
        let e = MacrecError.writerFinalizationTimeout(url)
        #expect(e.description.contains("/recordings/session.m4a"))
    }

    @Test("pidFileWriteFailed description contains path and reason")
    func pidFileWriteFailedInterpolation() {
        let e = MacrecError.pidFileWriteFailed(path: "/tmp/x.pid", reason: "permission denied")
        #expect(e.description.contains("/tmp/x.pid"))
        #expect(e.description.contains("permission denied"))
    }

    // MARK: - Locked stderr message spot checks (design §2.1)

    @Test("screenRecordingPermissionDenied description matches locked string")
    func lockedDescScreenRecordingDenied() {
        let e = MacrecError.screenRecordingPermissionDenied
        #expect(e.description == "Screen Recording permission denied")
    }

    @Test("microphonePermissionDenied description matches locked string")
    func lockedDescMicDenied() {
        let e = MacrecError.microphonePermissionDenied
        #expect(e.description == "Microphone permission denied")
    }

    @Test("noInputDevicesAvailable description matches locked string")
    func lockedDescNoInputDevices() {
        let e = MacrecError.noInputDevicesAvailable
        #expect(e.description == "no input audio devices found on this system")
    }

    @Test("microphonePermissionRestricted description matches locked string")
    func lockedDescMicRestricted() {
        let e = MacrecError.microphonePermissionRestricted
        #expect(e.description == "Microphone access is restricted by an MDM profile or parental control")
    }

    // MARK: - printToStderr smoke test

    @Test("printToStderr does not crash for any case")
    func printToStderrSmoke() {
        // We can't easily redirect FileHandle.standardError in a unit test
        // without touching shared infrastructure, but we can confirm the
        // call path runs without throwing or crashing. All 25 cases are
        // exercised.
        let cases: [MacrecError] = [
            .missingRequiredConfig(key: "K", sourcesChecked: ["env"]),
            .invalidConfigValue(key: "FORMAT", value: "flac", expected: "m4a|wav|caf"),
            .dotEnvParseError(path: "/tmp/a.env", line: 1, reason: "bad"),
            .outputParentMissing(URL(fileURLWithPath: "/tmp/dir/out.m4a")),
            .outputAlreadyExists(URL(fileURLWithPath: "/tmp/out.m4a")),
            .screenRecordingPermissionDenied,
            .screenRecordingPermissionNotDetermined,
            .microphonePermissionDenied,
            .microphonePermissionNotDetermined,
            .microphonePermissionRestricted,
            .noInputDevicesAvailable,
            .micDeviceNotFound("Built-in"),
            .scStreamFailedToStart(underlying: StubError("x")),
            .scStreamSilentStopExceeded(restartCount: 2),
            .avCaptureFailedToStart(underlying: StubError("y")),
            .writerFailedToStart(underlying: StubError("z")),
            .writerFinalizationTimeout(URL(fileURLWithPath: "/tmp/out.m4a")),
            .finishWritingFailed(underlying: StubError("w")),
            .noActiveRecording(pidFilePath: "/tmp/x.pid"),
            .staleRecording(pid: 1234, pidFilePath: "/tmp/x.pid"),
            .stopTimeout(pid: 99, seconds: 35),
            .alreadyRecording(pid: 1234, pidFilePath: "/tmp/x.pid"),
            .pidFileWriteFailed(path: "/tmp/p.pid", reason: "EPERM"),
            .ioError("something"),
            .unknown("weird"),
        ]
        for c in cases {
            // Must not crash.
            c.printToStderr()
        }
    }

    // MARK: - LocalizedError conformance

    @Test("errorDescription equals description")
    func errorDescriptionEqualsDescription() {
        let cases: [MacrecError] = [
            .ioError("test"),
            .screenRecordingPermissionDenied,
            .alreadyRecording(pid: 1, pidFilePath: "/tmp/p.pid"),
        ]
        for c in cases {
            #expect(c.errorDescription == c.description)
        }
    }

    @Test("recoverySuggestion equals remediation")
    func recoverySuggestionEqualsRemediation() {
        let cases: [MacrecError] = [
            .ioError("disk full"),
            .microphonePermissionDenied,
        ]
        for c in cases {
            #expect(c.recoverySuggestion == c.remediation)
        }
    }
}
