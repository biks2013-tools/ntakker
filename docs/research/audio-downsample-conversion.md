---
research_topic: "Float32/48kHz → PCM16/16kHz/mono via AVAudioConverter"
requested_by: investigation-live-transcription.md (Topic 2)
produced_at: "2026-04-26"
target_platform: macOS 14+
language: Swift
output_file: Sources/MacrecCore/Transcription/AudioDownsampler.swift (to be created)
---

# Audio Downsample Conversion: Float32/48kHz → PCM16/16kHz/Mono

## Overview

This document provides a complete implementation reference for the dedicated
`AVAudioConverter` that the transcription side-channel requires. The converter
bridges the audio formats as follows:

- **Input**: Float32 / 48 000 Hz / 1 or 2 channels / **non-interleaved** (planar)
  — the format produced by `SCKitSystemAudioSource` and emitted by
  `BufferSummer.summed` after the `HostClockAligner` tap.
- **Output**: Int16 / 16 000 Hz / 1 channel / **interleaved** — the raw PCM16
  little-endian format required by Gemini Live (`audio/pcm;rate=16000`),
  OpenAI Realtime (24 kHz variant aside), Deepgram, and AssemblyAI.

This converter is **separate** from all existing recorder converters per the
constraint in the refined request (§Technical): the M4A/WAV/CAF encoding
converters must not be reused.

---

## Key Concepts

### Why AVAudioConverter (not vDSP)

Apple TN3136 explicitly recommends `AVAudioConverter` for sample-rate conversion
between PCM buffers. Hand-rolled resamplers based on vDSP (decimation, linear
interpolation) introduce aliasing artefacts and must implement their own
anti-aliasing filter. `AVAudioConverter` uses the system's optimized
polyphase resampling kernel — the same kernel used by `AVAudioEngine` node
connections — without any of the setup cost of a full audio engine graph.

The FluidAudio framework guide states: "We do not implement custom resamplers
(e.g., linear interpolation/decimation). Always go through `AudioConverter` so
the system handles quality and buffering correctly."

### Interleaved vs. Non-Interleaved (Planar)

`AVAudioPCMBuffer` supports two memory layouts:

| Layout | Description | `floatChannelData` access |
|---|---|---|
| Non-interleaved (planar) | Each channel has its own buffer: `[L L L …][R R R …]` | `channelData[0]` = left, `channelData[1]` = right |
| Interleaved | Samples alternate by channel: `[L R L R L R …]` | Not accessible via `floatChannelData`; use `audioBufferList` |

`ScreenCaptureKit` delivers `CMSampleBuffer`s whose ASBD describes
**non-interleaved** (planar) Float32 stereo at 48 kHz. When converted to
`AVAudioPCMBuffer` via `CMSampleBufferCopyPCMDataIntoAudioBufferList`, the
buffer layout remains non-interleaved. The codebase scan confirms this in
`CaptureBuffer.swift:37–40`.

`BufferSummer.sum(_:_:)` operates element-wise on Float32 planar buffers and
returns a summed (mixed) mono or stereo planar buffer. After summing,
`BufferSummer.summed` is still non-interleaved.

For the output target (Int16 mono), **both interleaved and non-interleaved are
identical** for a single channel — there is only one stream of samples. The
output format is created with `interleaved: true` here to match the
conventional Gemini/Deepgram expectation of a packed byte stream. The
`Data` extraction path is the same either way for mono.

### Conversion Ratio

```
inputSampleRate  / outputSampleRate  = 48000 / 16000 = 3.0
inputFrameCount  / outputFrameCount ≈ 4800  / 1600  = 3.0
```

For a 100 ms input window at 48 kHz:
- Input frames: `0.100 × 48000 = 4800`
- Output frames: `0.100 × 16000 = 1600`

The converter buffers partial input internally across calls, so rounding is
handled by the system; the output may occasionally be 1599 or 1601 frames
without the caller needing to compensate.

### Stereo-to-Mono Downmix

`AVAudioConverter` performs stereo-to-mono downmix automatically when
`inputFormat.channelCount = 2` and `outputFormat.channelCount = 1`.

The exact mixing formula is not publicly documented by Apple. Empirical
evidence and the Core Audio convention suggest the system applies an
equal-amplitude mix: `(L + R) / 2`. This prevents clipping when both channels
carry full-scale signals and is the conventional stereo downmix for telephony
and speech pipelines.

