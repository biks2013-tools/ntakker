import Foundation
import Testing
@testable import NtakkerStudioKit

/// Calendar JSON, the calendar command and recording → meeting matching
/// (2026-10-18).
@Suite("Calendar matching")
struct CalendarMatchTests {

    private static let athens = TimeZone(identifier: "Europe/Athens")!

    private func t(_ s: String) -> Date { CalendarDocument.parseDate(s)! }

    private func event(_ subject: String, _ start: String, _ end: String,
                       response: String = "accepted", allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: subject, subject: subject, start: t(start), end: t(end), allDay: allDay, myResponse: response)
    }

    // MARK: - JSON

    @Test("reads m365mail's export document and a bare list")
    func readsDocuments() throws {
        let export = """
        {"calendar":"Calendar","count":2,"events":[
          {"id":"a","subject":"NBG | FIREBLOCKS","start":"2026-10-02T15:30:00+03:00","end":"2026-10-02T16:15:00+03:00",
           "allDay":false,"myResponse":"accepted","organizer":{"name":"Anna","address":"anna@x.com"},
           "attendees":[{"name":"Bob","address":"bob@x.com","response":"accepted","type":"required"}],
           "onlineMeeting":{"joinUrl":"https://teams/x","provider":"teamsForBusiness"}},
          {"id":"b","subject":"Holiday","start":"2026-06-02","end":"2026-06-03","allDay":true}
        ]}
        """
        let events = try CalendarDocument.events(from: Data(export.utf8))
        #expect(events.count == 2)
        #expect(events[0].subject == "NBG | FIREBLOCKS")
        #expect(events[0].duration == 45 * 60)
        #expect(events[0].organizer?.display == "Anna")
        #expect(events[0].attendees.map(\.display) == ["Bob"])
        #expect(events[0].webLink == "https://teams/x")
        #expect(events[1].allDay && !events[1].isCandidate)

        let bare = #"[{"subject":"S","start":"2026-10-02T13:00:00.000Z","end":"2026-10-02T14:00:00Z"}]"#
        let one = try CalendarDocument.events(from: Data(bare.utf8))
        #expect(one.count == 1 && one[0].duration == 3600)
    }

    @Test("bad documents say what is wrong")
    func badDocuments() {
        #expect(throws: CalendarDocumentError.self) { try CalendarDocument.events(from: Data("not json".utf8)) }
        #expect(throws: CalendarDocumentError.noEventList) { try CalendarDocument.events(from: Data(#"{"items":[]}"#.utf8)) }
        #expect(throws: CalendarDocumentError.self) {
            try CalendarDocument.events(from: Data(#"[{"subject":"S","start":"tomorrow","end":"2026-10-02T14:00:00Z"}]"#.utf8))
        }
        #expect(throws: CalendarDocumentError.self) {
            try CalendarDocument.events(from: Data(#"[{"start":"2026-10-02T13:00:00Z","end":"2026-10-02T14:00:00Z"}]"#.utf8))
        }
    }

    // MARK: - Matching

    @Test("a recording inside a long block goes to the meeting that fits it (real case, 2 Oct)")
    func fitBeatsRawOverlap() {
        let events = [
            event("WE BUILD - FS Group call #7", "2026-10-02T15:00:00+03:00", "2026-10-02T16:30:00+03:00"),
            event("Partner sync", "2026-10-02T15:30:00+03:00", "2026-10-02T16:15:00+03:00"),
        ]
        // 15:44–16:29, without a name hint.
        let r = MeetingMatcher.match(recordingStart: t("2026-10-02T15:44:00+03:00"), duration: 45 * 60, events: events)
        #expect(r.best?.event.subject == "Partner sync")
        #expect(r.matches.count == 2)
    }

    @Test("a word of the recording's name in the subject decides")
    func nameHint() {
        let events = [
            event("WE BUILD - FS Group call #7", "2026-10-02T15:00:00+03:00", "2026-10-02T16:30:00+03:00"),
            event("NBG | FIREBLOCKS", "2026-10-02T15:30:00+03:00", "2026-10-02T16:15:00+03:00"),
        ]
        let r = MeetingMatcher.match(recordingStart: t("2026-10-02T15:44:00+03:00"), duration: 45 * 60,
                                     name: "fireblocks-recording-2026-10-02-16-29", events: events)
        #expect(r.best?.event.subject == "NBG | FIREBLOCKS")
        #expect(r.best?.nameMatches == true)
        #expect(r.confidence == .strong)
        #expect(MeetingMatcher.nameWords("fireblocks-recording-2026-10-02-16-29") == ["fireblocks"])
        #expect(MeetingMatcher.subjectMatches("V/C | Strategic AI - Catch-up", words: ["strategy"]))
        #expect(MeetingMatcher.subjectMatches("V/C | CX Hubs & CMT", words: ["cmt"]))
    }

    @Test("a recording left running over back-to-back meetings lists them; a clash counts once")
    func severalMeetings() {
        let events = [
            event("Catch-up", "2026-10-02T13:00:00+03:00", "2026-10-02T13:45:00+03:00"),
            event("Clash at the same time", "2026-10-02T13:00:00+03:00", "2026-10-02T13:30:00+03:00", response: "notResponded"),
            event("Scope 2027", "2026-10-02T14:00:00+03:00", "2026-10-02T14:30:00+03:00"),
            event("Programme", "2026-10-02T14:30:00+03:00", "2026-10-02T15:15:00+03:00"),
        ]
        let r = MeetingMatcher.match(recordingStart: t("2026-10-02T13:02:00+03:00"), duration: 161 * 60, events: events)
        #expect(r.spansSeveralMeetings)
        #expect(r.covered.map(\.event.subject) == ["Catch-up", "Scope 2027", "Programme"])
    }

    @Test("declined and all-day events are never matches; nothing overlapping means no match")
    func candidates() {
        let events = [
            event("Declined", "2026-10-02T10:00:00+03:00", "2026-10-02T11:00:00+03:00", response: "declined"),
            event("Out of office", "2026-10-02T00:00:00+03:00", "2026-10-03T00:00:00+03:00", allDay: true),
            event("Later", "2026-10-02T12:00:00+03:00", "2026-10-02T13:00:00+03:00"),
        ]
        let r = MeetingMatcher.match(recordingStart: t("2026-10-02T10:05:00+03:00"), duration: 50 * 60, events: events)
        #expect(r.matches.isEmpty && r.confidence == nil)
    }

    @Test("a few seconds that touch a meeting are weak")
    func weak() {
        let events = [event("Long meeting", "2026-10-02T10:00:00+03:00", "2026-10-02T11:00:00+03:00")]
        let r = MeetingMatcher.match(recordingStart: t("2026-10-02T10:30:00+03:00"), duration: 12, events: events)
        #expect(r.confidence == .weak)
    }

    @Test("a linked meeting is saved in studio.json and read back; older files without one still load")
    func linkedMeetingRoundTrip() throws {
        let url = StudioFixtures.tempDir("meta").appendingPathComponent("r.studio.json")
        var e = event("NBG | FIREBLOCKS", "2026-10-02T15:30:00+03:00", "2026-10-02T16:15:00+03:00")
        e.organizer = CalendarPerson(name: "Anna", address: "anna@x.com")
        e.attendees = [CalendarPerson(name: nil, address: "bob@x.com")]
        let meta = StudioMetadata(speakerNames: ["1": "Anna"], meeting: LinkedMeeting(e))
        try meta.save(to: url)
        let back = try StudioMetadata.load(from: url)
        #expect(back == meta)
        #expect(back.meeting?.organizer == "Anna" && back.meeting?.attendees == ["bob@x.com"])

        try Data(#"{"version":1,"speakerNames":{},"syncOffsetSec":0,"exactTimingTranscripts":[]}"#.utf8).write(to: url)
        #expect(try StudioMetadata.load(from: url).meeting == nil)
    }

    // MARK: - Command

    @Test("the template needs {from} and {to}; days are substituted")
    func template() throws {
        #expect(throws: CalendarCommandError.notConfigured) { try CalendarCommand(template: "  ") }
        #expect(throws: CalendarCommandError.missingPlaceholders) { try CalendarCommand(template: "cal --from {from}") }
        #expect(throws: CalendarCommandError.notConfigured) { try CalendarCommand.configured(in: [:]) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.athens
        let c = try CalendarCommand(template: "cal export --from {from} --to {to}")
        let line = c.commandLine(from: t("2026-10-01T00:30:00+03:00"), to: t("2026-10-17T23:00:00+03:00"), calendar: cal)
        #expect(line == "cal export --from 2026-10-01 --to 2026-10-17")
    }

    @Test("runs the command and reads its JSON; a failing command reports its error")
    func runs() async throws {
        let ok = try CalendarCommand(template: #"printf '%s' '[{"subject":"{from}..{to}","start":"2026-10-02T13:00:00Z","end":"2026-10-02T14:00:00Z"}]'"#)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.athens
        let events = try await ok.events(from: t("2026-10-02T12:00:00+03:00"), to: t("2026-10-03T12:00:00+03:00"), calendar: cal)
        #expect(events.map(\.subject) == ["2026-10-02..2026-10-03"])

        let bad = try CalendarCommand(template: "echo 'Not signed in' >&2; exit 3 # {from} {to}")
        await #expect(throws: CalendarCommandError.failed(status: 3, stderr: "Not signed in\n")) {
            _ = try await bad.events(from: Date(), to: Date())
        }
    }

    @Test("days are fetched in ranges of at most 31 days, skipping long gaps")
    func ranges() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.athens
        let spans = [
            (t("2026-05-14T16:00:00+03:00"), t("2026-05-14T17:00:00+03:00")),
            (t("2026-05-20T23:50:00+03:00"), t("2026-05-21T00:20:00+03:00")),   // over midnight
            (t("2026-06-20T10:00:00+03:00"), t("2026-06-20T11:00:00+03:00")),
            (t("2026-10-01T10:00:00+03:00"), t("2026-10-01T11:00:00+03:00")),
        ]
        let r = MeetingLookup.dayRanges(spans, calendar: cal)
        func day(_ d: Date) -> String { CalendarCommand.day(d, cal) }
        #expect(r.map { "\(day($0.from))…\(day($0.to))" } == [
            "2026-05-14…2026-05-21", "2026-06-20…2026-06-20", "2026-10-01…2026-10-01",
        ])
    }
}
