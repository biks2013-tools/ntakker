// NtakkerCoreTests/RecordingOptionsTests.swift — see project-design.md §2.4 / §3.1
// Phase B — Bootstrap + Config

import Foundation
import Testing
@testable import NtakkerCore

@Suite("RecordingOptions")
struct RecordingOptionsTests {

    @Test("Defaults are populated correctly when only `output` is supplied")
    func defaultsApplied() {
        let url = URL(fileURLWithPath: "/tmp/ntakker-cli-out.m4a")
        let opts = RecordingOptions(output: url)

        #expect(opts.output == url)
        #expect(opts.format == .m4a)
        #expect(opts.layout == .mixed)
        #expect(opts.micChannel == .left)
        #expect(opts.sampleRate == 48_000)
        #expect(opts.bitDepth == 16)
        #expect(opts.bitrate == 192_000)
        #expect(opts.micDevice == nil)
        #expect(opts.logLevel == .info)
        #expect(opts.maxDuration == nil)
        #expect(opts.overwrite == false)
        #expect(opts.runMode == .foreground)
        #expect(opts.stopTimeout == 35)
    }

    @Test("Default pidFile and logFile resolve under ~/.tool-agents/ntakker-cli/")
    func detachDefaultsUnderToolAgents() {
        let opts = RecordingOptions(output: URL(fileURLWithPath: "/tmp/x.m4a"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(opts.pidFile.path == "\(home)/.tool-agents/ntakker-cli/ntakker-cli.pid")
        #expect(opts.logFile.path == "\(home)/.tool-agents/ntakker-cli/ntakker-cli.log")
    }

    @Test("Enums are CaseIterable + String-backed (round-trip via rawValue)")
    func enumRoundTrip() {
        // OutputFormat
        for c in OutputFormat.allCases {
            #expect(OutputFormat(rawValue: c.rawValue) == c)
        }
        // TrackLayout — note `.stereoSplit` rawValue is "stereo-split"
        #expect(TrackLayout(rawValue: "mixed") == .mixed)
        #expect(TrackLayout(rawValue: "split") == .split)
        #expect(TrackLayout(rawValue: "stereo-split") == .stereoSplit)
        for c in TrackLayout.allCases {
            #expect(TrackLayout(rawValue: c.rawValue) == c)
        }
        // StereoChannel / MicChannel alias
        for c in StereoChannel.allCases {
            #expect(MicChannel(rawValue: c.rawValue) == c)
        }
        // LogLevel
        for c in LogLevel.allCases {
            #expect(LogLevel(rawValue: c.rawValue) == c)
        }
        // RunMode
        for c in RunMode.allCases {
            #expect(RunMode(rawValue: c.rawValue) == c)
        }
    }

    @Test("Explicit non-default values are preserved")
    func explicitOverrides() {
        let url = URL(fileURLWithPath: "/tmp/y.wav")
        let opts = RecordingOptions(
            output: url,
            format: .wav,
            layout: .stereoSplit,
            micChannel: .right,
            sampleRate: 44_100,
            bitDepth: 24,
            bitrate: 256_000,
            micDevice: "BlackHole",
            logLevel: .debug,
            maxDuration: 120,
            overwrite: true,
            runMode: .detached,
            stopTimeout: 60
        )
        #expect(opts.format == .wav)
        #expect(opts.layout == .stereoSplit)
        #expect(opts.micChannel == .right)
        #expect(opts.sampleRate == 44_100)
        #expect(opts.bitDepth == 24)
        #expect(opts.bitrate == 256_000)
        #expect(opts.micDevice == "BlackHole")
        #expect(opts.logLevel == .debug)
        #expect(opts.maxDuration == 120)
        #expect(opts.overwrite == true)
        #expect(opts.runMode == .detached)
        #expect(opts.stopTimeout == 60)
    }
}
