// MacrecCore/Transcription/AudioDownsampler.swift — see
// docs/research/audio-downsample-conversion.md §"Drop-In AudioDownsampler"
// and project-design.md §LT-6.3 / §LT-13.
//
// Phase B (plan-003) — verbatim drop-in of the research-doc class, adapted
// to the project's logging stack (`swift-log`'s `Logging.Logger` rather
// than `os.log.Logger`) so the downsampler integrates with
// `LoggerFactory.bootstrap(...)` like every other MacrecCore component.
//
// Threading & lifecycle reminders (the ones that matter for this file):
//
//   * NOT thread-safe. `convert(_:)` must be called from a single serial
//     context (in production: the `TranscriptionDriver`'s producer Task —
//     see §LT-6.3).
//   * One instance per recording session. Filter state is preserved
//     across chunks; do NOT recreate per chunk (R-Top4 in plan-003).
//   * Output format is hard-coded: PCM16-LE, 16 kHz, mono, interleaved.

import AVFoundation
import Foundation
import Logging

// MARK: - AudioDownsampler

/// Converts a continuous stream of Float32 / 48 kHz / non-interleaved PCM
/// buffers (mono or stereo) into Int16 / 16 kHz / mono / interleaved
/// little-endian `Data` chunks suitable for live-transcription APIs
/// (Gemini Live, Deepgram, AssemblyAI).
///
/// ## Threading
///
/// This type is NOT thread-safe. All calls to `convert(_:)` must arrive on
/// the same serial executor (e.g., the `TranscriptionDriver`'s producer
/// `Task`). The caller must never call `convert(_:)` from two different
/// queues simultaneously.
///
/// ## Lifecycle
///
/// Create once per recording session (or once per `TranscriptionDriver`).
/// Do NOT create a new instance per audio chunk — the underlying
/// `AVAudioConverter` maintains resampling filter state across calls to
/// preserve phase continuity. Recreating drops that state and produces an
/// audible click at every chunk boundary.
///
/// ## Output Format
///
/// Int16 / 16 000 Hz / mono / interleaved / little-endian. At 100 ms input
/// (4800 frames @ 48 kHz), expected output is ~1600 frames = 3200 bytes.
public final class AudioDownsampler {

    // MARK: - Constants

    /// Target sample rate for all transcription providers.
    public static let outputSampleRate: Double = 16_000

    /// Output channel count (mono).
    public static let outputChannelCount: AVAudioChannelCount = 1

    // MARK: - Private State

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let logger: Logger

    // MARK: - Init

    /// Creates a downsampler configured for the given input format.
    ///
    /// - Parameter inputFormat: The `AVAudioFormat` of the incoming PCM
    ///   buffers. Must be Float32, non-interleaved, sample rate 48 000 Hz
    ///   or 44 100 Hz, channel count 1 or 2.
    ///
    /// - Throws:
    ///   * `AudioDownsamplerError.unsupportedInputFormat` — input format
    ///     fails any of the constraints above.
    ///   * `AudioDownsamplerError.converterCreationFailed` —
    ///     `AVAudioConverter` cannot be instantiated for the format pair.
    public init(
        inputFormat: AVAudioFormat,
        logger: Logger = Logger(label: "macrec.transcription.downsampler")
    ) throws {
        // Validate input format constraints.
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved
        else {
            throw AudioDownsamplerError.unsupportedInputFormat(
                "Expected Float32 non-interleaved; got \(inputFormat)"
            )
        }
        guard inputFormat.channelCount == 1 || inputFormat.channelCount == 2 else {
            throw AudioDownsamplerError.unsupportedInputFormat(
                "Channel count must be 1 or 2; got \(inputFormat.channelCount)"
            )
        }
        // Per the phase-B brief, only 48 kHz and 44.1 kHz are supported.
        // Other rates would still resample correctly via AVAudioConverter
        // but they fall outside the contract the recording pipeline
        // currently produces and we want a fail-fast surface for the
        // downstream transcription tests.
        let sr = inputFormat.sampleRate
        guard sr == 48_000 || sr == 44_100 else {
            throw AudioDownsamplerError.unsupportedInputFormat(
                "Unsupported sample rate \(sr); expected 48000 or 44100"
            )
        }

        // Build the output format: Int16 / 16k / mono / interleaved.
        // For a single-channel (mono) format, interleaved and
        // non-interleaved are memory-equivalent; interleaved is used here
        // to match the conventional PCM wire format expected by
        // transcription APIs.
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioDownsampler.outputSampleRate,
            channels: AudioDownsampler.outputChannelCount,
            interleaved: true
        ) else {
            throw AudioDownsamplerError.converterCreationFailed(
                "AVAudioFormat(Int16/16k/1ch/interleaved) returned nil"
            )
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: outFmt) else {
            throw AudioDownsamplerError.converterCreationFailed(
                "AVAudioConverter(from: \(inputFormat), to: \(outFmt)) returned nil"
            )
        }

