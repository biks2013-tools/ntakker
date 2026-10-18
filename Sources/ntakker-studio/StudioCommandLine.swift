// ntakker-studio/StudioCommandLine.swift — 2026-10-18.
//
// The studio's entry point. With no arguments it opens the app; with a
// command it runs that command in the terminal and exits:
//
//   ntakker-studio match-meetings [--from YYYY-MM-DD] [--to YYYY-MM-DD]
//                                 [--name <text>] [--library <folder>]
//
// `match-meetings` runs the calendar command (NTAKKER_CALENDAR_COMMAND in
// ~/.tool-agents/ntakker/.env) and prints, as JSON, the meeting each
// recording of the library most likely is. Options narrow the recordings:
// by start day (both included), by a case-insensitive part of the name,
// and the library folder (default: NTAKKER_RECORDINGS_DIR).
//
// Exit codes: 0 success, 64 usage, 78 missing configuration, 1 failure.

import AppKit
import Foundation
import NtakkerCore
import NtakkerStudioKit

@main
enum StudioMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // Finder and `open` may pass -psn_… / -NSDocumentRevisionsDebugMode;
        // only a bare first word is a command.
        guard let first = args.first, !first.hasPrefix("-") else {
            NtakkerStudioApp.main()
            return
        }
        let code: Int32
        switch first {
        case "match-meetings":
            code = runBlocking { await MatchMeetingsCommand.run(Array(args.dropFirst())) }
        case "help", "--help", "-h":
            print(StudioCommandLine.usage)
            code = 0
        default:
            StudioCommandLine.fail("unknown command \(first)\n\n\(StudioCommandLine.usage)")
            code = 64
        }
        exit(code)
    }

    private static func runBlocking(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value
    }
}

private final class ResultBox: @unchecked Sendable { var value: Int32 = 1 }

enum StudioCommandLine {
    static let usage = """
    usage: ntakker-studio [command]

      (no command)        open the app
      match-meetings      print, as JSON, the meeting each recording most likely is
          --from DAY        only recordings that started on or after DAY (YYYY-MM-DD)
          --to DAY          only recordings that started on or before DAY
          --name TEXT       only recordings whose name contains TEXT (any case)
          --library DIR     the library folder (default: NTAKKER_RECORDINGS_DIR)

    The calendar comes from NTAKKER_CALENDAR_COMMAND in ~/.tool-agents/ntakker/.env:
    a command line printing calendar JSON, with {from} and {to} replaced by days, e.g.
      /full/path/m365mail calendar export --from {from} --to {to} --no-description
    """

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("ntakker-studio: \(message)\n".utf8))
    }
}

enum MatchMeetingsCommand {
    struct Options {
        var from: Date?
        var to: Date?
        var name: String?
        var library: URL?
    }

    static func run(_ args: [String]) async -> Int32 {
        let options: Options
        do { options = try parse(args) } catch {
            StudioCommandLine.fail("\(error.localizedDescription)\n\n\(StudioCommandLine.usage)")
            return 64
        }
        do {
            _ = try EnvFileStore.loadIntoProcess(toolName: SharedSettings.toolName)
        } catch {
            StudioCommandLine.fail("could not read \(SharedSettings.fileURL.path): \(error.localizedDescription)")
            return 78
        }
        let env = ProcessInfo.processInfo.environment
        let command: CalendarCommand
        do { command = try CalendarCommand.configured(in: env) } catch {
            StudioCommandLine.fail(error.localizedDescription)
            return 78
        }
        guard let root = options.library ?? env[SharedSettings.Keys.recordingsDir].map({
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }) else {
            StudioCommandLine.fail("no library folder: set \(SharedSettings.Keys.recordingsDir) in \(SharedSettings.fileURL.path) or pass --library")
            return 78
        }

        let calendar = Calendar.current
        let recordings = RecordingLibraryScanner.scan(root: root).filter { r in
            let day = calendar.startOfDay(for: RecordingTiming.start(of: r))
            if let from = options.from, day < from { return false }
            if let to = options.to, day > to { return false }
            if let name = options.name, !r.displayName.localizedCaseInsensitiveContains(name),
               !r.stem.localizedCaseInsensitiveContains(name) { return false }
            return true
        }
        do {
            let matched = try await MeetingLookup.match(recordings, command: command, calendar: calendar)
            print(String(decoding: try report(matched, library: root), as: UTF8.self))
            return 0
        } catch {
            StudioCommandLine.fail(error.localizedDescription)
            return 1
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value() throws -> String {
            guard i + 1 < args.count else { throw UsageError("\(args[i]) needs a value") }
            i += 1
            return args[i]
        }
        func day(_ s: String) throws -> Date {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: s) else { throw UsageError("not a day (YYYY-MM-DD): \(s)") }
            return d
        }
        while i < args.count {
            switch args[i] {
            case "--from": o.from = try day(try value())
            case "--to": o.to = try day(try value())
            case "--name": o.name = try value()
            case "--library":
                o.library = URL(fileURLWithPath: (try value() as NSString).expandingTildeInPath, isDirectory: true)
            default: throw UsageError("unknown option \(args[i])")
            }
            i += 1
        }
        return o
    }

    struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - Output

    static func report(_ matched: [RecordingMeeting], library: URL) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        func minutes(_ s: TimeInterval) -> Double { (s / 60 * 10).rounded() / 10 }
        func percent(_ x: Double) -> Int { Int((x * 100).rounded()) }
        func meeting(_ m: MeetingMatch, full: Bool) -> [String: Any] {
            var d: [String: Any] = [
                "subject": m.event.subject,
                "start": iso.string(from: m.event.start),
                "end": iso.string(from: m.event.end),
                "overlapMinutes": minutes(m.overlap),
                "recordingCoveragePercent": percent(m.recordingCoverage),
                "meetingCoveragePercent": percent(m.meetingCoverage),
                "startOffsetMinutes": minutes(m.startOffset),
                "fitPercent": percent(m.fit),
                "nameMatches": m.nameMatches,
            ]
            if full {
                d["id"] = m.event.id
                if let o = m.event.organizer { d["organizer"] = o.display }
                d["attendees"] = m.event.attendees.map(\.display)
                if let r = m.event.myResponse { d["myResponse"] = r }
                if let l = m.event.location { d["location"] = l }
                if let w = m.event.webLink { d["webLink"] = w }
            }
            return d
        }
        let rows: [[String: Any]] = matched.map { r in
            var row: [String: Any] = [
                "recording": r.recording.displayName,
                "stem": r.recording.stem,
                "folder": r.recording.folder.path,
                "start": iso.string(from: r.start),
                "end": iso.string(from: r.end),
                "durationMinutes": minutes(r.duration),
                "confidence": r.result.confidence?.rawValue ?? "none",
            ]
            if let best = r.result.best { row["meeting"] = meeting(best, full: true) }
            if r.result.spansSeveralMeetings {
                row["spansSeveralMeetings"] = true
                row["meetingsCovered"] = r.result.covered.map { meeting($0, full: false) }
            }
            row["alternatives"] = r.result.matches.dropFirst().map { meeting($0, full: false) }
            return row
        }
        var counts: [String: Int] = ["strong": 0, "likely": 0, "weak": 0, "none": 0, "spansSeveralMeetings": 0]
        for r in matched {
            counts[r.result.confidence?.rawValue ?? "none", default: 0] += 1
            if r.result.spansSeveralMeetings { counts["spansSeveralMeetings", default: 0] += 1 }
        }
        let doc: [String: Any] = [
            "library": library.path,
            "recordings": matched.count,
            "matched": counts,
            "results": rows,
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