Alternatively, the caller can force left-channel-only routing via
`converter.channelMap = [0]`. For a mixed system+mic source where both
channels carry distinct but equal-importance content, the default downmix
(`downmix = true` is implied when the channel counts differ) is the correct
choice.

### Internal State and Chunk Continuity

`AVAudioConverter` maintains internal state (delay line, filter history)
across consecutive `convert(to:error:withInputFrom:)` calls **when the same
converter instance is reused**. This is exactly what is needed for a
continuous real-time stream: the resampling filter's phase state carries over
from chunk to chunk, producing phase-continuous output.

- **Do not** create a new `AVAudioConverter` per chunk — it is expensive and
  discards the filter state, producing a click/discontinuity at every boundary.
- **Do not** reset or re-initialize the converter during the session.
- The converter is created once in `init` and lives for the duration of the
  recording session.

### Input Block Contract: `.haveData` / `.noDataNow`

The `withInputFrom:` block follows a strict contract:

1. On the **first** call of the block per `convert(to:error:withInputFrom:)`
   invocation: set `outStatus.pointee = .haveData` and return the input buffer.
2. On **subsequent** calls within the same `convert(…)` invocation (the
   converter may call the block multiple times if it needs more input to fill
   the output): set `outStatus.pointee = .noDataNow` and return `nil`.

**Never** return `.endOfStream` for a live stream. Doing so permanently locks
the converter (confirmed by multiple Apple Developer Forum reports). The
`.noDataNow` path signals "I have given you all available input; produce as
much output as you can and return".

### Output Buffer `frameLength` Pre-Set

`AVAudioPCMBuffer.frameLength` defaults to `0`. The converter uses
`frameLength` as its target fill count. You **must** set
`outputBuffer.frameLength = outputBuffer.frameCapacity` before calling
`convert(to:error:withInputFrom:)`; otherwise the converter produces zero
frames.

---

## Buffer Flow Diagram

```
HostClockAligner.onAlignedFrame  (macrec.aligner.serial queue)
        │
        │  AlignedFrame  { systemBuffer: AVAudioPCMBuffer?,
        │                  micBuffer:    AVAudioPCMBuffer? }
        │  Format: Float32 / 48000 Hz / 1-2 ch / non-interleaved
        │  Window: 100 ms  →  4800 frames
        ▼
BufferSummer.sum(systemBuffer, micBuffer)
        │
        │  summed: AVAudioPCMBuffer
        │  Format: Float32 / 48000 Hz / 1-2 ch / non-interleaved
        │  Frames: 4800
        ▼
AudioDownsampler.convert(_ input:)
        │
        ├─ guard input.frameLength > 0
        │
        │  outputBuffer: AVAudioPCMBuffer
        │  Format: Int16 / 16000 Hz / 1 ch / interleaved
        │  Capacity: 1600 frames  (= ceil(4800 / 3.0))
        │  frameLength: set to frameCapacity before convert
        │
        │  AVAudioConverter.convert(to: outputBuffer, …)
        │    inputBlock called once: .haveData  → returns input
        │    inputBlock called again: .noDataNow → returns nil
        │
        │  Actual output frameLength: ~1600 frames
        ▼
Data extraction  (UnsafeBufferPointer<Int16> → Data)
        │
        │  bytes: 1600 × 2 bytes = 3200 bytes per chunk
        │  byte order: little-endian (native on all Apple platforms)
        ▼
TranscriptionPCMChunk { pcmData: Data, sampleRate: 16000,
                        channelCount: 1, source: .mixed,
                        hostTime: … }
        │
        ▼
AsyncStream<TranscriptionPCMChunk>  (bounded, .bufferingNewest(64))
        │
        ▼
GeminiLiveTranscriptionProvider  (base64-encodes pcmData, sends via WebSocket)
```

---

## Drop-In `AudioDownsampler` Swift Class

This class is designed to be copied verbatim into
`Sources/MacrecCore/Transcription/AudioDownsampler.swift`.

