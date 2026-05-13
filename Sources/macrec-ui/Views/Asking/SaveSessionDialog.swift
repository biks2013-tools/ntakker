// macrec-ui/Views/Asking/SaveSessionDialog.swift — plan-015 Pattern C
// Layout commitment 3 (FR-IRQ-49 / FR-IRQ-50 / FR-IRQ-51).
//
// Phase 1 ships the *visual surface* only: the folder-name field, the
// live `~/Recordings/<folder-name>/` path preview, and the "Will be
// saved" file list. Confirm closes the dialog and emits a stub toast
// via the `onConfirm` callback — the actual on-disk write is wired in
// Phase 2 (TranscriptExporter, FR-IRQ-51 / FR-IRQ-54).

import SwiftUI

struct SaveSessionDialog: View {
    @Environment(\.palette) private var palette

    /// Default folder name derived at presentation time from the
    /// recording's *start* time (FR-IRQ-49 / FR-IRQ-51 default).
    let defaultFolderName: String
    /// The user's chosen audio output filename — surfaces in the
    /// "Will be saved" preview list so they know which file lands in
    /// the new folder. Phase 2 will compute this from the resolved
    /// `RecordingOptions.output` rather than accepting it as a string.
    let audioFilename: String

    /// Fired when the user clicks Save (or hits ⏎) with a non-empty
    /// folder name. Payload is the sanitised folder name (alpha-num +
    /// `._-` only, max 96 chars per FR-IRQ-49 constraints).
    let onConfirm: (String) -> Void
    /// Fired on Cancel / Esc / click-outside.
    let onCancel: () -> Void

    @State private var folderName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "FOLDER NAME"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.07 * 10)
                    .foregroundStyle(palette.secondary)

                TextField(String(localized: "recording-…"), text: $folderName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(palette.value)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.fieldBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.controlStroke, lineWidth: 0.5)
                    )
                    .onSubmit(submit)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.tertiary)
                    Text(pathPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "WILL BE SAVED"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.07 * 10)
                    .foregroundStyle(palette.secondary)

                VStack(spacing: 0) {
                    fileRow(name: "transcript.md", desc: String(localized: "Live transcript (Markdown, timestamped)."))
                    Divider().overlay(palette.separator)
                    fileRow(name: "qa.md", desc: String(localized: "Q&A interjections, chronologically."))
                    Divider().overlay(palette.separator)
                    fileRow(name: audioFilename, desc: String(localized: "Primary audio file from this session."))
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.groupBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.groupStroke, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            footer
        }
        .padding(20)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.groupStroke, lineWidth: 0.5)
        )
        .onAppear {
            if folderName.isEmpty { folderName = defaultFolderName }
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Save this recording"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.label)
            Text(String(localized: "Everything is saved together under ~/Recordings/<folder-name>/."))
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onCancel) {
                Text(String(localized: "Cancel"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(palette.controlBackground))
                    .overlay(Capsule().strokeBorder(palette.controlStroke, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                Text(String(localized: "Save"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [palette.accent, palette.accent.opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(sanitized.isEmpty)
        }
    }

    @ViewBuilder
    private func fileRow(name: String, desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.value)
                .frame(width: 140, alignment: .leading)
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Derived

    private var pathPreview: String {
        let name = sanitized.isEmpty ? "<folder-name>" : sanitized
        return "~/Recordings/\(name)/"
    }

    /// Sanitised folder name per FR-IRQ-49 constraints, Unicode-safe
    /// for non-Latin alphabets (Greek, CJK, …):
    ///   * Unicode letters and digits are kept verbatim.
    ///   * Whitespace runs collapse to a single `-`.
    ///   * Path-illegal characters (`/ : \ * ? " < > |`) and ASCII
    ///     control characters are stripped silently.
    ///   * Other punctuation is kept as-is so users can type the names
    ///     they actually want (e.g. parentheses, em-dashes).
    ///   * Trimmed to a leading/trailing dash-or-whitespace boundary
    ///     and capped at 96 characters.
    private var sanitized: String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        var out = ""
        out.reserveCapacity(folderName.count)
        var lastWasDash = false
        for scalar in folderName.unicodeScalars {
            if illegal.contains(scalar) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasDash && !out.isEmpty {
                    out.append("-")
                    lastWasDash = true
                }
                continue
            }
            out.unicodeScalars.append(scalar)
            lastWasDash = (scalar == "-")
        }
        // Trim leading/trailing dashes so a stray space at either end
        // doesn't leave a dangling `-`.
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(96))
    }

    private func submit() {
        guard !sanitized.isEmpty else { return }
        onConfirm(sanitized)
    }
}
