// MacrecCore/Transcription/Persistence/SidecarPathBuilder.swift
//
// Phase D (plan-003 §4 Phase D) — pure helper that derives the URL of
// a transcript sidecar file from a recording's audio URL. No I/O. No
// logging. Every method is a pure function over its inputs so unit
// tests can pin down every naming case verbatim.
//
// The naming rules follow FR-51 (refined-request-live-transcription.md)
// updated by plan-004 R-LT-1 to include a `.transcript.` infix that
// disambiguates the sidecar from any other file derived from the same
// recording:
//
//   audio:                                   sidecar:
//   recording-2026-04-26-22-30-00.m4a    →   recording-2026-04-26-22-30-00.transcript.jsonl
//   recording-2026-04-26-22-30-00.part01.m4a → recording-2026-04-26-22-30-00.part01.transcript.jsonl
//
// Per-source split: when `--layout split` AND `--transcribe-source both`,
// the writer emits TWO sidecars — one per `SourceTag`. The source label
// is inserted as a dot-separated suffix BEFORE the `transcript` token:
//
//   recording-2026-04-26-22-30-00.system.transcript.jsonl
//   recording-2026-04-26-22-30-00.microphone.transcript.jsonl
//
// For multi-part + per-source split the part token comes BEFORE the
// source token so all parts of the same segment sort adjacently when
// the directory is listed alphabetically:
//
//   recording-….part02.system.transcript.jsonl
//   recording-….part02.microphone.transcript.jsonl
//
// (Mirrors the audio-file convention enforced by `SegmentNamer.partURL`
// — but `SegmentNamer` uses `mic` while transcripts use `microphone`
// to match the `SourceTag` rawValue. This is intentional: audio
// filenames are tightly bound to the existing `--layout split` shipping
// convention, while transcript filenames follow the public
// `SourceTag` rawValue used in the JSONL `source` field.)

import Foundation

/// Pure URL-derivation helper for the transcript sidecar files written
/// by `TranscriptSidecarWriter`. Stateless — no instances are ever
/// constructed.
public enum SidecarPathBuilder {

    /// Compute the URL of the transcript sidecar that pairs with a
    /// recording's audio URL.
    ///
    /// - Parameters:
    ///   - recording: The audio file URL the sidecar pairs with. Only
    ///     the directory and the filename stem are read — the audio
    ///     extension is replaced with the transcript extension. The
    ///     filename's path components (including any embedded dots
    ///     that are part of the user-chosen basename) are preserved
    ///     verbatim except for the trailing extension.
    ///   - format: The chosen sidecar format. Drives the file
    ///     extension (`jsonl`, `srt`, `vtt`, `txt`).
    ///   - partNumber: When non-nil, inserts a `.partNN` infix before
    ///     the format extension (and before the source token if
    ///     present). `NN` is zero-padded to two digits — `partNumber:
    ///     1` produces `…part01.<ext>` exactly. The caller decides
    ///     whether part numbering is required (multi-segment
    ///     recordings do; a single-segment recording calls with
    ///     `partNumber: nil`).
    ///   - sourceTag: When non-nil, inserts a per-source token (the
    ///     `SourceTag.rawValue`, currently `"system"` or
    ///     `"microphone"`) just before the format extension. Callers
    ///     pass `nil` for `mixed` recordings or single-source
    ///     transcription where one sidecar represents the whole
    ///     stream.
    /// - Returns: The transcript sidecar URL.
    public static func sidecarURL(forRecording recording: URL,
                                  format: TranscriptFormat,
                                  partNumber: Int? = nil,
                                  sourceTag: SourceTag? = nil) -> URL {

        let folder = recording.deletingLastPathComponent()
        // The "stem" is the filename without its trailing extension.
        // Dots that are part of the stem (e.g. timestamps formatted
        // with periods, or the user's own basename containing dots)
        // are preserved.
        let stem = recording.deletingPathExtension().lastPathComponent

        var components: [String] = [stem]

        if let partNumber {
            precondition(partNumber >= 0,
                "partNumber must be non-negative when provided")
            components.append(String(format: "part%02d", partNumber))
        }

        if let sourceTag {
            components.append(sourceTag.rawValue)
        }

        // R-LT-1 (plan-004 Phase F.1): insert the `transcript` infix
        // immediately before the format extension so the sidecar is
        // unambiguously identifiable as a transcript artefact.
        components.append("transcript")
        components.append(format.rawValue)

        let filename = components.joined(separator: ".")
        return folder.appendingPathComponent(filename)
    }
}
