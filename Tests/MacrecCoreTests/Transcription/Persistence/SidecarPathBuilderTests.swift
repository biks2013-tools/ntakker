// MacrecCoreTests/Transcription/Persistence/SidecarPathBuilderTests.swift
//
// Phase D (plan-003 §4 Phase D) — exhaustive coverage for the pure
// `SidecarPathBuilder.sidecarURL(...)` helper. The naming rules are
// load-bearing for AC-LT-5 (sidecar naming follows segmentation), so
// every shape that can appear in production has its own test case.

import Foundation
import Testing
@testable import MacrecCore

@Suite("SidecarPathBuilder")
struct SidecarPathBuilderTests {

    // MARK: - Single segment, all four formats

    @Test("single segment, mixed: jsonl extension")
    func singleSegmentJSONL() {
        let audio = URL(fileURLWithPath: "/tmp/recordings/recording-2026-04-26-22-30-00.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .jsonl)
        #expect(sidecar.path == "/tmp/recordings/recording-2026-04-26-22-30-00.transcript.jsonl")
    }

    @Test("single segment, mixed: srt extension")
    func singleSegmentSRT() {
        let audio = URL(fileURLWithPath: "/tmp/recordings/recording-2026-04-26-22-30-00.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .srt)
        #expect(sidecar.path == "/tmp/recordings/recording-2026-04-26-22-30-00.transcript.srt")
    }

    @Test("single segment, mixed: vtt extension")
    func singleSegmentVTT() {
        let audio = URL(fileURLWithPath: "/tmp/recordings/recording-2026-04-26-22-30-00.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .vtt)
        #expect(sidecar.path == "/tmp/recordings/recording-2026-04-26-22-30-00.transcript.vtt")
    }

    @Test("single segment, mixed: txt extension")
    func singleSegmentTXT() {
        let audio = URL(fileURLWithPath: "/tmp/recordings/recording-2026-04-26-22-30-00.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .txt)
        #expect(sidecar.path == "/tmp/recordings/recording-2026-04-26-22-30-00.transcript.txt")
    }

    // MARK: - Multi-part — verify zero-padding to 2 digits

    @Test("partNumber 1 → part01")
    func partOneZeroPadded() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 1
        )
        #expect(sidecar.lastPathComponent == "recording.part01.transcript.jsonl")
    }

    @Test("partNumber 2 → part02")
    func partTwoZeroPadded() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 2
        )
        #expect(sidecar.lastPathComponent == "recording.part02.transcript.jsonl")
    }

    @Test("partNumber 9 → part09")
    func partNineZeroPadded() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 9
        )
        #expect(sidecar.lastPathComponent == "recording.part09.transcript.jsonl")
    }

    @Test("partNumber 10 → part10 (still two digits, no extra padding)")
    func partTenTwoDigits() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 10
        )
        #expect(sidecar.lastPathComponent == "recording.part10.transcript.jsonl")
    }

    @Test("multi-part with all formats")
    func multiPartAllFormats() {
        let audio = URL(fileURLWithPath: "/tmp/r.m4a")
        let formats: [(TranscriptFormat, String)] = [
            (.jsonl, "r.part03.transcript.jsonl"),
            (.srt, "r.part03.transcript.srt"),
            (.vtt, "r.part03.transcript.vtt"),
            (.txt, "r.part03.transcript.txt"),
        ]
        for (format, expectedName) in formats {
            let sidecar = SidecarPathBuilder.sidecarURL(
                forRecording: audio,
                format: format,
                partNumber: 3
            )
            #expect(sidecar.lastPathComponent == expectedName,
                    "format \(format.rawValue) produced \(sidecar.lastPathComponent)")
        }
    }

    // MARK: - Per-source split mode

    @Test("split layout, source = system: emits .system. infix")
    func splitSystemSource() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            sourceTag: .system
        )
        #expect(sidecar.lastPathComponent == "recording.system.transcript.jsonl")
    }

    @Test("split layout, source = microphone: emits .microphone. infix")
    func splitMicrophoneSource() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            sourceTag: .microphone
        )
        #expect(sidecar.lastPathComponent == "recording.microphone.transcript.jsonl")
    }

    @Test("split layout + multi-part: part token comes BEFORE source token")
    func splitWithPartNumber() {
        let audio = URL(fileURLWithPath: "/tmp/recording.m4a")
        let systemSide = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 2,
            sourceTag: .system
        )
        let micSide = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 2,
            sourceTag: .microphone
        )
        #expect(systemSide.lastPathComponent == "recording.part02.system.transcript.jsonl")
        #expect(micSide.lastPathComponent == "recording.part02.microphone.transcript.jsonl")
    }

    // MARK: - Unusual filenames

    @Test("filename with spaces preserves them verbatim")
    func filenameWithSpaces() {
        let audio = URL(fileURLWithPath: "/tmp/My Recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .jsonl)
        #expect(sidecar.lastPathComponent == "My Recording.transcript.jsonl")
    }

    @Test("filename with embedded periods (e.g. v1.2 in basename) keeps them")
    func filenameWithPeriodsInStem() {
        // The user's basename `meeting.v1.2` has periods. Foundation's
        // `deletingPathExtension` strips only the LAST dot-suffix, so
        // `meeting.v1.2.m4a` → stem `meeting.v1.2`. The sidecar
        // therefore reads `meeting.v1.2.transcript.jsonl`. (Documented behavior.)
        let audio = URL(fileURLWithPath: "/tmp/meeting.v1.2.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .jsonl)
        #expect(sidecar.lastPathComponent == "meeting.v1.2.transcript.jsonl")
    }

    @Test("filename with periods + part number")
    func filenameWithPeriodsAndPart() {
        let audio = URL(fileURLWithPath: "/tmp/meeting.v1.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(
            forRecording: audio,
            format: .jsonl,
            partNumber: 5
        )
        #expect(sidecar.lastPathComponent == "meeting.v1.part05.transcript.jsonl")
    }

    @Test("nil partNumber and nil sourceTag → bare stem + extension")
    func bareCase() {
        let audio = URL(fileURLWithPath: "/tmp/r.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .jsonl)
        #expect(sidecar.lastPathComponent == "r.transcript.jsonl")
    }

    @Test("preserves the parent directory verbatim")
    func preservesParentDirectory() {
        let audio = URL(fileURLWithPath: "/Users/me/Recordings/sub/recording.m4a")
        let sidecar = SidecarPathBuilder.sidecarURL(forRecording: audio, format: .vtt)
        #expect(sidecar.path == "/Users/me/Recordings/sub/recording.transcript.vtt")
    }
}
