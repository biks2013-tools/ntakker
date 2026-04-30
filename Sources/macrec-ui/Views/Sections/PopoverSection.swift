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

import SwiftUI

/// Inset-grouped section with a title (above) and a group-styled body
/// (below). Used by `RootView` to render the General + Live
/// Transcription sections per the mockup.
struct PopoverSection<Header: View, Content: View>: View {

    @Environment(\.palette) private var palette

    let header: () -> Header
    let content: () -> Content

    init(
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            group
        }
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
    init(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            header: { PopoverSectionTitle(title: title) },
            content: content
        )
    }
}

/// Plain section-title text styled per the mockup `.section-title` rule.
struct PopoverSectionTitle: View {
    @Environment(\.palette) private var palette
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.07 * 11)
                .foregroundStyle(palette.secondary)
            Spacer()
        }
    }
}
