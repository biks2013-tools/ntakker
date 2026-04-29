// macrec-ui/RootView.swift — see project-design.md §15.1, §15.2,
// §15.4 and plan-002-toolbar-ui.md §3 Phase E.
//
// Top-level SwiftUI body that the `NSPopover` hosts via
// `NSHostingController<RootView>`.
//
// PHASE E — composes the real popover form. Every sub-view lives in
// `Sources/macrec-ui/Views/` and reads
// `@Environment(\.recordingController)` to pull state from the shared
// `RecordingController`. The popover is small (~360 pt wide); the form
// is a vertical stack with row-shaped composite cells.
//
// Layout (top-to-bottom):
//   0. ErrorBanner                  — only when latestError != nil
//                                     (Phase G; self-conditions, returns
//                                     EmptyView when no error)
//   1. PermissionStatusView         — top-of-popover indicator block
//   2. FilenameField + FormatPicker — composed in one row
//   3. LayoutPicker + FolderPicker  — composed in one row
//   4. MicrophonePicker             — full-width row
//   5. LevelMeterView               — only while recording / paused
//   6. ElapsedTimeView              — only while recording / paused
//   7. ControlBar                   — always visible
//   8. SavedToDisclosure            — only when segments non-empty
//
// Per the design (§15.12 Threading): every view is implicitly
// `@MainActor` (SwiftUI default on macOS 14+); no explicit annotation
// is required on the view itself. The environment-supplied
// `RecordingController` is itself `@MainActor`-isolated so any reads
// here are safe.
//
// Phase F (quit-while-recording) and Phase G (error mapping) both edit
// this file. To keep merge-friendly, Phase E confines its changes to:
//   * replacing the body composition;
//   * keeping the `@Environment(\.recordingController)` declaration in
//     the same position so Phase F/G's environment additions can sit
//     beside it without conflicts.

import MacrecUIKit
import SwiftUI

/// Top-level popover content view. Hosted by
/// `PopoverController.popover.contentViewController =
/// NSHostingController<RootView>(rootView: RootView())`.
struct RootView: View {
    @Environment(\.recordingController) private var recordingController

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

    /// Whether the transcription disclosure-group is expanded.
    /// Persisted so the user's last preference is remembered across
    /// popover open/close and app restarts.
    @AppStorage("com.macrec.ui.transcriptionExpanded")
    private var transcriptionExpanded: Bool = false

