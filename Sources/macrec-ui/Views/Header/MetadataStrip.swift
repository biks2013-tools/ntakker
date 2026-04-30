// macrec-ui/Views/Header/MetadataStrip.swift — plan-008 Unit E.
//
// Small horizontal line of pills + dot separators below the filename
// title, mirroring the mockup `header-meta` rule
// (docs/design/mockups/popover-redesign.html lines 224..246):
//
//   [● All permissions granted] · [📁 Recordings  Choose…] · Idle      [☼] [⚙]
//
// The strip composes `PermissionPill`, `SaveToChip`, and a state label
// produced by the parent (so this view stays content-agnostic) and
// accepts a closure for trailing chrome (`AppearanceSwitcher`,
// `SettingsLink`, etc.) so RootView keeps full control over what lives
// at the trailing edge.

import SwiftUI

/// Metadata strip rendered under the filename title field. The trailing
/// closure is the place to inject the appearance switcher, settings
/// link, or any future per-recording chrome.
struct MetadataStrip<Trailing: View>: View {
    @Environment(\.palette) private var palette

    /// Human-readable session-state label — "Idle" / "Recording" /
    /// "Paused" — composed by the parent so this view does not have to
    /// reach into the `RecordingController`.
    let stateLabel: String

    /// Bound to `PermissionPill` so a tap on the missing-permissions
    /// pill expands the rows that the parent renders below the strip.
    @Binding var permissionsExpanded: Bool

    /// Trailing chrome (Appearance switcher, Settings link, …).
    let trailing: () -> Trailing

    init(
        stateLabel: String,
        permissionsExpanded: Binding<Bool>,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.stateLabel = stateLabel
        self._permissionsExpanded = permissionsExpanded
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            PermissionPill(expanded: $permissionsExpanded)
            separator
            SaveToChip()
            separator
            Text(stateLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 4)
            trailing()
        }
    }

    /// Dot separator between metadata items (matches mockup `.sep`).
    private var separator: some View {
        Text("·")
            .font(.system(size: 11.5))
            .foregroundStyle(palette.tertiary)
    }
}
