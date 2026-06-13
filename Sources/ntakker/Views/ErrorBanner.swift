// ntakker/Views/ErrorBanner.swift — see project-design.md §15.10
// and plan-002-toolbar-ui.md §3 Phase G.
//
// Non-modal red banner shown at the top of the popover whenever
// `recordingController.latestError` is non-nil. Hosted by `RootView`.
//
// The banner self-handles the conditional: it returns an `EmptyView`
// when there is no error, so `RootView` can include it unconditionally
// at the top of its `VStack`.
//
// Recovery actions (per project-design §15.10):
//   * `.openSystemSettings(let url)` → "Open Settings" button →
//     `NSWorkspace.shared.open(url)` then `dismissError()`.
//   * `.retry`                       → "Try Again" button →
//     `recordingController.start()` then `dismissError()`.
//   * `.dismiss`                     → "Dismiss" button →
//     `dismissError()`.
//
// A close `X` button on the far right always calls `dismissError()`.
//
// Threading: SwiftUI views on macOS 14+ are implicitly `@MainActor`;
// no explicit annotation required. `recordingController` is also
// `@MainActor`-isolated, so the calls below are safe.
//
// NFR-12: a recoverable engine error MUST NOT bring down the UI
// process. The banner is non-modal — the user can simply dismiss
// it and continue using the app.
//
// NFR-16: every recovery click is logged at `.debug` so a debug-log
// session shows what the user did with the banner.

import AppKit
import Logging
import NtakkerCore
import NtakkerUIKit
import SwiftUI

/// Banner shown at the top of the popover when the controller has
/// surfaced a `NtakkerError`. Returns an `EmptyView()` when no error
/// is present, so callers can include `ErrorBanner()` unconditionally.
struct ErrorBanner: View {

    @Environment(\.recordingController) private var recordingController

    private let logger = Logger(label: "ntakker-cli.ui.errorbanner")

    var body: some View {
        if let controller = recordingController, let error = controller.latestError {
            let message = UIErrorPresenter.present(error)
            content(controller: controller, message: message)
                .transition(
                    .move(edge: .top).combined(with: .opacity)
                )
        } else {
            EmptyView()
        }
    }

    // MARK: - Banner content

    @ViewBuilder
    private func content(
        controller: RecordingController,
        message: UIErrorMessage
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .font(.title3)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message.detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if let recovery = message.recovery {
                recoveryButton(
                    controller: controller,
                    recovery: recovery
                )
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.white)
            }

            Button {
                logger.debug("error banner closed via X")
                controller.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.92))
        )
    }

    // MARK: - Recovery button

    @ViewBuilder
    private func recoveryButton(
        controller: RecordingController,
        recovery: UIErrorMessage.RecoveryAction
    ) -> some View {
        switch recovery {
        case let .openSystemSettings(url):
            Button(String(localized: "Open Settings")) {
                logger.debug("error banner opening settings: \(url.absoluteString)")
                NSWorkspace.shared.open(url)
                controller.dismissError()
            }
        case .retry:
            Button(String(localized: "Try Again")) {
                logger.debug("error banner retry")
                controller.start()
                controller.dismissError()
            }
        case .dismiss:
            Button(String(localized: "Dismiss")) {
                logger.debug("error banner dismissed")
                controller.dismissError()
            }
        }
    }
}
