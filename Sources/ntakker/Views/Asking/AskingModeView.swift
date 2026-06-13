// ntakker/Views/Asking/AskingModeView.swift — plan-015 Phase 4
// (FR-IRQ-6, FR-IRQ-8, FR-IRQ-19). Live Q&A pane.
//
// Submit path:
//   1. Append a new `QAEntry` with `isStreaming=true`.
//   2. Call `AskService.ask(...)` on a background task; iterate the
//      token stream and append tokens to the entry's `answer`.
//   3. On stream completion: flip `isStreaming=false`.
//   4. On error: set `entry.errorMessage`, flip `isStreaming=false`.
//      The row renders the error inline instead of the empty answer
//      (FR-IRQ-19).
//
// FR-IRQ-18 privacy gate: when the resolved provider is a cloud
// provider AND the per-provider acknowledgement is unset, the Submit
// button instead opens the `AskPrivacyDisclosureSheet`. The pending
// question is held in `pendingQuestion` and re-submitted once the user
// acknowledges. Cancelling the sheet drops the pending question.

import NtakkerCore
import SwiftUI

/// One Q&A exchange — the model used by `AskingModeView`'s in-memory
/// history. Promoted to `NtakkerCore` if/when the floating overlay
/// (plan-015 Phase 5) needs to share the same state.
struct QAEntry: Identifiable, Equatable {
    let id: UUID = .init()
    let recordingTimestampSeconds: TimeInterval
    let question: String
    var answer: String
    var isStreaming: Bool
    /// Wall-clock at submit — recorded so the sidecar writer can fill
    /// `ts_wall` correctly.
    let askedAt: Date
    /// Provider that produced (or attempted to produce) the answer.
    /// `nil` while the request is still resolving config.
    var provider: AskProvider?
    /// Resolved model id used for the request. `nil` until resolved.
    var model: String?
    /// Transcript-window start used in the prompt (for FR-IRQ-14).
    var windowStart: Date?
    /// Transcript-window end used in the prompt (for FR-IRQ-14).
    var windowEnd: Date?
    /// Typed inline error per FR-IRQ-19. When non-nil the row renders
    /// in error style and the empty `answer` is replaced by the message.
    var errorMessage: String?

    var recordingTimestampLabel: String {
        let secs = Int(recordingTimestampSeconds)
        let hours   = secs / 3600
        let minutes = (secs % 3600) / 60
        let seconds = secs % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d in recording", hours, minutes, seconds)
        }
        return String(format: "%d:%02d in recording", minutes, seconds)
    }
}

/// Observable container for the live Q&A history. Owns the streaming
/// tasks per-entry so cancellation on session reset propagates.
@MainActor
final class AskingSessionStore: ObservableObject {
    @Published var history: [QAEntry] = []

    /// Streaming tasks, keyed by entry id, so `clear()` can cancel
    /// any in-flight network operation.
    private var streamingTasks: [UUID: Task<Void, Never>] = [:]

    /// Submit a real question. Appends an entry, kicks off the
    /// streaming pipeline. Returns the new entry's id so the caller
    /// can correlate the privacy-disclosure flow.
    @discardableResult
    func submit(
        question: String,
        atSeconds seconds: TimeInterval,
        transcriptSegments: [TranscriptSegment],
        window: AskContextWindow? = nil
    ) -> UUID? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let entry = QAEntry(
            recordingTimestampSeconds: seconds,
            question: trimmed,
            answer: "",
            isStreaming: true,
            askedAt: Date(),
            provider: nil,
            model: nil,
            windowStart: nil,
            windowEnd: nil,
            errorMessage: nil
        )
        history.append(entry)
        let entryId = entry.id

        let stream: AskAnswerStream
        do {
            stream = try AskService.ask(
                question: trimmed,
                transcriptSegments: transcriptSegments,
                window: window
            )
        } catch {
            // Config-stage failure surfaces inline (FR-IRQ-19) — never
            // crashes, never falls back.
            markError(entryId: entryId, error: error)
            return entryId
        }

        // Record the provider / model / window before tokens start so
        // the sidecar entry has the metadata even if the request fails
        // mid-stream.
        if let idx = history.firstIndex(where: { $0.id == entryId }) {
            history[idx].provider    = stream.metadata.provider
            history[idx].model       = stream.metadata.model
            history[idx].windowStart = stream.metadata.windowStart
            history[idx].windowEnd   = stream.metadata.windowEnd
        }

