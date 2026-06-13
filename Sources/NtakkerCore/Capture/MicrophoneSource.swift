// NtakkerCore/Capture/MicrophoneSource.swift — see project-design.md §2.8
//
// Phase E (plan-001) — finalized protocol. The microphone counterpart of
// `SystemAudioSource`. Conformers tag their emitted `CaptureBuffer`s
// with `.microphone`. See `SystemAudioSource.swift` (same folder) for
// the shared `AudioSource` supertype that defines the actual surface.

import Foundation
import CoreMedia

/// Marker protocol identifying a microphone source. Conformers tag
/// their emitted `CaptureBuffer`s with `.microphone`.
public protocol MicrophoneSource: AudioSource { }
