// macrec-ui/Views/Transcription/Dual/DualTranscriptionControls.swift —
// plan-010 Phase F (Lane L-8); see project-design §DT-8 (UI design,
// "Dual mode panel" sub-section) and §DT-9 (AppStorage keys table).
//
// Dual-mode live-transcription control set. Composed inside
// `LiveTranscriptionSection` when the segmented mode switch is on
// "Dual". Layout (top-to-bottom) per the §DT-8 ASCII mockup:
//
//   1. Source picker (Mixed / Microphone / System / Both) bound to
//      `@AppStorage("com.macrec.ui.dual.source")` — DISJOINT from
//      single-mode `transcribeSource` per AC-2 / DT-ADR-13. Toggling
//      Single↔Dual MUST round-trip Single-mode state verbatim, which
//      requires zero key collision.
//
//   2. Channel A row — small "EN · Channel A — Apple (on-device)"
//      caption + `DualLocalePicker` constrained to
//      `DualLocaleSets.channelASupportedLocales` (~42 locales, NO
//      Greek). Bound to `@AppStorage("com.macrec.ui.dual.channelALocale")`
//      with default `"en-US"`. Inline error display (FR-4) renders
//      under the picker when `RecordingController.dualChannelErrors[.channelA]`
//      is non-nil.
//
//   3. Channel B row — small "EL · Channel B — Apple Cloud" caption +
//      `DualLocalePicker` constrained to `DualLocaleSets.channelBSupportedLocales`
//      (~57 locales, INCLUDES Greek). Bound to
//      `@AppStorage("com.macrec.ui.dual.channelBLocale")` with default
//      `"el-GR"`. Inline error display analogous to Channel A.
//
//   4. Sidecar format picker (jsonl / srt / vtt / txt) bound to
//      `@AppStorage("com.macrec.ui.dual.transcriptFormat")` — DISJOINT
//      from single-mode `transcriptFormat` per the same AC-2 reasoning.
//
//   5. `DualTranscriptionMetricsView()` — per-channel metrics footer
//      owned by Lane L-11 (Wave 5). Reads `RecordingController.dualMetrics`
//      and renders `EmptyView()` until the metrics-poll wiring lands
//      (see `PLAN-010-PENDING-L11-WIRING`). Embedded as the last row
//      of this view per the L-11 frozen contract (no-arg init).
//
// Channel-A locale-set fragility (plan-010 §DT-13 lane notes):
// the Channel A picker MUST source from
// `DualLocaleSets.channelASupportedLocales` — NEVER
// `SFSpeechRecognizer.supportedLocales()`. A user picking Greek for
// the on-device English channel would silently fail at session-open
// inside `DualTranscriptionConfig.init`. Enforced at the construction
// site below — `DualLocalePicker` does NOT consult any locale source
// itself; the array is INJECTED by the caller.
//
// AC-2 (round-trip Single↔Dual preserves single-mode state) is
// verified at the key-string level by §DT-9's collision check: every
// dual-mode key uses the `com.macrec.ui.dual.*` prefix; every
// single-mode key uses the `com.macrec.ui.transcribe*` /
// `com.macrec.ui.transcript*` prefixes. The two sets are disjoint.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Dual-mode live-transcription control set. Renders the source /
/// channel-A locale / channel-B locale / format rows, with per-channel
/// inline error display.
struct DualTranscriptionControls: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    // MARK: - Persisted dual-mode preferences (DT-9 / DT-ADR-13)

    /// Channel A (Apple on-device) locale identifier. Default `"en-US"`.
    /// Bad / missing values are caught at `DualTranscriptionConfig.init`
    /// time per the project's no-fallback rule.
    @AppStorage("com.macrec.ui.dual.channelALocale")
    private var channelALocaleRaw: String = "en-US"

    /// Channel B (Apple Cloud) locale identifier. Default `"el-GR"`.
    @AppStorage("com.macrec.ui.dual.channelBLocale")
    private var channelBLocaleRaw: String = "el-GR"

    /// Audio source for Dual mode. Independent of single-mode
    /// `com.macrec.ui.transcribeSource` per AC-2 / DT-ADR-13.
    @AppStorage("com.macrec.ui.dual.source")
    private var sourceRaw: String = TranscriptionSource.mixed.rawValue

    /// Sidecar transcript format for Dual mode. Independent of single-
    /// mode `com.macrec.ui.transcriptFormat` per AC-2 / DT-ADR-13.
    @AppStorage("com.macrec.ui.dual.transcriptFormat")
    private var formatRaw: String = TranscriptFormat.jsonl.rawValue

    // MARK: - Derived state

    private var isLocked: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .idle, .stopped, .failed:
            return false
        default:
            return true
        }
    }

    private var sourceBinding: Binding<TranscriptionSource> {
        Binding(
            get: { TranscriptionSource(rawValue: sourceRaw) ?? .mixed },
            set: { sourceRaw = $0.rawValue }
        )
    }

    private var formatBinding: Binding<TranscriptFormat> {
        Binding(
            get: { TranscriptFormat(rawValue: formatRaw) ?? .jsonl },
            set: { formatRaw = $0.rawValue }
        )
    }

    private var channelAError: String? {
        recordingController?.dualChannelErrors[.channelA]
    }

    private var channelBError: String? {
        recordingController?.dualChannelErrors[.channelB]
    }

    // MARK: - Body

    var body: some View {
        // 1. Source picker — first row of the §DT-8 mockup.
        Picker(String(localized: "Source"), selection: sourceBinding) {
            Text("System").tag(TranscriptionSource.system)
            Text("Microphone").tag(TranscriptionSource.mic)
            Text("Mixed").tag(TranscriptionSource.mixed)
            Text("Both").tag(TranscriptionSource.both)
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "Audio source fed into both transcription channels."))

        // 2. Channel A — Apple on-device. MUST use
        //    `DualLocaleSets.channelASupportedLocales` (NOT
        //    `SFSpeechRecognizer.supportedLocales()`).
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "EN · Channel A — Apple (on-device)"))
                .font(.caption)
                .foregroundStyle(palette.secondary)
            DualLocalePicker(
                label: String(localized: "Locale"),
                supportedLocales: DualLocaleSets.channelASupportedLocales,
                selection: $channelALocaleRaw,
                help: String(localized: "On-device locale for Channel A. Sourced from SpeechTranscriber.supportedLocales (~42 locales; does NOT include Greek).")
            )
            if let err = channelAError {
                channelErrorRow(err)
            }
        }

        // 3. Channel B — Apple Cloud. Uses the cloud-path locale set
        //    which DOES include Greek.
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "EL · Channel B — Apple Cloud"))
                .font(.caption)
                .foregroundStyle(palette.secondary)
            DualLocalePicker(
                label: String(localized: "Locale"),
                supportedLocales: DualLocaleSets.channelBSupportedLocales,
                selection: $channelBLocaleRaw,
                help: String(localized: "Cloud locale for Channel B. Sourced from SFSpeechRecognizer.supportedLocales() (~57 locales; includes Greek el-GR).")
            )
            if let err = channelBError {
                channelErrorRow(err)
            }
        }

        // 4. Sidecar transcript format — Dual-mode-specific slot
        //    (DISJOINT from single-mode `transcriptFormat`).
        Picker(String(localized: "Transcript format"), selection: formatBinding) {
            Text("jsonl").tag(TranscriptFormat.jsonl)
            Text("srt").tag(TranscriptFormat.srt)
            Text("vtt").tag(TranscriptFormat.vtt)
            Text("txt").tag(TranscriptFormat.txt)
        }
        .pickerStyle(.menu)
        .disabled(isLocked)
        .help(String(localized: "File format for the merged dual-channel sidecar transcript."))

        // 5. Lane L-11 per-channel metrics footer. Reads
        //    `RecordingController.dualMetrics`; renders `EmptyView()`
        //    until `PLAN-010-PENDING-L11-WIRING` is resolved.
        DualTranscriptionMetricsView()
    }

    // MARK: - Per-channel inline error row (FR-4)

    /// Renders an amber warning glyph + caption-style message under the
    /// affected channel's locale row. Mirrors the existing single-mode
    /// `lastTranscriptionError` styling in `LiveTranscriptPanel.swift`
    /// (orange triangle glyph + small secondary text) so the two
    /// surfaces feel consistent.
    @ViewBuilder
    private func channelErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .lineLimit(3)
        }
        .padding(.horizontal, 4)
    }
}
