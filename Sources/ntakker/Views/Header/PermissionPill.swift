// ntakker/Views/Header/PermissionPill.swift — plan-008 Unit E
// (project-design §UR-4.7).
//
// Compact green/red pill rendered inside the popover's metadata strip.
// Shows the consolidated TCC state for Screen Recording + Microphone
// without occupying the full-row real-estate that the existing
// `PermissionStatusView` rows do.
//
// When ANY permission is missing, the pill flips to a "Permissions
// needed" affordance and tapping it expands the existing
// `PermissionStatusView(visibility: .always)` underneath the header so
// the user can act on the missing grant. The all-granted case is
// presence-only (single-line green pill) — matches the mockup
// `header-meta .perm-pill` rule (popover-redesign.html §234..246).
//
// The view is intentionally self-contained: it owns its own
// `PermissionGate.snapshot()` poll loop on the same 2 s cadence that
// `PermissionStatusView` uses, so the pill text stays current without
// having to thread state through the parent. The two pollers are
// independent but cheap (`PermissionGate` is a thin TCC API wrapper).

import AppKit
import NtakkerCore
import SwiftUI

/// Compact pill used inside the popover header's metadata strip to
/// indicate the consolidated TCC state for Screen Recording + Mic.
struct PermissionPill: View {

    @Environment(\.palette) private var palette

    /// Latest snapshot from `PermissionGate`. `nil` until the first
    /// poll completes. Treated optimistically (assume granted) so the
    /// strip does not flash a red "permissions needed" pill on every
    /// popover open before the polling loop finishes its first lap.
    @State private var snapshot: PermissionGate.Snapshot?

    /// Whether the user expanded the missing-permissions disclosure.
    /// Bound by the parent header so the disclosed
    /// `PermissionStatusView` renders right beneath the header strip.
    @Binding var expanded: Bool

    private let gate = PermissionGate()

    /// All permissions granted? Optimistic during the bootstrap
    /// (pre-snapshot) phase: returns `true` so the green pill shows
    /// without a flash of red on first popover open.
    private var allGranted: Bool {
        guard let s = snapshot else { return true }
        return s.screenRecording == .authorized && s.microphone == .authorized
    }

    var body: some View {
        Group {
            if allGranted {
                grantedPill
            } else {
                missingPill
            }
        }
        .task { await pollLoop() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await refreshOnce() }
        }
    }

    // MARK: - Pill variants

    @ViewBuilder
    private var grantedPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(palette.successDot)
                .frame(width: 6, height: 6)
            Text("All permissions granted")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.01 * 10.5)
                .foregroundStyle(palette.successForeground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(palette.successBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "All permissions granted"))
    }

    @ViewBuilder
    private var missingPill: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text(expanded
                     ? String(localized: "Hide permissions")
                     : String(localized: "Permissions needed"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.01 * 10.5)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: "Tap to show / hide the per-permission rows."))
        .accessibilityHint(String(localized: "Toggles the missing-permission rows."))
    }

    // MARK: - Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func refreshOnce() async {
        let fresh = await gate.snapshot()
        if fresh != snapshot {
            snapshot = fresh
        }
    }
}
