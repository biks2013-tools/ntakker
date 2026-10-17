// ntakker-studio/Views/RecordingDetailView.swift — plan-024 T9.
//
// Header, player and waveform on top; transcript on the left and the
// tools (Ask, Minutes, Speakers, Cut, Re-transcribe, Info) on the right.

import NtakkerStudioKit
import SwiftUI

struct RecordingDetailView: View {
    @Bindable var workspace: RecordingWorkspace

    var body: some View {
        VStack(spacing: 0) {
            RecordingHeader(workspace: workspace)
            if let error = workspace.lastError ?? workspace.metadataError {
                ErrorBanner(message: error) {
                    if workspace.lastError != nil { workspace.lastError = nil }
                }
            }
            PlayerBar(workspace: workspace)
            WaveformStrip(workspace: workspace)
                .frame(height: 72)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            // A plain HStack rather than HSplitView: the split view sizes
            // panes by their unwrapped text width and pushed the window
            // content past its edges.
            HStack(spacing: 0) {
                TranscriptPane(workspace: workspace)
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                InspectorPane(workspace: workspace)
                    .frame(width: 390)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let t = TimecodeLinks.seconds(from: url) {
                workspace.player.seek(to: t)
                return .handled
            }
            return .systemAction
        })
    }
}

struct RecordingHeader: View {
    let workspace: RecordingWorkspace

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.recording.displayName).font(.title2.bold()).lineLimit(1)
                HStack(spacing: 10) {
                    Text(workspace.audioStart, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                    if workspace.duration > 0 {
                        Text(StudioAsk.timecode(workspace.duration, longForm: true))
                    }
                    Text(workspace.recording.tracks.count > 1 ? "mic + system" : workspace.recording.tracks.first?.url.pathExtension.uppercased() ?? "")
                    Text("\(workspace.entries.count) lines")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            TranscriptPicker(workspace: workspace)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// Which transcripts are shown (several can be on at once, e.g. mic + system).
struct TranscriptPicker: View {
    @Bindable var workspace: RecordingWorkspace

    var body: some View {
        if workspace.recording.transcripts.isEmpty {
            Text("No transcript").foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(workspace.recording.transcripts) { t in
                    Toggle(isOn: Binding(
                        get: { workspace.visibleTranscripts.contains(t.url) },
                        set: { on in
                            if on { workspace.visibleTranscripts.insert(t.url) } else { workspace.visibleTranscripts.remove(t.url) }
                        }
                    )) {
                        Text(t.displayName + (workspace.isExact(t) ? " · exact timing" : ""))
                    }
                }
            } label: {
                Label(pickerTitle, systemImage: "text.quote")
            }
            .fixedSize()
        }
    }

    private var pickerTitle: String {
        let shown = workspace.recording.transcripts.filter { workspace.visibleTranscripts.contains($0.url) }
        switch shown.count {
        case 0: return "No transcript shown"
        case 1: return shown[0].displayName
        default: return "\(shown.count) transcripts"
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

struct PlayerBar: View {
    @Bindable var workspace: RecordingWorkspace
    @AppStorage("studio.echoFilter") private var echoFilterPref = false
    @State private var showEchoSettings = false

    var body: some View {
        let player = workspace.player
        HStack(spacing: 12) {
            Button { player.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                .help("Back 10 s (←: 5 s)")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / pause (space)")
            .disabled(player.duration == 0)
            Button { player.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                .help("Forward 10 s (→: 5 s)")
            Text("\(StudioAsk.timecode(player.currentTime, longForm: true)) / \(StudioAsk.timecode(player.duration, longForm: true))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if let error = player.loadError {
                Text("Audio: \(error)").foregroundStyle(.red).font(.caption).lineLimit(1)
            }
            if player.canFilterEcho {
                Button {
                    player.echoFilter.toggle()
                    echoFilterPref = player.echoFilter
                } label: {
                    Label(player.echoFilter ? "Echo removed" : "Remove echo",
                          systemImage: player.echoFilter ? "ear.fill" : "ear")
                        .foregroundStyle(player.echoFilter ? Color.accentColor : Color.secondary)
                }
                .help(player.echoFilter
                      ? "Echo filter on: the system audio that leaked into the microphone is being subtracted. Click to hear the original."
                      : "Echo filter: subtract the system audio that leaked into the microphone (speakers picked up by the mic), while you listen. The files are not changed.")
                .accessibilityValue(player.echoFilter ? "on" : "off")
                Button { showEchoSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Echo filter settings: strength, extra suppression, adaptation speed, echo delay")
                    .popover(isPresented: $showEchoSettings, arrowEdge: .bottom) {
                        EchoSettingsView(workspace: workspace)
                    }
            }
            Toggle("Skip cuts", isOn: $workspace.previewCuts)
                .toggleStyle(.checkbox)
                .disabled(workspace.cuts.isEmpty)
                .help("Preview the cut: playback jumps over the ranges marked for removal")
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                ForEach(PlayerController.availableRates, id: \.self) { r in
                    Text(r == 1 ? "1×" : String(format: "%g×", r)).tag(r)
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onChange(of: player.canFilterEcho, initial: true) { _, can in
            if can { player.echoFilter = echoFilterPref }
        }
    }
}

/// Waveform with playhead, transcript-line ticks, cuts and the selection.
/// Click to seek; drag to select a range for cutting.
struct WaveformStrip: View {
    @Bindable var workspace: RecordingWorkspace
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let duration = workspace.duration
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let peaks = workspace.waveform.peaks
                    guard !peaks.isEmpty else { return }
                    let mid = size.height / 2
                    let step = size.width / CGFloat(peaks.count)
                    var path = Path()
                    for (i, p) in peaks.enumerated() {
                        let x = CGFloat(i) * step
                        let amp = max(0.5, CGFloat(p) * (mid - 2))
                        path.addRect(CGRect(x: x, y: mid - amp, width: max(1, step * 0.8), height: amp * 2))
                    }
                    ctx.fill(path, with: .color(.accentColor.opacity(0.55)))
                }
                if workspace.waveform.peaks.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Reading audio…").font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if duration > 0 {
                    ForEach(workspace.cuts) { c in
                        Rectangle().fill(.red.opacity(0.28))
                            .frame(width: max(1, (c.end - c.start) / duration * w), height: h)
                            .offset(x: c.start / duration * w)
                            .allowsHitTesting(false)
                    }
                    if let s = workspace.selection {
                        Rectangle().fill(.blue.opacity(0.25))
                            .overlay(Rectangle().stroke(.blue.opacity(0.6)))
                            .frame(width: max(1, s.duration / duration * w), height: h)
                            .offset(x: s.start / duration * w)
                            .allowsHitTesting(false)
                    }
                    Rectangle().fill(.primary)
                        .frame(width: 1.5, height: h)
                        .offset(x: min(w - 1.5, workspace.player.currentTime / duration * w))
                        .allowsHitTesting(false)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard duration > 0 else { return }
                        let t = max(0, min(duration, g.location.x / w * duration))
                        if dragStart == nil { dragStart = max(0, min(duration, g.startLocation.x / w * duration)) }
                        if abs(g.translation.width) > 3, let s = dragStart {
                            workspace.selection = CutRange(start: s, end: t)
                        }
                    }
                    .onEnded { g in
                        defer { dragStart = nil }
                        guard duration > 0 else { return }
                        if abs(g.translation.width) <= 3 {
                            workspace.selection = nil
                            workspace.player.seek(to: max(0, min(duration, g.location.x / w * duration)))
                        }
                    }
            )
            .help("Click to jump there; drag to select a range to cut")
        }
    }
}

/// The echo filter's adjustable settings. Strength, suppression and
/// adaptation are app-wide; the delay override belongs to the recording.
/// They apply while listening and to "Export Copy" with echo removal.
struct EchoSettingsView: View {
    let workspace: RecordingWorkspace

    var body: some View {
        let player = workspace.player
        let settings = Binding(
            get: { player.echoSettings },
            set: { player.echoSettings = $0; $0.save() }
        )
        VStack(alignment: .leading, spacing: 14) {
            Text("Echo filter").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Strength")
                    Spacer()
                    Text("\(Int((settings.wrappedValue.strength * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: settings.strength, in: 0...1, step: 0.05)
                Text("How much of the echo to take out. Lower keeps a little of the original sound, if the voice sounds thin.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Extra suppression")
                Picker("Extra suppression", selection: settings.suppression) {
                    Text("Off").tag(EchoFilterSettings.Suppression.off)
                    Text("Low").tag(EchoFilterSettings.Suppression.low)
                    Text("High").tag(EchoFilterSettings.Suppression.high)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("A second stage that also quietens what the main filter leaves (room reverb, speaker distortion). High removes the most but can make voices sound slightly muffled when both sides talk at once.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Adaptation")
                Picker("Adaptation", selection: settings.adaptation) {
                    Text("Stable").tag(EchoFilterSettings.Adaptation.stable)
                    Text("Fast").tag(EchoFilterSettings.Adaptation.fast)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("Fast re-learns within a second when the echo changes (someone moved the laptop). Stable learns more slowly but holds up better in a noisy room. Changing it restarts the learning.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Set the echo delay by hand", isOn: Binding(
                    get: { player.echoDelayOverride != nil },
                    set: { on in workspace.setEchoDelayOverride(on ? (player.echoDelay ?? 0.12) * 1000 : nil) }
                ))
                if let o = player.echoDelayOverride {
                    HStack {
                        Slider(value: Binding(get: { o * 1000 }, set: { workspace.setEchoDelayOverride($0) }), in: 0...400, step: 5)
                        Text("\(Int(o * 1000)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Text(player.echoDelay.map { "Measured for this recording: \(Int($0 * 1000)) ms." } ?? "Measuring the echo delay…")
                    .font(.caption).foregroundStyle(.secondary)
                Text("How long after the other side speaks their voice reaches your mic. Set it by hand only if the echo is still clearly audible; it is saved with this recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Reset to Defaults") {
                    settings.wrappedValue = .standard
                    workspace.setEchoDelayOverride(nil)
                }
                Spacer()
                Text("Also used by Export Copy").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