```swift
import AVFoundation
import os.log

// MARK: - AudioDownsampler

/// Converts a continuous stream of Float32/48kHz/non-interleaved PCM buffers
/// (mono or stereo) into Int16/16kHz/mono/interleaved Data chunks suitable
/// for transmission to live-transcription APIs (Gemini Live, Deepgram, etc.).
///
/// ## Threading
/// This type is NOT thread-safe. All calls to `convert(_:)` must arrive on
/// the same serial queue (e.g., `macrec.aligner.serial`).  The caller must
/// never call `convert(_:)` from two different queues simultaneously.
///
/// ## Lifecycle
/// Create once per recording session (or once per `TranscriptionDriver`).
/// Do NOT create a new instance per audio chunk — the converter maintains
/// resampling filter state across calls to preserve phase continuity.
///
/// ## Output Format
/// Int16 / 16 000 Hz / mono / interleaved / little-endian.
/// At 100 ms input (4800 frames @ 48k), expected output is ~1600 frames = 3200 bytes.
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
    private let logger = Logger(subsystem: "com.local.macrec", category: "AudioDownsampler")

    // MARK: - Init

    /// Creates a downsampler configured for the given input format.
    ///
    /// - Parameter inputFormat: The `AVAudioFormat` of the incoming PCM buffers.
    ///   Must be Float32, non-interleaved.  Sample rate is typically 48000 Hz.
    ///   Channel count must be 1 (mono) or 2 (stereo).
    ///
    /// - Throws: `AudioDownsamplerError.unsupportedInputFormat` if the input
    ///   format is not Float32 non-interleaved, or
    ///   `AudioDownsamplerError.converterCreationFailed` if `AVAudioConverter`
    ///   cannot be instantiated for the format pair.
    public init(inputFormat: AVAudioFormat) throws {
        // Validate input format constraints.
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved else {
            throw AudioDownsamplerError.unsupportedInputFormat(
                "Expected Float32 non-interleaved; got \(inputFormat)"
            )
        }
        guard inputFormat.channelCount == 1 || inputFormat.channelCount == 2 else {
            throw AudioDownsamplerError.unsupportedInputFormat(
                "Channel count must be 1 or 2; got \(inputFormat.channelCount)"
            )
        }

        // Build the output format: Int16 / 16k / mono / interleaved.
        // For a single-channel (mono) format, interleaved and non-interleaved
        // are memory-equivalent; interleaved is used here to match the
        // conventional PCM wire format expected by transcription APIs.
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

        // Set sample-rate converter quality.
        // For speech-to-text: AVAudioQuality.medium (.medium = 64) balances
        // latency and quality well.  The difference between .medium and .max
        // is inaudible at 16 kHz / voice bandwidth.  Use .medium to reduce
        // per-chunk CPU time on slower machines.
        // The algorithm is left at the system default
        // (AVSampleRateConverterAlgorithm_Normal) — the "mastering" algorithm
        // provides no meaningful benefit for narrowband speech and is slower.
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        self.inputFormat = inputFormat
        self.outputFormat = outFmt
        self.converter = conv
    }

    // MARK: - Conversion

    /// Converts one Float32/48kHz input chunk into Int16/16kHz/mono `Data`.
    ///
    /// Returns `nil` when the input buffer has zero frames (skip, no error),
    /// or when a conversion error occurs (the error is logged; recording
    /// continues unaffected).
    ///
    /// The caller must NOT modify `input` until after this method returns
    /// (the converter's internal input block may reference `input` until the
    /// `convert(to:error:withInputFrom:)` call returns).
    ///
    /// - Parameter input: A non-interleaved Float32 PCM buffer at 48 kHz,
    ///   1 or 2 channels.  Typically 4800 frames (100 ms @ 48 kHz).
    ///
    /// - Returns: A `Data` value containing raw Int16 little-endian PCM bytes,
    ///   or `nil` on skip / error.
    public func convert(_ input: AVAudioPCMBuffer) -> Data? {
        // Guard: skip empty buffers — calling the converter with frameLength=0
        // is safe but wastes CPU and may confuse downstream consumers.
        guard input.frameLength > 0 else { return nil }

        // Compute output capacity from the actual number of input frames,
        // not from the buffer capacity.  Use ceil to avoid off-by-one when
        // frameLength is not an exact multiple of the ratio (3.0).
        let ratio = inputFormat.sampleRate / outputFormat.sampleRate  // 3.0
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

        // CRITICAL: set frameLength before calling convert; the default is 0
        // and the converter will produce zero output if this is not set.
        outputBuffer.frameLength = outputCapacity

        // Input-block state.  The 'gotData' flag enforces the correct protocol:
        //   - First call:  .haveData  → return the input buffer
        //   - Second call: .noDataNow → return nil
        // This pattern is mandated by Apple's documentation and avoids the
        // "converter replays the input indefinitely" bug.  Never return
        // .endOfStream for a live stream — it permanently locks the converter.
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
            // The converter produced some output but ran out of input before
            // filling the entire output buffer.  outputBuffer.frameLength has
            // been updated to reflect the actual frames produced.  This is
            // normal for the last chunk or whenever frameLength < 4800.
            break

        case .error:
            let msg = conversionError?.localizedDescription ?? "unknown"
            logger.error("AudioDownsampler: conversion error — \(msg). Dropping chunk.")
            return nil

        case .endOfStream:
            // Should not occur for a live stream; treat as a no-data condition.
            logger.warning("AudioDownsampler: unexpected endOfStream status. Dropping chunk.")
            return nil

        @unknown default:
            logger.warning("AudioDownsampler: unknown status \(status.rawValue). Continuing.")
        }

        // Guard against zero-frame output (can happen if input was very short).
        guard outputBuffer.frameLength > 0 else { return nil }

        // Extract raw Int16 bytes from the output buffer.
        // For an interleaved mono Int16 buffer, the audio data lives in a
        // single contiguous AudioBuffer.  We access it via int16ChannelData
        // (channel 0) which returns a pointer to the packed samples.
        //
        // On all Apple platforms (arm64, x86_64) integers are stored
        // little-endian in memory.  No byte-swapping is required before
        // sending to Gemini Live, Deepgram, or AssemblyAI, all of which
        // require PCM16 little-endian.
        return extractInt16Data(from: outputBuffer)
    }

    // MARK: - Helpers

    /// Copies the valid Int16 PCM samples from `buffer` into a `Data` value.
    ///
    /// Uses `int16ChannelData[0]` which returns a pointer to the first (and
    /// only, for mono) channel's sample array.  For an interleaved mono buffer
    /// this is identical to the raw AudioBufferList pointer.
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

public enum AudioDownsamplerError: Error, CustomStringConvertible {
    case unsupportedInputFormat(String)
    case converterCreationFailed(String)

    public var description: String {
        switch self {
        case .unsupportedInputFormat(let msg): return "AudioDownsampler: unsupported input format — \(msg)"
        case .converterCreationFailed(let msg): return "AudioDownsampler: converter creation failed — \(msg)"
        }
    }
}
```

