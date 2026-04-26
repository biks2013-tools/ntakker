// MacrecCore/Permissions/MicrophonePermission.swift
// Reference: project-design.md §2.6 and §8.2
//
// Wraps `AVCaptureDevice.authorizationStatus(for:)` and
// `AVCaptureDevice.requestAccess(for:)` for the `.audio` media type.

import AVFoundation
import Foundation

public enum MicrophonePermission {
    /// Four-valued state. Maps 1:1 to `AVAuthorizationStatus`.
    public enum State: String, Sendable, Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    /// Reads the current microphone authorization status without prompting.
    public static func current() -> State {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Triggers the microphone TCC prompt if the current status is
    /// `.notDetermined`; returns the post-prompt state.
    ///
    /// `AVCaptureDevice.requestAccess(for:)` is callback-based, so we bridge
    /// it to async/await with `withCheckedContinuation`. The Bool delivered
    /// to the completion handler is true iff the post-prompt status is
    /// `.authorized`; we ignore the boolean and re-read `current()` so we
    /// can return the full four-valued state (e.g. `.restricted` from MDM).
    public static func request() async -> State {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume()
            }
        }
        return current()
    }

    private static func map(_ status: AVAuthorizationStatus) -> State {
        switch status {
        case .authorized:    return .authorized
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }
}
