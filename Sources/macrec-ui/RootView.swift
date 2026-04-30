// macrec-ui/RootView.swift — see project-design.md §UR-5 (layout
// architecture), §UR-4.5..§UR-4.13 (composed view contracts), and
// plan-008 §E (central composition root).
//
// Top-level SwiftUI body that the `NSPopover` hosts via
// `NSHostingController<RootView>`. Composition root for the new
// popover layout: the legacy DisclosureGroup-based form is replaced
// by an inset-grouped Form (UR-ADR-1) inside a three-band frame:
//
//   1. Pinned top    — `ErrorBanner` + `PopoverHeader` (filename
//                      title + metadata strip + optional permissions).
//   2. Flexible mid  — General + Live Transcription `Form` sections
//                      (intrinsic height) + `LiveTranscriptPanel`
//                      (claims residual via `.frame(maxHeight:.infinity)`)
//                      + transient level-meter / clock when recording.
//   3. Pinned bottom — `PopoverFooter` (ReadyPill + ControlBar) +
//                      `SavedToDisclosure` + `ResizeHandle`.
//
// Elasticity invariant (§UR-5): the Form sections carry
// `.fixedSize(horizontal: false, vertical: true)` so the
// `LiveTranscriptPanel` is the only sibling claiming
// `.frame(maxHeight: .infinity)`. The bottom band is therefore always
// visible while the user resizes the popover via `ResizeHandle`.
//
// Unit E preserves every existing `@AppStorage` declaration even when
// the new layout no longer reads from it (UR-ADR-10):
//   * `transcriptionExpanded` and `recordingSettingsExpanded` are
//     orphaned but retained so a downgrade to v1.5 still finds them.
//   * `transcribeProvider` and `privacyAcknowledged` continue to drive
//     the cloud-provider privacy disclosure flow.
//
// Per the design (§15.12 Threading): every view is implicitly
// `@MainActor` (SwiftUI default on macOS 14+); no explicit annotation
// is required on the view itself. The environment-supplied
// `RecordingController` is itself `@MainActor`-isolated so any reads
// here are safe.

import MacrecCore
import MacrecUIKit
import SwiftUI

