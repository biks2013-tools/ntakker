// MacrecUITests/UIErrorPresenterTests.swift — see plan-002-toolbar-ui.md
// §3 Phase G and project-design.md §15.10.
//
// Verifies that `UIErrorPresenter.present(_:)` emits a non-empty
// title + detail and the documented recovery action for every case in
// `MacrecError`.
//
// R-22 / R-31: every change must come with regression tests. The
// `everyMacrecErrorCaseHasAMapping` test is the exhaustiveness gate —
// new `MacrecError` cases will surface here as missing entries in the
// hand-maintained array.

import Foundation
import Testing
@testable import MacrecUIKit
@testable import MacrecCore

@Suite("UIErrorPresenter")
struct UIErrorPresenterTests {

    // MARK: - Permissions ----------------------------------------------------

    @Test("microphonePermissionDenied → openSystemSettings(Privacy_Microphone)")
    func microphonePermissionDenied() {
        let p = UIErrorPresenter.present(.microphonePermissionDenied)
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        if case let .openSystemSettings(url) = p.recovery {
            #expect(url.absoluteString.contains("Privacy_Microphone"))
        } else {
            Issue.record("expected .openSystemSettings recovery; got \(String(describing: p.recovery))")
        }
    }

    @Test("microphonePermissionNotDetermined → retry")
    func microphonePermissionNotDetermined() {
        let p = UIErrorPresenter.present(.microphonePermissionNotDetermined)
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    @Test("microphonePermissionRestricted → dismiss")
    func microphonePermissionRestricted() {
        let p = UIErrorPresenter.present(.microphonePermissionRestricted)
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    @Test("screenRecordingPermissionDenied → openSystemSettings(Privacy_ScreenCapture)")
    func screenRecordingPermissionDenied() {
        let p = UIErrorPresenter.present(.screenRecordingPermissionDenied)
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        if case let .openSystemSettings(url) = p.recovery {
            #expect(url.absoluteString.contains("Privacy_ScreenCapture"))
        } else {
            Issue.record("expected .openSystemSettings recovery; got \(String(describing: p.recovery))")
        }
    }

    @Test("screenRecordingPermissionNotDetermined → retry")
    func screenRecordingPermissionNotDetermined() {
        let p = UIErrorPresenter.present(.screenRecordingPermissionNotDetermined)
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    // MARK: - Output path ----------------------------------------------------

    @Test("outputAlreadyExists interpolates the lastPathComponent")
    func outputAlreadyExists() {
        let url = URL(fileURLWithPath: "/tmp/example.m4a")
        let p = UIErrorPresenter.present(.outputAlreadyExists(url))
        #expect(!p.title.isEmpty)
        #expect(p.detail.contains("example.m4a"))
        #expect(p.recovery == .dismiss)
    }

    @Test("outputParentMissing → dismiss")
    func outputParentMissing() {
        let url = URL(fileURLWithPath: "/tmp/ghost-folder/file.m4a")
        let p = UIErrorPresenter.present(.outputParentMissing(url))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    // MARK: - Configuration --------------------------------------------------

    @Test("missingRequiredConfig → dismiss, includes the key")
    func missingRequiredConfig() {
        let p = UIErrorPresenter.present(
            .missingRequiredConfig(key: "MACREC_OUTPUT", sourcesChecked: ["env"])
        )
        #expect(!p.title.isEmpty)
        #expect(p.detail.contains("MACREC_OUTPUT"))
        #expect(p.recovery == .dismiss)
    }

    @Test("invalidConfigValue → dismiss")
    func invalidConfigValue() {
        let p = UIErrorPresenter.present(
            .invalidConfigValue(
                key: "MACREC_LAYOUT",
                value: "weird",
                expected: "mixed|split|stereo-split"
            )
        )
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    @Test("dotEnvParseError → dismiss")
    func dotEnvParseError() {
        let p = UIErrorPresenter.present(
            .dotEnvParseError(path: "/tmp/.env", line: 4, reason: "missing =")
        )
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    // MARK: - Devices --------------------------------------------------------

    @Test("noInputDevicesAvailable → dismiss")
    func noInputDevicesAvailable() {
        let p = UIErrorPresenter.present(.noInputDevicesAvailable)
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    @Test("micDeviceNotFound → dismiss, includes identifier")
    func micDeviceNotFound() {
        let p = UIErrorPresenter.present(.micDeviceNotFound("AppleHDA:1"))
        #expect(!p.title.isEmpty)
        #expect(p.detail.contains("AppleHDA:1"))
        #expect(p.recovery == .dismiss)
    }

    // MARK: - Capture --------------------------------------------------------

    @Test("scStreamFailedToStart → retry")
    func scStreamFailedToStart() {
        let underlying = NSError(domain: "test", code: 1)
        let p = UIErrorPresenter.present(.scStreamFailedToStart(underlying: underlying))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    @Test("scStreamSilentStopExceeded → retry")
    func scStreamSilentStopExceeded() {
        let p = UIErrorPresenter.present(.scStreamSilentStopExceeded(restartCount: 3))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    @Test("avCaptureFailedToStart → retry")
    func avCaptureFailedToStart() {
        let underlying = NSError(domain: "test", code: 2)
        let p = UIErrorPresenter.present(.avCaptureFailedToStart(underlying: underlying))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    // MARK: - Encoding -------------------------------------------------------

    @Test("writerFailedToStart → retry (encoderFailure slot)")
    func writerFailedToStart() {
        let underlying = NSError(domain: "test", code: 3)
        let p = UIErrorPresenter.present(.writerFailedToStart(underlying: underlying))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    @Test("writerFinalizationTimeout → dismiss, includes lastPathComponent")
    func writerFinalizationTimeout() {
        let url = URL(fileURLWithPath: "/tmp/partial.m4a")
        let p = UIErrorPresenter.present(.writerFinalizationTimeout(url))
        #expect(!p.title.isEmpty)
        #expect(p.detail.contains("partial.m4a"))
        #expect(p.recovery == .dismiss)
    }

    @Test("finishWritingFailed → retry")
    func finishWritingFailed() {
        let underlying = NSError(domain: "test", code: 4)
        let p = UIErrorPresenter.present(.finishWritingFailed(underlying: underlying))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    // MARK: - Detach / stop subcommand --------------------------------------

    @Test("noActiveRecording → dismiss")
    func noActiveRecording() {
        let p = UIErrorPresenter.present(
            .noActiveRecording(pidFilePath: "/tmp/macrec.pid")
        )
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    @Test("staleRecording → retry")
    func staleRecording() {
        let p = UIErrorPresenter.present(
            .staleRecording(pid: 99999, pidFilePath: "/tmp/macrec.pid")
        )
        #expect(!p.title.isEmpty)
        #expect(p.detail.contains("99999"))
        #expect(p.recovery == .retry)
    }

    @Test("stopTimeout → dismiss")
    func stopTimeout() {
        let p = UIErrorPresenter.present(.stopTimeout(pid: 1234, seconds: 30))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    @Test("alreadyRecording → dismiss")
    func alreadyRecording() {
        let p = UIErrorPresenter.present(
            .alreadyRecording(pid: 4321, pidFilePath: "/tmp/macrec.pid")
        )
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    @Test("pidFileWriteFailed → dismiss")
    func pidFileWriteFailed() {
        let p = UIErrorPresenter.present(
            .pidFileWriteFailed(path: "/tmp/macrec.pid", reason: "EACCES")
        )
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    // MARK: - Generic --------------------------------------------------------

    @Test("ioError → retry")
    func ioError() {
        let p = UIErrorPresenter.present(.ioError("disk full"))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .retry)
    }

    @Test("unknown → dismiss")
    func unknownError() {
        let p = UIErrorPresenter.present(.unknown("boom"))
        #expect(!p.title.isEmpty)
        #expect(!p.detail.isEmpty)
        #expect(p.recovery == .dismiss)
    }

    // MARK: - Exhaustiveness gate -------------------------------------------

    /// Hand-maintained list of every `MacrecError` case. When a new
    /// case is added to `MacrecError`, this list MUST be updated. The
    /// test asserts that `UIErrorPresenter.present(_:)` emits a
    /// non-empty title for every entry — protecting against silent
    /// regressions (e.g. a future case that defaults to an empty
    /// "Unknown" mapping).
    private static let allMacrecErrors: [MacrecError] = [
        // Configuration
        .missingRequiredConfig(key: "MACREC_OUTPUT", sourcesChecked: ["env"]),
        .invalidConfigValue(key: "MACREC_LAYOUT", value: "x", expected: "y"),
        .dotEnvParseError(path: "/tmp/.env", line: 1, reason: "bad"),

        // Output path
        .outputParentMissing(URL(fileURLWithPath: "/tmp/x/y.m4a")),
        .outputAlreadyExists(URL(fileURLWithPath: "/tmp/x.m4a")),

        // Permissions
        .screenRecordingPermissionDenied,
        .screenRecordingPermissionNotDetermined,
        .microphonePermissionDenied,
        .microphonePermissionNotDetermined,
        .microphonePermissionRestricted,

        // Devices
        .noInputDevicesAvailable,
        .micDeviceNotFound("uid"),

        // Capture
        .scStreamFailedToStart(underlying: NSError(domain: "t", code: 1)),
        .scStreamSilentStopExceeded(restartCount: 5),
        .avCaptureFailedToStart(underlying: NSError(domain: "t", code: 2)),

        // Encoding
        .writerFailedToStart(underlying: NSError(domain: "t", code: 3)),
        .writerFinalizationTimeout(URL(fileURLWithPath: "/tmp/x.m4a")),
        .finishWritingFailed(underlying: NSError(domain: "t", code: 4)),

        // Detach mode and `stop` subcommand
        .noActiveRecording(pidFilePath: "/tmp/macrec.pid"),
        .staleRecording(pid: 1, pidFilePath: "/tmp/macrec.pid"),
        .stopTimeout(pid: 2, seconds: 10),
        .alreadyRecording(pid: 3, pidFilePath: "/tmp/macrec.pid"),
        .pidFileWriteFailed(path: "/tmp/macrec.pid", reason: "EACCES"),

        // Generic
        .ioError("err"),
        .unknown("err"),
    ]

    @Test("every MacrecError case has a non-empty mapping")
    func everyMacrecErrorCaseHasAMapping() {
        for error in Self.allMacrecErrors {
            let p = UIErrorPresenter.present(error)
            #expect(!p.title.isEmpty, "title empty for \(error.description)")
            #expect(!p.detail.isEmpty, "detail empty for \(error.description)")
        }
    }
}
