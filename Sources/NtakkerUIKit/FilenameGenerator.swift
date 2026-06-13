// NtakkerUIKit/FilenameGenerator.swift — see project-design.md §15.6
// and plan-002-toolbar-ui.md §3 Phase D (FR-34, FR-35, FR-38).
//
// Pure helper: produces the default basename for a recording session
// and resolves filename collisions on disk. No I/O at construction
// time, no logging, no allocations on a hot path. Used exclusively by
// the UI layer (the CLI never auto-generates output names — see
// codebase scan §4.3 / investigation Topic 6).
//
// `defaultBasename` is **deterministic** for a given `now: Date`. The
// `DateFormatter` is locked to `en_US_POSIX` locale and the user's
// current time zone (per design §15.6 and investigation Topic 6
// "Gotchas") so:
//   * tests using a fixed `Date` get a predictable basename string;
//   * users on systems with non-Gregorian calendars get the expected
//     `yyyy-MM-dd-HH-mm` format (no Arabic-numeral / Buddhist-era
//     surprises).
//
// The basename **excludes** the file extension and any folder
// component. `RecordingController` joins `<folder>/<basename>.<ext>`
// when it builds the first-segment URL, and `SegmentNamer` inserts
// `partNN` infixes for multi-segment recordings.

import Foundation
import NtakkerCore

/// Filename helper for the default basename of a recording session and
/// for collision-avoidance on the resolved URL.
public struct FilenameGenerator: Sendable {

    // MARK: - Default basename

    /// `DateFormatter` locked to the project-design §15.6 contract:
    ///   * locale  = `en_US_POSIX` — deterministic numerals, Gregorian.
    ///   * timeZone = current local time zone — basenames reflect what
    ///     the user sees on the wall clock (FR-35 default).
    ///   * dateFormat = `yyyy-MM-dd-HH-mm` — zero-padded components,
    ///     suitable for sort-by-filename.
    ///
    /// Note: design §15.6 documents the format as `yyyy-MM-dd-HHmmss`
    /// (six-digit time) for the engine-locked format. The Phase D
    /// contract per plan-002 §3 specifies a five-digit form
    /// (`yyyy-MM-dd-HH-mm`) so the user-edited filename field stays
    /// short on the popover. The format here matches the Phase D
    /// contract verbatim — the design's `HHmmss` form is reserved for
    /// engine-internal output naming if/when the design is unified.
    public static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        return f
    }()

    /// Produce the default basename for a recording started at `now`.
    /// The returned string has neither a file extension nor a folder
    /// component — the UI layer joins those separately.
    ///
    /// Examples (`Locale: en_US_POSIX`, system time zone applied):
    ///   * 2026-04-26 18:30 local → `"recording-2026-04-26-18-30"`
    ///   * 2026-12-01 00:01 local → `"recording-2026-12-01-00-01"`
    ///
    /// - Parameter now: The instant from which to format the basename.
    ///   Defaults to `Date()`. Tests pass a fixed value for golden
    ///   comparisons.
    public static func `default`(now: Date = Date()) -> String {
        "recording-\(formatter.string(from: now))"
    }

    /// Convenience returning `"<basename>.<ext>"` for the supplied
    /// `OutputFormat`. The extension comes from the format's raw value
    /// (`"m4a"`, `"wav"`, `"caf"`).
    ///
    /// Used by `RecordingController` when computing the first-segment
    /// URL (`folder.appendingPathComponent(filename)`).
    public static func filename(now: Date = Date(), format: OutputFormat) -> String {
        "\(`default`(now: now)).\(format.rawValue)"
    }

    // MARK: - Unique URL (collision avoidance)

    /// Maximum number of `-N` suffixes attempted before bailing out. At
    /// 1000 collisions on a single timestamp basename, something is
    /// very wrong upstream and we surface it as `NtakkerError` rather
    /// than spinning forever. Per design §15.6 collision-avoidance
    /// algorithm.
    public static let maxCollisionRetries: Int = 1000

    /// Resolve a unique URL on disk by appending an integer suffix to
    /// the filename's stem when the proposed URL already exists. The
    /// suffix is inserted **before** the extension:
    ///
    ///     proposed:  /tmp/recording-2026-04-26-18-30.m4a (exists)
    ///     attempt:   /tmp/recording-2026-04-26-18-30-1.m4a
    ///     attempt:   /tmp/recording-2026-04-26-18-30-2.m4a
    ///
    /// If the proposed URL does not exist, it is returned unchanged.
    /// If `maxCollisionRetries` collisions are reached, a
    /// `NtakkerError.outputAlreadyExists` is thrown — there is no
    /// fallback behavior (per project rule "no fallback configuration
    /// values" — a saturated namespace is the user's problem to solve).
    ///
    /// - Parameter proposed: The URL to test. Must be a file URL.
    /// - Returns: A URL that does not currently exist on disk.
    /// - Throws: `NtakkerError.outputAlreadyExists(proposed)` if no
    ///   unique URL can be produced within `maxCollisionRetries` attempts.
    public static func unique(
        _ proposed: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        if !fileManager.fileExists(atPath: proposed.path) {
            return proposed
        }
        let folder = proposed.deletingLastPathComponent()
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        for n in 1...maxCollisionRetries {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem)-\(n)"
            } else {
                candidateName = "\(stem)-\(n).\(ext)"
            }
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw NtakkerError.outputAlreadyExists(proposed)
    }
}
