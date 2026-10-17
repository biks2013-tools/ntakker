// ntakker/EnvironmentKeys.swift — see project-design.md §15.4
// (RecordingController) and plan-002-toolbar-ui.md §3 Phase D / Phase E.
//
// Bundles every SwiftUI `EnvironmentKey` consumed by the popover view
// tree:
//
//   * `\.recordingController` — the shared `RecordingController`
//     view-model (Phase D wiring, see project-design §15.4).
//   * `\.popoverBehavior` — closure that swaps the underlying
//     `NSPopover.behavior` for the duration of an `NSOpenPanel` so
//     the popover stays open while the system file dialog is up
//     (plan-002 R-27, project-design §15.11). Provided by
//     `AppDelegate` from `PopoverController.setBehaviorForPanel(_:)`.
//
// Both keys live in the executable target (NOT `NtakkerUIKit`) because
// SwiftUI's `EnvironmentKey` protocol is only available when `SwiftUI`
// is imported, and `NtakkerUIKit` is the pure-logic UI domain layer
// (no SwiftUI dependency).
//
// The optional storage shape (controller is `RecordingController?`,
// popover behavior is an optional closure) lets the SwiftUI preview
// machinery in Phase E construct views without an AppDelegate-supplied
// runtime: a preview can render with `nil` and gracefully degrade.

import AppKit
import NtakkerUIKit
import SwiftUI

// MARK: - RecordingController environment key

/// SwiftUI environment key for the shared `RecordingController`. The
/// AppDelegate sets the value via
/// `RootView.environment(\.recordingController, controller)` once at
/// launch.
private struct RecordingControllerKey: EnvironmentKey {
    static let defaultValue: RecordingController? = nil
}

// MARK: - Popover-behavior environment key

/// Closure type the FolderPicker calls to switch the hosting popover
/// between `.transient` and `.semitransient`. Provided by
/// `AppDelegate` and fulfilled by
/// `PopoverController.setBehaviorForPanel(_:)`.
///
/// The closure is `@MainActor` because `NSPopover.behavior` is a main-
/// thread-only AppKit property.
public typealias PopoverBehaviorSetter = @MainActor (NSPopover.Behavior) -> Void

private struct PopoverBehaviorKey: EnvironmentKey {
    static let defaultValue: PopoverBehaviorSetter? = nil
}

extension EnvironmentValues {
    /// The currently-active `RecordingController`, if one has been
    /// installed by the app shell. Views read via:
    ///
    ///     @Environment(\.recordingController) private var controller
    var recordingController: RecordingController? {
        get { self[RecordingControllerKey.self] }
        set { self[RecordingControllerKey.self] = newValue }
    }

    /// Closure used by `FolderPicker` to swap popover behavior to
    /// `.semitransient` while the `NSOpenPanel` is up, restoring
    /// `.transient` afterwards (R-27).
    var popoverBehavior: PopoverBehaviorSetter? {
        get { self[PopoverBehaviorKey.self] }
        set { self[PopoverBehaviorKey.self] = newValue }
    }
}

// MARK: - Window-presentation environment key

/// Whether the UI is shown in the menu-bar popover or popped out into
/// its own window, plus the actions that move it between the two.
/// Owned by `PopoverController`; views read it to show the right
/// pop-out / dock-back button and to size themselves (a window is
/// freely resizable, the popover keeps its own resize handle).
@MainActor
@Observable
final class PopoverPresentation {
    /// True while the UI lives in the separate window.
    var isDetached = false

    /// Move the UI out of the popover into a window.
    var popOut: () -> Void = {}

    /// Move the UI back under the menu-bar icon and show the popover.
    var dockBack: () -> Void = {}
}

private struct PopoverPresentationKey: EnvironmentKey {
    static let defaultValue: PopoverPresentation? = nil
}

extension EnvironmentValues {
    /// Popover / window presentation state. `nil` in previews.
    var popoverPresentation: PopoverPresentation? {
        get { self[PopoverPresentationKey.self] }
        set { self[PopoverPresentationKey.self] = newValue }
    }
}
