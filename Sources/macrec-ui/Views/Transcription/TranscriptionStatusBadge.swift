// macrec-ui/Views/Transcription/TranscriptionStatusBadge.swift — see
// project-design.md §LT-8.1 / §LT-12 and plan-003 Phase G, updated for
// plan-004 Phase H (rest-batch UI state).
//
// Compact status pill rendered in the header of `LiveTranscriptPanel`
// (and reusable next to the `TranscriptionPicker`). The rest-batch
// pipeline does not surface connection-level state; the badge collapses
// to three states:
//
//   * `.idle`   — hidden (transcription disabled or no events yet).
//   * `.active` — green ("Active") — manager has produced segments
//                  and/or metric ticks.
//   * `.error`  — red ("Error") with the message in the help tooltip.

import MacrecUIKit
import SwiftUI

struct TranscriptionStatusBadge: View {
    @Environment(\.recordingController) private var recordingController

    private var status: TranscriptionUIState {
        recordingController?.transcriptionStatus ?? .idle
    }

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .active:
            badge(text: "Active", color: .green)
        case let .error(message):
            badge(text: "Error", color: .red)
                .help(message)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.12))
        )
    }
}
