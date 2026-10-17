// ntakker-studio/Views/MarkdownText.swift — plan-024 T9.
//
// Enough Markdown for Ask answers and minutes: headings, bullets,
// task-list items, rules and paragraphs, with inline styling and links.
// `[mm:ss]` citations are turned into seek links first
// (`TimecodeLinks`); the enclosing view handles them via `openURL`.

import NtakkerStudioKit
import SwiftUI

struct MarkdownText: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String, checked: Bool?)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let indent, let text, let checked):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let checked {
                            Image(systemName: checked ? "checkmark.square" : "square")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("•").foregroundStyle(.secondary)
                        }
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .rule:
                    Divider()
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        let linked = TimecodeLinks.linkify(text)
        if let attributed = try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); out.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                flush()
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                var item = String(line.dropFirst(2))
                var checked: Bool?
                if item.hasPrefix("[ ] ") { checked = false; item = String(item.dropFirst(4)) }
                else if item.lowercased().hasPrefix("[x] ") { checked = true; item = String(item.dropFirst(4)) }
                out.append(.bullet(indent, item, checked: checked))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                // A numbered item keeps its number as written.
                flush()
                out.append(.paragraph(line))
                continue
            }
            paragraph.append(line)
        }
        flush()
        return out
    }
}
