// MacrecCore/Transcription/SourceTag.swift — see project-design.md §LT-3.2
//
// Phase A (plan-003) — transcription namespace alias for the existing
// capture-side enum. We deliberately reuse `CaptureSourceTag` (defined at
// `Capture/CaptureBuffer.swift:20`) instead of introducing a parallel
// transcription enum, so a chunk's source label is a single source-of-
// truth across the audio pipeline and the transcription pipeline.
//
// Plan-003 §4 Phase A "Files to create" lists `SourceTag.swift` as an
// optional file: "(no new file needed if the existing enum is already
// public)". We keep it as a tiny typealias file so call sites under
// `Transcription/` can spell `SourceTag` and so the namespace is
// self-documenting; the underlying type is unchanged.

import Foundation

/// Source attribution for a transcription chunk. Aliased to the existing
/// capture-side `CaptureSourceTag` so that audio frames and the transcripts
/// derived from them share the same labels (`.system`, `.microphone`).
///
/// Design §LT-3.2: "do NOT introduce a parallel enum."
public typealias SourceTag = CaptureSourceTag

// MARK: - Transcription-namespace conformances on the underlying type
//
// `CaptureSourceTag` is declared in `Capture/CaptureBuffer.swift` as
// `String, Sendable, CaseIterable`. The transcription pipeline additionally
// needs `Codable` (jsonl sidecar writing — Phase D, but `TranscriptionEvent`
// declares the conformance up front so the protocol is locked in Phase A)
// and `Equatable` (test assertions on event sequences). Both are derivable
// for free from the `String` raw value, but conformance must be
// declared explicitly. We declare them here, in the transcription
// namespace, rather than editing the capture-side declaration, so the
// capture module's surface stays unchanged.
extension CaptureSourceTag: Codable {}
extension CaptureSourceTag: Equatable {}
