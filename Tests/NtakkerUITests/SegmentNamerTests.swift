// NtakkerUITests/SegmentNamerTests.swift — see plan-002 §3 Phase D
// (FR-34) and project-design.md §15.6.
//
// Exhaustive cases per the FR-34 multi-file spec:
//   * Single segment (segment 1) → no `partNN` infix.
//   * Multi-segment, mixed layout → `<basename>.partNN.<ext>`.
//   * `--layout split` → `partNN` infix BEFORE the `.system` / `.mic`
//     layout token.
//   * Off-by-one boundary at segment 99 → 100 (still uses
//     `String(format: "part%02d")` which produces a 3-digit string for
//     segments ≥ 100).

import Foundation
import Testing
@testable import NtakkerUIKit

@Suite("SegmentNamer")
struct SegmentNamerTests {

    private func tmpURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    @Test("segment 1 returns the original URL unchanged (no partNN infix)")
    func segmentOneIsUnsuffixed() {
        let original = tmpURL("recording-2026-04-26-18-30.m4a")
        let result = SegmentNamer.next(after: original, segment: 1)
        #expect(result == original)
    }

    @Test("segment 2 inserts .part02 before the extension (mixed layout)")
    func segmentTwoMixedLayout() {
        let original = tmpURL("recording-2026-04-26-18-30.m4a")
        let result = SegmentNamer.next(after: original, segment: 2)
        #expect(result.lastPathComponent == "recording-2026-04-26-18-30.part02.m4a")
    }

    @Test("segment 10 zero-pads to part10")
    func segmentTenPads() {
        let original = tmpURL("recording-2026-04-26-18-30.wav")
        let result = SegmentNamer.next(after: original, segment: 10)
        #expect(result.lastPathComponent == "recording-2026-04-26-18-30.part10.wav")
    }

    @Test("split-layout system file: partNN goes BEFORE .system token")
    func splitLayoutSystem() {
        let original = tmpURL("recording-2026-04-26-18-30.system.m4a")
        let result = SegmentNamer.next(after: original, segment: 2)
        #expect(result.lastPathComponent == "recording-2026-04-26-18-30.part02.system.m4a")
    }

    @Test("split-layout mic file: partNN goes BEFORE .mic token")
    func splitLayoutMic() {
        let original = tmpURL("recording-2026-04-26-18-30.mic.m4a")
        let result = SegmentNamer.next(after: original, segment: 3)
        #expect(result.lastPathComponent == "recording-2026-04-26-18-30.part03.mic.m4a")
    }

    @Test("partURL with segment 1 yields .part01 (rename helper for FR-34)")
    func partURLSegmentOneForRename() {
        let original = tmpURL("recording-2026-04-26-18-30.m4a")
        let renamed = SegmentNamer.partURL(originalURL: original, segment: 1)
        #expect(renamed.lastPathComponent == "recording-2026-04-26-18-30.part01.m4a")
    }

    @Test("99 → 100 boundary expands the zero-pad to three digits")
    func segmentBoundary99To100() {
        let original = tmpURL("recording-2026-04-26-18-30.m4a")
        let s99 = SegmentNamer.next(after: original, segment: 99)
        let s100 = SegmentNamer.next(after: original, segment: 100)
        #expect(s99.lastPathComponent == "recording-2026-04-26-18-30.part99.m4a")
        // String(format: "part%02d", 100) → "part100"; %02d is a
        // minimum width, not maximum.
        #expect(s100.lastPathComponent == "recording-2026-04-26-18-30.part100.m4a")
    }

    @Test("Files with no extension still get the partNN infix")
    func noExtension() {
        let original = tmpURL("recording-2026-04-26-18-30")
        let result = SegmentNamer.next(after: original, segment: 2)
        #expect(result.lastPathComponent == "recording-2026-04-26-18-30.part02")
    }

    @Test("renameForFirstSegment yields the .part01 sibling for mixed layout")
    func renameForFirstSegmentMixed() {
        let original = tmpURL("recording-2026-04-26-18-30.m4a")
        let renamed = SegmentNamer.renameForFirstSegment(original)
        #expect(renamed.lastPathComponent == "recording-2026-04-26-18-30.part01.m4a")
    }

    @Test("renameForFirstSegment preserves the .system / .mic split-layout token")
    func renameForFirstSegmentSplit() {
        let system = tmpURL("recording-2026-04-26-18-30.system.m4a")
        let mic = tmpURL("recording-2026-04-26-18-30.mic.m4a")
        let renamedSystem = SegmentNamer.renameForFirstSegment(system)
        let renamedMic = SegmentNamer.renameForFirstSegment(mic)
        #expect(renamedSystem.lastPathComponent == "recording-2026-04-26-18-30.part01.system.m4a")
        #expect(renamedMic.lastPathComponent == "recording-2026-04-26-18-30.part01.mic.m4a")
    }

    @Test("splitSidecarURLs derives the engine's <base>.<side>.<ext> sibling pair")
    func splitSidecarURLsDerivation() {
        let base = tmpURL("recording-2026-04-26-18-30.m4a")
        let pair = SegmentNamer.splitSidecarURLs(baseURL: base)
        #expect(pair.system.lastPathComponent == "recording-2026-04-26-18-30.system.m4a")
        #expect(pair.mic.lastPathComponent == "recording-2026-04-26-18-30.mic.m4a")
    }

    @Test("splitSidecarURLs handles extensionless basenames")
    func splitSidecarURLsNoExtension() {
        let base = tmpURL("recording-2026-04-26-18-30")
        let pair = SegmentNamer.splitSidecarURLs(baseURL: base)
        #expect(pair.system.lastPathComponent == "recording-2026-04-26-18-30.system")
        #expect(pair.mic.lastPathComponent == "recording-2026-04-26-18-30.mic")
    }
}
