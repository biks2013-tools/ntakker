// NtakkerStudioKit/Calendar/MeetingLookup.swift — 2026-10-18.
//
// Map many recordings to meetings with as few calendar-command runs as
// possible: the days the recordings span are grouped into ranges of at
// most `maxRangeDays` days (a new range starts at the first recording day
// past the limit, so long stretches without recordings are not fetched),
// the command runs once per range, and every recording is matched against
// all the events fetched.

import Foundation

public struct RecordingMeeting: Sendable {
    public let recording: Recording
    public let start: Date
    public let duration: TimeInterval
    public let result: MeetingMatchResult

    public var end: Date { start.addingTimeInterval(duration) }
}

public enum MeetingLookup {
    /// Longest range of days asked of the calendar command in one run.
    public static let maxRangeDays = 31

    /// Match `recordings` against the calendar `command` prints.
    public static func match(
        _ recordings: [Recording],
        command: CalendarCommand,
        calendar: Calendar = .current
    ) async throws -> [RecordingMeeting] {
        let timed = recordings.map { r in
            (recording: r, start: RecordingTiming.start(of: r), duration: RecordingTiming.duration(of: r))
        }
        var events: [String: CalendarEvent] = [:]
        for range in dayRanges(timed.map { ($0.start, $0.start.addingTimeInterval($0.duration)) }, calendar: calendar) {
            for e in try await command.events(from: range.from, to: range.to, calendar: calendar) {
                events[e.id] = e
            }
        }
        let all = Array(events.values)
        return timed.map {
            RecordingMeeting(
                recording: $0.recording, start: $0.start, duration: $0.duration,
                result: MeetingMatcher.match(
                    recordingStart: $0.start, duration: $0.duration,
                    name: $0.recording.displayName + " " + $0.recording.stem, events: all
                )
            )
        }
    }

    /// The days covered by `spans`, grouped into ranges of at most
    /// `maxRangeDays` days (first and last day included).
    static func dayRanges(_ spans: [(Date, Date)], calendar: Calendar) -> [(from: Date, to: Date)] {
        var days = Set<Date>()
        for (start, end) in spans {
            var d = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: max(start, end))
            while d <= last {
                days.insert(d)
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }
        var ranges: [(from: Date, to: Date)] = []
        for day in days.sorted() {
            if let current = ranges.last,
               let limit = calendar.date(byAdding: .day, value: maxRangeDays - 1, to: current.from),
               day <= limit {
                ranges[ranges.count - 1].to = day
            } else {
                ranges.append((day, day))
            }
        }
        return ranges
    }
}
