// macrec-ui/Views/Sections/LiveTranscriptionSection.swift —
// plan-008 Unit E (project-design §UR-5); plan-010 Phase E / Lane L-7
// (mode switch + Single sub-view extraction).
//
// Body of the Live Transcription section. The `transcriptionEnabled`
// master switch lives on the section header (UR-ADR-7); when OFF the
// section body collapses to a single hint line so the persisted
// engine + key state survives without consuming popover height.
//
// When ON, the section body composes (top-to-bottom) per project-design
// §DT-8:
//
//   1. `TranscriptionModeSwitch` — segmented "Single | Dual" picker
//      bound to `@AppStorage("com.macrec.ui.transcriptionMode")`
//      (plan-010 Lane L-7). Always rendered above the mode-dependent
//      controls.
//   2. The mode-dependent controls:
//      * `.single` → `SingleTranscriptionControls()` — the verbatim
//        extraction of the pre-plan-010 four-row block (Transcribe /
//        Source / Transcript format / Language) plus the per-provider
//        API-key row. Behaviourally identical to today (AC-1).
//      * `.dual`   → `DualTranscriptionControls()` — the dual-mode
//        control set landed by plan-010 Lane L-8 (Wave 5). Renders
//        the source / Channel-A locale / Channel-B locale / format
//        rows plus per-channel inline error display (FR-4).
//
// The mode is read here via `@AppStorage` directly (rather than from
// `RecordingController.transcriptionMode`) so the branch reactively
// re-evaluates on user flip without going through a controller-side
// `Notification` round-trip. The controller still keeps an
// independent mirror so the engine-side `RecordingSession`
// construction can read the mode at Start time.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Body of the Live Transcription section. Wrapped in a `Section` so it
/// composes cleanly inside the parent `Form` (UR-ADR-1).
struct LiveTranscriptionSection: View {
    @Environment(\.palette) private var palette

    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    /// Persisted mode (plan-010 Lane L-7). Bad / missing values
    /// collapse to `.single` — same fallback semantics as
    /// `RecordingController.loadTranscriptionMode`.
    @AppStorage(RecordingController.transcriptionModeStorageKey)
    private var transcriptionModeRaw: String = LiveTranscriptionMode.single.rawValue

    private var transcriptionMode: LiveTranscriptionMode {
        LiveTranscriptionMode(rawValue: transcriptionModeRaw) ?? .single
    }

    var body: some View {
        Section {
            if transcriptionEnabled {
                TranscriptionModeSwitch()
                if transcriptionMode == .single {
                    SingleTranscriptionControls()
                } else {
                    DualTranscriptionControls()
                }
            } else {
                Text("Off — toggle on to enable live transcription")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiary)
                    .padding(.vertical, 2)
            }
        }
    }
}
