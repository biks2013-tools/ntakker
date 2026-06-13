// NtakkerCore/Permissions/SpeechPermission.swift
// Reference: plan-005-apple-speech-streaming.md §"Phase C — SpeechPermission + NtakkerError case"
//
// Wraps `SFSpeechRecognizer.authorizationStatus()` and
// `SFSpeechRecognizer.requestAuthorization(_:)` for the Apple on-device
// Speech framework. Mirrors the surface of `MicrophonePermission` and
// `ScreenRecordingPermission` (a `State` enum with the four documented
// values, a synchronous `current()` reader, and an async `request()`
// trigger) so call sites and tests have a uniform shape across the three
// TCC-gated capabilities.
//
// `ensureGranted()` is the new helper required by the streaming Apple
// Speech provider: it reads the current state, prompts once if it is
// `.notDetermined`, and either resolves to authorized or throws
// `NtakkerError.transcriptionPermissionDenied(provider: "apple")`.

import Foundation
import Speech

public enum SpeechPermission {
    /// Four-valued state. Maps 1:1 to `SFSpeechRecognizerAuthorizationStatus`.
    public enum State: String, Sendable, Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    /// Reads the current Speech Recognition authorization status without
    /// prompting.
    public static func current() -> State {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    /// Triggers the Speech Recognition TCC prompt if the current status is
    /// `.notDetermined`; returns the post-prompt state.
    ///
    /// `SFSpeechRecognizer.requestAuthorization(_:)` is callback-based, so
    /// we bridge it to async/await with `withCheckedContinuation`.
    public static func request() async -> State {
        await withCheckedContinuation { (continuation: CheckedContinuation<State, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    /// **No-op on macOS 26+ when using `SpeechAnalyzer`.** Empirical
    /// finding from the plan-005 Phase I e2e debug session (2026-04-28):
    /// the modern `SpeechAnalyzer` API does not require any TCC permission
    /// — it runs entirely on-device using assets from
    /// `AssetInventory.assetInstallationRequest(...)` and does not invoke
    /// the legacy `SFSpeechRecognizerAuthorization` flow. Construction,
    /// audio ingestion, and result streaming all proceed without any
    /// `kTCCServiceSpeechRecognition` IPC.
    ///
    /// The legacy `SFSpeechRecognizer.requestAuthorization(_:)` call —
    /// which this method previously made — instead aborts the process
    /// with SIGABRT on ad-hoc-signed CLIs on macOS 26 (TCC framework
    /// rejects the request even when `NSSpeechRecognitionUsageDescription`
    /// is correctly embedded in the binary's `__TEXT,__info_plist`
    /// section). The same call works fine on `.app` bundles signed with
    /// a real Developer ID. Since SpeechAnalyzer doesn't need the TCC
    /// grant at all, we simply skip the preflight.
    ///
    /// `current()` and `request()` are kept as informational APIs (for
    /// `ntakker-cli check-permissions` and any future Developer-ID-signed
    /// `.app` packaging that uses the legacy SFSpeechRecognizer pathway),
    /// but `ensureGranted()` itself is a no-op and never throws.
    public static func ensureGranted() async throws {
        // Intentional no-op; see method docs.
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> State {
        switch status {
        case .authorized:    return .authorized
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }
}
