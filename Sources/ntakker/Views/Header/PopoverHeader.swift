// ntakker/Views/Header/PopoverHeader.swift — plan-008 Unit E
// (project-design §UR-5 / §UR-4.7..§UR-4.9).
//
// Composite header: big-title `FilenameTitleField` over a
// `MetadataStrip` that hosts the permission pill, save-to chip, state
// label, and trailing chrome (appearance switcher + settings link).
//
// When the user taps the missing-permissions pill, the header
// expands the existing `PermissionStatusView(visibility: .always)`
// underneath the strip so the per-permission rows are reachable
// without leaving the popover.

import SwiftUI

/// Popover header band — filename title + metadata strip + (optionally)
/// the expanded permission rows.
struct PopoverHeader<Trailing: View>: View {

    /// Human-readable session-state label provided by the parent
    /// (RootView). Keeps the header decoupled from
    /// `RecordingController` state mapping.
    let stateLabel: String

    /// Trailing chrome (Appearance switcher, Settings link).
    let trailing: () -> Trailing

    /// Self-owned expansion state for the missing-permissions disclosure.
    @State private var permissionsExpanded: Bool = false

    init(
        stateLabel: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.stateLabel = stateLabel
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FilenameTitleField()
            MetadataStrip(
                stateLabel: stateLabel,
                permissionsExpanded: $permissionsExpanded,
                trailing: trailing
            )

            // Reveal the existing per-permission rows when the user taps
            // the "Permissions needed" pill. Uses the existing
            // `PermissionStatusView(.always)` — when both grants are in
            // place the rows render their checkmark variant; when one
            // is missing the user can act on it in place.
            if permissionsExpanded {
                PermissionStatusView(visibility: .always)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: permissionsExpanded)
    }
}
