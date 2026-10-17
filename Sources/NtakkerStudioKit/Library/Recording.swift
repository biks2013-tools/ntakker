// NtakkerStudioKit/Library/Recording.swift — plan-024 T2.
//
// A recording is the set of files in one folder that share a filename
// stem: the audio track(s), the transcript sidecars, the studio's own
// metadata and the generated minutes / Q&A notes.
//
//   <stem>.m4a | .wav | .caf                  mixed or stereo-split audio
//   <stem>.mic.<ext> + <stem>.system.<ext>    split layout
//   <stem>.transcript.jsonl                   main transcript
//   <stem>.<label>.transcript.jsonl           per-source transcript
//                                             (microphone / system) or a
//                                             re-transcription
//   <stem>.studio.json                        studio metadata
//   <stem>.minutes.md / <stem>.studio-qa.md   studio outputs
//
// Each `.partNN` of a split session is its own recording (its stem
// ends in `.partNN`), because each part has its own audio and
// transcripts.

import Foundation
import NtakkerCore

/// What an audio file carries.
public enum AudioTrackRole: String, Sendable, Codable, CaseIterable {
    /// The whole mix (or a stereo-split file, which plays as one).
    case mixed
    case microphone
    case system

    /// Source tag a transcript of this track is written with. A mixed
    /// track has no source of its own; `.system` is used, as it is
    /// the "everything that was heard" side.
    public var sourceTag: SourceTag {
        switch self {
        case .microphone: return .microphone
        case .mixed, .system: return .system
        }
    }

    /// Filename token used for a per-track derived file.
    public var fileToken: String {
        switch self {
        case .mixed: return "mixed"
        case .microphone: return "microphone"
        case .system: return "system"
        }
    }
}

public struct AudioTrack: Sendable, Hashable, Codable {
    public let url: URL
    public let role: AudioTrackRole

    public init(url: URL, role: AudioTrackRole) {
        self.url = url
        self.role = role
    }
}

/// One transcript sidecar of a recording.
public struct TranscriptFile: Sendable, Hashable, Codable, Identifiable {
    public var id: URL { url }
    public let url: URL
    /// The tokens between the stem and `.transcript.jsonl`, joined by
    /// dots. Empty for the main transcript.
    public let label: String

    public init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    /// Short name for the transcript picker.
    public var displayName: String {
        switch label {
        case "": return "Transcript"
        case "microphone": return "Microphone"
        case "system": return "System audio"
        default: return label
        }
    }
}

public struct Recording: Sendable, Hashable, Identifiable {
    /// Folder path + stem; stable across rescans.
    public var id: String { folder.appendingPathComponent(stem).path }

    public let folder: URL
    public let stem: String
    public let tracks: [AudioTrack]
    public let transcripts: [TranscriptFile]
    /// Other files that belong to the recording (minutes, notes, the
    /// bundle's `transcript.md` / `qa.md` when the folder holds only
    /// this recording).
    public let attachments: [URL]
    /// Creation date of the first audio file — the best available
    /// estimate of when recording started.
    public let createdAt: Date
    /// Sum of the audio files' sizes.
    public let byteSize: Int64
    /// Whether other recordings (not just this one's parts) live in the
    /// same folder.
    public let sharesFolder: Bool

    public init(
        folder: URL,
        stem: String,
        tracks: [AudioTrack],
        transcripts: [TranscriptFile],
        attachments: [URL],
        createdAt: Date,
        byteSize: Int64,
        sharesFolder: Bool = false
    ) {
        self.folder = folder
        self.stem = stem
        self.tracks = tracks
        self.transcripts = transcripts
        self.attachments = attachments
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.sharesFolder = sharesFolder
    }

    /// Name shown in the library: the session folder's name when the
    /// recording has its folder to itself, otherwise the stem.
    public var displayName: String {
        guard !sharesFolder else { return stem }
        let folderName = folder.lastPathComponent
        if let part = partNumber { return "\(folderName) · part \(part)" }
        return folderName
    }

    /// `NN` of a `.partNN` stem.
    public var partNumber: Int? {
        guard let last = stem.split(separator: ".").last,
              last.hasPrefix("part"), last.count == 6,
              let n = Int(last.dropFirst(4)) else { return nil }
        return n
    }

    public var metadataURL: URL { folder.appendingPathComponent("\(stem).studio.json") }
    public var minutesURL: URL { folder.appendingPathComponent("\(stem).minutes.md") }
    public var studioQAURL: URL { folder.appendingPathComponent("\(stem).studio-qa.md") }

    /// URL for a new transcript `<stem>.<label>.transcript.jsonl`.
    public func transcriptURL(label: String) -> URL {
        label.isEmpty
            ? folder.appendingPathComponent("\(stem).transcript.jsonl")
            : folder.appendingPathComponent("\(stem).\(label).transcript.jsonl")
    }
}
