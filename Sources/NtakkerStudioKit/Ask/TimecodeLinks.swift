// NtakkerStudioKit/Ask/TimecodeLinks.swift — plan-024 T5.
//
// Turns the `[mm:ss]` / `[hh:mm:ss]` citations in an Ask answer or in
// minutes into Markdown links the app opens as "seek the player".

import Foundation

public enum TimecodeLinks {
    public static let scheme = "ntakker-studio"

    /// Seconds for `mm:ss` or `hh:mm:ss` (no brackets).
    public static func seconds(from code: String) -> Double? {
        let parts = code.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.map { $0! }
        guard n.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return Double(n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : n[0] * 60 + n[1])
    }

    /// The seek URL for a time.
    public static func url(seconds: Double) -> URL {
        URL(string: "\(scheme)://seek?t=\(Int(seconds))")!
    }

    /// The time a seek URL points at.
    public static func seconds(from url: URL) -> Double? {
        guard url.scheme == scheme, url.host == "seek",
              let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value
        else { return nil }
        return Double(t)
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"\[((?:\d{1,2}:)?\d{1,3}:\d{2})\](?!\()"#
    )

    /// Replace each bracketed timecode with a Markdown link. Timecodes
    /// that are already links are left alone; codes that are not valid
    /// times (`[12:75]`) are left as text.
    public static func linkify(_ markdown: String) -> String {
        let ns = markdown as NSString
        var out = ""
        var cursor = 0
        for m in pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: m.range(at: 1))
            guard let s = seconds(from: code) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += "[\(code)](\(url(seconds: s).absoluteString))"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
