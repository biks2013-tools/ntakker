// MacrecUIKit/LiveTranscriptPanelBranchSelector.swift — pure
// branch selector for LiveTranscriptPanel's three-way dispatch
// (single / dual / source-split). Lives in MacrecUIKit so it's
// unit-testable without spinning up SwiftUI. Plan-012 Phase C6.

import Foundation
import MacrecCore

public enum LiveTranscriptPanelBranch: Equatable, Sendable {
    case single
    case dual
    case sourceSplit
}

public enum LiveTranscriptPanelBranchSelector {
    /// Select which body to render for the given mode + source.
    /// Logic:
    ///   * dual mode wins regardless of source.
    ///   * single mode + .both        → sourceSplit (Phase C6).
    ///   * single mode + anything else → single (legacy DT-INV path).
    public static func branch(
        mode: LiveTranscriptionMode,
        source: TranscriptionSource
    ) -> LiveTranscriptPanelBranch {
        if mode == .dual { return .dual }
        if source == .both { return .sourceSplit }
        return .single
    }
}