    /// Whether the new Recording-settings (format/layout/folder)
    /// disclosure-group is expanded. Default `false` so the popover
    /// stays compact on first launch — the user's most-frequent
    /// settings (Filename + Live transcription) remain at top level.
    @AppStorage("com.macrec.ui.recordingSettingsExpanded")
    private var recordingSettingsExpanded: Bool = false

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
        // The popover content is split into THREE bands so the
        // lifecycle controls always remain visible regardless of how
        // much vertical space the configuration / live-meter / live-
        // transcript sections consume:
        //
        //   1. Top band — `ErrorBanner` + `PermissionStatusView`. Pinned
        //      so a missing-permission error is never scrolled away.
        //   2. Middle band — every configuration/live-data view, wrapped
        //      in a `ScrollView` so it can grow without pushing the
        //      bottom band off-screen. `maxHeight` on the outer frame
        //      caps the popover's natural size; once exceeded, the
        //      ScrollView takes over.
        //   3. Bottom band — `ControlBar` (Start/Pause/Resume/Stop/Split)
        //      plus the optional `SavedToDisclosure`. Pinned so the user
        //      can ALWAYS reach Stop while a recording is in flight.
        //
        // The bug this fixes: adding the language picker pushed the
        // `ControlBar` past the popover's visible area while a recording
        // was active, leaving the user with no way to stop. Sticky
        // bottom + scrollable middle is the standard mac-app pattern
        // for the same constraint.
        VStack(spacing: 0) {
            // -- Top band (always visible) --
            VStack(alignment: .leading, spacing: 12) {
                ErrorBanner()
                    .animation(
                        .easeInOut(duration: 0.2),
                        value: recordingController?.latestError != nil
                    )

                PermissionStatusView()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Divider()
                .padding(.top, 12)

            // -- Compact controls (intrinsic vertical height) --
            // Filename, the two disclosure groups, microphone, and
            // (when recording) the live-stats rows. NO ScrollView —
            // the user explicitly asked that these controls stay
            // FULLY VISIBLE at all times. They take their intrinsic
            // vertical height; expanding `Recording settings` or
            // `Live transcription` makes the section taller and
            // shrinks the transcript accordingly. `.fixedSize(...)`
            // pins the vertical axis to intrinsic so the parent
            // VStack does not stretch this block to absorb the
            // popover surplus — that is the transcript panel's job.
            VStack(alignment: .leading, spacing: 12) {
                // Filename stays at the top level so the user
                // always sees the next-recording name without
                // expanding anything (per the user instruction:
                // only Format/Layout/Folder go in the new group).
                FilenameField()

                // -- Recording settings (collapsible) --
                // Format / Layout / Folder live here, stacked
                // vertically. The expanded/collapsed state is
                // persisted via @AppStorage.
                DisclosureGroup(
                    String(localized: "Recording settings"),
                    isExpanded: $recordingSettingsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        FormatPicker()
                        LayoutPicker()
                        FolderPicker()
                    }
                    .padding(.top, 4)
                }

                MicrophonePicker()

                // -- Live transcription (plan-003 Phase G; design §LT-8.1) --
                DisclosureGroup(
                    String(localized: "Live transcription"),
                    isExpanded: $transcriptionExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        TranscriptionPicker()
                        if transcribeProviderRaw != "none" {
                            TranscriptionSourcePicker()
                            TranscriptionFormatPicker()
                            // Plan-005 Phase H follow-up: language picker
                            // for the on-device Apple Speech provider (also
                            // surfaces the primary hint to Gemini, which
                            // honors only the first hint as a prompt-side
                            // language note).
                            TranscriptionLanguagePicker()
                            // Gemini API key — visible only when the
                            // picker selects a Gemini variant. Persists
                            // GOOGLE_API_KEY to ~/.tool-agents/macrec-ui/.env
                            // (mode 0600) and pushes it into the running
                            // process so the very next Start picks it up.
                            GeminiKeyField()
                        }
                    }
                    .padding(.top, 4)
                }
                .onChange(of: transcribeProviderRaw) { _, newValue in
                    // Privacy gate: when the user flips the picker into a
                    // CLOUD-touching provider AND has not yet acknowledged
                    // the disclosure, present the modal sheet. Apple Speech
                    // is on-device, so it does not need the disclosure
                    // (plan-005 Phase H).
                    if Self.isCloudProvider(newValue),
                       !privacyAcknowledged
                    {
                        showPrivacySheet = true
                    }
                }

                if showsLiveStats {
                    Divider()
                    LevelMeterView()
                    ElapsedTimeView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Pin the vertical axis to the controls' intrinsic
            // height so the surrounding VStack does not steal extra
            // popover space and put it here as empty padding. The
            // transcript band below is the ONLY view with
            // `.frame(maxHeight: .infinity)` and therefore receives
            // 100% of the surplus.
            .fixedSize(horizontal: false, vertical: true)

            // -- Flexible transcript band --
            // Receives 100% of the surplus popover height because
            // it is the only sibling with `.frame(maxHeight:
            // .infinity)`. Shrinks automatically when the controls
            // above get taller (user expands a disclosure group) or
            // when the user drags the resize handle to make the
            // popover smaller. The inner ScrollView already has its
            // own `minHeight: 80` floor so the transcript stays
            // legible even when squeezed.
            LiveTranscriptPanel()
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)

            // Cost / latency footer — pinned just above the bottom
            // band so it stays visible while the transcript scrolls.
            TranscriptionMetricsView()
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            Divider()

            // -- Bottom band (always visible) --
            VStack(alignment: .leading, spacing: 12) {
                ControlBar()

                if showsSavedDisclosure {
                    Divider()
                    SavedToDisclosure()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // -- Resize handle (vertical resize, persisted height) --
            ResizeHandle(height: $popoverHeight)
        }
        .frame(width: 360)
        // Vertical resize: explicit height bound to the persisted
        // `@AppStorage` slot. The user drags `ResizeHandle` (above)
        // to update it; `PopoverController` observes the same
        // UserDefaults key and pushes the value onto
        // `NSPopover.contentSize` so the popover frame actually
        // grows/shrinks. Clamp matches `ResizeHandle.minHeight` /
        // `.maxHeight`. `alignment: .top` pins the inner VStack to
        // the top of the frame as a defence against
        // `.center`-default behaviour — without it, when the inner
        // VStack content is shorter than the frame (e.g. transcript
        // panel returns nothing), SwiftUI vertically centres the
        // content and we get empty padding above and below.
        .frame(
            height: min(max(popoverHeight, ResizeHandle.minHeight), ResizeHandle.maxHeight),
            alignment: .top
        )
        .sheet(isPresented: $showPrivacySheet) {
            PrivacyDisclosureSheet(
                onAcknowledge: {
                    privacyAcknowledged = true
                    showPrivacySheet = false
                },
                onCancel: {
                    // Reset the picker to the on-device Apple Speech
                    // provider (plan-005 Phase H). Falling back to the
                    // safe default lets the user continue transcribing
                    // locally without sending audio off-device.
                    transcribeProviderRaw = "apple"
                    showPrivacySheet = false
                }
            )
        }
    }

    /// Live stats (level meters + elapsed clock) appear while there is
    /// an active or paused session. Phases F/G are not affected by
    /// this gate — they only mutate the alert / quit pipeline.
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

    /// Plan-005 Phase H: cloud-touching providers that require the
    /// privacy disclosure to be acknowledged before they can run.
    /// `"apple"` is on-device and excluded; the deprecated alias
    /// `"gemini-live"` is treated the same as `"gemini"` so users
    /// upgrading from a previous release also see the sheet.
    private static func isCloudProvider(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "gemini", "gemini-live":
            return true
        default:
            return false
        }
    }
}