---

## AVAudioFormat Initialization Reference

### Input Formats

Both of these should be created from the live buffer's `format` property
rather than constructed manually, because the ASBD that `ScreenCaptureKit`
provides is authoritative. However, for unit tests and documentation purposes:

```swift
// Mono Float32 48 kHz non-interleaved (e.g., after BufferSummer produces mono output)
let monoInputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48_000,
    channels: 1,
    interleaved: false
)!

// Stereo Float32 48 kHz non-interleaved (raw SCKit system audio)
let stereoInputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48_000,
    channels: 2,
    interleaved: false
)!
```

In the `TranscriptionDriver`, derive the input format from the actual buffer:

```swift
// Inside the HostClockAligner tap:
let summed: AVAudioPCMBuffer = BufferSummer.sum(frame.systemBuffer, frame.micBuffer)
// summed.format IS the canonical input format — pass it to AudioDownsampler.init
```

### Output Format

```swift
let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true   // conventional for PCM wire transmission
)!
```

### Confirming the Formats Match

`AVAudioConverter` will return `nil` at init time (not throw) if the format
pair is unsupported. The `throws` wrapper in `AudioDownsampler.init` converts
this into a structured error. Add a precondition-check log line at init to
surface format mismatches early in integration.

---

## Quality and Algorithm Settings

### `sampleRateConverterQuality`

`sampleRateConverterQuality` is an `Int` property. The values are drawn from
`AVAudioQuality`:

| Constant | Raw Value | Description |
|---|---|---|
| `.min` | 0 | Fastest, lowest quality — inappropriate for speech |
| `.low` | 32 | Acceptable for telephony; noticeable aliasing |
| `.medium` | 64 | Recommended for speech-to-text upstream |
| `.high` | 96 | Higher quality; marginal benefit for voice |
| `.max` | 127 | Highest quality; mastering grade; unnecessary for voice |

**Recommendation**: `.medium` (64). The speech frequency range (80–8000 Hz)
is well within the 8 kHz Nyquist of the 16 kHz output. Quality differences
between `.medium` and `.max` are not perceptible for ASR.

### `sampleRateConverterAlgorithm`

Two values are exposed:

| Constant | Description |
|---|---|
| `AVSampleRateConverterAlgorithm_Normal` (default) | Optimized for standard use cases |
| `AVSampleRateConverterAlgorithm_Mastering` | Higher-precision, higher-latency algorithm for studio mastering |