        let task = Task { [weak self] in
            do {
                for try await delta in stream.tokens {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.appendDelta(entryId: entryId, delta: delta)
                    }
                }
                await MainActor.run {
                    self?.finalize(entryId: entryId)
                }
            } catch {
                await MainActor.run {
                    self?.markError(entryId: entryId, error: error)
                }
            }
        }
        streamingTasks[entryId] = task
        return entryId
    }

    /// Cancel every in-flight request and wipe the in-memory log.
    /// Called by `clearSession()` per FR-IRQ-56.
    func clear() {
        for (_, task) in streamingTasks { task.cancel() }
        streamingTasks.removeAll()
        history.removeAll()
    }

    /// Snapshot used by the sidecar writer at session-stop.
    func snapshotForSidecar() -> [QAEntry] { history }

    // MARK: - Private mutation helpers

    private func appendDelta(entryId: UUID, delta: String) {
        guard let idx = history.firstIndex(where: { $0.id == entryId }) else { return }
        history[idx].answer.append(delta)
    }

    private func finalize(entryId: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == entryId }) else { return }
        history[idx].isStreaming = false
        streamingTasks[entryId] = nil
        if history[idx].answer.isEmpty && history[idx].errorMessage == nil {
            history[idx].errorMessage = String(localized: "Provider closed the stream without producing an answer.")
        }
    }

    private func markError(entryId: UUID, error: Error) {
        guard let idx = history.firstIndex(where: { $0.id == entryId }) else { return }
        history[idx].isStreaming = false
        let message: String
        if let ntakker = error as? NtakkerError {
            message = ntakker.errorDescription ?? "\(ntakker)"
        } else {
            message = error.localizedDescription
        }
        history[idx].errorMessage = message
        streamingTasks[entryId] = nil
    }
}

