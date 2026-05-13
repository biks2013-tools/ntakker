// macrec-ui/RootView.swift — see project-design.md §UR-5 (layout
// architecture), §UR-4.5..§UR-4.13 (composed view contracts), plan-008
// §E (central composition root), and **plan-015 Pattern C** (top
// segmented control + bottom status bar + post-stop Save/New-Session).
//
// Top-level SwiftUI body that the `NSPopover` hosts via
// `NSHostingController<RootView>`. Composition root, post-plan-015:
//
//   1. Pinned top    — `ErrorBanner` + `PopoverHeader` (filename
//                      title + metadata strip + optional permissions)
//                      + `PopoverModeSwitcher` (Transcription | Asking).
//   2. Flexible mid  — **mode-dependent body**:
//                      • Transcription mode: the legacy General +
//                        Live Transcription `Form` sections (engine &
//                        language collapsible, default-collapsed per
//                        FR-IRQ-44a) + `LiveTranscriptPanel` (claims
//                        residual via `.frame(maxHeight: .infinity)`).
//                      • Asking mode: `AskingModeView` — Q&A history
//                        scroll + persistent input row pinned bottom.
//   3. Pinned bottom — `PopoverStatusBar` (mic + sys bouncing bars,
//                      state pill, elapsed clock, action area
//                      Stop/[New Session/Save…] per FR-IRQ-48) +
//                      `SavedToDisclosure` (when segments exist) +
//                      `ResizeHandle`.
//
// The Stop / New Session / Save callbacks are owned here (not by the
// status bar) so all Pattern-C state machine transitions live in one
// place — the Save dialog presentation, the New-Session confirmation
// modal, and the `clearSession()` fade animation.

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

    /// In-memory Asking-mode history. UI-local in Phase 1; promoted to
    /// `MacrecCore.QASessionHistory` in Phase 4 so the floating overlay
    /// (Phase 5) can share the same source of truth.
    @StateObject private var askingStore = AskingSessionStore()

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

    /// Whether the Live Transcription ("Engine & Language") section
    /// body is expanded. plan-015 (FR-IRQ-44a) flips the fresh-launch
    /// default to **false** so the live transcript pane has the
    /// maximum vertical real-estate by default in Transcription mode.
    @AppStorage("com.macrec.ui.transcriptionExpanded")
    private var transcriptionExpanded: Bool = false

    /// Whether the General section body is expanded.
    @AppStorage("com.macrec.ui.recordingSettingsExpanded")
    private var recordingSettingsExpanded: Bool = true

    /// Master enable/disable for live transcription (UR-ADR-7).
    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    /// Pattern-C popover mode — Transcription (default) | Asking.
    /// plan-015 FR-IRQ-43. Backed by the public storage key
    /// `kPopoverModeStorageKey` declared in `PopoverModeSwitcher.swift`.
    @AppStorage(kPopoverModeStorageKey)
    private var popoverModeRaw: String = PopoverMode.transcription.rawValue

    /// User-chosen popover height (vertical resizable popover).
    @AppStorage(RootView.popoverHeightKey)
    private var popoverHeight: Double = 600

    static let popoverHeightKey = "com.macrec.ui.popoverHeight"

    /// plan-015 (FR-IRQ-59): default width raised to 480 so the new
    /// status-bar layout (mic + sys indicators + state pill + clock +
    /// `[ New Session ][ Save… ]` pair) fits without wrapping on first
    /// launch. Matches `PopoverController.defaultWidth`.
    @AppStorage(RootView.popoverWidthKey)
    private var popoverWidth: Double = 480

    static let popoverWidthKey = "com.macrec.ui.popoverWidth"

    /// plan-015 sheet presentation flags.
    @State private var showSaveDialog: Bool = false
    @State private var showNewSessionConfirm: Bool = false
    /// Brief opacity dip applied to the body when `clearSession()`
    /// fires (FR-IRQ-56 visible-fade signal).
    @State private var clearingFade: Bool = false
    /// When true, the next successful Save (Save dialog → confirm)
    /// chains into `clearSession()` per FR-IRQ-55 "Save and start new".
    /// Cleared after the cycle completes or the dialog is cancelled.
    @State private var pendingClearAfterSave: Bool = false

    /// plan-015 Phase 4 (FR-IRQ-18) — Q&A privacy gate state.
    /// Provider awaiting acknowledgement; non-nil presents the sheet.
    @State private var askPrivacyProvider: AskProvider?
    /// Q&A privacy view-model — bridge to `UserDefaults` keyspace.
    private let askPrivacyVM = AskPrivacyDisclosureViewModel()

    /// plan-015 Phase 2 — transient Save-result banner. Holds either
    /// the success URL (for the Finder-reveal tap) or a typed error
    /// message rendered inline in the popover footer.
    @State private var saveResult: SaveOutcome?

    /// Discriminated result of a Save attempt.
    fileprivate enum SaveOutcome: Equatable {
        case success(URL)
        case failure(String)
    }

    private static let screenVerticalReserve: CGFloat = 40
    private static let screenHorizontalReserve: CGFloat = 16

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

    /// Two-way binding into the persisted-mode raw string.
    private var modeBinding: Binding<PopoverMode> {
        Binding(
            get: { PopoverMode(rawValue: popoverModeRaw) ?? .transcription },
            set: { popoverModeRaw = $0.rawValue }
        )
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

                // plan-015 Pattern C — top segmented mode switch.
                PopoverModeSwitcher(selection: modeBinding)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // ============ MIDDLE BAND (mode-dependent body) ============
            body(for: modeBinding.wrappedValue)
                .opacity(clearingFade ? 0 : 1)
                .animation(.easeInOut(duration: 0.18), value: clearingFade)

            // Transient save-result banner (plan-015 Phase 2).
            if let outcome = saveResult {
                saveResultBanner(outcome)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }

            // ============ BOTTOM BAND (pinned, never scrolls) ============
            PopoverStatusBar(
                onStop: { recordingController?.stop() },
                onNewSession: { showNewSessionConfirm = true },
                onSave: { showSaveDialog = true }
            )

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
            width: Self.fittedWidth(popoverWidth)
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
        .sheet(isPresented: $showSaveDialog) {
            SaveSessionDialog(
                defaultFolderName: defaultSessionFolderName(),
                audioFilename: defaultAudioFilename(),
                onConfirm: { folderName in
                    showSaveDialog = false
                    performSessionSave(folderName: folderName)
                    if pendingClearAfterSave {
                        pendingClearAfterSave = false
                        clearSession()
                    }
                },
                onCancel: {
                    showSaveDialog = false
                    // Cancelling the Save dialog after a "Save and
                    // start new" choice MUST abort the chained restart
                    // — the user is signalling "actually, keep this
                    // session". Drop the pending flag silently.
                    pendingClearAfterSave = false
                }
            )
        }
        .sheet(isPresented: $showNewSessionConfirm) {
            NewSessionConfirmModal(
                onSaveAndStart: {
                    showNewSessionConfirm = false
                    pendingClearAfterSave = true
                    showSaveDialog = true
                },
                onDiscardAndStart: {
                    showNewSessionConfirm = false
                    clearSession()
                },
                onCancel: { showNewSessionConfirm = false }
            )
        }
        .sheet(item: $askPrivacyProvider) { provider in
            AskPrivacyDisclosureSheet(
                provider: provider,
                onAcknowledge: {
                    askPrivacyVM.acknowledge(provider)
                    askPrivacyProvider = nil
                    // The child holds the draft (it returned early in
                    // `submitDraft`). The user re-taps Send / presses
                    // Return to fire the submit now that the gate is
                    // closed — kept manual to avoid surprise submits.
                },
                onCancel: {
                    askPrivacyProvider = nil
                }
            )
        }
        // FR-IRQ-14 / FR-IRQ-15 — Q&A sidecar write on session stop.
        // Fired whenever the controller observes the `.stopped`
        // transition; the writer no-ops when there are no entries so
        // it's safe to run on every stop.
        .onChange(of: recordingController?.state) { _, newState in
            guard case .stopped = newState else { return }
            persistQASidecarIfNeeded()
        }
    }

    // MARK: - Q&A sidecar

    /// FR-IRQ-14 / FR-IRQ-15. Writes `<basename>.questions.jsonl`
    /// alongside the most-recent completed audio segment. No-ops when
    /// the user never asked anything. Persistence failures are logged
    /// but never propagate — the recording-integrity invariant is the
    /// priority.
    private func persistQASidecarIfNeeded() {
        let snapshot = askingStore.snapshotForSidecar()
        guard !snapshot.isEmpty else { return }
        guard let audioURL = recordingController?.completedSegments.last
                ?? recordingController?.options?.output
        else { return }

        // recording-start wall-clock — use `askedAt - elapsed` for the
        // FIRST question to derive an anchor, fall back to the entry's
        // own `askedAt` when nothing better is available.
        let entries: [QASidecarEntry] = snapshot.map { e in
            QASidecarEntry(
                recordingMs: Int(e.recordingTimestampSeconds * 1000),
                wallClock: e.askedAt,
                question: e.question,
                answer: e.answer,
                model: e.model ?? "(unresolved)",
                provider: e.provider?.rawValue ?? "(unresolved)",
                windowStart: e.windowStart,
                windowEnd: e.windowEnd
            )
        }

        if let err = QASessionSidecar.write(audioURL: audioURL, entries: entries) {
            // Surface as a recoverable, non-fatal error — does NOT walk
            // the session back into `.failed`.
            print("QA sidecar write failed: \(err.localizedDescription)")
        }
    }

    // MARK: - Session save (plan-015 Phase 2)

    /// Bundle the session (audio + transcript.md + qa.md + sidecars)
    /// into `~/Recordings/<folderName>/` and surface the result as a
    /// transient banner. Reveals the new folder in Finder on success.
    private func performSessionSave(folderName: String) {
        let segments     = recordingController?.transcriptSegments ?? []
        let qaSnapshot   = askingStore.snapshotForSidecar()
        let audioSources = recordingController?.completedSegments ?? []
        do {
            let result = try SessionExporter.write(
                folderName: folderName,
                transcript: segments,
                qaHistory: qaSnapshot,
                audioSources: audioSources
            )
            saveResult = .success(result.folder)
            // Reveal in Finder so the user sees the bundle.
            NSWorkspace.shared.activateFileViewerSelecting([result.folder])
            scheduleSaveBannerClear()
        } catch let error as SessionExporter.ExportError {
            saveResult = .failure(error.errorDescription ?? String(describing: error))
            scheduleSaveBannerClear()
        } catch {
            saveResult = .failure(error.localizedDescription)
            scheduleSaveBannerClear()
        }
    }

    @ViewBuilder
    private func saveResultBanner(_ outcome: SaveOutcome) -> some View {
        switch outcome {
        case .success(let folder):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "Saved to \(folder.lastPathComponent)"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.label)
                Spacer()
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([folder]) }) {
                    Text(String(localized: "Reveal in Finder"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                Button(action: { saveResult = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5)
            )
        case .failure(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { saveResult = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    private func scheduleSaveBannerClear() {
        let captured = saveResult
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if saveResult == captured { saveResult = nil }
        }
    }

    // MARK: - Mode-dependent body

    @ViewBuilder
    private func body(for mode: PopoverMode) -> some View {
        switch mode {
        case .transcription:
            transcriptionBody
        case .asking:
            AskingModeView(
                store: askingStore,
                requestPrivacyAck: { provider in
                    // FR-IRQ-18: gate the submit on a one-time per-provider
                    // acknowledgement. Return `true` to tell the child the
                    // parent will present the sheet (child holds the draft).
                    guard provider.isCloud else { return false }
                    if askPrivacyVM.hasAcknowledged(provider) { return false }
                    askPrivacyProvider = provider
                    return true
                }
            )
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
    }

    private var transcriptionBody: some View {
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

            // -- Live Transcription section (collapsed by default,
            //     plan-015 FR-IRQ-44a) --
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

            // -- Cost / latency footer --
            TranscriptionMetricsView()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - clearSession()

    /// plan-015 FR-IRQ-56 — reset the popover to its pre-record state
    /// and start a fresh recording. Sequence:
    ///   1. 180 ms fade-out of the body (visible-deliberate signal).
    ///   2. Mid-fade: clear Q&A history, re-collapse the engine row,
    ///      reset mode to Transcription, stop the previous recording if
    ///      one is still active.
    ///   3. Kick off a brand-new recording via
    ///      `RecordingStarter.start(controller:)` — this composes a
    ///      fresh `RecordingOptions` (re-derived basename / filename
    ///      defaults) so the elapsed clock resets to 00:00 automatically
    ///      (`RecordingController.start()` zeroes the elapsed counter
    ///      on the `.recording` transition).
    ///   4. Fade back in.
    private func clearSession() {
        withAnimation(.easeInOut(duration: 0.18)) {
            clearingFade = true
        }
        // Mutate the model while the panes are faded so the user does
        // not see the empty state pop in mid-fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            askingStore.clear()
            transcriptionExpanded = false
            popoverModeRaw = PopoverMode.transcription.rawValue

            // Bring the recording engine to a clean slate, then re-arm.
            // If the controller is still in an active state (the user
            // pressed New Session *while recording* via a future
            // shortcut), stop it first; otherwise start() would refuse.
            // Today the New-Session affordance is only reachable from
            // `.stopped`, but the guard is cheap and future-proofs the
            // shortcut path (Phase 5 global hotkey).
            if let controller = recordingController {
                switch controller.state {
                case .recording, .paused, .pausing, .resuming, .splitting:
                    controller.stop()
                default:
                    break
                }
                RecordingStarter.start(controller: controller)
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                clearingFade = false
            }
        }
    }

    // MARK: - Derived helpers

    /// Saved-files disclosure appears only when segments have been
    /// produced.
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

    /// Default folder name for a freshly-stopped session — derived from
    /// the recording's start wall-clock (Phase 2 will sample the actual
    /// start time off `RecordingController`; Phase 1 uses `now()`).
    private func defaultSessionFolderName() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HH-mm"
        return "recording-\(fmt.string(from: Date()))"
    }

    /// Default primary-audio filename shown in the Save dialog file
    /// list. Phase 2 will read the actual filename off
    /// `RecordingController.completedSegments` / the in-flight session.
    private func defaultAudioFilename() -> String { "recording-001.m4a" }

    // MARK: - Privacy / cloud provider helpers

    private static func isCloudProvider(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "gemini", "gemini-live", "soniox", "azure", "azure-openai-realtime", "elevenlabs", "apple-cloud":
            return true
        default:
            return false
        }
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

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
