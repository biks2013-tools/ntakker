// MacrecCore/Capture/SystemAudioSource.swift — see project-design.md §2.8
//
// Phase E (plan-001) — finalized protocols. Defines the `AudioSource`
// supertype that both system-audio and microphone capture sources
// implement, plus the `SystemAudioSource` marker that the orchestrator
// uses to inject a system source. The microphone counterpart lives in
// `MicrophoneSource.swift`.
//
// The protocols are intentionally minimal so that:
//   * the in-process fake (`FakeAudioSource`) and the real implementations
//     (`SCKitSystemAudioSource`, `AVMicrophoneSource`) are exchangeable
//     without dragging ScreenCaptureKit / AVFoundation symbols into
//     callers that only need the protocol surface;
//   * `RecordingSession` can depend on the protocol alone (DI), which
//     is what makes the Phase E unit tests possible without TCC prompts.

import Foundation
import CoreMedia

// NOTE: `CaptureSourceTag` lives in `CaptureBuffer.swift` (§3.4) so that
// the envelope and its tag are co-located. Do not redeclare it here.

/// Common base protocol for any audio capture source in `macrec`.
///
/// Conformers must:
///   * Deliver buffers in the pipeline canonical format (Float32 / 48 kHz
///     / stereo, non-interleaved). Real sources reach this via a
///     per-source `AVAudioConverter`; the fake synthesizes it directly.
///   * Stamp `CMSampleBuffer.presentationTimeStamp` from
///     `CMClockGetHostTimeClock()` so that system + mic frames are
///     comparable on a single timeline (FR-22).
///   * Invoke `onSampleBuffer` on the source's own delivery queue. The
///     closure must enqueue and return promptly — heavy work belongs
///     downstream of the aligner.
public protocol AudioSource: AnyObject {
    /// The Core Media format description of the buffers this source
    /// emits *after* its per-source converter (or, for the fake, of the
    /// buffers it synthesizes). `nil` until the source has produced its
    /// first buffer or until `start()` has finished setting up its
    /// converter, whichever comes first.
    var formatDescription: CMAudioFormatDescription? { get }

    /// Set by the orchestrator **before** `start()`. Called on the
    /// source's own delivery queue.
    var onSampleBuffer: ((CaptureBuffer) -> Void)? { get set }

    /// Begin capturing. Idempotent — implementations should return
    /// immediately if already running. Throws on hard setup failures
    /// (permissions, device-not-found, SCStream setup failure, etc.).
    func start() async throws

    /// Stop capturing and tear down. Idempotent — implementations
    /// should return immediately if already stopped.
    func stop() async

    /// Latest unrecoverable error from the source, if any. The
    /// orchestrator's terminal-error poll surfaces this via the run
    /// loop's `.error` resolver, after which the session tears down
    /// the pipeline and surfaces the error from `RecordingSession.run`.
    ///
    /// The default implementation returns `nil`; sources that have no
    /// concept of an unrecoverable error (e.g. `FakeAudioSource`) keep
    /// the default and remain selectable as DI replacements.
    var terminalError: Error? { get }
}

extension AudioSource {
    /// Default — sources that have no terminal-error concept inherit
    /// this implementation and report `nil`.
    public var terminalError: Error? { nil }
}

/// Marker protocol identifying a system-audio source. Conformers tag
/// their emitted `CaptureBuffer`s with `.system`.
public protocol SystemAudioSource: AudioSource { }
