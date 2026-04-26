// macrec-ui/EnvironmentKeys.swift — see project-design.md §15.4
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
// Both keys live in the executable target (NOT `MacrecUIKit`) because
// SwiftUI's `EnvironmentKey` protocol is only available when `SwiftUI`
// is imported, and `MacrecUIKit` is the pure-logic UI domain layer
// (no SwiftUI dependency).
//
// The optional storage shape (controller is `RecordingController?`,
// popover behavior is an optional closure) lets the SwiftUI preview
// machinery in Phase E construct views without an AppDelegate-supplied
// runtime: a preview can render with `nil` and gracefully degrade.

import AppKit
import MacrecUIKit
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
