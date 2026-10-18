// NtakkerStudioKit/Transcript/StudioMetadata.swift — plan-024 T3.
//
// `<stem>.studio.json`: what the studio knows about a recording beyond
// ntakker's own files. Written only when the user changes something
// (or by the studio's own exports), so browsing never adds files.

import Foundation

public struct StudioMetadata: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// When the audio's first sample was recorded. `nil` means "use the
    /// audio file's creation date".
    public var audioStart: Date?
    /// Display names keyed by the raw speaker id in the transcript
    /// (e.g. Soniox `"1"` or `"spk:1"`).
    public var speakerNames: [String: String]
    /// Seconds added to every live-transcript offset to line it up with
    /// the audio. Positive moves lines later.
    public var syncOffsetSec: Double
    /// Transcript filenames whose timestamps are exact audio positions
    /// (written by the studio), so no live-timing correction applies.
    public var exactTimingTranscripts: [String]
    /// The echo filter's delay set by hand (ms), instead of the measured
    /// one. `nil` = measured automatically.
    public var echoDelayMs: Double?
    /// The calendar meeting the user linked this recording to.
    public var meeting: LinkedMeeting?

    public init(
        audioStart: Date? = nil,
        speakerNames: [String: String] = [:],
        syncOffsetSec: Double = 0,
        exactTimingTranscripts: [String] = [],
        echoDelayMs: Double? = nil,
        meeting: LinkedMeeting? = nil
    ) {
        self.version = Self.currentVersion
        self.audioStart = audioStart
        self.speakerNames = speakerNames
        self.syncOffsetSec = syncOffsetSec
        self.exactTimingTranscripts = exactTimingTranscripts
        self.echoDelayMs = echoDelayMs
        self.meeting = meeting
    }

    private enum CodingKeys: String, CodingKey {
        case version, audioStart, speakerNames, syncOffsetSec, exactTimingTranscripts, echoDelayMs, meeting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        audioStart = try c.decodeIfPresent(Date.self, forKey: .audioStart)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        syncOffsetSec = try c.decodeIfPresent(Double.self, forKey: .syncOffsetSec) ?? 0
        exactTimingTranscripts = try c.decodeIfPresent([String].self, forKey: .exactTimingTranscripts) ?? []
        echoDelayMs = try c.decodeIfPresent(Double.self, forKey: .echoDelayMs)
        meeting = try c.decodeIfPresent(LinkedMeeting.self, forKey: .meeting)
    }

    /// Display name for a raw speaker id: the user's name, else `S1`-style.
    public func speakerName(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let name = speakerNames[raw], !name.isEmpty { return name }
        if raw.hasPrefix("spk:") { return "Speaker " + raw.dropFirst(4) }
        return "Speaker \(raw)"
    }

    // MARK: - Persistence

    /// Read `url`. A missing file is an empty metadata; a corrupt one
    /// throws, so the user's names are never silently replaced.
    public static func load(from url: URL) throws -> StudioMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else { return StudioMetadata() }
        let data = try Data(contentsOf: url)
        return try decoder.decode(StudioMetadata.self, from: data)
    }

    public func save(to url: URL) throws {
        let data = try Self.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = isoFormatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(s)")
            }
            return date
        }
        return d
    }()

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// A calendar meeting saved with a recording (`studio.json` → `meeting`).
public struct LinkedMeeting: Codable, Sendable, Equatable {
    public var id: String
    public var subject: String
    public var start: Date
    public var end: Date
    public var organizer: String?
    public var attendees: [String]
    public var location: String?
    public var webLink: String?

    public init(id: String, subject: String, start: Date, end: Date, organizer: String? = nil,
                attendees: [String] = [], location: String? = nil, webLink: String? = nil) {
        self.id = id
        self.subject = subject
        self.start = start
        self.end = end
        self.organizer = organizer
        self.attendees = attendees
        self.location = location
        self.webLink = webLink
    }

    public init(_ e: CalendarEvent) {
        self.init(id: e.id, subject: e.subject, start: e.start, end: e.end, organizer: e.organizer?.display,
                  attendees: e.attendees.map(\.display), location: e.location, webLink: e.webLink)
    }
}
