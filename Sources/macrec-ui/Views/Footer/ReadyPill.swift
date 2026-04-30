// macrec-ui/Views/Footer/ReadyPill.swift — plan-008 Unit E
// (project-design §UR-4.12).
//
// Compact "● Ready / ● Recording / ● Paused" pill rendered at the
// leading edge of the popover footer. The dot color tracks the
// session state — green when idle/ready, red when recording, amber
// when paused — and the recording variant pulses subtly so the user's
// peripheral vision picks it up while the popover is open.
//
// Visual contract per mockup `.ready-pill` rule
// (docs/design/mockups/popover-redesign.html lines 439..447):
//   * 11.5pt font, secondary foreground.
//   * 7pt circular dot with a 6pt soft glow.

import MacrecCore
import SwiftUI

/// Footer leading-edge state pill.
struct ReadyPill: View {
    @Environment(\.palette) private var palette

    /// Current session state — provided by the parent so the pill stays
    /// stateless and the parent owns the controller binding.
    let state: SessionState

    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(0.55), radius: 3)
                .scaleEffect(state.isRecording && pulse ? 1.18 : 1.0)
                .animation(
                    state.isRecording
                        ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear { pulse = true }
                .onChange(of: state.isRecording) { _, recording in
                    pulse = recording
                }
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .idle, .stopped:    return String(localized: "Ready")
        case .starting:          return String(localized: "Starting…")
        case .recording:         return String(localized: "Recording")
        case .pausing:           return String(localized: "Pausing…")
        case .paused:            return String(localized: "Paused")
        case .resuming:          return String(localized: "Resuming…")
        case .splitting:         return String(localized: "Splitting…")
        case .stopping:          return String(localized: "Stopping…")
        case .failed:            return String(localized: "Error")
        }
    }

    private var dotColor: Color {
        switch state {
        case .recording, .splitting:           return .red
        case .paused, .pausing, .resuming:     return .yellow
        case .failed:                          return .red
        default:                               return palette.successDot
        }
    }
}

private extension SessionState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
