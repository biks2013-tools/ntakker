// NtakkerStudioKit/Calendar/MeetingMatcher.swift — 2026-10-18.
//
// Which calendar meeting a recording is. A recording covers
// [start, start + duration]; every candidate event (not all-day, not
// declined) that overlaps it is a match.
//
// Ranking. Raw overlap favours long meetings (a 45-minute recording
// inside a 90-minute block "overlaps" it fully), so matches are ranked by
// how well the two spans fit each other — overlap ÷ the span they cover
// together (1 = same start and end) — plus a bonus when a word of the
// recording's name appears in the meeting's subject (users name
// recordings after the meeting: "fireblocks-recording-…"). Ties go to
// meetings the user accepted or organised, then to the closest start.
//
// Several meetings. A recording left running across back-to-back
// meetings mostly records more than one of them; those (≥ 80 % of the
// meeting recorded, clashing meetings counted once) are listed in time
// order in `covered`, and the result says so instead of pretending one
// meeting is the answer.
//
// Confidence of the best match:
//   strong — fit ≥ 0.5 (or the name matches and fit ≥ 0.25), and no other
//            match scores nearly as well;
//   likely — fit ≥ 0.2, or the name matches;
//   weak   — it only touches the recording.

import AVFoundation
import Foundation

public struct MeetingMatch: Sendable, Hashable {
    public enum Confidence: String, Sendable, Codable { case strong, likely, weak }

    public let event: CalendarEvent
    /// Seconds the meeting and the recording overlap.
    public let overlap: TimeInterval
    /// Share of the recording inside the meeting (0…1).
    public let recordingCoverage: Double
    /// Share of the meeting that was recorded (0…1).
    public let meetingCoverage: Double
    /// Overlap ÷ the span both cover together (0…1).
    public let fit: Double
    /// Whether a word of the recording's name is in the subject.
    public let nameMatches: Bool
    /// Recording start minus meeting start, in seconds (negative = the
    /// recording started first).
    public let startOffset: TimeInterval

    /// The ranking score.
    public var score: Double { fit + (nameMatches ? MeetingMatcher.nameBonus : 0) }
}

public struct MeetingMatchResult: Sendable {
    /// Every overlapping meeting, best first.
    public let matches: [MeetingMatch]
    /// Meetings the recording mostly covers, in time order.
    public let covered: [MeetingMatch]
    public let confidence: MeetingMatch.Confidence?

    public var best: MeetingMatch? { matches.first }
    /// The recording spans two or more meetings.
    public var spansSeveralMeetings: Bool { covered.count >= 2 }
}

public enum MeetingMatcher {
    static let nameBonus = 0.5
    /// A meeting counts as recorded when this share of it was.
    static let coveredShare = 0.8

    /// - Parameter name: the recording's name (stem or display name);
    ///   its words are looked for in the subjects.
    public static func match(
        recordingStart: Date, duration: TimeInterval, name: String? = nil, events: [CalendarEvent]
    ) -> MeetingMatchResult {
        let recEnd = recordingStart.addingTimeInterval(max(duration, 0))
        let words = name.map(nameWords) ?? []
        let matches = events.filter(\.isCandidate).compactMap { e -> MeetingMatch? in
            let overlap = min(recEnd, e.end).timeIntervalSince(max(recordingStart, e.start))
            guard overlap > 0 else { return nil }
            let union = max(recEnd, e.end).timeIntervalSince(min(recordingStart, e.start))
            return MeetingMatch(
                event: e,
                overlap: overlap,
                recordingCoverage: duration > 0 ? min(1, overlap / duration) : 0,
                meetingCoverage: min(1, overlap / e.duration),
                fit: union > 0 ? overlap / union : 0,
                nameMatches: subjectMatches(e.subject, words: words),
                startOffset: recordingStart.timeIntervalSince(e.start)
            )
        }
        .sorted { a, b in
            if abs(a.score - b.score) > 0.02 { return a.score > b.score }
            if rank(a.event) != rank(b.event) { return rank(a.event) < rank(b.event) }
            return abs(a.startOffset) < abs(b.startOffset)
        }
        return MeetingMatchResult(matches: matches, covered: covered(matches), confidence: confidence(matches))
    }

    /// The meetings mostly recorded, in time order. Meetings held at the
    /// same time (a clash in the calendar) count once: best first, a
    /// meeting is skipped when it overlaps one already kept by more than
    /// half of the shorter of the two.
    static func covered(_ matches: [MeetingMatch]) -> [MeetingMatch] {
        var kept: [MeetingMatch] = []
        for m in matches where m.meetingCoverage >= coveredShare {
            let clashes = kept.contains { k in
                let overlap = min(k.event.end, m.event.end).timeIntervalSince(max(k.event.start, m.event.start))
                return overlap > 0.5 * min(k.event.duration, m.event.duration)
            }
            if !clashes { kept.append(m) }
        }
        return kept.sorted { $0.event.start < $1.event.start }
    }

    /// Lower is preferred: what the user committed to first.
    static func rank(_ e: CalendarEvent) -> Int {
        switch e.myResponse?.lowercased() {
        case "organizer", "accepted": return 0
        case "tentativelyaccepted": return 1
        default: return 2
        }
    }

    static func confidence(_ matches: [MeetingMatch]) -> MeetingMatch.Confidence? {
        guard let best = matches.first else { return nil }
        let rival = matches.dropFirst().first.map { $0.score >= best.score * 0.8 } ?? false
        if !rival && (best.fit >= 0.5 || (best.nameMatches && best.fit >= 0.25)) { return .strong }
        if best.fit >= 0.2 || best.nameMatches { return .likely }
        return .weak
    }

    // MARK: - Name words

    /// Words that do not identify a meeting.
    static let ignoredWords: Set<String> = [
        "recording", "record", "meeting", "call", "part", "copy", "clean", "studio", "with", "and", "the",
        "nbg", "bank", "prep", "test", "video",
    ]

    /// The distinctive words of a recording name: letters only, at least
    /// three of them (short ones are acronyms: cmt, gtf), lowercased,
    /// without generic words and dates.
    static func nameWords(_ name: String) -> [String] {
        name.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= 3 && !ignoredWords.contains($0) }
    }

    /// Whether any word of the subject shares a stem with one of `words`
    /// (equal, or the same first five letters: "strategy" ~ "strategic").
    static func subjectMatches(_ subject: String, words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let subjectWords = subject.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        return words.contains { w in
            subjectWords.contains { s in
                s == w || (w.count >= 5 && s.count >= 5 && s.prefix(5) == w.prefix(5))
            }
        }
    }
}

/// When a recording started and how long it is.
public enum RecordingTiming {
    /// The start: the studio's `audioStart` when set, else the audio
    /// file's creation date.
    public static func start(of recording: Recording) -> Date {
        let meta = try? StudioMetadata.load(from: recording.metadataURL)
        return meta?.audioStart ?? recording.createdAt
    }

    /// The longest audio track's length in seconds (0 when none can be
    /// read).
    public static func duration(of recording: Recording) -> TimeInterval {
        recording.tracks.compactMap { track -> TimeInterval? in
            guard let f = try? AVAudioFile(forReading: track.url) else { return nil }
            let rate = f.processingFormat.sampleRate
            return rate > 0 ? Double(f.length) / rate : nil
        }.max() ?? 0
    }
}
