// macrec-ui/Views/MicEchoCancellationToggle.swift — plan-013 §4.4
//
// SwiftUI Toggle bound to the `com.macrec.ui.micAEC` AppStorage key.
// Default: `true` (AEC on). Off captures the raw mic via the legacy
// `AVMicrophoneSource`; on routes through `VPMicrophoneSource`
// (`AVAudioEngine` + voice-processing AEC) so Apple's echo-cancellation
// subtracts system-output bleed from the mic signal.
//
// Locked while a recording is in flight — the source is wired in
// `RecordingSession.run()` from the immutable `RecordingOptions`
// snapshot, so flipping the toggle mid-session would have no effect on
// the current recording. We disable the control and update its tooltip
// to make that clear.

import SwiftUI
import MacrecUIKit

/// Persistent UI default for `RecordingOptions.micAEC`. Read at
/// `start()` time by `ControlBar`. Plan-013 §4.4 / AC-2.
public let kMicAECStorageKey = "com.macrec.ui.micAEC"

struct MicEchoCancellationToggle: View {
    @Environment(\.recordingController) private var recordingController

    @AppStorage(kMicAECStorageKey) private var micAEC: Bool = false

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    var body: some View {
        Toggle(String(localized: "Mic echo cancellation"), isOn: $micAEC)
            .disabled(isLocked)
            .help(String(localized: "Off by default (plan-014). Turn on to subtract speaker-to-mic acoustic bleed via a software NLMS adaptive filter (uses the captured system audio as the reference). Preserves the mic's native frequency response — no AGC, no noise suppression, no band narrowing. Recommended only when you are actually capturing speaker bleed; on headphones it costs CPU for no benefit."))
    }
}
