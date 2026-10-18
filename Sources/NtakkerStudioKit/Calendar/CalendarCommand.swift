// NtakkerStudioKit/Calendar/CalendarCommand.swift — 2026-10-18.
//
// Runs the configured calendar command (`NTAKKER_CALENDAR_COMMAND` in
// ~/.tool-agents/ntakker/.env) for a range of days and decodes the JSON
// it prints. The command is a shell command line in which `{from}` and
// `{to}` are replaced by the first and last day (YYYY-MM-DD, local time,
// both included), e.g.
//
//   /Users/me/.local/bin/m365mail calendar export --from {from} --to {to} --no-description
//
// It runs through `/bin/sh -c` with the app's environment. Apps started
// from Finder or the Dock have a short PATH (/usr/bin:/bin:…), so give
// the program's full path. There is no built-in command: when the
// setting is missing, `CalendarCommandError.notConfigured` is thrown.

import Foundation
import NtakkerCore

public enum CalendarCommandError: Error, LocalizedError, Equatable {
    case notConfigured
    case missingPlaceholders
    case failed(status: Int32, stderr: String)
    case timedOut(seconds: Int)
    case launch(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No calendar command is configured. Set \(SharedSettings.Keys.calendarCommand) in ~/.tool-agents/ntakker/.env (Settings ▸ Studio ▸ Calendar), e.g. `/full/path/m365mail calendar export --from {from} --to {to} --no-description`."
        case .missingPlaceholders:
            return "\(SharedSettings.Keys.calendarCommand) must contain {from} and {to}; they are replaced by the first and last day (YYYY-MM-DD)."
        case .failed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The calendar command failed (exit \(status))" + (detail.isEmpty ? "." : ": \(detail.prefix(400))")
        case .timedOut(let seconds):
            return "The calendar command did not finish within \(seconds) s."
        case .launch(let detail):
            return "The calendar command could not be started: \(detail)"
        }
    }
}

public struct CalendarCommand: Sendable {
    /// Longest a single run may take.
    public static let timeoutSeconds = 120

    public let template: String

    public init(template: String) throws {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw CalendarCommandError.notConfigured }
        guard t.contains("{from}"), t.contains("{to}") else { throw CalendarCommandError.missingPlaceholders }
        self.template = t
    }

    /// The command from the shared settings in `values` (the shared
    /// file's contents, or the process environment).
    public static func configured(in values: [String: String]) throws -> CalendarCommand {
        guard let t = values[SharedSettings.Keys.calendarCommand], !t.isEmpty else {
            throw CalendarCommandError.notConfigured
        }
        return try CalendarCommand(template: t)
    }

    /// The command line for `from`…`to` (days in `calendar`'s time zone).
    public func commandLine(from: Date, to: Date, calendar: Calendar = .current) -> String {
        template
            .replacingOccurrences(of: "{from}", with: Self.day(from, calendar))
            .replacingOccurrences(of: "{to}", with: Self.day(to, calendar))
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Run for the days `from`…`to` and return the events it printed.
    public func events(from: Date, to: Date, calendar: Calendar = .current) async throws -> [CalendarEvent] {
        let data = try await Self.run(commandLine(from: from, to: to, calendar: calendar))
        return try CalendarDocument.events(from: data)
    }

    /// Run `line` with `/bin/sh -c`; stdout on success.
    static func run(_ line: String) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Read both pipes while the command runs, so a large calendar
        // cannot fill a pipe buffer and stall it.
        async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            _ = await (stdout, stderr)
            throw CalendarCommandError.launch(error.localizedDescription)
        }
        let fired = Flag()
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning { fired.set(); process.terminate() }
        }
        let (o, e) = await (stdout, stderr)
        process.waitUntilExit()
        watchdog.cancel()
        if fired.value { throw CalendarCommandError.timedOut(seconds: timeoutSeconds) }
        guard process.terminationStatus == 0 else {
            throw CalendarCommandError.failed(status: process.terminationStatus, stderr: String(decoding: e, as: UTF8.self))
        }
        return o
    }
}

/// Set once by the timeout watchdog.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.lock(); raised = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
