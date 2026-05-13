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
//     re-activated 2026-05-02 to drive the new collapsibility of the
//     General + Live Transcription sections (chevron + tap-to-toggle).
//     Default `true` preserves the post-plan-008 default of "both
//     sections expanded" so an existing user sees no change on upgrade.
//   * `transcribeProvider` and `privacyAcknowledged` continue to drive
//     the cloud-provider privacy disclosure flow.
//
// Per the design (§15.12 Threading): every view is implicitly
// `@MainActor` (SwiftUI default on macOS 14+); no explicit annotation
// is required on the view itself. The environment-supplied
// `RecordingController` is itself `@MainActor`-isolated so any reads
// here are safe.

import AppKit
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

    /// Whether the Live Transcription section body is expanded.
    /// Re-activated 2026-05-02 — the section header now exposes a
    /// chevron + tap-to-toggle that drives this binding. Default `true`
    /// preserves the post-plan-008 default of "both sections expanded"
    /// for users upgrading from a build that ignored the slot.
    @AppStorage("com.macrec.ui.transcriptionExpanded")
    private var transcriptionExpanded: Bool = true

    /// Whether the General section body is expanded. Same lifecycle
    /// notes as `transcriptionExpanded` above — re-activated to drive
    /// the new collapsibility, default `true` to preserve UX.
    @AppStorage("com.macrec.ui.recordingSettingsExpanded")
    private var recordingSettingsExpanded: Bool = true

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

    /// User-chosen popover width (horizontal resizable popover, added
    /// plan-008-followup-1). The `ResizeHandle` at the bottom of the
    /// popover applies horizontal drag translation to this binding;
    /// `PopoverController` observes the key and pushes the new
    /// `NSPopover.contentSize.width` so the AppKit frame grows/shrinks.
    /// Default 420 matches `PopoverController.defaultWidth` so first-run
    /// users see the same width as before this feature landed.
    @AppStorage(RootView.popoverWidthKey)
    private var popoverWidth: Double = 420

    /// UserDefaults key for the persisted popover width. Same exposure
    /// pattern as `popoverHeightKey`.
    static let popoverWidthKey = "com.macrec.ui.popoverWidth"

    /// Reserved space above and below the popover body when fitting it
    /// to the current screen's `visibleFrame`. The vertical reserve
    /// covers the popover's callout arrow (~13pt) plus a small gap so
    /// the resize handle stays hit-testable even with the Dock pinned
    /// to "always show". The horizontal reserve is a symmetric edge
    /// margin so the popover does not abut the screen edges.
    private static let screenVerticalReserve: CGFloat = 40
    private static let screenHorizontalReserve: CGFloat = 16

    /// Compute the popover height for the current render, clamped
    /// against `ResizeHandle`'s min/max AND the active screen's
    /// `visibleFrame.height` minus `screenVerticalReserve`. Falls back
    /// to the static `ResizeHandle.maxHeight` cap when no screen can
    /// be resolved (extremely unusual). Pure function — re-evaluated
    /// on every body render, so a popover re-shown on a smaller
    /// display picks up the tighter cap automatically.
    static func fittedHeight(_ requested: Double) -> CGFloat {
        let screenCap: CGFloat = {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                return ResizeHandle.maxHeight
            }
            return max(ResizeHandle.minHeight, screen.visibleFrame.height - screenVerticalReserve)
        }()
        let staticCap = min(ResizeHandle.maxHeight, screenCap)
        return min(max(CGFloat(requested), ResizeHandle.minHeight), staticCap)
    }

    /// Sibling of `fittedHeight(_:)` for the horizontal axis.
    static func fittedWidth(_ requested: Double) -> CGFloat {
        let screenCap: CGFloat = {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                return ResizeHandle.maxWidth
            }
            return max(ResizeHandle.minWidth, screen.visibleFrame.width - screenHorizontalReserve)
        }()
        let staticCap = min(ResizeHandle.maxWidth, screenCap)
        return min(max(CGFloat(requested), ResizeHandle.minWidth), staticCap)
    }

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
                    // Quit button (added 2026-05-02). Routes through
                    // `NSApp.terminate(_:)` so AppKit calls
                    // `applicationShouldTerminate(_:)`, which delegates
                    // to the existing `QuitFlow` (project-design §15.11)
                    // and presents the "Stop & Quit?" confirmation alert
                    // when a recording is in flight. Idle state quits
                    // immediately.
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .imageScale(.medium)
                            .foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q", modifiers: .command)
                    .help(String(localized: "Quit macrec-ui (⌘Q) — confirms before stopping an active recording"))
                    .accessibilityLabel(String(localized: "Quit"))
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
                PopoverSection(
                    title: "General",
                    isExpanded: $recordingSettingsExpanded
                ) {
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
                    isExpanded: $transcriptionExpanded,
                    header: {
                        LiveTranscriptionSectionHeader(
                            isExpanded: $transcriptionExpanded
                        )
                    }
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

            ResizeHandle(width: $popoverWidth, height: $popoverHeight)
        }
        .frame(
            width:  Self.fittedWidth(popoverWidth)
        )
        .frame(
            height: Self.fittedHeight(popoverHeight),
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
        case "gemini", "gemini-live", "soniox", "azure", "azure-openai-realtime", "elevenlabs", "apple-cloud":
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
