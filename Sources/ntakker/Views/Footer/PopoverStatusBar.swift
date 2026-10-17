// ntakker/Views/Footer/PopoverStatusBar.swift — plan-015 Pattern C
// commitment 1 (FR-IRQ-40, FR-IRQ-41, FR-IRQ-42) + commitment 3
// (FR-IRQ-48).
//
// The bottom band of the redesigned popover. Replaces the legacy
// `PopoverFooter` (ReadyPill + ControlBar) with a single status-bar
// row containing, in left-to-right order:
//
//   1. Mic bouncing bars (7 × 3pt) + `mic` label
//   2. 0.5pt vertical hairline
//   3. System-audio bouncing bars + `sys` label
//   4. Hairline
//   5. Live state pill (red pulsing dot + label while recording)
//   6. Elapsed `mm:ss` clock
//   7. Flexible spacer
//   8. Action area:
//      - While `recording | paused | pausing | resuming | splitting`:
//        a single red `Stop` button (mirrors `.record-btn` gradient).
//      - While `stopped | idle | failed`: a two-button pair
//        `[ New Session ] [ Save… ]` (FR-IRQ-48). New Session is a
//        transparent-fill button with a 1pt accent stroke + accent
//        text; Save… is filled with the accent gradient.
//
// The bouncing-bar geometry is driven by `recordingController.latestLevels`
// — the same publisher the legacy `LevelMeterView` subscribes to. Each
// bar's height is the source's dBFS-mapped RMS times a fixed
// centre-weighted profile (EVAL 2026-10-16 UI-5). When the session is
// not recording, all bars freeze at min-height per FR-IRQ-42.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

struct PopoverStatusBar: View {
    @Environment(\.palette) private var palette
    @Environment(\.recordingController) private var recordingController

    /// Callbacks owned by `RootView` so this view stays presentation-only.
    let onStop: () -> Void
    let onNewSession: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(palette.separator)
            HStack(spacing: 10) {
                BouncingBars(
                    color: palette.successDot, // mic green
                    intensity: micIntensity,
                    isActive: barsActive
                )
                BarsLabel(text: String(localized: "mic"))

                hairline

                BouncingBars(
                    color: palette.accent, // system audio accent
                    intensity: systemIntensity,
                    isActive: barsActive
                )
                BarsLabel(text: String(localized: "sys"))

                hairline

                statePill
                clock

                Spacer(minLength: 6)

                actionArea
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Sub-views

    private var hairline: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: 0.5, height: 18)
    }

    private var statePill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateDotColor)
                .frame(width: 6, height: 6)
                .shadow(color: stateDotColor.opacity(0.55), radius: 2)
            Text(stateLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stateLabel)
    }

    private var clock: some View {
        Text(elapsedFormatted)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.secondary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var actionArea: some View {
        switch state {
        case .recording, .paused, .pausing, .resuming, .splitting, .stopping:
            stopButton
        case .starting:
            // Transient — show a disabled stop placeholder so the slot
            // does not visibly resize while the session is spinning up.
            stopButton.disabled(true)
        case .stopped:
            HStack(spacing: 6) {
                discardButton
                newSessionButton
                saveButton
            }
        case .idle, .failed:
            // Fresh launch / post-error state — fall back to the
            // legacy ControlBar's Start button so we reuse the
            // recording-options composition (RecordingOptions +
            // env-var resolution) without duplicating ~200 LOC.
            // Pattern-C-specific Start chrome is a Phase 6 polish.
            ControlBar()
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                Text(String(localized: "Stop"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(palette.recordButtonGradient)
            )
            .shadow(color: palette.recordGradientEnd.opacity(0.25), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop and finalize the recording."))
    }

    private var discardButton: some View {
        Button(action: onDiscard) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(localized: "Discard"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.clear))
            .overlay(
                Capsule().strokeBorder(Color.red.opacity(0.65), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: "Discard this recording — throw away the transcript and Q&A without saving."))
    }

    private var newSessionButton: some View {
        Button(action: onNewSession) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(localized: "New Session"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.clear))
            .overlay(
                Capsule().strokeBorder(palette.accent, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: "Start a new recording session — confirms before discarding the current transcript."))
    }

    private var saveButton: some View {
        Button(action: onSave) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(localized: "Save…"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [palette.accent, palette.accent.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .shadow(color: palette.accent.opacity(0.25), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Save this recording — audio + transcript + Q&A to ~/Recordings/<folder>/"))
    }

    // MARK: - Derived state

    private var state: SessionState { recordingController?.state ?? .idle }

    private var barsActive: Bool {
        switch state {
        case .recording, .splitting, .resuming, .pausing: return true
        default: return false
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:                                  return String(localized: "Idle")
        case .starting:                              return String(localized: "Starting…")
        case .recording:                             return String(localized: "Recording")
        case .pausing:                               return String(localized: "Pausing…")
        case .paused:                                return String(localized: "Paused")
        case .resuming:                              return String(localized: "Resuming…")
        case .splitting:                             return String(localized: "Splitting…")
        case .stopping:                              return String(localized: "Stopping…")
        case .stopped:                               return String(localized: "Stopped")
        case .failed:                                return String(localized: "Stopped · error")
        }
    }

    private var stateDotColor: Color {
        switch state {
        case .recording, .splitting:                       return Color(red: 1, green: 0.18, blue: 0.13)
        case .paused, .pausing, .resuming:                 return .yellow
        case .failed:                                       return .red
        case .idle, .stopped, .starting, .stopping:        return palette.tertiary
        }
    }

    /// `mm:ss` for the total elapsed time across all segments of the
    /// current session.
    private var elapsedFormatted: String {
        let total = max(0, Int(recordingController?.totalElapsed ?? 0))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var micIntensity: Double {
        LevelMeterScale.normalized(recordingController?.latestLevels?.mic?.rms ?? 0)
    }

    private var systemIntensity: Double {
        LevelMeterScale.normalized(recordingController?.latestLevels?.system?.rms ?? 0)
    }
}

// MARK: - BouncingBars

/// 7-bar level indicator. M1 / UI-5 (EVAL 2026-10-16): the bar heights
/// come from the live level alone — a fixed centre-weighted profile
/// scaled by the dBFS-mapped RMS — and SwiftUI tweens between
/// published values. No `TimelineView`: the view redraws only when
/// the level changes, and silence draws flat bars.
private struct BouncingBars: View {
    let color: Color
    let intensity: Double  // 0...1, dBFS-mapped RMS (`LevelMeterScale`)
    let isActive: Bool

    /// Relative bar heights, tallest in the middle.
    private static let profile: [Double] = [
        0.45, 0.7, 0.9, 1.0, 0.85, 0.65, 0.5,
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(Self.profile.enumerated()), id: \.offset) { _, weight in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: barHeight(weight))
                    .opacity(isActive ? 1.0 : 0.45)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: intensity)
    }

    /// Min height 3pt (per FR-IRQ-41), max 14pt.
    private func barHeight(_ weight: Double) -> CGFloat {
        guard isActive else { return 3 }
        let level = max(0, min(1, intensity))
        return CGFloat(3 + 11 * level * weight)
    }
}

private struct BarsLabel: View {
    @Environment(\.palette) private var palette
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(palette.tertiary)
    }
}
