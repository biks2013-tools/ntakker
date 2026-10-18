// NtakkerStudioKit/Calendar/CalendarEvent.swift — 2026-10-18.
//
// A calendar item as the studio needs it to map recordings to meetings,
// decoded from the JSON a configured calendar command prints
// (`NTAKKER_CALENDAR_COMMAND`). Accepted documents:
//
//   { "events": [ {…}, … ], … }      — e.g. `m365mail calendar export`
//   [ {…}, … ]                       — a bare list
//
// Each event needs `subject`, `start` and `end` (ISO 8601 with an offset,
// e.g. `2026-10-02T13:00:00+03:00`; all-day events may give a bare day,
// `2026-06-02`). Optional: `id`, `allDay`,
// `location`, `organizer {name, address}`, `attendees [{name, address}]`,
// `myResponse`, `showAs`, `webLink`, `onlineMeeting.joinUrl`. Unknown
// fields are ignored, so other calendar tools can be used as long as they
// print this shape.

import Foundation

public struct CalendarPerson: Codable, Sendable, Hashable {
    public var name: String?
    public var address: String?

    public init(name: String? = nil, address: String? = nil) {
        self.name = name
        self.address = address
    }

    /// The name, else the address.
    public var display: String { (name?.isEmpty == false ? name : address) ?? "" }
}

public struct CalendarEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var subject: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    public var organizer: CalendarPerson?
    public var attendees: [CalendarPerson]
    /// e.g. accepted, tentativelyAccepted, organizer, declined, notResponded.
    public var myResponse: String?
    /// e.g. busy, tentative, free, oof.
    public var showAs: String?
    public var webLink: String?

    public init(
        id: String, subject: String, start: Date, end: Date, allDay: Bool = false,
        location: String? = nil, organizer: CalendarPerson? = nil, attendees: [CalendarPerson] = [],
        myResponse: String? = nil, showAs: String? = nil, webLink: String? = nil
    ) {
        self.id = id
        self.subject = subject
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.myResponse = myResponse
        self.showAs = showAs
        self.webLink = webLink
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Whether the event can be a meeting the user recorded: not all-day,
    /// not declined, and with a positive length.
    public var isCandidate: Bool {
        !allDay && duration > 0 && myResponse?.lowercased() != "declined"
    }
}

public enum CalendarDocumentError: Error, LocalizedError, Equatable {
    case notJSON(String)
    case noEventList
    case badEvent(index: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notJSON(let detail):
            return "The calendar command did not print JSON: \(detail)"
        case .noEventList:
            return "The calendar JSON has no event list: expected { \"events\": [ … ] } or [ … ]."
        case .badEvent(let index, let reason):
            return "Calendar event #\(index + 1) is unusable: \(reason)"
        }
    }
}

public enum CalendarDocument {
    /// Decode the events in `data`. Throws when the document is not JSON,
    /// has no event list, or an event lacks `subject` / `start` / `end`.
    public static func events(from data: Data) throws -> [CalendarEvent] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            let head = String(decoding: data.prefix(120), as: UTF8.self)
            throw CalendarDocumentError.notJSON(head.isEmpty ? "empty output" : head)
        }
        let list: [Any]
        if let array = root as? [Any] {
            list = array
        } else if let object = root as? [String: Any], let array = object["events"] as? [Any] {
            list = array
        } else {
            throw CalendarDocumentError.noEventList
        }
        return try list.enumerated().map { index, item in
            guard let e = item as? [String: Any] else {
                throw CalendarDocumentError.badEvent(index: index, reason: "not an object")
            }
            return try event(e, index: index)
        }
    }

    private static func event(_ e: [String: Any], index: Int) throws -> CalendarEvent {
        func string(_ k: String) -> String? {
            guard let v = e[k] as? String, !v.isEmpty else { return nil }
            return v
        }
        func date(_ k: String) throws -> Date {
            guard let s = string(k) else { throw CalendarDocumentError.badEvent(index: index, reason: "no \"\(k)\"") }
            guard let d = parseDate(s) else {
                throw CalendarDocumentError.badEvent(index: index, reason: "\"\(k)\" is not an ISO 8601 date (with an offset) or a day: \(s)")
            }
            return d
        }
        func person(_ v: Any?) -> CalendarPerson? {
            guard let p = v as? [String: Any] else { return nil }
            let person = CalendarPerson(name: p["name"] as? String, address: p["address"] as? String)
            return person.display.isEmpty ? nil : person
        }
        guard let subject = string("subject") else {
            throw CalendarDocumentError.badEvent(index: index, reason: "no \"subject\"")
        }
        let start = try date("start"), end = try date("end")
        let online = (e["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String
        return CalendarEvent(
            id: string("id") ?? string("iCalUId") ?? "\(subject)@\(Int(start.timeIntervalSince1970))",
            subject: subject,
            start: start,
            end: end,
            allDay: e["allDay"] as? Bool ?? false,
            location: string("location"),
            organizer: person(e["organizer"]),
            attendees: (e["attendees"] as? [Any] ?? []).compactMap(person),
            myResponse: string("myResponse"),
            showAs: string("showAs"),
            webLink: string("webLink") ?? online
        )
    }

    /// ISO 8601 with an offset, with or without fractional seconds; or a
    /// bare day (`2026-06-02`, as all-day events give it), read as the
    /// start of that day in the local time zone.
    static func parseDate(_ s: String) -> Date? {
        if let d = plain.date(from: s) { return d }
        if let d = fractional.date(from: s) { return d }
        return dayOnly.date(from: s)
    }

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
