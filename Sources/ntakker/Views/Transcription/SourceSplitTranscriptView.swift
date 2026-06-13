// ntakker/Views/Transcription/SourceSplitTranscriptView.swift —
// plan-012 Phase C6. Two-lane stacked view used when single-mode +
// `--transcribe-source both` is active. Each lane is a SourceLane
// with the matching SourceTag filter and a friendly header. v1
// uses a fixed 50/50 vertical split — a draggable divider is a
// follow-up.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

struct SourceSplitTranscriptView: View {
    var body: some View {
        VStack(spacing: 8) {
            SourceLane(filter: .system,     headerLabel: String(localized: "System audio"))
            SourceLane(filter: .microphone, headerLabel: String(localized: "Microphone"))
        }
        .frame(maxHeight: .infinity)
    }
}
