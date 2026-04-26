// MacrecUIKit/SegmentNamer.swift — see project-design.md §15.6 and
// plan-002-toolbar-ui.md §3 Phase D (FR-34).
//
// Pure value-type helper that derives the segment URLs for stop-and-
// stitch pause/resume and manual split. There are two shapes the
// coordinator cares about:
//
//   1. The first segment of a session is always **unsuffixed**:
//
//          recording-2026-04-26-18-30.m4a                       (mixed)
//          recording-2026-04-26-18-30.system.m4a                (split)
//          recording-2026-04-26-18-30.mic.m4a                   (split)
//
//      `RecordingController` computes this URL via
//      `SegmentNamer.next(after: original, segment: 1)` which returns
//      the original URL unchanged.
//
//   2. Segments 2..N have a `.partNN` infix inserted **before** the
//      extension (and, for `--layout split` recordings, before the
//      `.system`/`.mic` token so sort-by-filename groups all parts of
//      the same segment together — FR-34 verbatim):
//
//          recording-2026-04-26-18-30.part02.m4a
//          recording-2026-04-26-18-30.part02.system.m4a
//          recording-2026-04-26-18-30.part02.mic.m4a
//
//      `NN` is zero-padded to two digits. Segments numbered 100+ would
//      use three digits, but in practice no recording produces that
//      many segments — see `SegmentNamerTests` for the off-by-one
//      coverage at the 99 → 100 boundary.
//
// This file is **pure** — no I/O, no logging. Tests can call every
// method directly.
//
// FR-34 multi-file rename note (design §15.5): when `totalSegments`
// transitions from 1 to 2 (first pause OR first split), the already-
// finalized segment-1 file must be renamed from `<basename>.<ext>` to
// `<basename>.part01.<ext>`. The rename itself is performed by
// `SessionCoordinator`; this helper exposes the URL form required for
// that rename via `next(after:segment:)` with `segment: 1` (which is
// the no-infix shape). Two-arg overload `partURL(originalURL:segment:)`
// covers the `segment >= 2` case directly.

import Foundation

/// Pure URL-derivation helper for multi-segment recordings. Stateless
/// — no instances are ever constructed.
public enum SegmentNamer {

    /// Compute the URL of segment `segment` given the URL of the
    /// session's first segment. The first segment URL is the one
    /// `RecordingOptions.output` was originally set to.
    ///
    /// - Parameters:
    ///   - current: The first-segment URL (e.g.
    ///     `/Recordings/recording-2026-04-26-18-30.m4a`). For split-
    ///     layout recordings, this is the URL of either the `.mic` or
    ///     the `.system` file — the `partNN` infix is inserted in the
    ///     same position regardless.
    ///   - segment: 1-based segment number. `1` returns `current`
    ///     unchanged (the first segment never carries a `partNN`
    ///     infix, per FR-34). `2`+ inserts the zero-padded
    ///     `part02..partNN` infix before the extension.
    /// - Returns: The URL for the requested segment.
    /// - Precondition: `segment >= 1`.
    public static func next(after current: URL, segment: Int) -> URL {
        precondition(segment >= 1, "segment number must be 1-based positive integer")
        if segment == 1 {
            return current
        }
        return partURL(originalURL: current, segment: segment)
    }