        // `.medium` (64) balances latency and quality for narrowband
        // speech. The mastering algorithm is left at default —
        // mastering-grade conversion provides no perceptible benefit at
        // 16 kHz / voice bandwidth and is slower per frame.
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        self.inputFormat = inputFormat
        self.outputFormat = outFmt
        self.converter = conv
        self.logger = logger
    }

    // MARK: - Conversion

    /// Converts one Float32 / 48 kHz input chunk into Int16 / 16 kHz / mono
    /// `Data`.
    ///
    /// Returns `nil` when the input buffer has zero frames (skip, no
    /// error), or when a conversion error occurs (the error is logged;
    /// recording continues unaffected).
    ///
    /// The caller must NOT modify `input` until after this method returns:
    /// the converter's input block may reference `input` until
    /// `convert(to:error:withInputFrom:)` returns.
    ///
    /// - Parameter input: A non-interleaved Float32 PCM buffer at the
    ///   sample rate this downsampler was constructed with, 1 or 2
    ///   channels. Typically 4800 frames (100 ms @ 48 kHz).
    ///
    /// - Returns: A `Data` value containing raw Int16 little-endian PCM
    ///   bytes, or `nil` on skip / error.
    public func convert(_ input: AVAudioPCMBuffer) -> Data? {
        // Guard: skip empty buffers — calling the converter with
        // frameLength=0 is safe but wastes CPU and may confuse downstream
        // consumers.
        guard input.frameLength > 0 else { return nil }

        // Compute output capacity from the actual number of input frames,
        // not from the buffer capacity. Use ceil to avoid off-by-one when
        // `frameLength` is not an exact multiple of the ratio.
        let ratio = inputFormat.sampleRate / outputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) / ratio)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            logger.error("AudioDownsampler: failed to allocate output buffer (capacity=\(outputCapacity))")
            return nil
        }

        // CRITICAL: set frameLength before calling convert; default is 0
        // and the converter would otherwise produce zero output.
        outputBuffer.frameLength = outputCapacity

        // Input-block state. The `gotData` flag enforces the correct
        // protocol:
        //   * First call:  .haveData  → return the input buffer
        //   * Second call: .noDataNow → return nil
        // This pattern is mandated by Apple's documentation. Never return
        // .endOfStream for a live stream — it permanently locks the
        // converter (Pitfall 6 in the research doc).
        var gotData = false
        var conversionError: NSError?

        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError,
            withInputFrom: { [input] (_, outStatus) -> AVAudioBuffer? in
                if gotData {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                gotData = true
                outStatus.pointee = .haveData
                return input
            }
        )

        switch status {
        case .haveData:
            // Normal path: all requested output was produced.
            break

        case .inputRanDry:
            // The converter produced some output but ran out of input
            // before filling the entire output buffer. `frameLength` has
            // been updated to reflect actual frames produced. Normal for
            // the last chunk or whenever input < a full window.
            break

        case .error:
            let msg = conversionError?.localizedDescription ?? "unknown"
            logger.error("AudioDownsampler: conversion error — \(msg). Dropping chunk.")
            return nil

        case .endOfStream:
            // Should not occur for a live stream; treat as no-data.
            logger.warning("AudioDownsampler: unexpected endOfStream status. Dropping chunk.")
            return nil

        @unknown default:
            logger.warning("AudioDownsampler: unknown status \(status.rawValue). Continuing.")
        }

        // Guard against zero-frame output (can happen if input was very
        // short).
        guard outputBuffer.frameLength > 0 else { return nil }

        // Extract raw Int16 bytes. On all Apple platforms (arm64, x86_64),
        // integers are stored little-endian in memory; no byte-swapping
        // needed before sending to PCM16-LE consumers (Gemini Live,
        // Deepgram, AssemblyAI).
        return extractInt16Data(from: outputBuffer)
    }

    // MARK: - Helpers

    /// Copies the valid Int16 PCM samples from `buffer` into a `Data` value.
    private func extractInt16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else {
            logger.error("AudioDownsampler: int16ChannelData is nil — unexpected format")
            return nil
        }
        let frameCount = Int(buffer.frameLength)
        // Each frame is 1 sample for mono; each sample is 2 bytes (Int16).
        let byteCount = frameCount * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}

// MARK: - Error Type

/// Errors raised by `AudioDownsampler.init(inputFormat:)`. Conversion-time
/// errors are logged and dropped (the convert method returns `nil`); they
/// do not surface as throws because the recording must remain unaffected
/// (NFR-17).
public enum AudioDownsamplerError: Error, CustomStringConvertible, Sendable {

    /// Input format violates one of the constraints checked at init time
    /// (must be Float32 non-interleaved, 1 or 2 channels, 48 kHz or
    /// 44.1 kHz).
    case unsupportedInputFormat(String)

    /// `AVAudioConverter(from:to:)` or `AVAudioFormat(...)` returned
    /// `nil` for the requested format pair — should not happen in
    /// practice for the supported input rates but surfaced here for
    /// fail-fast visibility.
    case converterCreationFailed(String)

    public var description: String {
        switch self {
        case .unsupportedInputFormat(let msg):
            return "AudioDownsampler: unsupported input format — \(msg)"
        case .converterCreationFailed(let msg):
            return "AudioDownsampler: converter creation failed — \(msg)"
        }
    }
}