**Recommendation**: leave at the default (`AVSampleRateConverterAlgorithm_Normal`).
For speech, the mastering algorithm provides no benefit and adds unnecessary
CPU cost. The `AudioDownsampler` class above does not set this property,
relying on the default.

---

## Pitfall Reference

### Pitfall 1: Input Buffer with `frameLength = 0`

The `HostClockAligner` gap-fills silence, so genuinely zero-frame buffers
should be rare, but they can arrive if the aligner fires before either source
has produced data (startup transient) or when a segment rotation is in
progress.

**Handling**: The `convert(_:)` method returns `nil` immediately for
`frameLength == 0`. The caller (`TranscriptionDriver`) treats `nil` return
as a skip — the chunk is not enqueued and no error is logged.

### Pitfall 2: `convert()` Returns `.error`

Causes include: format mismatch detected at runtime (unlikely if `init` passed),
a system resource shortage, or an Apple framework bug on an edge-case macOS
version.

**Handling**: Log the `NSError` with category `macrec.transcription`, drop
the chunk, and continue. The recording is not affected. Consecutive errors
(>5 within 1 second) should escalate to `TranscriptEvent.error(isFatal: false)`
so the UI surfaces the degraded state.

### Pitfall 3: Input Is Interleaved Float32 Instead of Non-Interleaved

The codebase scan confirms `CaptureBuffer.swift:37–40` uses non-interleaved
Float32. `BufferSummer.sum(_:_:)` also operates on non-interleaved buffers
and returns non-interleaved output. The `AVAudioConverter` created in
`AudioDownsampler.init` expects non-interleaved input; if an interleaved
buffer were passed, the channel count and byte layout would be interpreted
incorrectly.

The `init` method guards on `!inputFormat.isInterleaved` and throws
`AudioDownsamplerError.unsupportedInputFormat` if this constraint is violated.

**Verification at integration time**: Add an assertion or precondition in the
`TranscriptionDriver` tap closure:

```swift
precondition(!summed.format.isInterleaved,
             "AudioDownsampler requires non-interleaved input")
```

### Pitfall 4: Frame Rounding at Chunk Boundaries

For a 100 ms window the ratio is exactly 3.0, so 4800 input frames produce
exactly 1600 output frames. If the input window is not exactly 100 ms (e.g.,
during startup, pause/resume transitions, or if the aligner's window size
ever changes), the frame count may not be an exact multiple of 3.

The converter handles this internally:
- Partial input frames are buffered inside the converter's state.
- On the next `convert()` call, those leftover samples are consumed first.
- Output `frameLength` after a short input will be less than `outputCapacity`;
  the `outputCapacity` is computed with `ceil()` to ensure the output buffer
  is always large enough.

**The caller does not need to manage carry-over manually.** This is a key
advantage of reusing a single converter instance.

### Pitfall 5: Forgetting to Set `outputBuffer.frameLength`

`AVAudioPCMBuffer.frameLength` defaults to 0. If the output buffer is
allocated but `frameLength` is not set to `frameCapacity` before calling
`convert(to:…)`, the converter interprets the target as "fill zero frames"
and returns immediately with `haveData` and a zero-length result.

The `AudioDownsampler.convert(_:)` implementation sets
`outputBuffer.frameLength = outputCapacity` before calling the converter.

### Pitfall 6: `.endOfStream` Locks the Converter

Never return `.endOfStream` from the input block for a live stream. Multiple
Apple Developer Forum reports confirm that after `.endOfStream` is returned,
the converter enters a terminal state and all subsequent conversions return
either empty output or `.error`. The converter must be discarded and recreated.

Use `.noDataNow` when there is no more input for the current call; use
`.endOfStream` only at true stream termination (which does not occur during
a recording session).

### Pitfall 7: `outputBuffer.frameLength` After Convert

The `status == .inputRanDry` case sets `outputBuffer.frameLength` to the
actual number of frames produced (which may be less than `outputCapacity`).
Always use `outputBuffer.frameLength` (not `frameCapacity`) to size the byte
extraction. The `extractInt16Data(from:)` helper reads `buffer.frameLength`
correctly.

---

## Validation: Test Case Reasoning

### Test Case 1: 100 ms Stereo Float32 Silence → Int16 Zeros

- Input: `AVAudioPCMBuffer`, format stereo Float32 48k non-interleaved,
  `frameLength = 4800`, all samples `0.0f`.