/// Top-level popover content view. Hosted by
/// `PopoverController.popover.contentViewController =
/// NSHostingController<RootView>(rootView: RootView())`.
struct RootView: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    /// Persisted provider id (mirrored from `TranscriptionPicker`'s
    /// `@AppStorage` slot) so this view can decide whether to show
    /// the privacy disclosure on first opt-in. Default `"apple"` per
    /// plan-005 Phase H.
    @AppStorage("com.macrec.ui.transcribeProvider")
    private var transcribeProviderRaw: String = "apple"

    /// Acknowledged-flag for the privacy disclosure (per design
    /// §LT-8.2 / FR-53). Once flipped to `true`, never re-fires.
    @AppStorage(PrivacyDisclosureViewModel.userDefaultsKey)
    private var privacyAcknowledged: Bool = false

    /// Whether the privacy sheet is currently presented.
    @State private var showPrivacySheet: Bool = false

    /// Orphan-but-retained per UR-ADR-10. The new layout no longer
    /// reads this slot; the keys remain in `UserDefaults` so a
    /// downgrade to v1.5 finds them.
    @AppStorage("com.macrec.ui.transcriptionExpanded")
    private var transcriptionExpanded: Bool = false

    /// Orphan-but-retained per UR-ADR-10 (see above).
    @AppStorage("com.macrec.ui.recordingSettingsExpanded")
    private var recordingSettingsExpanded: Bool = false

    /// Master enable/disable for live transcription (UR-ADR-7). Mirrored
    /// here from `ControlBar.swift` (Unit I declared the slot) +
    /// `LiveTranscriptionSectionHeader.swift` so the section visibility
    /// can update without an extra Binding round-trip. Default `true`
    /// preserves existing users' transcription on upgrade.
    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    /// User-chosen popover height (vertical resizable popover). The
    /// `ResizeHandle` at the bottom of the popover updates this via a
    /// drag gesture. `PopoverController` observes this same key (via
    /// `UserDefaults`) and pushes the value onto `NSPopover.contentSize`
    /// so the AppKit popover frame actually grows/shrinks.
    /// Default 600 matches the previous `maxHeight` cap so first-run
    /// users see no change.
    @AppStorage(RootView.popoverHeightKey)
    private var popoverHeight: Double = 600

    /// UserDefaults key for the persisted popover height. Exposed as a
    /// public-static constant so `PopoverController` can subscribe to
    /// the same key without re-deriving the string.
    static let popoverHeightKey = "com.macrec.ui.popoverHeight"

    var body: some View {
        VStack(spacing: 0) {

            // ============ TOP BAND (pinned, never scrolls) ============
            VStack(alignment: .leading, spacing: 10) {
                ErrorBanner()
                    .animation(
                        .easeInOut(duration: 0.2),
                        value: recordingController?.latestError != nil
                    )

                PopoverHeader(stateLabel: stateLabel) {
                    AppearanceSwitcher()
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .imageScale(.medium)
                            .foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Open Settings (⌘,) — manage cloud-provider API keys and tuning"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // ============ MIDDLE BAND ============
            // Two intrinsically-sized `Form` sections + the elastic
            // transcript panel. The Form's `.fixedSize(...)` modifier
            // keeps the LiveTranscriptPanel's `.frame(maxHeight:.infinity)`
            // as the sole claimer of residual vertical space (§UR-5).
            VStack(alignment: .leading, spacing: 14) {
                // -- General section --
                PopoverSection(title: "General") {
                    Form {
                        GeneralSection()
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollContentBackground(.hidden)
                }

                // -- Live Transcription section --
                PopoverSection(
                    header: { LiveTranscriptionSectionHeader() }
                ) {
                    Form {
                        LiveTranscriptionSection()
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollContentBackground(.hidden)
                }
                .onChange(of: transcribeProviderRaw) { _, newValue in
                    // Privacy gate (per-provider acknowledgement per
                    // plan-007 Task 0.3): present the disclosure modal
                    // when the user flips into a cloud provider that
                    // has not been acknowledged yet. Apple Speech /
                    // WhisperKit are on-device and skip the gate.
                    let normalised = Self.normalize(newValue)
                    if Self.isCloudProvider(normalised),
                       !Self.hasAcknowledged(provider: normalised)
                    {
                        showPrivacySheet = true
                    }
                }

                // -- Live transcript streaming panel --
                LiveTranscriptPanel()
                    .frame(maxHeight: .infinity)

                // -- Transient live-stats: meter + elapsed clock --
                if showsLiveStats {
                    VStack(alignment: .leading, spacing: 6) {
                        LevelMeterView()
                        ElapsedTimeView()
                    }
                    .transition(.opacity)
                }

                // -- Cost / latency footer --
                TranscriptionMetricsView()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            // ============ BOTTOM BAND (pinned, never scrolls) ============
            PopoverFooter()

            if showsSavedDisclosure {
                Divider()
                    .overlay(palette.separator)
                SavedToDisclosure()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            ResizeHandle(height: $popoverHeight)
        }
        .frame(width: 360)
        .frame(
            height: min(max(popoverHeight, ResizeHandle.minHeight), ResizeHandle.maxHeight),
            alignment: .top
        )
        .sheet(isPresented: $showPrivacySheet) {
            PrivacyDisclosureSheet(
                selectedProvider: Self.normalize(transcribeProviderRaw),
                onAcknowledge: {
                    let provider = Self.normalize(transcribeProviderRaw)
                    Self.persistAcknowledgement(for: provider)
                    privacyAcknowledged = true
                    showPrivacySheet = false
                },
                onCancel: {
                    transcribeProviderRaw = "apple"
                    showPrivacySheet = false
                }
            )
        }
    }

    // MARK: - Derived state

    /// Live stats (level meters + elapsed clock) appear while there is
    /// an active or paused session.
    private var showsLiveStats: Bool {
        guard let state = recordingController?.state else { return false }
        switch state {
        case .recording, .paused, .pausing, .resuming, .splitting, .stopping:
            return true
        default:
            return false
        }
    }

    /// Saved-files disclosure appears only when segments have been
    /// produced. The disclosure view itself also no-ops on empty.
    private var showsSavedDisclosure: Bool {
        !(recordingController?.completedSegments.isEmpty ?? true)
    }

    /// Human-readable state label rendered into `MetadataStrip`.
    private var stateLabel: String {
        guard let state = recordingController?.state else { return String(localized: "Idle") }
        switch state {
        case .idle, .stopped:    return String(localized: "Idle")
        case .starting:          return String(localized: "Starting…")
        case .recording:         return String(localized: "Recording")
        case .pausing:           return String(localized: "Pausing…")
        case .paused:            return String(localized: "Paused")
        case .resuming:          return String(localized: "Resuming…")
        case .splitting:         return String(localized: "Splitting…")
        case .stopping:          return String(localized: "Stopping…")
        case .failed:            return String(localized: "Error")
        }
    }

    // MARK: - Privacy / cloud provider helpers
    // (Preserved verbatim from the legacy RootView so the privacy gate
    // semantics survive the layout refactor unchanged.)

    /// Cloud-touching providers that require the privacy disclosure to
    /// be acknowledged. `"apple"` and `"whisperkit"` are on-device.
    private static func isCloudProvider(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "gemini", "gemini-live", "soniox", "azure", "azure-openai-realtime", "elevenlabs":
            return true
        default:
            return false
        }
    }

    /// Lowercase + trim — defensive normalisation against drifted
    /// persisted values.
    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Per-provider acknowledgement check, with a back-compat read of
    /// the legacy single boolean for the Gemini and Soniox paths so a
    /// user upgrading does not see the dialog twice.
    private static func hasAcknowledged(provider: String) -> Bool {
        let key = PrivacyDisclosureViewModel.acknowledgedKey(for: provider)
        if UserDefaults.standard.bool(forKey: key) { return true }
        if provider == "gemini" {
            return UserDefaults.standard.bool(forKey: PrivacyDisclosureViewModel.userDefaultsKey)
        }
        if provider == "soniox" {
            return UserDefaults.standard.bool(forKey: PrivacyDisclosureViewModel.sonioxUserDefaultsKey)
        }
        return false
    }

    private static func persistAcknowledgement(for provider: String) {
        UserDefaults.standard.set(
            true,
            forKey: PrivacyDisclosureViewModel.acknowledgedKey(for: provider)
        )
    }
}
