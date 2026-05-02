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

    /// Plan-010 Lane L-12 (Phase J / §DT-11): the live-transcription
    /// mode raw value, mirrored from the same `@AppStorage` slot driven
    /// by `TranscriptionModeSwitch` (L-7). Read here so the Start-tap
    /// guard below can branch on Single vs Dual without going through
    /// `RecordingController.transcriptionMode` (which is itself a
    /// mirror of this same key, but observing AppStorage directly keeps
    /// the gate reactive without a `Notification` round-trip).
    @AppStorage(RecordingController.transcriptionModeStorageKey)
    private var transcriptionModeRaw: String = LiveTranscriptionMode.single.rawValue

    /// Plan-010 Lane L-12: which provider id the dual-mode disclosure
    /// guard intercepted at Start-tap. `nil` when no dual-mode guard is
    /// active. When non-nil, the privacy sheet's `selectedProvider`
    /// renders this id (always `"apple-cloud"` in v1, since Channel B is
    /// the only cloud channel in dual mode and on-device Channel A
    /// (`apple`) needs no disclosure). Drives the `onAcknowledge` /
    /// `onCancel` branches in the `.sheet` block so dual-mode acceptance
    /// persists under the correct per-provider key and dual-mode cancel
    /// does NOT mutate `transcribeProviderRaw` (which is a single-mode
    /// concern).
    @State private var dualModeDisclosureProvider: String? = nil

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
                .onChange(of: recordingController?.state) { oldValue, newValue in
                    // Plan-010 Lane L-12 (Phase J / §DT-11) — Start-tap
                    // guard for Dual mode. The single-mode privacy
                    // disclosure trigger above fires on provider-pick
                    // (`.onChange(of: transcribeProviderRaw)`), but
                    // dual-mode flips no provider — the user just
                    // toggles `transcriptionMode = .dual` and clicks
                    // Start. §DT-11 requires the disclosure to fire on
                    // Start-tap (NOT on mode toggle alone — the user
                    // must be allowed to preview the dual panel without
                    // committing to apple-cloud disclosure).
                    //
                    // The actual Start tap lives in
                    // `ControlBar.startTapped()` (which is L-6
                    // territory and is intentionally not modified by
                    // L-12 — `ControlBar` already landed in Wave 4 and
                    // L-12 must touch a disjoint file set). We
                    // therefore observe the controller's state
                    // transition from `.idle / .stopped / .failed`
                    // (the showsStart-true set per ControlBar:174-181)
                    // into `.starting` or `.recording`, which uniquely
                    // signals "Start was just pressed".
                    //
                    // When that transition fires AND the active mode is
                    // `.dual` AND apple-cloud has NOT been acknowledged
                    // for this user (single OR dual — the per-provider
                    // key is shared, per DT-ADR-12), we:
                    //
                    //   1. Stop the recording immediately via
                    //      `controller.stop()` so no audio reaches
                    //      Apple's cloud servers before the user has
                    //      seen the disclosure.
                    //   2. Present the existing PrivacyDisclosureSheet
                    //      with `selectedProvider: "apple-cloud"` —
                    //      verbatim copy per IP-15 / DT-ADR-12.
                    //   3. On accept, persist the per-provider key.
                    //      The user re-clicks Start to begin recording.
                    //   4. On cancel, no key is persisted and the
                    //      recording stays stopped.
                    //
                    // Channel A (`apple` on-device) does NOT need a
                    // disclosure (no current single-mode `apple`
                    // disclosure exists; the on-device path has no
                    // privacy implications).
                    guard let oldValue, let newValue else { return }
                    let wasIdle: Bool = {
                        switch oldValue {
                        case .idle, .stopped, .failed: return true
                        default: return false
                        }
                    }()
                    let isStarting: Bool = {
                        switch newValue {
                        case .starting, .recording: return true
                        default: return false
                        }
                    }()
                    guard wasIdle, isStarting else { return }

                    let mode = LiveTranscriptionMode(rawValue: transcriptionModeRaw) ?? .single
                    guard mode == .dual else { return }

                    // Channel B is always `apple-cloud` in v1 (DT-ADR-12).
                    let providerId = "apple-cloud"
                    if !Self.hasAcknowledged(provider: providerId) {
                        recordingController?.stop()
                        dualModeDisclosureProvider = providerId
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
            width:  min(max(popoverWidth,  ResizeHandle.minWidth),  ResizeHandle.maxWidth)
        )
        .frame(
            height: min(max(popoverHeight, ResizeHandle.minHeight), ResizeHandle.maxHeight),
            alignment: .top
        )
        .sheet(isPresented: $showPrivacySheet) {
            // Plan-010 Lane L-12 (Phase J / §DT-11): when the dual-mode
            // Start-tap guard armed `dualModeDisclosureProvider`, the
            // sheet renders THAT provider's copy (always `apple-cloud`
            // in v1) and routes accept / cancel through dual-mode
            // branches that do NOT mutate `transcribeProviderRaw`
            // (which is a Single-mode picker concern). Otherwise the
            // sheet renders the existing Single-mode flow verbatim.
            if let dualProvider = dualModeDisclosureProvider {
                PrivacyDisclosureSheet(
                    selectedProvider: dualProvider,
                    onAcknowledge: {
                        Self.persistAcknowledgement(for: dualProvider)
                        // Leave `privacyAcknowledged` (the legacy
                        // single-bool back-compat slot) untouched —
                        // the per-provider key is the source of truth
                        // post-plan-007 and the legacy slot is migrated
                        // by `PrivacyDisclosureViewModel` only for the
                        // Gemini flow.
                        showPrivacySheet = false
                        dualModeDisclosureProvider = nil
                        // The recording was stopped by the guard; the
                        // user must re-click Start to begin recording.
                    },
                    onCancel: {
                        // Do NOT mutate `transcribeProviderRaw` — that
                        // is a Single-mode concern. Dual mode reverts
                        // to "no recording" by leaving the controller
                        // in its post-`.stop()` state. The user can
                        // toggle back to Single mode or re-open the
                        // disclosure on the next Start.
                        showPrivacySheet = false
                        dualModeDisclosureProvider = nil
                    }
                )
            } else {
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
