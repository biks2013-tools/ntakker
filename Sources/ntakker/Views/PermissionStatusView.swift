// ntakker/Views/PermissionStatusView.swift — see project-design.md
// §15.8, §8 (deep links) and plan-002-toolbar-ui.md §3 Phase E (FR-37).
//
// Two indicator rows showing TCC state for Screen Recording and
// Microphone. Polls `PermissionGate.snapshot()` on a 2 s cadence ONLY
// while the popover is visible (battery-friendly per §15.8).
//
// Visual contract (§15.8):
//   * authorized    → green dot + checkmark, no action button
//   * notDetermined → yellow dot + "Grant…" button → calls
//                     `*Permission.request()`
//   * denied/restricted → red dot + "Open Settings" button → opens the
//     System Settings deep link from project-design §8
//     (`Privacy_ScreenCapture` for screen recording,
//     `Privacy_Microphone` for microphone).
//
// The polling lifecycle is owned by SwiftUI's `.task { ... }` modifier,
// which runs while the view is in the hierarchy and is automatically
// cancelled on dismissal. Re-arms on
// `NSApplication.didBecomeActiveNotification` so a hop to System
// Settings + back refreshes immediately (§15.8 second arrow).

import AppKit
import Logging
import NtakkerCore
import SwiftUI

/// Two-row permission indicator. Polls every 2 s while visible.
///
/// Visibility modes:
///   - `.always` — both rows always render (used by the Settings
///     panel where the user expects to see status at any time).
///   - `.onlyWhenIssues` — the view collapses to nothing when both
///     permissions are `.authorized` (used by the popover so a clean
///     setup does not waste vertical space; non-`authorized` rows
///     still render so the user can act on them in place).
struct PermissionStatusView: View {

    enum Visibility {
        case always
        case onlyWhenIssues
    }

    let visibility: Visibility

    /// Latest snapshot from `PermissionGate`. `nil` until first poll.
    @State private var snapshot: PermissionGate.Snapshot?

    private let gate = PermissionGate()
    private let logger = Logger(label: "ntakker-cli.ui.permission")

    init(visibility: Visibility = .always) {
        self.visibility = visibility
    }

    var body: some View {
        Group {
            if shouldRender {
                VStack(alignment: .leading, spacing: 6) {
                    row(
                        title: String(localized: "Screen Recording"),
                        state: screenRecordingState,
                        action: screenRecordingAction
                    )
                    row(
                        title: String(localized: "Microphone"),
                        state: microphoneState,
                        action: microphoneAction
                    )
                }
            }
        }
        .task {
            await pollLoop()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await refreshOnce() }
        }
    }

    /// `false` only when `visibility == .onlyWhenIssues` AND both
    /// permissions are authorized; in every other case the rows are
    /// rendered (including the bootstrap pre-snapshot phase, so the
    /// user is not left wondering whether the tool can record).
    private var shouldRender: Bool {
        if visibility == .always { return true }
        guard let s = snapshot else { return true }
        return !(s.screenRecording == .authorized && s.microphone == .authorized)
    }

    // MARK: - Polling

    /// 2 s polling loop. Stays alive for the lifetime of the SwiftUI
    /// `.task { ... }` block — SwiftUI cancels it on view disappear.
    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func refreshOnce() async {
        let fresh = await gate.snapshot()
        // Only mutate if changed — avoids spurious SwiftUI re-renders.
        if fresh != snapshot {
            snapshot = fresh
        }
    }

    // MARK: - State adapters

    /// Tri-state badge classification mirroring §15.8's visual contract.
    private enum BadgeState {
        case authorized
        case notDetermined
        case denied
    }

    private var screenRecordingState: BadgeState {
        guard let s = snapshot else { return .notDetermined }
        switch s.screenRecording {
        case .authorized:    return .authorized
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        }
    }

    private var microphoneState: BadgeState {
        guard let s = snapshot else { return .notDetermined }
        switch s.microphone {
        case .authorized:                return .authorized
        case .notDetermined:             return .notDetermined
        case .denied, .restricted:       return .denied
        }
    }

    // MARK: - Actions

    /// Click handler for the Screen Recording row. Picks the right
    /// action by current state: `.notDetermined` → trigger TCC prompt;
    /// `.denied` → open System Settings deep link.
    private func screenRecordingAction() {
        switch screenRecordingState {
        case .authorized:
            return
        case .notDetermined:
            logger.debug("triggering screen recording TCC prompt")
            ScreenRecordingPermission.request()
            Task { await refreshOnce() }
        case .denied:
            logger.debug("opening screen recording system settings")
            openSettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        }
    }

    private func microphoneAction() {
        switch microphoneState {
        case .authorized:
            return
        case .notDetermined:
            logger.debug("triggering microphone TCC prompt")
            Task {
                _ = await MicrophonePermission.request()
                await refreshOnce()
            }
        case .denied:
            logger.debug("opening microphone system settings")
            openSettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        }
    }

    private func openSettings(_ deepLink: String) {
        guard let url = URL(string: deepLink) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(
        title: String,
        state: BadgeState,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            badge(state)
            Text(title)
                .font(.callout)
            Spacer(minLength: 0)
            switch state {
            case .authorized:
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .notDetermined:
                Button(String(localized: "Grant"), action: action)
                    .controlSize(.small)
            case .denied:
                Button(String(localized: "Open Settings"), action: action)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func badge(_ state: BadgeState) -> some View {
        let color: Color = {
            switch state {
            case .authorized:    return .green
            case .notDetermined: return .yellow
            case .denied:        return .red
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
