// NtakkerCore/Permissions/ScreenRecordingPermission.swift
// Reference: project-design.md §2.6 and §8.1
//
// Wraps both the legacy `CGPreflight/CGRequestScreenCaptureAccess` and the
// modern `ScreenCaptureKit.SCShareableContent.current` APIs. SCShareableContent
// is the authoritative source on macOS 14+; the CG* preflight is kept as a
// fast synchronous fallback when async context is unavailable.
//
// ## Known limitation — TCC ad-hoc-signing instability
//
// `swift build` produces an ad-hoc-signed binary. Each rebuild creates a new
// code-signature identity (cdhash), which TCC treats as a new app entirely.
// Therefore developer builds re-prompt for Screen Recording access on every
// rebuild and accumulate stale rows in System Settings. There is no in-process
// mitigation; users must:
//
//   sudo tccutil reset ScreenCapture        # nuclear option (resets every app)
//   # then re-grant in System Settings → Privacy & Security → Screen Recording
//
// Wrapping in a `.app` bundle with a stable Developer-ID signature is the only
// production-grade fix. (See docs/reference/investigation-recording-tool.md.)

import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ScreenRecordingPermission {
    public enum State: String, Sendable, Equatable {
        case notDetermined
        case denied
        case authorized
    }

    /// Synchronous, fast preflight via the legacy Core Graphics API.
    ///
    /// Note: `CGPreflightScreenCaptureAccess` cannot distinguish "never asked"
    /// from "explicitly denied" — both produce `false`, mapped here to `.denied`.
    /// On macOS 14+ this API can also fail to reflect the current System Settings
    /// state until the binary actually attempts a screen-capture operation.
    /// Prefer `currentAsync()` for an authoritative read.
    public static func current() -> State {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    /// Authoritative async check via `SCShareableContent.current`.
    ///
    /// `SCShareableContent.current` is the modern macOS 13+ API. It throws if
    /// the binary lacks Screen Recording permission and returns content if it
    /// has it. This is the most reliable indicator on macOS 14+ ad-hoc-signed
    /// CLI tools, where the legacy `CGPreflight` can return stale results.
    public static func currentAsync() async -> State {
        do {
            // We don't need the result — we only need to know if the call
            // succeeds (granted) or throws (denied / not determined).
            _ = try await SCShareableContent.current
            return .authorized
        } catch {
            return .denied
        }
    }

    /// Synchronously triggers `CGRequestScreenCaptureAccess`. The OS displays
    /// the legacy TCC prompt if (and only if) the user has not previously been
    /// asked about this binary identity. Subsequent calls are no-ops.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Modern path: attempt `SCShareableContent.current` to trigger macOS 14+'s
    /// permission flow. On the first call from a not-yet-known binary, the OS
    /// surfaces the System Settings → Screen Recording prompt and adds the
    /// binary to the list. Returns the post-call state.
    @discardableResult
    public static func requestAsync() async -> State {
        await currentAsync()
    }
}
