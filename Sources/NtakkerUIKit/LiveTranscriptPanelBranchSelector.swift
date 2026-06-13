// NtakkerUIKit/LiveTranscriptPanelBranchSelector.swift — pure
// branch selector for LiveTranscriptPanel's two-way dispatch
// (single / source-split). Lives in NtakkerUIKit so it's
// unit-testable without spinning up SwiftUI. Plan-012 Phase C6.

import Foundation
import NtakkerCore

public enum LiveTranscriptPanelBranch: Equatable, Sendable {
    case single
    case sourceSplit
}

public enum LiveTranscriptPanelBranchSelector {
    /// Select which body to render for the given source.
    /// Logic:
    ///   * `.both` → sourceSplit (Phase C6).
    ///   * anything else → single (legacy path).
    public static func branch(
        source: TranscriptionSource
    ) -> LiveTranscriptPanelBranch {
        if source == .both { return .sourceSplit }
        return .single
    }
}
