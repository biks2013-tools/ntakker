// ntakker/Views/FilenameField.swift — see project-design.md §15.6
// (FilenameGenerator), §15.4 (RecordingController inputs), and
// plan-002-toolbar-ui.md §3 Phase E (FR-35, AC-UI-8).
//
// SwiftUI `TextField` bound to the recording's pre-flight basename.
// While `recordingController.state == .idle | .stopped | .failed` the
// field is editable; while a session is in flight it is disabled
// (AC-UI-8 — "filename field locks during recording"). When empty the
// field placeholder shows the deterministic
// `FilenameGenerator.default(now:)` basename, which is also what the
// controller will fall back to if the user starts without typing.
//
// The view does NOT mutate `RecordingOptions` directly; it owns the
// transient `basename: String` state and persists it via `@AppStorage`
// so the user's last-typed name survives popover dismissal. The
// `RecordingController` reads the persisted value at `start()` time
// when it composes the per-segment URL.

import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// User-editable filename field. Locked while non-`.idle`.
struct FilenameField: View {
    @Environment(\.recordingController) private var recordingController

    /// User-typed basename (no folder, no extension). Empty → fall back
    /// to `FilenameGenerator.default(now:)`. Persisted across popover
    /// open/close so the user does not have to retype mid-session.
    @AppStorage("com.ntakker-cli.ui.basename") private var basename: String = ""

    /// Current state derived from the controller. `nil` controller (e.g.
    /// SwiftUI preview) treated as `.idle`.
    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// Deterministic placeholder shown when `basename` is empty.
    /// Matches what the controller would compose at `start()`.
    private var placeholder: String {
        FilenameGenerator.default(now: Date())
    }

    var body: some View {
        TextField(
            String(localized: "Filename"),
            text: $basename,
            prompt: Text(placeholder)
        )
        .textFieldStyle(.roundedBorder)
        .disabled(isLocked)
        .help(String(localized: "Base filename for the next recording (no extension)."))
    }
}

// `#Preview { … }` requires Xcode's PreviewsMacros plugin which is not
// available when building via the command-line `swift` toolchain
// (SwiftPM CLI). Phase E sticks to a CLI-only toolchain — the SwiftPM
// `swift build` invocation in plan-002 §3 Phase E gate criteria is the
// authoritative test. SwiftUI canvas previews can be re-enabled
// trivially under Xcode by re-introducing a `#Preview { ... }` block.
