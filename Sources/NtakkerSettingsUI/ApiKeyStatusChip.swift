// ntakker/Views/Transcription/ApiKeyStatusChip.swift — plan-008 Unit D
//
// Compact status chip rendered to the right of an API-key section
// header. v1.6 surfaces presence-only state ("Configured" /
// "Not configured") per UR-ADR-8 (frozen). A future plan adds an
// `expires: Date?` parameter for expiration text — the API today
// accepts a generic `present: Bool` so that extension can land
// without breaking the contract.

import SwiftUI

/// Compact status chip rendered to the right of an API-key section header.
/// v1.6 surfaces presence-only state ("Configured" / "Not configured").
/// A future plan adds an `expires: Date?` parameter for expiration text.
public struct ApiKeyStatusChip: View {
    let present: Bool

    public init(present: Bool) { self.present = present }

    /// System colours (the chip moved into the shared settings module, plan-025).
    private enum palette {
        static let successDot = Color.green
        static let successForeground = Color.green
        static let tertiary = Color(nsColor: .tertiaryLabelColor)
        static let secondary = Color.secondary
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(present ? palette.successDot : palette.tertiary)
                .frame(width: 6, height: 6)
            Text(present ? "Configured" : "Not configured")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(present ? palette.successForeground : palette.secondary)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ApiKeyStatusChip(present: true)
        ApiKeyStatusChip(present: false)
    }
    .padding()
}
