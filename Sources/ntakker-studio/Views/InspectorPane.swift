// ntakker-studio/Views/InspectorPane.swift — plan-024 T9.

import AppKit
import NtakkerCore
import NtakkerStudioKit
import SwiftUI

struct InspectorPane: View {
    let workspace: RecordingWorkspace
    @AppStorage("studio.inspectorTab") private var tab = Tab.ask

    enum Tab: String, CaseIterable, Identifiable {
        case ask = "Ask", minutes = "Minutes", speakers = "Speakers", cut = "Cut", retranscribe = "Re-transcribe", info = "Info"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .ask: return "bubble.left.and.text.bubble.right"
            case .minutes: return "list.bullet.clipboard"
            case .speakers: return "person.2"
            case .cut: return "scissors"
            case .retranscribe: return "waveform.badge.magnifyingglass"
            case .info: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tool", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Image(systemName: t.icon).help(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Text(tab.rawValue).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Divider().padding(.top, 6)
            Group {
                switch tab {
                case .ask: AskPanel(workspace: workspace)
                case .minutes: MinutesPanel(workspace: workspace)
                case .speakers: SpeakersPanel(workspace: workspace)
                case .cut: CutPanel(workspace: workspace)
                case .retranscribe: RetranscribePanel(workspace: workspace)
                case .info: InfoPanel(workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Ask

struct AskPanel: View {
    let workspace: RecordingWorkspace
    @State private var question = ""

    private let suggestions = [
        "What were the main points?",
        "What did we agree on?",
        "Which open questions remain?",
        "What did each participant want?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if workspace.exchanges.isEmpty && !workspace.isAsking {
                            Text("Ask anything about this recording. Answers cite the moments they rely on — click a time to listen.")
                                .foregroundStyle(.secondary)
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { workspace.ask(s) }.buttonStyle(.link)
                            }
                        }
                        ForEach(Array(workspace.exchanges.enumerated()), id: \.offset) { _, x in
                            ExchangeView(question: x.question, answer: x.answer)
                        }
                        if let q = workspace.pendingQuestion {
                            ExchangeView(question: q, answer: workspace.streamingAnswer.isEmpty ? "…" : workspace.streamingAnswer)
                                .id("pending")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: workspace.streamingAnswer) { _, _ in proxy.scrollTo("pending", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom) {
                    TextField("Ask about this recording", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit(send)
                    if workspace.isAsking {
                        Button("Stop") { workspace.stopAsking() }
                    } else {
                        Button("Ask", action: send)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || workspace.entries.isEmpty)
                    }
                }
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var footer: String {
        let who = workspace.askProviderLine.map { "Using \($0)" } ?? "Uses ntakker's Ask settings"
        return "\(who) · the whole transcript is sent · answers are saved to \(workspace.recording.studioQAURL.lastPathComponent)"
    }

    private func send() {
        workspace.ask(question)
        question = ""
    }
}

struct ExchangeView: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question).font(.body.bold()).textSelection(.enabled)
            MarkdownText(markdown: answer)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Minutes

struct MinutesPanel: View {
    let workspace: RecordingWorkspace
    @AppStorage("studio.minutesLanguage") private var language = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Language (blank: as spoken)", text: $language)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Spacer()
                if workspace.minutesGenerating {
                    ProgressView().controlSize(.small)
                    Button("Stop") { workspace.stopMinutes() }
                } else {
                    Button(workspace.minutes.isEmpty ? "Write Minutes" : "Rewrite") {
                        let l = language.trimmingCharacters(in: .whitespaces)
                        workspace.generateMinutes(language: l.isEmpty ? nil : l)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.entries.isEmpty)
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                if workspace.minutes.isEmpty && !workspace.minutesGenerating {
                    Text("Minutes summarise the meeting: topics, decisions, action items and open questions, each linked to the moment it was said. They are saved to \(workspace.recording.minutesURL.lastPathComponent).")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    MarkdownText(markdown: workspace.minutes).padding(12)
                }
            }
            if !workspace.minutes.isEmpty && !workspace.minutesGenerating {
                Divider()
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(workspace.minutes, forType: .string)
                    }
                    if FileManager.default.fileExists(atPath: workspace.recording.minutesURL.path) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.recording.minutesURL]) }
                        Button("Open") { NSWorkspace.shared.open(workspace.recording.minutesURL) }
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
    }
}

