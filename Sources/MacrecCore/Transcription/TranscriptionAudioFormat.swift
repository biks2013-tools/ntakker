// MacrecCore/Transcription/TranscriptionAudioFormat.swift — see project-design.md §LT-3.2
//
// Phase A (plan-003) — value type describing the PCM format a
// `TranscriptionProvider` consumes. The transcription driver reads a
// provider's `requiredAudioFormat` and configures its `AudioDownsampler`
// accordingly (Phase B). v1's only real provider, Gemini Live, requires
// `pcm16le16k1ch`; the type is parameterised so future providers (e.g.
// OpenAI Realtime, Deepgram) can advertise different formats without
// schema churn.

import Foundation

/// PCM wire format advertised by a `TranscriptionProvider`.
///
/// All four fields are required; this type intentionally has NO default
/// initializer (project rule: "never substitute the missing config value
/// with a default or a fallback value"). Use the named static factories
/// (e.g. `pcm16le16k1ch`) for the canonical formats.
public struct TranscriptionAudioFormat: Sendable, Equatable {

    /// Sampling rate in Hz (e.g. `16_000`).
    public let sampleRate: Int

    /// Bit depth per sample (e.g. `16`).
    public let bitDepth: Int

    /// Channel count (`1` for mono, `2` for stereo). v1 providers all use mono.
    public let channelCount: Int

    /// Endianness of the encoded sample stream.
    public let byteOrder: ByteOrder

    /// Endianness label. Kept as a nested enum so the type's name spells
    /// itself out at use sites (`TranscriptionAudioFormat.ByteOrder.little`).
    public enum ByteOrder: String, Sendable, Equatable, Codable {
        case little
        case big
    }

    public init(sampleRate: Int, bitDepth: Int, channelCount: Int, byteOrder: ByteOrder) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.byteOrder = byteOrder
    }

    /// Canonical 16-bit little-endian, 16 kHz, mono. The format every v1
    /// provider (Gemini Live) accepts on input.
    public static let pcm16le16k1ch = TranscriptionAudioFormat(
        sampleRate: 16_000,
        bitDepth: 16,
        channelCount: 1,
        byteOrder: .little
    )
}
