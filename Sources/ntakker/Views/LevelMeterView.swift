// ntakker/Views/LevelMeterView.swift — see project-design.md §15.7
// (level-meter pipeline) and plan-002-toolbar-ui.md §3 Phase E (FR-43).
//
// Two horizontal bars showing system-audio + microphone peak/RMS. Reads
// `recordingController.latestLevels` (a `MergedLevelSample` published
// at 30 Hz from `LevelMeterPublisher`). Re-renders on every mutation
// because the controller is `@Observable`; SwiftUI tracks the read.
//
// Visual contract:
//   * Peak: thin bright line at width = peak * geometry.width.
//   * RMS:  thicker filled rectangle at width = rms * geometry.width.
// Both `peak` and `rms` are in linear (0..1) magnitude per
// `LevelSample` documentation. Values are clamped into [0, 1] so a
// transient spike past 1.0 does not overrun the bar.
//
// `.animation(.linear(duration: 0.05))` smooths the visual transition
// between 30 Hz samples (investigation Topic 5).

import NtakkerUIKit
import SwiftUI

/// Per-source peak + RMS bar. Re-rendered as `latestLevels` changes.
struct LevelMeterView: View {
    @Environment(\.recordingController) private var recordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(
                label: String(localized: "System"),
                sample: recordingController?.latestLevels?.system
            )
            row(
                label: String(localized: "Mic"),
                sample: recordingController?.latestLevels?.mic
            )
        }
        .animation(.linear(duration: 0.05), value: animationKey)
    }

    /// Keys the implicit animation off the two source samples so SwiftUI
    /// re-runs the linear-50 ms tween on every 30 Hz tick.
    private var animationKey: String {
        let sys = recordingController?.latestLevels?.system
        let mic = recordingController?.latestLevels?.mic
        return "\(sys?.peak ?? 0)|\(sys?.rms ?? 0)|\(mic?.peak ?? 0)|\(mic?.rms ?? 0)"
    }

    @ViewBuilder
    private func row(label: String, sample: LevelSample?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track.
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 8)

                    // RMS — filled bar.
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(
                            width: geo.size.width * clamp01(CGFloat(sample?.rms ?? 0)),
                            height: 8
                        )

                    // Peak — thin bright overlay.
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(
                            width: geo.size.width * clamp01(CGFloat(sample?.peak ?? 0)),
                            height: 2
                        )
                        .offset(y: -3)
                }
            }
            .frame(height: 14)
        }
    }

    /// Clamp an arbitrary value into the [0, 1] range used by the bar
    /// geometry. `LevelSample.peak/rms` are linear magnitudes per the
    /// `LevelSample` doc, so out-of-range values would only happen on a
    /// pathological transient.
    private func clamp01(_ x: CGFloat) -> CGFloat {
        max(0, min(1, x))
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