    /// Insert a `.partNN` infix into `originalURL`'s filename, where
    /// `NN` is `segment` zero-padded to two digits.
    ///
    /// This handles the `--layout split` case correctly: if the
    /// original filename has a `.system` or `.mic` token immediately
    /// before the extension, the `partNN` infix is inserted **before**
    /// that token, so the two halves of the same segment sort
    /// adjacently:
    ///
    ///     recording-2026-04-26-18-30.system.m4a
    ///       → recording-2026-04-26-18-30.part02.system.m4a
    ///
    /// - Parameters:
    ///   - originalURL: A URL whose last path component is
    ///     `<stem>[.layoutToken].<ext>`. `layoutToken` is `.system`,
    ///     `.mic`, or absent (mixed/stereo-split recordings produce
    ///     a single file with no layout token).
    ///   - segment: 1-based segment number (`>= 2` recommended; this
    ///     method does not special-case `1`, so `partURL(..., segment: 1)`
    ///     yields `recording-2026-04-26-18-30.part01.m4a` — useful for
    ///     the FR-34 first-segment rename in `SessionCoordinator`).
    /// - Returns: The URL with the `partNN` infix inserted.
    /// - Precondition: `segment >= 1`.
    public static func partURL(originalURL: URL, segment: Int) -> URL {
        precondition(segment >= 1, "segment number must be 1-based positive integer")
        let folder = originalURL.deletingLastPathComponent()
        let ext = originalURL.pathExtension
        // Strip the extension to inspect the layout token.
        let withoutExt = originalURL.deletingPathExtension().lastPathComponent
        let infix = String(format: "part%02d", segment)

        // Detect a trailing `.system` / `.mic` layout token. Per FR-34,
        // the partNN infix goes BEFORE that token. We only recognize the
        // exact tokens emitted by the engine's recorder factory for
        // `--layout split` recordings — any other final dotted segment
        // is assumed to be part of the user-chosen basename.
        let layoutTokens: Set<String> = ["system", "mic"]
        if let dotRange = withoutExt.range(of: ".", options: .backwards) {
            let tail = String(withoutExt[dotRange.upperBound...])
            if layoutTokens.contains(tail) {
                let head = String(withoutExt[..<dotRange.lowerBound])
                let newName = ext.isEmpty
                    ? "\(head).\(infix).\(tail)"
                    : "\(head).\(infix).\(tail).\(ext)"
                return folder.appendingPathComponent(newName)
            }
        }

        // No layout token — the infix goes between the stem and the
        // extension.
        let newName = ext.isEmpty
            ? "\(withoutExt).\(infix)"
            : "\(withoutExt).\(infix).\(ext)"
        return folder.appendingPathComponent(newName)
    }

    /// Convenience wrapper for the FR-34 first-segment rename. Returns
    /// the URL the just-finalized segment-1 file should be renamed to
    /// when a recording transitions from a single segment into a
    /// multi-segment recording (i.e. on the very first `pause()` or
    /// `split()` call). Equivalent to `partURL(originalURL:, segment: 1)`
    /// but expresses intent at the call site.
    ///
    /// - Parameter url: The bare-named segment-1 URL (e.g.
    ///   `recording.m4a`, `recording.system.m4a`, `recording.mic.m4a`).
    /// - Returns: The corresponding `.part01.` URL (e.g.
    ///   `recording.part01.m4a`, `recording.part01.system.m4a`,
    ///   `recording.part01.mic.m4a`). For split-layout filenames the
    ///   `.part01` infix is inserted BEFORE the `.system` / `.mic` token
    ///   so segment 1 and segment 2 sort adjacently.
    public static func renameForFirstSegment(_ url: URL) -> URL {
        return partURL(originalURL: url, segment: 1)
    }

    /// Derive the per-side sibling URLs the `.split` layout writes for a
    /// given base output URL. The engine factory (see
    /// `M4ARecorder.sidecarURL(base:side:)`) inserts `.system` and
    /// `.mic` between the stem and the extension; this helper mirrors
    /// that convention so the coordinator can locate both files for the
    /// FR-34 first-segment rename.
    ///
    /// - Parameter baseURL: The bare-named segment-1 URL the engine was
    ///   handed via `RecordingOptions.output` (e.g. `recording.m4a`).
    /// - Returns: A tuple of `(systemURL, micURL)` pointing at
    ///   `recording.system.m4a` and `recording.mic.m4a` respectively.
    public static func splitSidecarURLs(baseURL: URL) -> (system: URL, mic: URL) {
        let folder = baseURL.deletingLastPathComponent()
        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let systemName = ext.isEmpty ? "\(stem).system" : "\(stem).system.\(ext)"
        let micName = ext.isEmpty ? "\(stem).mic" : "\(stem).mic.\(ext)"
        return (
            system: folder.appendingPathComponent(systemName),
            mic: folder.appendingPathComponent(micName)
        )
    }
}
