// macrec-ui/Views/MicrophonePicker.swift — see project-design.md §15.2,
// project-functions.md FR-39 and plan-002-toolbar-ui.md §3 Phase E
// (FR-39, AC-UI-11).
//
// SwiftUI `Picker` listing every input-capable audio device returned by
// `AudioDeviceEnumerator.listInputs()`. The selected device's UID is
// persisted under `com.macrec.ui.micUID` so the choice survives popover
// dismissal and process restart.
//
// Hot-plug refresh (AC-UI-11): the view subscribes to
// `AVCaptureDeviceWasConnectedNotification` /
// `AVCaptureDeviceWasDisconnectedNotification` via `.onReceive(...)`.
// When either fires, the view re-runs the enumerator. The locked AC-11
// budget is "≤ 2 s after hot-plug"; AVFoundation delivers these
// notifications synchronously within a few hundred milliseconds, well
// inside the budget.
//
// Disabled while a session is in flight — changing the mic device
// mid-session would not affect the already-running `RecordingSession`
// (AC-UI-8 spirit).

import AVFoundation
import AppKit
import Logging
import MacrecCore
import MacrecUIKit
import SwiftUI

/// Sentinel UID used by the picker to mean "system default input".
/// Empty string is reserved as the storage representation of "no
/// preference saved yet"; we use a distinct sentinel for the user's
/// explicit pick of "default input".
private let kDefaultInputSentinel = "__default__"

/// Microphone selector. Locked while non-`.idle`.
struct MicrophonePicker: View {
    @Environment(\.recordingController) private var recordingController

    /// Persisted device UID. Empty string → no choice yet (controller
    /// uses system default at `start()`). `kDefaultInputSentinel` →
    /// user explicitly picked "Default Input".
    @AppStorage("com.macrec.ui.micUID") private var micUID: String = ""

    /// Live device list. Re-populated on appear and on hot-plug.
    @State private var devices: [AudioInputDevice] = []

    private let logger = Logger(label: "macrec.ui.micPicker")

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    /// Bind the picker's selection to `micUID`. The empty-string state
    /// is normalized to the default sentinel so the picker has a
    /// concrete row selected when the user has not yet chosen.
    private var selectionBinding: Binding<String> {
        Binding(
            get: { micUID.isEmpty ? kDefaultInputSentinel : micUID },
            set: { micUID = $0 }
        )
    }

    var body: some View {
        Picker(String(localized: "Microphone"), selection: selectionBinding) {
            Text(String(localized: "Default Input"))
                .tag(kDefaultInputSentinel)
            Divider()
            ForEach(devices, id: \.uid) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "Microphone used for the next recording."))
        .task { refreshDevices() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .AVCaptureDeviceWasConnected
            )
        ) { _ in refreshDevices() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .AVCaptureDeviceWasDisconnected
            )
        ) { _ in refreshDevices() }
    }

    /// Re-enumerate the input device list. Errors are logged and the
    /// previous list is preserved (the user's selection still works
    /// against the cached snapshot until the next refresh succeeds).
    private func refreshDevices() {
        do {
            let fresh = try AudioDeviceEnumerator.listInputs()
            devices = fresh
            logger.debug("refreshed device list (count=\(fresh.count))")
        } catch {
            logger.warning("failed to enumerate input devices: \(error.localizedDescription)")
        }
    }
}

// SwiftUI `#Preview` blocks omitted — see FilenameField.swift comment.
