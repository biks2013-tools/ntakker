// ntakker/Views/SavedToDisclosure.swift — see project-design.md
// §15.4 (completedSegments) and plan-002-toolbar-ui.md §3 Phase E
// (FR-34, OQ-UI-11).
//
// Disclosure group listing every completed segment URL produced by the
// session. Empty list → the entire view collapses (the parent layout
// should not render this view when `completedSegments.isEmpty`, but we
// also no-op here as a safety net).
//
// Each row renders:
//   * the file's last-path component (filename only, the absolute
//     path is in the row's tooltip);
//   * a click-target on the row that calls
//     `NSWorkspace.shared.activateFileViewerSelecting([url])` to
//     reveal the file in Finder.
//
// For `--layout split` the engine writes paired `.system` and `.mic`
// files; both URLs land on `completedSegments` and are rendered as
// adjacent rows here (FR-34 / OQ-UI-11).

import AppKit
import Logging
import NtakkerUIKit
import SwiftUI

/// Expandable list of saved files for the current session.
struct SavedToDisclosure: View {
    @Environment(\.recordingController) private var recordingController

    @State private var expanded: Bool = true

    private let logger = Logger(label: "ntakker-cli.ui.savedTo")

    /// Convenience accessor — empty when no controller (preview path).
    private var segments: [URL] {
        recordingController?.completedSegments ?? []
    }

    var body: some View {
        if segments.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup(
                isExpanded: $expanded,
                content: { content },
                label: {
                    Text(String(
                        localized: "Saved files (\(segments.count))"
                    ))
                    .font(.callout)
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(segments, id: \.self) { url in
                row(for: url)
            }
        }
    }

    @ViewBuilder
    private func row(for url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                reveal(url)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Reveal in Finder"))
        }
        .help(url.path)
    }

    /// Open Finder selecting the supplied URL. Logs at debug.
    private func reveal(_ url: URL) {
        logger.debug("revealing in Finder: \(url.path)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
