// macrec-ui/Views/Sections/PopoverSection.swift — plan-008 Unit E.
//
// Inset-grouped section frame matching the mockup `.section` /
// `.section-title` / `.group` rules
// (docs/design/mockups/popover-redesign.html lines 248..303).
//
// Visual contract:
//   * Section header: 11pt semibold, uppercased, 0.07em tracking,
//     `palette.secondary` foreground, 0..8pt horizontal padding,
//     6pt bottom padding.
//   * Body group: 10pt rounded corners, `palette.groupBackground` fill,
//     0.5pt `palette.groupStroke` hairline border (drawn via
//     `.shadow(color:, radius: 0)` is unreliable cross-version, so we
//     use `.overlay(stroke)`), `clipShape` to round the inner Form's
//     scroll edges.
//
// Collapsibility (added 2026-05-02): an optional
// `isExpanded: Binding<Bool>?` lets a caller flip the section between
// expanded (full body) and collapsed (header only). When the binding
// is `nil` the section behaves exactly as before — body is always
// visible. The header view is responsible for rendering the chevron
// and exposing the tap target; this struct only gates the body
// rendering. State changes are wrapped in
// `withAnimation(.easeInOut(duration: 0.18))` so collapse / expand
// animates smoothly. Persistence (e.g. via `@AppStorage`) is the
// caller's concern — `RootView` owns the two persisted keys.

import SwiftUI

/// Inset-grouped section with a title (above) and a group-styled body
/// (below). Used by `RootView` to render the General + Live
/// Transcription sections per the mockup.
struct PopoverSection<Header: View, Content: View>: View {

    @Environment(\.palette) private var palette

    let header: () -> Header
    let content: () -> Content
    /// Optional collapsibility binding. When non-nil and `false`, the
    /// body group is omitted from the layout (animated). When nil, the
    /// body is always rendered (legacy behaviour).
    let isExpanded: Binding<Bool>?

    init(
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .padding(.horizontal, 8)
                .padding(.bottom, isBodyVisible ? 6 : 0)
            if isBodyVisible {
                group
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isBodyVisible)
    }

    private var isBodyVisible: Bool {
        isExpanded?.wrappedValue ?? true
    }

    private var group: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
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
}

// MARK: - Title-only convenience init

extension PopoverSection where Header == PopoverSectionTitle {
    /// Convenience initializer when the header is a plain text title.
    /// When `isExpanded` is non-nil, the rendered title shows a chevron
    /// and the whole header row becomes a tap target that toggles the
    /// binding.
    init(
        title: String,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            isExpanded: isExpanded,
            header: { PopoverSectionTitle(title: title, isExpanded: isExpanded) },
            content: content
        )
    }
}

/// Plain section-title text styled per the mockup `.section-title` rule.
/// When `isExpanded` is non-nil, a leading chevron rotates between
/// `0°` (expanded) and `-90°` (collapsed), and the whole row becomes a
/// click target that toggles the binding (animated).
struct PopoverSectionTitle: View {
    @Environment(\.palette) private var palette
    let title: String
    let isExpanded: Binding<Bool>?

    init(title: String, isExpanded: Binding<Bool>? = nil) {
        self.title = title
        self.isExpanded = isExpanded
    }

    var body: some View {
        if let isExpanded {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                row(showsChevron: true, expanded: isExpanded.wrappedValue)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isExpanded.wrappedValue
                ? String(localized: "Expanded")
                : String(localized: "Collapsed")))
            .accessibilityHint(Text(String(localized: "Double-tap to expand or collapse")))
        } else {
            row(showsChevron: false, expanded: true)
        }
    }

    private func row(showsChevron: Bool, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .animation(.easeInOut(duration: 0.18), value: expanded)
                    .frame(width: 10)
            }
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.07 * 11)
                .foregroundStyle(palette.secondary)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