/// Body content for Asking mode. Pinned-bottom input row + scrolling
/// history above.
struct AskingModeView: View {
    @Environment(\.palette) private var palette
    @Environment(\.recordingController) private var recordingController
    @ObservedObject var store: AskingSessionStore
    @EnvironmentObject private var predefinedStore: PredefinedQuestionsStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.popoverBehavior) private var popoverBehavior

    /// Closure the parent (`RootView`) installs to gate the submit
    /// path on the FR-IRQ-18 privacy disclosure. Returns `true` when
    /// the parent will handle the privacy flow (in which case this
    /// view holds the question in `pendingDraft` until the parent
    /// confirms via `confirmPendingSubmit`). Returns `false` when no
    /// disclosure is required and the view should submit immediately.
    var requestPrivacyAck: ((AskProvider) -> Bool)? = nil

    @State private var draft: String = ""

    /// Persisted context-window choice — stored as the enum's
    /// `storageID` so future cases (e.g. `.minutes(30)`) can be added
    /// without breaking the persisted value.
    static let contextWindowStorageKey = "com.ntakker.ui.ask.contextWindow"

    @AppStorage(AskingModeView.contextWindowStorageKey)
    private var contextWindowRaw: String = AskContextWindow.minutes(10).storageID

    /// Concrete five-option set shown in the popover picker. The order
    /// is the user-requested presentation order (full → 15 → 10 → 2 →
    /// none) so the most common "everything" choice is at the top.
    private static let contextWindowOptions: [AskContextWindow] = [
        .full,
        .minutes(15),
        .minutes(10),
        .minutes(2),
        AskContextWindow.none,
    ]

    private var contextWindow: AskContextWindow {
        AskContextWindow.fromStorageID(contextWindowRaw) ?? .minutes(10)
    }

    var body: some View {
        VStack(spacing: 0) {
            historyPane
            inputRow
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historyPane: some View {
        if store.history.isEmpty {
            VStack {
                Spacer()
                Text(String(localized: "No questions yet. Type one below to ask the agent about what's been said so far."))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                historyHeader
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.history) { entry in
                                entryRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    .onChange(of: store.history.last?.id) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(newID, anchor: .bottom)
                        }
                    }
                    .onChange(of: store.history.last?.answer) { _, _ in
                        // Keep the bottom anchored while tokens stream in.
                        if let last = store.history.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Header row above the Q&A history. Mirrors the trash affordance
    /// in `LiveTranscriptPanel` so both panes have a consistent
    /// "clear the in-memory pane, leave the on-disk sidecar untouched"
    /// gesture. Only rendered when there is at least one entry to
    /// clear — keeps the empty-state pane visually quiet.
    @ViewBuilder
    private var historyHeader: some View {
        HStack(spacing: 6) {
            Text(String(localized: "Questions"))
                .font(.caption)
                .foregroundStyle(palette.secondary)
            Spacer()
            Button {
                let body = SessionExporter.renderQAMarkdown(history: store.history)
                MarkdownPaneExporter.presentSave(
                    contents: body,
                    defaultFilename: "qa.md",
                    title: String(localized: "Save Questions"),
                    behaviorSetter: popoverBehavior
                )
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .imageScale(.small)
                    .foregroundStyle(palette.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Save questions to a Markdown file"))
            .accessibilityLabel(String(localized: "Save questions"))
            Button {
                store.clear()
            } label: {
                Image(systemName: "trash")
                    .imageScale(.small)
                    .foregroundStyle(palette.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Clear questions (sidecar file is unaffected)"))
            .accessibilityLabel(String(localized: "Clear questions"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func entryRow(_ entry: QAEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Q row
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Q")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(entry.recordingTimestampLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.secondary)
                if let provider = entry.provider {
                    Text("· \(provider.displayName)\(entry.model.map { " · \($0)" } ?? "")")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(palette.tertiary)
                }
            }
            Text(entry.question)
                .font(.system(size: 13))
                .foregroundStyle(palette.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)

            // A row header
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("A")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.errorMessage == nil ? palette.accent : .red)
                if entry.isStreaming {
                    Text(String(localized: "streaming…"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
            }

            // A body — error path takes precedence over the streaming
            // answer so a partial answer followed by an error reads
            // cleanly as "this failed".
            if let err = entry.errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            } else {
                Text(entry.answer.isEmpty && entry.isStreaming
                     ? "…"
                     : entry.answer)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.value)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(entry.errorMessage == nil
                      ? palette.accent.opacity(0.06)
                      : Color.red.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.groupStroke, lineWidth: 0.5)
        )
    }

    // MARK: - Input row

    @ViewBuilder
    private var inputRow: some View {
        VStack(spacing: 0) {
            Divider().overlay(palette.separator)
            contextWindowChip
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.tertiary)
                    .help(String(localized: "Voice input — coming soon"))

                TextField(
                    String(localized: "Ask a question about this recording…"),
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.value)
                .lineLimit(1...4)
                .onSubmit(submitDraft)

                // Always-visible picker for predefined questions. Kept
                // separate from the Send button so the predefined-list
                // affordance is discoverable (plan-016 follow-up — the
                // earlier combined Menu hid behind `.menuIndicator(.hidden)`
                // and was unreachable without a long-press).
                Menu {
                    if predefinedStore.questions.isEmpty {
                        Text(String(localized: "No predefined questions"))
                            .foregroundStyle(.secondary)
                        Divider()
                    } else {
                        Section(String(localized: "Predefined questions")) {
                            ForEach(predefinedStore.questions) { q in
                                Button(q.label) {
                                    pickPredefined(q)
                                }
                            }
                        }
                        Divider()
                    }
                    Button(String(localized: "Manage…")) {
                        UserDefaults.standard.set(
                            SettingsCategory.predefinedQuestions.rawValue,
                            forKey: "com.ntakker.ui.settings.selectedCategory"
                        )
                        openSettings()
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().strokeBorder(palette.groupStroke, lineWidth: 0.5)
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(localized: "Pick a predefined question or manage the list"))

                Button(action: submitDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(canSubmit ? palette.accent : palette.tertiary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help(String(localized: "Send question (Return)"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.fieldBackground)
        }
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Submit path with FR-IRQ-18 privacy gate.
    ///
    /// If `requestPrivacyAck` returns `true`, the parent has accepted
    /// responsibility for presenting the disclosure sheet and the
    /// pending draft is preserved so a successful acknowledgement can
    /// re-fire `submitDraft()` (the parent invokes it through the
    /// shared store's draft snapshot). For simplicity v1 of the
    /// privacy gate calls the closure with the resolved provider and,
    /// when the closure signals "showing", aborts the local submit —
    /// the parent submits via the store directly once the user accepts.
    private func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Resolve the provider just to drive the privacy gate decision.
        // The full resolve runs again inside `AskService.ask(...)` —
        // duplicating that early resolution here keeps the gate
        // synchronous and avoids speculatively appending an entry that
        // would have to be unwound if the sheet is cancelled.
        if let provider = try? AskConfigResolver.resolve().provider,
           provider.isCloud,
           let ack = requestPrivacyAck,
           ack(provider)
        {
            // Parent will present the sheet and re-submit on accept.
            // Keep the draft in the field so the user sees what's
            // queued.
            return
        }

        let elapsed = recordingController?.totalElapsed ?? 0
        let segments = recordingController?.transcriptSegments ?? []
        _ = store.submit(
            question: trimmed,
            atSeconds: elapsed,
            transcriptSegments: segments,
            window: contextWindow
        )
        draft = ""
    }

    /// Compact picker chip rendered above the input row. Uses a Menu
    /// (rather than a SwiftUI `Picker`) so the trigger surface is a
    /// small ASCII chip — fits the tight popover chrome and stays
    /// consistent visually with the predefined-questions menu next to
    /// the Send button.
    @ViewBuilder
    private var contextWindowChip: some View {
        let current = contextWindow
        HStack(spacing: 6) {
            Text(String(localized: "Context:"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.tertiary)
            Menu {
                ForEach(Self.contextWindowOptions, id: \.storageID) { option in
                    Button {
                        contextWindowRaw = option.storageID
                    } label: {
                        if option == current {
                            Label(option.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(option.displayLabel)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current.displayLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(palette.fieldBackground)
                )
                .overlay(
                    Capsule().strokeBorder(palette.groupStroke, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "How much of the transcript to send as context with each question"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// Selecting a predefined question loads its text into the draft
    /// and routes through `submitDraft()` so the privacy gate, the
    /// AskService submit, and the streaming behavior all stay on a
    /// single code path.
    private func pickPredefined(_ q: PredefinedQuestion) {
        draft = q.text
        submitDraft()
    }
}