- `AudioDownsampler.init(inputFormat: stereoInputFormat)`: succeeds.
- `convert(_:)`:
  - `outputCapacity = ceil(4800 / 3.0) = 1600`
  - AVAudioConverter mixes L+R (both zero) → mono zero at 48k.
  - Downsamples 48k → 16k: output is all-zero at 16k.
  - `outputBuffer.frameLength = 1600` (status `.haveData`).
  - `extractInt16Data`: 1600 × 2 = 3200 bytes, all `0x00`.
- Expected result: `Data` of 3200 zero bytes. Pass.

### Test Case 2: 100 ms Mono Float32 1 kHz Sine → Int16 Sine at 1 kHz

- Input: `AVAudioPCMBuffer`, format mono Float32 48k non-interleaved,
  `frameLength = 4800`, samples = `sin(2π × 1000 × n/48000)` for n in 0..<4800.
- `convert(_:)`:
  - No channel mixing (already mono).
  - Downsamples 48k → 16k: applies anti-aliasing filter, retains 1 kHz
    component (well below 8 kHz Nyquist).
  - Output: 1600 Int16 samples representing `sin(2π × 1000 × n/16000)`.
- Expected result: `Data` of 3200 bytes encoding a 1 kHz sine at Int16 scale.
  Verify by decoding back to Float32 and checking frequency peak at 1 kHz.
  Pass.

### Test Case 3: Two Consecutive 50 ms Chunks → ~1600 Frames Total

- First call: input `frameLength = 2400` (50 ms @ 48k).
  - `outputCapacity = ceil(2400 / 3.0) = 800`
  - Converter produces 800 output frames. Returns Data of 1600 bytes.
- Second call: input `frameLength = 2400` (next 50 ms).
  - `outputCapacity = ceil(2400 / 3.0) = 800`
  - Converter consumes remaining input, produces 800 frames. Returns Data of
    1600 bytes.
- Total output: 800 + 800 = 1600 frames = 3200 bytes. Same as single 100 ms
  chunk. The converter's internal state correctly handles the split boundary
  without discontinuity. Pass.

> **Note on test infrastructure**: these tests can run in `MacrecCoreTests`
> without any TCC grants (they use only in-memory `AVAudioPCMBuffer` objects,
> not live capture). The `AudioDownsampler` class has no system audio
> dependency.

---

## Performance Notes

### Expected CPU Time per 100 ms Chunk on Apple Silicon

No published benchmark exists specifically for `AVAudioConverter` at this
format pair and chunk size on Apple Silicon. Reasoning from first principles:

- **Input**: 4800 Float32 samples (mono) or 9600 (stereo). At 4 bytes per
  sample, that is 19–38 KB of input per 100 ms.
- **Operation**: polyphase FIR downsampling at ratio 3:1, with optional
  stereo-to-mono mix. Apple's implementation uses Accelerate/vDSP internally.
- **Output**: 1600 Int16 samples = 3200 bytes.

On an M1/M2/M3 Apple Silicon chip, vDSP-backed polyphase filtering of 4800
Float32 samples runs in the range of **50–200 µs** (0.05–0.2 ms). This is
well under 1% of the 100 ms budget, and orders of magnitude below the network
I/O latency that dominates the transcription pipeline.

The converter creation in `init` is the expensive operation (allocates filter
state, validates format pair, may involve an `AudioConverter` graph allocation).
This is why it is done **once** at session start, not per chunk.

**Practical rule**: the downsample step is not a performance concern on any
Mac manufactured in 2020 or later. Profile only if sustained CPU usage
exceeds 10% from this module specifically.

### Memory per Chunk

- Input buffer: `4800 frames × 2 channels × 4 bytes = 38 400 bytes ≈ 38 KB`
  (stereo) or 19 KB (mono). This buffer is owned by the caller (aligner);
  `AudioDownsampler` does not copy it.
- Output buffer: `1600 frames × 1 channel × 2 bytes = 3200 bytes`. Allocated
  and released per `convert(_:)` call.
- At 10 calls/second (100 ms cadence), allocation rate is 3200 bytes × 10 =
  32 KB/s — negligible.

---

## Integration Checklist for `TranscriptionDriver`

1. Obtain the `AVAudioFormat` from the first non-nil `AlignedFrame` buffer
   **before** creating `AudioDownsampler`. Defer creation to the first frame,
   not to `TranscriptionDriver.init()` (the format is not known until capture
   starts and the aligner fires).

2. Create `AudioDownsampler` once and store it as an actor-isolated property.

