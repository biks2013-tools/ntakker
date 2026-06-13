// ntakker/Views/ElapsedTimeView.swift — see project-design.md §15.4
// (segmentElapsed / totalElapsed) and plan-002-toolbar-ui.md §3 Phase E
// (FR-40, AC-UI-12).
//
// Displays the segment-elapsed time as `HH:MM:SS`. Driven by a 1 Hz
// `TimelineView(.periodic(...))` so the rendered value refreshes once
// per second even when no other observable mutation has fired
// (AC-UI-12 — "elapsed-time advances at 1 Hz; freezes on pause").
//
// The actual numeric source is `recordingController.segmentElapsed`,
// which the controller advances inside `tickElapsed()` only while
// `state == .recording`. When the state is `.paused` / `.pausing` /
// `.stopping`, `tickElapsed()` is not called → the elapsed value is
// frozen. The `TimelineView` re-renders periodically but reads the
// same frozen value, so the displayed clock visibly stops on pause —
// exactly what AC-UI-12 specifies.

import NtakkerUIKit
import SwiftUI

/// 1 Hz `mm:ss` (or `h:mm:ss` for long sessions) elapsed-time clock.
struct ElapsedTimeView: View {
    @Environment(\.recordingController) private var recordingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(formatted)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.primary)
                .accessibilityLabel(String(localized: "Elapsed time"))
        }
    }

    /// Render `recordingController.segmentElapsed` as `HH:MM:SS` if the
    /// session has run for at least an hour, else `MM:SS`. Defaults to
    /// `00:00` when there is no controller (preview path).
    private var formatted: String {
        let elapsed = recordingController?.segmentElapsed ?? 0
        let total = max(0, Int(elapsed))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
