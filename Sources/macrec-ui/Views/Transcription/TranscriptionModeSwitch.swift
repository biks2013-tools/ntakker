// macrec-ui/Views/Transcription/TranscriptionModeSwitch.swift —
// plan-010 Phase E (Lane L-7); see project-design §DT-8 (UI design)
// and §DT-9 (AppStorage keys).
//
// Compact segmented `Picker` ("Single" / "Dual") rendered at the TOP
// of the Live Transcription panel, ABOVE the existing four-row block
// (Transcribe / Source / Transcript format / Language). The picker
// is bound to `@AppStorage("com.macrec.ui.transcriptionMode")` —
// the same key mirrored by `RecordingController.transcriptionMode`
// (plan-010 Lane L-5). Default `.single` preserves existing
// behaviour for users who do not opt into dual mode.
//
// The persisted slot is a `String` rather than the `LiveTranscriptionMode`
// enum directly because `@AppStorage` does not support arbitrary
// `Codable` types; we round-trip through a computed `Binding`.
//
// AC-1 (single sub-view pixel-identical to today) is a hard
// constraint: this view introduces ONE new row at the top of the
// panel; the four rows below it are produced by
// `SingleTranscriptionControls` verbatim and retain their identity.
// User confirmation captured during plan-010 Phase 4 ↔ Phase 5
// hand-off — the new mode-switch row is acceptable per the "spirit"
// reading of NFR-1.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// One-row segmented mode switch placed at the top of the Live
/// Transcription panel. Drives the `transcriptionMode` slot in both
/// `@AppStorage` and `RecordingController`.
struct TranscriptionModeSwitch: View {
    /// Persisted raw value of the live-transcription mode. Default
    /// `"single"`. Bound to the same key that `RecordingController`
    /// reads via the `transcriptionModeStorageKey` constant.
    @AppStorage(RecordingController.transcriptionModeStorageKey)
    private var modeRaw: String = LiveTranscriptionMode.single.rawValue

    /// Round-trip binding between the persisted `String` and the
    /// strongly-typed enum the picker uses internally. Bad / missing
    /// values collapse to `.single` (mirrors `RecordingController`'s
    /// `loadTranscriptionMode` behaviour).
    private var modeBinding: Binding<LiveTranscriptionMode> {
        Binding(
            get: { LiveTranscriptionMode(rawValue: modeRaw) ?? .single },
            set: { modeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker(String(localized: "Mode"), selection: modeBinding) {
            Text("Single").tag(LiveTranscriptionMode.single)
            Text("Dual").tag(LiveTranscriptionMode.dual)
        }
        .pickerStyle(.segmented)
        .help(String(localized: "Switch between single-provider and dual-provider live transcription."))
    }
}