3. In the `onAlignedFrame` tap closure (which runs on `macrec.aligner.serial`):
   a. Call `BufferSummer.sum(frame.systemBuffer, frame.micBuffer)` → `summed`.
   b. Call `downsampler.convert(summed)` → `Data?`.
   c. If not nil, construct `TranscriptionPCMChunk` and call
      `continuation.yield(.init(pcmData: data, …))`.
   d. Return immediately. Do not `await` inside this closure.

4. At session stop: the `AudioDownsampler` is released naturally when the
   `TranscriptionDriver` actor is deallocated. No explicit flush is needed
   (we discard the final partial chunk rather than trying to drain the
   converter's internal buffer — losing <100 ms of audio at session end is
   acceptable).

5. On pause/resume: the `AudioDownsampler` instance continues unchanged.
   There is no need to reset or recreate it across `RecordingSession.split()`
   calls, as the transcription tap does not participate in segment rotation.

---

## Assumptions and Scope

### Validated Assumptions

| Assumption | Confidence | Basis |
|---|---|---|
| `SCKitSystemAudioSource` produces Float32 non-interleaved at 48 kHz stereo | HIGH | Codebase scan `CaptureBuffer.swift:37–40`; ScreenCaptureKit WWDC22 docs; whisper.cpp discussion #2704 |
| `BufferSummer.summed` is non-interleaved | HIGH | Codebase scan §5; `BufferSummer.sum(_:_:)` element-wise on planar buffers |
| `AVAudioConverter` maintains filter state between `convert()` calls | HIGH | Apple Developer Forum confirmations; WhisperKit chunked-resampling discussion |
| The gotData flag is the correct input-block pattern | HIGH | Multiple independent Apple Developer Forum reports; TN3136 |
| `.endOfStream` locks the converter permanently | HIGH | Multiple Apple Developer Forum reports (threads 67106, 64180) |
| Int16 on Apple platforms is little-endian | HIGH | ARM64 and x86_64 are both little-endian; no byte-swap needed |
| `downmix = true` is automatically implied when channelCount differs | MEDIUM | Apple docs on `downmix` property; confirmed by search results |
| Stereo downmix formula is (L+R)/2 | MEDIUM | Core Audio convention; Apple does not publish the exact formula |
| `.medium` quality is sufficient for Gemini Live ASR accuracy | MEDIUM | General speech codec knowledge; no specific AVAudioConverter benchmark |
| `outputBuffer.frameLength` must be preset to `frameCapacity` | HIGH | Apple Developer Forum thread 67106; confirmed by multiple code samples |

### Open Questions for the Implementer

1. **Format derivation at runtime**: The `AudioDownsampler` is designed to
   accept any non-interleaved Float32 format. Confirm at integration time
   that `summed.format` is always non-interleaved when `BufferSummer` returns
   a single-channel result from two stereo inputs.

2. **Mono input from `mic`-only transcription source**: When
   `--transcribe-source mic` is selected and `AVMicrophoneSource` provides
   a mono Float32 buffer (AVCapture mic is typically 1 ch at the hardware
   sample rate), the `AudioDownsampler` must be initialized with that mono
   format instead. Confirm the mic source's native sample rate — if it is
   44100 Hz rather than 48000 Hz, the converter still handles this correctly
   (44100 → 16000 is a supported non-integer ratio).

3. **`outputBuffer.frameLength` after `.inputRanDry`**: Empirically verify
   (in a unit test) that after a short input (e.g., 2400 frames), the
   `outputBuffer.frameLength` is updated by the converter to reflect actual
   output, not left at `outputCapacity`. The documented behavior says it
   should be updated; confirm on macOS 14.

4. **Downmix channel order**: Verify that when stereo input is
   `[L_ch0, R_ch1]` non-interleaved, the converter's default `downmix`
   behavior selects `(L+R)/2` and not just channel 0. This can be validated
   by feeding a stereo buffer where L=1.0 and R=0.0 (or vice versa) and
   checking the output amplitude. Expected: 0.5. If the result is 1.0 or 0.0,
   only one channel is being selected (channel mapping, not mixing).

5. **`sampleRateConverterQuality` thread safety**: The quality property is
   set once at `init` and never modified. The property documentation does not
   explicitly call it thread-safe. Since `AudioDownsampler` documents that all
   calls must arrive on the same serial queue, this is not a practical concern.

---

