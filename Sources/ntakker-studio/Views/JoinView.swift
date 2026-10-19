// ntakker-studio/Views/JoinView.swift — 2026-10-19.
//
// Shown when several recordings are selected in the library: the parts
// in the order they were recorded, the pauses between them, and Join,
// which writes one recording from them (`RecordingJoiner`).

import NtakkerStudioKit
import SwiftUI

struct JoinView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Join \(library.selection.count) recordings").font(.title2.bold())
                Text("Makes one recording from the selected ones, in the order they were recorded: the audio end to end (pauses between them are left out) and every transcript re-timed onto it. The originals are not changed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if library.joinPreparing {
                    HStack { ProgressView().controlSize(.small); Text("Reading the recordings…").foregroundStyle(.secondary) }
                } else if let error = library.joinPlanError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let plan = library.joinPlan {
                    PlanTable(plan: plan)
                    summary(plan)
                    HStack {
                        if let p = library.joinProgress {
                            ProgressView(value: p).frame(maxWidth: 220)
                            Text("Writing the joined recording…").foregroundStyle(.secondary)
                        } else {
                            Button("Clear Selection") { library.selection = [] }
                            Spacer()
                            Button("Join") { library.join() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if let error = library.joinError {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ plan: JoinPlan) -> some View {
        let labels = plan.transcriptLabels.map { TranscriptFile(url: URL(fileURLWithPath: "/"), label: $0).displayName }
        return VStack(alignment: .leading, spacing: 4) {
            Text("The joined recording: \(StudioAsk.timecode(plan.duration, longForm: true)) long, starting \(plan.audioStart.formatted(date: .abbreviated, time: .shortened)), named \(plan.stem).")
            Text(labels.isEmpty ? "No transcripts to carry over." : "Transcripts: \(labels.joined(separator: ", ")). Minutes and notes are not carried over; make them again on the joined recording.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PlanTable: View {
    let plan: JoinPlan

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.items.enumerated()), id: \.offset) { i, item in
                    if let pause = item.pauseBefore {
                        pauseRow(pause)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.part.recording.displayName).lineLimit(1)
                            Text("\(item.part.audioStart.formatted(date: .omitted, time: .standard)) · \(StudioAsk.timecode(item.part.duration, longForm: true)) · \(lineCount(item.part) == 1 ? "1 line" : "\(lineCount(item.part)) lines")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("at \(StudioAsk.timecode(item.offset, longForm: plan.duration >= 3600))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("Where this part begins in the joined recording")
                    }
                    .padding(.vertical, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func pauseRow(_ pause: Double) -> some View {
        HStack(spacing: 6) {
            if pause < -1 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("starts \(StudioAsk.timecode(-pause, longForm: false)) before the previous part ends — are these parts of the same session?")
            } else {
                Image(systemName: "pause.circle")
                Text(pause < 1 ? "no pause" : "paused \(StudioAsk.timecode(pause, longForm: pause >= 3600)) (left out)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 28)
        .padding(.vertical, 2)
    }

    private func lineCount(_ part: JoinPart) -> Int {
        part.entriesByTranscript.values.reduce(0) { $0 + $1.count }
    }
}