// MARK: - Speakers

struct SpeakersPanel: View {
    let workspace: RecordingWorkspace
    @State private var drafts: [String: String] = [:]

    var body: some View {
        let speakers = workspace.speakers
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if speakers.isEmpty {
                    Text("No speakers yet — the transcript is empty.").foregroundStyle(.secondary)
                } else if speakers.allSatisfy({ $0.raw == nil }) {
                    Text("This transcript has no speaker labels (the provider did not separate speakers), so lines are labelled by source.")
                        .foregroundStyle(.secondary)
                }
                ForEach(speakers, id: \.key) { s in
                    HStack {
                        Circle().fill(SpeakerColor.color(for: s.key)).frame(width: 10, height: 10)
                        if let raw = s.raw {
                            TextField(workspace.metadata.speakerName(for: raw) ?? raw, text: Binding(
                                get: { drafts[raw] ?? workspace.metadata.speakerNames[raw] ?? "" },
                                set: { drafts[raw] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save(raw) }
                        } else {
                            Text(s.label)
                        }
                        Text("\(s.count) lines").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        Button {
                            workspace.player.seek(to: s.first)
                            workspace.player.play()
                        } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                        .help("Hear this speaker's first line")
                    }
                }
                if speakers.contains(where: { $0.raw != nil }) {
                    HStack {
                        Spacer()
                        Button("Save Names") { for s in speakers { if let raw = s.raw { save(raw) } } }
                            .buttonStyle(.borderedProminent)
                            .disabled(drafts.isEmpty)
                    }
                    Text("Names are saved to \(workspace.recording.metadataURL.lastPathComponent) and used in the transcript, Ask and minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func save(_ raw: String) {
        guard let d = drafts[raw] else { return }
        workspace.renameSpeaker(raw: raw, to: d)
        drafts[raw] = nil
    }
}

// MARK: - Cut

struct CutPanel: View {
    @Environment(LibraryStore.self) private var library
    let workspace: RecordingWorkspace

    var body: some View {
        let long = workspace.duration >= 3600
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drag across the waveform (or use a line's menu) to select a range, then add it as a cut. Exporting writes a new copy without the cuts; transcript times are shifted to match. The original is never changed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Selection") {
                    if let s = workspace.selection {
                        HStack {
                            Text("\(StudioAsk.timecode(s.start, longForm: long)) – \(StudioAsk.timecode(s.end, longForm: long))")
                                .monospacedDigit()
                            Text(String(format: "(%.1f s)", s.duration)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Play") { workspace.player.seek(to: s.start); workspace.player.play() }
                            Button("Add as Cut") { workspace.addSelectionAsCut() }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text("Nothing selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Cuts") {
                    VStack(alignment: .leading, spacing: 6) {
                        if workspace.cuts.isEmpty {
                            Text("No cuts yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(workspace.cuts) { c in
                            HStack {
                                Text("\(StudioAsk.timecode(c.start, longForm: long)) – \(StudioAsk.timecode(c.end, longForm: long))").monospacedDigit()
                                Text(String(format: "(%.1f s)", c.duration)).foregroundStyle(.secondary)
                                Spacer()
                                Button { workspace.player.seek(to: max(0, c.start - 3)); workspace.player.play() } label: { Image(systemName: "play.circle") }
                                    .help("Play from 3 s before the cut")
                                Button { workspace.removeCut(c) } label: { Image(systemName: "trash") }
                                    .help("Remove this cut")
                            }
                            .buttonStyle(.borderless)
                        }
                        if !workspace.cuts.isEmpty {
                            Divider()
                            let plan = workspace.cutPlan
                            Text("Removes \(StudioAsk.timecode(plan.removedDuration, longForm: true)); the copy will be \(StudioAsk.timecode(plan.resultDuration, longForm: true)) long.")
                                .font(.callout)
                        }
                    }
                }

                HStack {
                    if let p = workspace.exportProgress {
                        ProgressView(value: p).frame(maxWidth: 180)
                        Text("Writing the copy…").foregroundStyle(.secondary)
                    } else {
                        Button("Clear Cuts") { workspace.clearCuts() }.disabled(workspace.cuts.isEmpty)
                        Spacer()
                        Button("Export Cut Copy") { workspace.exportCut() }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.cuts.isEmpty)
                    }
                }

                if let r = workspace.lastExport {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Saved \(r.folder.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Removed \(StudioAsk.timecode(r.removedSeconds, longForm: true)) and \(r.droppedLines) transcript lines.")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Open the Copy") { library.reveal(folder: r.folder) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

// MARK: - Re-transcribe

struct RetranscribePanel: View {
    let workspace: RecordingWorkspace
    @AppStorage("studio.retranscribeProvider") private var provider = "parakeet"
    @AppStorage("studio.retranscribeLanguages") private var languages = ""

    private let names: [String: String] = [
        "parakeet": "Parakeet (on this Mac)",
        "whisperkit": "WhisperKit (on this Mac)",
        "gemini": "Google Gemini",
        "azure": "Azure OpenAI",
        "elevenlabs": "ElevenLabs",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run the recording through a transcription provider again, for a better transcript or one from a different engine. The result is saved as a new transcript next to the recording, with exact timing; the existing ones stay.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Provider", selection: $provider) {
                    ForEach(Retranscriber.batchProviderIds, id: \.self) { id in Text(names[id] ?? id).tag(id) }
                }
                TextField("Languages, e.g. el, en (blank: provider decides)", text: $languages)
                    .textFieldStyle(.roundedBorder)
                Text("Keys and models come from ntakker's settings (~/.tool-agents/ntakker/.env). Soniox, Apple and Azure Realtime only work live, so they are not offered here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let p = workspace.retranscribeProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: p.fraction)
                        HStack {
                            Text("\(Int(p.fraction * 100))% · \(p.segmentsSoFar) lines").monospacedDigit()
                            Spacer()
                            Button("Cancel") { workspace.cancelRetranscribe() }
                        }
                        if let t = p.lastText {
                            Text(t).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Re-transcribe") {
                            let langs = languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            workspace.retranscribe(providerId: provider, languages: langs)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if let done = workspace.retranscribeDone {
                    Label("Wrote \(done.segmentCount) lines to \(done.files.map(\.lastPathComponent).joined(separator: ", ")). It is now the transcript shown; switch with the picker at the top.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

// MARK: - Info

struct InfoPanel: View {
    let workspace: RecordingWorkspace

    var body: some View {
        let rec = workspace.recording
        Form {
            Section("Timing") {
                LabeledContent("Audio started") {
                    Text(workspace.audioStart, format: .dateTime.day().month().year().hour().minute().second())
                }
                LabeledContent("Line offset") {
                    HStack {
                        Text(String(format: "%+.2f s", workspace.metadata.syncOffsetSec)).monospacedDigit()
                        Stepper("", value: Binding(
                            get: { workspace.metadata.syncOffsetSec },
                            set: { workspace.setSyncOffset($0) }
                        ), in: -30...30, step: 0.25)
                        .labelsHidden()
                        Button("Reset") { workspace.setSyncOffset(0) }
                            .disabled(workspace.metadata.syncOffsetSec == 0)
                    }
                }
                Text("Live transcripts are placed by the clock time each line was written. If lines start a little early or late, shift them here. Transcripts made by the studio have exact timing and are not shifted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                ForEach(rec.tracks, id: \.url) { t in fileRow(t.url, detail: t.role.rawValue) }
            }
            Section("Transcripts") {
                ForEach(rec.transcripts) { t in fileRow(t.url, detail: workspace.isExact(t) ? "exact timing" : "live") }
            }
            if !rec.attachments.isEmpty {
                Section("Notes") {
                    ForEach(rec.attachments, id: \.self) { fileRow($0, detail: nil) }
                }
            }
            Section {
                Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([rec.tracks.first?.url ?? rec.folder]) }
            }
        }
        .formStyle(.grouped)
    }

    private func fileRow(_ url: URL, detail: String?) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless).help("Open")
        }
    }
}