## References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Apple TN3136: AVAudioConverter sample rate conversions | https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions | Apple-recommended primitive for SRC; confirms vDSP hand-rolling is discouraged |
| 2 | Apple: AVAudioConverter reference | https://developer.apple.com/documentation/avfaudio/avaudioconverter | convert(to:error:withInputFrom:) signature; .haveData/.noDataNow/.endOfStream contract |
| 3 | Apple: AVAudioConverterOutputStatus | https://developer.apple.com/documentation/avfaudio/avaudioconverteroutputstatus | .haveData / .inputRanDry / .endOfStream / .error output status values |
| 4 | Apple: AVAudioConverter.downmix | https://developer.apple.com/documentation/avfaudio/avaudioconverter/1388244-downmix | Boolean: mixes channels vs. remaps; implied true when channelCounts differ |
| 5 | Apple: sampleRateConverterQuality | https://developer.apple.com/documentation/avfaudio/avaudioconverter/samplerateconverterquality | Int property; AVAudioQuality raw values |
| 6 | Apple: AVSampleRateConverterAlgorithm_Normal | https://developer.apple.com/documentation/avfaudio/avsamplerateconverteralgorithm_normal | Normal vs. Mastering algorithm constants |
| 7 | Apple Developer Forums: Use AVAudioConverter to convert AVAudioPCMBuffer | https://developer.apple.com/forums/thread/67106 | gotData pattern; .endOfStream lock risk; frameLength presetting |
| 8 | Apple Developer Forums: AVAudioConverter buffers over-filled | https://developer.apple.com/forums/thread/727705 | Internal buffering behavior; haveData loop bug |
| 9 | Apple Developer Forums: AVAudioEngine sample rate conversion | https://developer.apple.com/forums/thread/88144 | Converter creation cost; reuse pattern |
| 10 | CopyProgramming: AVAudioConverter stuttering | https://copyprogramming.com/howto/avaudioconverter-with-avaudioconverterinputblock-stutters-audio-after-processing | gotData flag pattern to prevent replay; .noDataNow after first submit |
| 11 | tad-iizuka/PCMDownSamplingSample | https://github.com/tad-iizuka/PCMDownSamplingSample | Worked Swift example: PCM 44100→16000 via AVAudioConverter+Engine |
| 12 | tad-iizuka AVAudioConverter Gist | https://gist.github.com/tad-iizuka/cde8ec749a4ce3eaff7067484dc1ce06 | Code pattern for installTap + AVAudioConverter downsampling |
| 13 | FluidInference/FluidAudio: AudioConversion guide | https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Guides/AudioConversion.md | "Never roll your own resampler; always go through AVAudioConverter"; chunked streaming pattern |
| 14 | whisper.cpp Discussion #2704: SCKit AVAudioPCMBuffer Conversion | https://github.com/ggml-org/whisper.cpp/discussions/2704 | Real-world pattern for SCKit → Float32 → 16k conversion; confirms non-interleaved output format from SCKit |
| 15 | WhisperKit Issue #16: Resample in chunks | https://github.com/argmaxinc/WhisperKit/issues/16 | Chunked conversion pattern; memory concerns with single large buffer |
| 16 | Apple Developer Forums: Convert stereo to mono | https://developer.apple.com/forums/thread/722285 | channelMap vs. downmix property for stereo-to-mono routing |
| 17 | Apple: int16ChannelData | https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/1388925-int16channeldata | Returns pointer to Int16 channel data; nil for non-Int16 formats |
| 18 | Apple: ScreenCaptureKit WWDC22 | https://developer.apple.com/videos/play/wwdc2022/10156/ | SCKit audio: up to 48 kHz stereo; CMSampleBuffer delivery |
| 19 | Apple Developer Forums: convertToBuffer:fromBuffer:error | https://developer.apple.com/documentation/avfaudio/avaudioconverter/1388341-converttobuffer | Simple (non-block) conversion path for offline use; not suitable for streaming |

### Recommended for Deep Reading

- **Apple TN3136** (ref 1): The authoritative Apple document on `AVAudioConverter`
  for sample-rate conversion. Required reading before modifying `AudioDownsampler`.
- **Apple Developer Forums thread 67106** (ref 7): The most comprehensive
  community discussion of the `gotData` pattern, the `.endOfStream` lock, and
  `frameLength` presetting. Contains multiple independently confirmed code
  samples.
- **whisper.cpp Discussion #2704** (ref 14): The closest existing real-world
  example of exactly this conversion (SCKit Float32 stereo 48k → Float32 mono
  16k), differing only in the output format (Float32 vs. Int16). The pattern
  in `AudioDownsampler` is a direct adaptation.
