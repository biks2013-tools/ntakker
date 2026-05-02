// macrec-ui/Views/Sections/LiveTranscriptionSectionHeader.swift —
// plan-008 Unit E (project-design §UR-4.10).
//
// Section header for the Live Transcription block. Renders the same
// uppercased small-caps "LIVE TRANSCRIPTION" label as the General
// section's title, plus an `NSSwitch`-style toggle at the trailing
// edge. The toggle binds to
// `@AppStorage("com.macrec.ui.transcriptionEnabled")` (declared in
// Unit I and mirrored in `RootView`); flipping it OFF collapses the
// section body to a one-line "Off — toggle on…" hint without mutating
// the persisted `transcribeProvider` (UR-ADR-7).
//
// Collapsibility (added 2026-05-02): an optional
// `isExpanded: Binding<Bool>?` lets the parent make the title area a
// tap target that expands / collapses the entire section. The trailing
// NSSwitch keeps its own hit target (it must NOT also collapse the
// section), so only the leading title + chevron region is wrapped in a
// Button.

import SwiftUI

/// Section header for the Live Transcription block — uppercased title
/// on the leading edge, NSSwitch on the trailing edge.
struct LiveTranscriptionSectionHeader: View {
    @Environment(\.palette) private var palette

    /// Master enable/disable switch — UR-ADR-7. Re-declared here so the
    /// Toggle binds locally and the `RootView` does not have to thread
    /// a Binding through.
    @AppStorage("com.macrec.ui.transcriptionEnabled")
    private var transcriptionEnabled: Bool = true

    /// Optional collapsibility binding (added 2026-05-02). When non-nil
    /// the leading title region renders a chevron and becomes a tap
    /// target that toggles the binding. The trailing NSSwitch remains
    /// independent so toggling transcription on/off does NOT also
    /// collapse the section.
    let isExpanded: Binding<Bool>?

    init(isExpanded: Binding<Bool>? = nil) {
        self.isExpanded = isExpanded
    }

    var body: some View {
        HStack(spacing: 8) {
            if let isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    titleRow(showsChevron: true, expanded: isExpanded.wrappedValue)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(String(localized: "Live Transcription")))
                .accessibilityValue(Text(isExpanded.wrappedValue
                    ? String(localized: "Expanded")
                    : String(localized: "Collapsed")))
                .accessibilityHint(Text(String(localized: "Double-tap to expand or collapse")))
            } else {
                titleRow(showsChevron: false, expanded: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $transcriptionEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .accessibilityLabel(String(localized: "Live transcription"))
                .accessibilityValue(transcriptionEnabled
                                    ? String(localized: "On")
                                    : String(localized: "Off"))
        }
    }

    private func titleRow(showsChevron: Bool, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .animation(.easeInOut(duration: 0.18), value: expanded)
                    .frame(width: 10)
            }
            Text("LIVE TRANSCRIPTION")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.07 * 11)
                .foregroundStyle(palette.secondary)
        }
        .contentShape(Rectangle())
    }
}
