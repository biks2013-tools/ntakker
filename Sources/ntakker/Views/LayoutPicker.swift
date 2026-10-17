// ntakker/Views/LayoutPicker.swift — see project-design.md §15.4
// and plan-002-toolbar-ui.md §3 Phase E (FR-38, AC-UI-8).
//
// SwiftUI `Picker` over the three `TrackLayout` values: `mixed`,
// `split`, `stereo-split`. Disabled while a session is in flight
// (AC-UI-8). The chosen layout is persisted under
// `com.ntakker-cli.ui.layout` per project-functions FR-38.

import NtakkerCore
import NtakkerUIKit
import SwiftUI
import NtakkerSettingsUI

/// Layout picker with three options (`mixed`, `split`, `stereo-split`).
struct LayoutPicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted layout raw value (one of `"mixed"`, `"split"`,
    /// `"stereo-split"`). Default `.mixed` per FR-4.
    @SharedSetting(SharedSettings.Keys.layout) private var layoutRaw: String = TrackLayout.mixed.rawValue

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    private var layoutBinding: Binding<TrackLayout> {
        Binding(
            get: { TrackLayout(rawValue: layoutRaw) ?? .mixed },
            set: { layoutRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker(String(localized: "Layout"), selection: layoutBinding) {
            Text(String(localized: "mixed")).tag(TrackLayout.mixed)
            Text(String(localized: "split")).tag(TrackLayout.split)
            Text(String(localized: "stereo-split")).tag(TrackLayout.stereoSplit)
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "Track layout for the next recording."))
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
