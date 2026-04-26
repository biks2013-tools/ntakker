# AVAssetWriter AAC Priming, Sample Alignment, and Live Finalization for `.m4a` Output

> **Scope:** Technical reference for `MacrecCore/Encoding/M4ARecorder.swift` and
> `MacrecCore/RecordingSession.swift`. Covers AVAssetWriter lifecycle, AAC priming,
> CMSampleBuffer requirements from the aligner, SIGINT-safe finalization, and format
> comparisons (m4a / wav / caf). Swift 5.9+, macOS 14.0 minimum.

---

## Table of Contents

1. [TL;DR — Copy-Paste Snippets](#1-tldr--copy-paste-snippets)
2. [Lifecycle Reference](#2-lifecycle-reference)
3. [AAC Priming](#3-aac-priming)
4. [Aligner Integration](#4-aligner-integration)
5. [SIGINT-Safe Finalization](#5-sigint-safe-finalization)
6. [Format-Specific Notes](#6-format-specific-notes)
7. [Open Issues](#7-open-issues)
8. [Sources](#8-sources)

---

## 1. TL;DR — Copy-Paste Snippets

### 1.1 AVAssetWriter for `.m4a` (AAC-LC, 192 kbps, 48 kHz stereo)

```swift
import AVFoundation
import CoreMedia

/// Call once on a dedicated serial queue (e.g. `writerQueue`).
/// `startTime` must be `CMClock.hostTimeClock.time` captured
/// at the moment the recording is started — NOT the PTS of the first
/// incoming buffer (see §2.3 for the "uptime PTS" trap).
func makeM4AWriter(outputURL: URL, startTime: CMTime) throws -> (AVAssetWriter, AVAssetWriterInput) {
    // 1. Writer
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

    // Enable moov-at-front so a partial file is playable after a crash.
    // NOTE: this trades a small write-amplification cost at finalization
    // for much better crash-recovery posture (AC-7).
    writer.shouldOptimizeForNetworkUse = true

    // 2. Channel layout (required for unambiguous stereo signaling)
    var channelLayout = AudioChannelLayout()
    memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
    channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo

    // 3. Output settings — feed LPCM Float32 in, receive AAC-LC out.
    let outputSettings: [String: Any] = [
        AVFormatIDKey:          Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey:        48_000,
        AVNumberOfChannelsKey:  2,
        AVEncoderBitRateKey:    192_000,   // 192 kbps
        AVChannelLayoutKey:     Data(bytes: &channelLayout,
                                     count: MemoryLayout<AudioChannelLayout>.size)
    ]

    // 4. Input — must have expectsMediaDataInRealTime = true for live capture.
    let audioInput = AVAssetWriterInput(mediaType: .audio,
                                        outputSettings: outputSettings)
    audioInput.expectsMediaDataInRealTime = true

    writer.add(audioInput)

    // 5. Lifecycle — startWriting THEN startSession.
    guard writer.startWriting() else {
        throw writer.error ?? NSError(domain: "M4ARecorder", code: -1)
    }
    writer.startSession(atSourceTime: startTime)

    return (writer, audioInput)
}

/// Call on `writerQueue` to append each buffer from the aligner.
/// Buffers must be LPCM Float32, 48 kHz, stereo, non-interleaved.
/// PTS values must be monotonically increasing and gap-free.
func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
    guard input.isReadyForMoreMediaData else {
        // Back-pressure: the encoder is full. In a real-time pipeline
        // with `expectsMediaDataInRealTime = true` this should be rare;
        // log a warning and drop the buffer rather than block.
        return
    }
    input.append(sampleBuffer)
}

/// Call when stopping (SIGINT or max-duration reached).
/// `endTime` = CMClock.hostTimeClock.time at the moment of stop.
func finish(writer: AVAssetWriter, input: AVAssetWriterInput,
            endTime: CMTime, completion: @escaping (Error?) -> Void) {
    input.markAsFinished()
    writer.endSession(atSourceTime: endTime)
    writer.finishWriting {
        completion(writer.error)
    }
}
```

**Key decisions and why:**

| Decision | Rationale |
|---|---|
| `startSession(atSourceTime: CMClock.hostTimeClock.time)` | Avoids the "uptime PTS" trap where using the first buffer's raw PTS bakes the host uptime (possibly 20 h) into the file's first-frame duration (§2.3) |
| `shouldOptimizeForNetworkUse = true` | Moves the `moov` atom to the front of the file, making partially-written files playable after crash or SIGINT kill (AC-7) |
| `expectsMediaDataInRealTime = true` | Required for live capture; causes `readyForMoreMediaData` to be computed against encoder throughput, not queue depth |
| `AVChannelLayoutKey` with `kAudioChannelLayoutTag_Stereo` | Strictly required only when `AVNumberOfChannelsKey > 2`, but including it eliminates ambiguity and ensures QuickTime reads stereo correctly |
| LPCM Float32 input | `AVAssetWriterInput` with non-nil `outputSettings` requires uncompressed PCM input; Float32 is what the aligner produces after `AVAudioConverter` |

---

### 1.2 AVAudioFile for `.wav` (16-bit PCM, 48 kHz stereo)

```swift
import AVFoundation

/// On-disk format: 16-bit signed integer, little-endian, interleaved.
/// Processing format fed to `write(from:)`: Float32 (AVAudioFile converts).
func makeWAVFile(outputURL: URL) throws -> AVAudioFile {
    let settings: [String: Any] = [
        AVFormatIDKey:              kAudioFormatLinearPCM,
        AVSampleRateKey:            48_000.0,
        AVNumberOfChannelsKey:      2,
        AVLinearPCMBitDepthKey:     16,
        AVLinearPCMIsFloatKey:      false,
        AVLinearPCMIsBigEndianKey:  false,   // WAV = little-endian
        AVLinearPCMIsNonInterleaved: false   // WAV = interleaved
    ]
    return try AVAudioFile(forWriting: outputURL,
                           settings: settings,
                           commonFormat: .pcmFormatFloat32,
                           interleaved: false)
    // Write by calling: try audioFile.write(from: avAudioPCMBuffer)
}
```

**Important:** Construct the settings dictionary manually — do not pass `buffer.format.settings` directly because it can trigger a runtime conflict between `interleaved` and `AVLinearPCMIsNonInterleaved`.

---

### 1.3 AVAudioFile for `.caf` (PCM, 48 kHz stereo)

```swift
func makeCAFFile(outputURL: URL) throws -> AVAudioFile {
    let settings: [String: Any] = [
        AVFormatIDKey:              kAudioFormatLinearPCM,
        AVSampleRateKey:            48_000.0,
        AVNumberOfChannelsKey:      2,
        AVLinearPCMBitDepthKey:     24,      // CAF supports 24-bit cleanly
        AVLinearPCMIsFloatKey:      false,
        AVLinearPCMIsBigEndianKey:  true,    // CAF = big-endian by default
        AVLinearPCMIsNonInterleaved: false
    ]
    return try AVAudioFile(forWriting: outputURL,
                           settings: settings,
                           commonFormat: .pcmFormatFloat32,
                           interleaved: false)
}
```

**Justification for using `AVAudioFile` rather than `AVAssetWriter` for `.caf` PCM:**
- `AVAudioFile` handles `.caf` cleanly and supports 24-bit PCM with correct big-endian byte order.
- AAC-in-CAF has no meaningful advantage over AAC-in-m4a for this use case.
- `AVAudioFile` has no priming-pad concern for PCM-CAF (no encoder delay on LPCM).
- `AVAssetWriter` would add unnecessary ceremony for a pure PCM write path.

---

### 1.4 SIGINT-Safe Finalization Snippet

```swift
import Dispatch
import Foundation
import AVFoundation

/// M4ARecorder must expose a thread-safe stop() method that drives the
/// AVAssetWriter finalization. Call this pattern from RecordingSession.
final class SignalHandler {
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    /// Call once during setup, before startCapture().
    func install(stopAction: @escaping () -> Void) {
        // Block default signal disposition FIRST.
        // Must be done before makeSignalSource to avoid race.
        Darwin.signal(SIGINT,  SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)

        let q = DispatchQueue(label: "macrec.signal", qos: .userInteractive)

        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: q)

        for source in [sigintSource!, sigtermSource!] {
            source.setEventHandler { stopAction() }
            source.resume()
        }
    }
}

// In RecordingSession:
final class RecordingSession {
    private let writerQueue = DispatchQueue(label: "macrec.writer")
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isStopping = false

    func stop(completion: @escaping (Error?) -> Void) {
        writerQueue.async { [self] in
            guard !isStopping else { return }
            isStopping = true

            // 1. Tell capture sources to deliver no more buffers.
            //    (implementation-specific; drain the ring buffer here)

            // 2. Finalize writer.
            guard let writer = assetWriter,
                  let input = audioInput,
                  writer.status == .writing else {
                completion(nil)
                return
            }

            input.markAsFinished()
            writer.endSession(atSourceTime: CMClock.hostTimeClock.time)
            writer.finishWriting {
                // Called on an internal AVFoundation queue.
                DispatchQueue.main.async {
                    completion(writer.error)
                    exit(writer.error == nil ? 0 : 1)
                }
            }

            // 3. Timeout watchdog — if finishWriting hangs > 30 s, force exit.
            writerQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard self != nil else { return }
                fputs("macrec: finishWriting timed out — exiting with partial file\n",
                      stderr)
                exit(2)
            }
        }
    }
}
```

---

## 2. Lifecycle Reference

### 2.1 Correct Ordering

```
AVAssetWriter(outputURL:fileType:)
  │
  ├── configure properties (.shouldOptimizeForNetworkUse etc.)
  │
  ├── AVAssetWriterInput(mediaType:outputSettings:)
  │     └── .expectsMediaDataInRealTime = true
  │
  ├── assetWriter.add(audioInput)
  │
  ├── assetWriter.startWriting()          ← writer enters .writing status
  │     ⚠ check return value / .error
  │
  ├── assetWriter.startSession(atSourceTime: T0)
  │     ← T0 = CMClock.hostTimeClock.time at recording start
  │
  ├── ─ ─ ─ capture loop ─ ─ ─
  │     audioInput.append(sampleBuffer)   ← repeat for every buffer
  │     (check .isReadyForMoreMediaData before each append)
  │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  │
  ├── audioInput.markAsFinished()         ← signals no more data
  │
  ├── assetWriter.endSession(atSourceTime: T_end)
  │     ← T_end = CMClock.hostTimeClock.time at stop
  │     ← optional but strongly recommended; without it,
  │        AVFoundation uses last buffer's PTS + duration
  │
  └── assetWriter.finishWriting { ... }   ← async; completion on internal queue
        ← file is NOT valid until completion fires
```

### 2.2 What Happens If You Skip Steps

| Skipped step | Failure mode |
|---|---|
| `startWriting()` not called | `append` logs "Must call startWriting first"; no crash but all buffers silently dropped |
| `startSession` not called | `append` crashes: "Must start a session using startSessionAtSourceTime: first" |
| `markAsFinished()` not called before `finishWriting` | `finishWriting` marks all inputs as finished automatically — but the final segment may be slightly truncated if the encoder hasn't flushed all pending frames |
| `endSession` not called | `finishWriting` uses the last appended buffer's `presentationTimeStamp + duration` as T_end — acceptable but less explicit |
| `finishWriting` not called (process killed) | File on disk is the temp file (randomized name, same directory as output); original output path does not exist or is incomplete. With `movieFragmentInterval` set, partial data may be recoverable |
| `append` called after `markAsFinished` | Logged error: "Cannot append sample buffer: Input is already marked as finished" |
| `finishWriting` called concurrently with `append` | Data race — undefined behavior; use a serial `writerQueue` to prevent this |

### 2.3 The Uptime PTS Trap

`CMClock.hostTimeClock` measures time since the system last booted. If your Mac has been running for 20 hours, the first audio buffer from `AVCaptureSession` (with `synchronizationClock = CMClockGetHostTimeClock()`) will have a PTS of ~72,000 seconds.

If you call `startSession(atSourceTime: firstBuffer.presentationTimeStamp)`, AVFoundation interprets the session as beginning at that huge time value. Relative to the session start the buffers appear close together, BUT some players calculate first-frame duration as `secondPTS - sessionStartTime`, which becomes enormous.

**The fix:** capture `CMClock.hostTimeClock.time` the instant the user issues `start`, store it as `sessionStartTime`, and use it for `startSession`. Retime incoming buffers relative to this time (subtract `firstBufferPTS - sessionStartTime`) OR accept that the file uses absolute host-time PTSs (which also works, as long as `startSession` uses the same reference point).

**Nonstrict's alternative approach:** call `startSession(atSourceTime: .zero)` and retime every buffer by subtracting `firstBufferPTS`. This produces a file whose timeline starts at 00:00:00, which is useful for QuickTime compatibility. The trade-off is that every buffer must go through `CMSampleBuffer(copying:withNewTiming:)`, adding allocations on the hot path.

**Recommendation for this project:** use `startSession(atSourceTime: CMClock.hostTimeClock.time)` captured at `RecordingSession.start()`. The aligner already produces buffers stamped in the host clock domain, so their PTSs will be numerically close to `sessionStartTime`. Playback in QuickTime will show the recording as starting at a non-zero offset, but duration and sync correctness are preserved. `afinfo` will report the correct duration.

### 2.4 Multiple Sessions

Multiple sessions (calling `startSession` a second time after `endSession`) are **not supported** by `AVAssetWriter`. The writer can only be used for one recording session; create a new `AVAssetWriter` instance for each recording.

### 2.5 Writer Status State Machine

```
.unknown  →  .writing  →  .completed
                       →  .failed
                       →  .cancelled  (if finishWriting is never called and object is released)
```

Always check `writer.status` and `writer.error` before and after critical operations.

---

## 3. AAC Priming

### 3.1 What the Priming Pad Is

AAC-LC is a block-based codec: the encoder needs 2112 input samples before it can produce its first valid output packet. These "priming frames" are silent padding inserted by the encoder at the start of every AAC bitstream.

From Apple TN2258:
- Priming = **2112 samples** at the head of the bitstream.
- Remainder = samples added at the end to round up to a 1024-frame packet boundary.
- A playback system must trim 2112 samples from the decoder output to hear audio start at t=0.

### 3.2 What AVAssetWriter Does Automatically

When you feed uncompressed LPCM into `AVAssetWriterInput` with `outputSettings` containing `kAudioFormatMPEG4AAC`, AVFoundation runs the AAC encoder internally. The resulting priming metadata is embedded in the container:

- For `.m4a` (MPEG-4 audio): AVFoundation writes the `iTunSMPB` tag in the `udta` atom AND the `edit list` atom (`elst`) to signal the priming offset. QuickTime Player, Music.app, and `AVAudioPlayer` all respect this automatically.
- The `kCMSampleBufferAttachmentKey_TrimDurationAtStart` attachment is applied **automatically by AVFoundation** to the first compressed output packet when the encoder's output is being written by `AVAssetWriter`. You do NOT need to apply it manually when using LPCM-in/AAC-out via `AVAssetWriterInput.outputSettings`.

**You only need to apply `TrimDurationAtStart` manually if you are feeding already-encoded AAC packets directly** (i.e., with `outputSettings: nil` and a source format hint). That path is not our pipeline.

### 3.3 Expected `afinfo` Output (AC-4)

For a 30-second recording at 48 kHz stereo, 192 kbps:

```
File: test.m4a
File type ID: m4af
Num Tracks: 1
----
Data format: 2 ch, 48000 Hz, 'aac ' (0x00000000)
  0 bits/channel, 0 bytes/packet, 1024 frames/packet, 0 bytes/frame
Channel layout: Stereo (L R)
estimated duration: 30.020000 sec
audio bytes: ~720000
audio packets: ~1407
bit rate: 192000 bits per second
audio 1440960 valid frames + 2112 priming + 832 remainder = 1443904
optimized
```

Key points:
- `2112 priming` confirms the encoder delay is correctly recorded.
- `optimized` confirms `shouldOptimizeForNetworkUse = true` moved the moov atom to the front.
- `valid frames` = `30 × 48000 = 1,440,000` (approximately; slight variation due to aligner timing).
- Duration should be within ±0.5 s of 30 s (AC-4).

### 3.4 Effect of Priming on Reported Duration

The priming frames do NOT inflate the reported duration in `afinfo`. The `estimated duration` field reflects only the `valid frames` count. QuickTime and AVPlayer automatically skip the priming pad on playback. No action needed by `M4ARecorder`.

### 3.5 AAC Priming and the `AVAudioConverter` in the Pipeline

The investigation notes that recreating `AVAudioConverter` per buffer causes dropped priming frames and produces silence runs. This applies to the converter used for **resampling** (mic 16 kHz → 48 kHz), not to the AVAssetWriter's internal encoder. One converter instance per source per session is the correct pattern. The AVAssetWriter encoder is a separate, opaque state machine that is correctly initialized once per writer session.

---

## 4. Aligner Integration

### 4.1 What Shape of CMSampleBuffer AVAssetWriterInput Requires

When `outputSettings` is non-nil (our AAC case), `AVAssetWriterInput.append(_:)` requires:

| Property | Required value |
|---|---|
| Format | Linear PCM (uncompressed) — `kAudioFormatLinearPCM` |
| Sample type | Float32 is accepted (and is what our aligner produces) |
| Interleaving | Non-interleaved is preferred (matches `AVAudioConverter` output) |
| Sample rate | Must match `AVSampleRateKey` in `outputSettings` (48 kHz) |
| Channel count | Must match `AVNumberOfChannelsKey` (2) |
| PTS | Must be valid (`CMTimeFlags.valid` set), monotonically increasing |
| Duration | Non-zero; `PTS + duration` must equal next buffer's PTS (no gaps, no overlaps) |
| `dataBuffer` | Non-nil `CMBlockBuffer` with actual sample data |
| `dataReady` | Must be `true` |

### 4.2 Monotonic PTS Requirement

`AVAssetWriterInput` processes buffers in the order they are appended. It does not sort or reorder them. If a buffer arrives with a PTS that is less than or equal to the previous buffer's `PTS + duration`, the behavior is undefined (may silently drop, may corrupt the track). The aligner MUST guarantee strict monotonicity.

### 4.3 Synthesized Silence Fill Buffers

When one source (e.g. SCStream) stalls for 50 ms while the mic stream keeps flowing, the aligner must insert silence-fill `CMSampleBuffer`s to maintain the timeline. These synthesized buffers:

- MUST carry a `CMBlockBuffer` of zeros of the correct byte length.
- MUST carry a valid `CMSampleTimingInfo` with `presentationTimeStamp` = the next expected PTS and `duration` = the gap duration.
- MUST use the same `CMAudioFormatDescription` as the real buffers.
- Are accepted by `AVAssetWriterInput.append(_:)` without any special treatment — they look like silent audio, which is valid.

**Creating a silence-fill CMSampleBuffer:**

```swift
func makeSilenceBuffer(
    startPTS: CMTime,
    duration: CMTime,
    formatDescription: CMAudioFormatDescription,
    sampleRate: Double = 48_000
) throws -> CMSampleBuffer {
    let frameCount = Int(duration.seconds * sampleRate)
    guard frameCount > 0 else { throw SilenceError.zeroDuration }

    // Non-interleaved Float32, 2 channels
    let bytesPerFrame = MemoryLayout<Float32>.stride
    let bytesPerChannel = frameCount * bytesPerFrame
    let totalBytes = bytesPerChannel * 2

    // Allocate zeroed block buffer
    var blockBuffer: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,        // let CM allocate
        blockLength: totalBytes,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: totalBytes,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else { throw SilenceError.allocationFailed }

    // Zero the memory (silence)
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer,
                               offsetIntoDestination: 0, dataLength: totalBytes)

    var timingInfo = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(sampleRate)),
        presentationTimeStamp: startPTS,
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let createStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timingInfo,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard createStatus == noErr, let sampleBuffer else { throw SilenceError.createFailed }
    return sampleBuffer
}

enum SilenceError: Error {
    case zeroDuration, allocationFailed, createFailed
}
```

**Note on `CMBlockBufferFillDataBytes`:** this is the correct API to zero a `CMBlockBuffer` without going through `UnsafeMutableRawPointer`. Avoids the ownership issue of passing a Swift-managed allocation to Core Media.

### 4.4 Converting AVAudioPCMBuffer to CMSampleBuffer

If the pipeline intermediate representation is `AVAudioPCMBuffer`, convert to `CMSampleBuffer` for the writer using `CMSampleBufferSetDataBufferFromAudioBufferList`:

```swift
func cmSampleBuffer(from pcmBuffer: AVAudioPCMBuffer,
                    presentationTime: CMTime) throws -> CMSampleBuffer {
    let asbd = pcmBuffer.format.streamDescription

    var formatDescription: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard let fmt = formatDescription else { throw ConvertError.formatFailed }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: fmt,
        sampleCount: CMItemCount(pcmBuffer.frameLength),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard let sb = sampleBuffer else { throw ConvertError.createFailed }

    CMSampleBufferSetDataBufferFromAudioBufferList(
        sb,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        bufferList: pcmBuffer.mutableAudioBufferList
    )
    return sb
}

enum ConvertError: Error { case formatFailed, createFailed }
```

### 4.5 Sample Rate and Format Constraints

- The mic may deliver 16 kHz mono Int16. The pipeline must resample to 48 kHz Float32 stereo **before** calling `append`. The `AVAudioConverter` instance handles this.
- `AVAssetWriterInput` with AAC `outputSettings` does NOT require Int16. Float32 is perfectly valid LPCM input and is preferred (avoids an extra quantization step).
- `AVChannelLayoutKey` is strictly required only when `AVNumberOfChannelsKey > 2`. For stereo (2 channels) it is optional per the SDK, but including it is recommended for clarity and compatibility with all decoders.
- `AVEncoderAudioQualityKey` and `AVSampleRateConverterAudioQualityKey` are NOT supported in `AVAssetWriterInput` output settings. Do not include them; they will be ignored or cause errors.

### 4.6 `readyForMoreMediaData` Back-Pressure

In live recording with `expectsMediaDataInRealTime = true`:
- `readyForMoreMediaData` is `false` only when the encoder cannot keep up.
- The correct response is to **drop the buffer** and log a warning (do not queue it up in memory — that is unbounded growth).
- Under normal desktop load on Apple Silicon this should never become `false` for 48 kHz stereo AAC at 192 kbps.

---

## 5. SIGINT-Safe Finalization

### 5.1 Full Pattern

The key constraint: signal handlers run in an async, interrupt context. You MUST NOT do meaningful work (memory allocation, Objective-C messaging, Swift runtime calls) directly in a POSIX signal handler. The canonical macOS Swift pattern is:

1. Suppress the default signal disposition with `Darwin.signal(SIGINT, SIG_IGN)`.
2. Create a `DispatchSourceSignal` on a private serial queue.
3. In the event handler (which runs on that queue, in a safe context), call the recording stop method.
4. The stop method calls `markAsFinished` + `endSession` + `finishWriting(completionHandler:)`.
5. In the `finishWriting` completion, call `exit(0)`.

```swift
// In RecordingSession (full SIGINT pattern):

private func installSignalHandlers() {
    Darwin.signal(SIGINT,  SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)

    let signalQueue = DispatchQueue(label: "macrec.signals", qos: .userInteractive)

    for sig in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        src.setEventHandler { [weak self] in
            self?.stop { error in
                if let error { fputs("macrec: stop error: \(error)\n", stderr) }
                // exit() is called inside stop's completion handler
            }
        }
        src.resume()
        signalSources.append(src)   // retain
    }
}
```

### 5.2 How Long Does `finishWriting` Take?

`AVAssetWriter` writes sample data to a **temporary file** during recording. `finishWriting` then:
1. Writes the `moov` atom (file header).
2. Appends or rearranges data from the temp file into the final output path.

For a 60-minute, 192 kbps AAC stereo recording:
- File size ≈ 192,000 bits/s × 3600 s / 8 = ~86 MB.
- With `shouldOptimizeForNetworkUse = true`: the moov atom (small, ~50–200 KB) is written first, then the mdat. Finalization time is dominated by the copy of the mdat, which on modern Apple Silicon (M1/M2 with SSD) takes approximately **2–8 seconds** for 86 MB.
- Without `shouldOptimizeForNetworkUse`: similar time; just different atom order.

**Bottom line:** For AC-7 (SIGINT must produce a playable file), the 30-second timeout watchdog in the finalization snippet (§1.4) provides ample headroom. On Apple Silicon the actual time should be well under 10 seconds for a 60-minute file.

### 5.3 Timeout and Recovery Strategy

```swift
// Inside stop(), on writerQueue:

writer.finishWriting { [weak self] in
    // Success path — cancel the watchdog.
    self?.finishWatchdog?.cancel()
    completion(writer.error)
    exit(writer.error == nil ? 0 : 1)
}

// Watchdog: schedule on a separate queue to avoid blocking writerQueue.
finishWatchdog = DispatchWorkItem {
    fputs("macrec: WARNING — finishWriting exceeded 30s timeout.\n", stderr)
    fputs("macrec: Output file at \(outputURL.path) may be incomplete.\n", stderr)
    // The temp file may contain recoverable data in the same directory.
    exit(2)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: finishWatchdog!)
```

**If `finishWriting` hangs:**
- The temp file (same directory as output, randomized name) contains raw sample data. It is recoverable with `ffmpeg` or `mp4box` in some cases, but this is not guaranteed.
- Setting `movieFragmentInterval` (e.g. `CMTime(value: 2, timescale: 1)` for 2-second fragments) causes the writer to flush complete, independently decodable fragments during recording. If the process is killed before `finishWriting`, the fragmented data can be read by VLC and `ffmpeg`. Apple's docs note that if `finishWriting` completes normally, the fragmented file is defragmented into a standard m4a.

**Recommended approach for AC-7:** use `shouldOptimizeForNetworkUse = true` (primary recovery mechanism) AND set `movieFragmentInterval = CMTime(value: 2, timescale: 1)` as a belt-and-suspenders measure. Accept that the normal-completion path defragments to a clean m4a, while a hard-kill path leaves a fragmented but playable file.

```swift
writer.shouldOptimizeForNetworkUse = true
writer.movieFragmentInterval = CMTime(value: 2, timescale: 1) // flush every 2 s
```

### 5.4 Thread Safety of append vs. finishWriting

It is explicitly not safe to call `finishWriting` concurrently with `append`. The implementation must transition through a state machine:

```
RECORDING → STOPPING → (no more appends allowed) → finishWriting called
```

Use a flag guarded by the serial `writerQueue`:

```swift
// On writerQueue:
private var state: WriterState = .idle

func append(_ buf: CMSampleBuffer) {
    writerQueue.async {
        guard self.state == .recording else { return }
        self.audioInput?.append(buf)
    }
}

func stop(completion: @escaping (Error?) -> Void) {
    writerQueue.async {
        guard self.state == .recording else { return }
        self.state = .stopping
        // ... markAsFinished, endSession, finishWriting ...
    }
}
```

---

## 6. Format-Specific Notes

### 6.1 m4a (AAC-LC in MPEG-4 Audio)

| Property | Details |
|---|---|
| Container | MPEG-4 Part 14 (`.mp4` / `.m4a`) |
| Codec | AAC-LC (`kAudioFormatMPEG4AAC`) |
| Priming pad | 2112 frames, signaled in `elst` edit list and `iTunSMPB`; handled automatically by AVFoundation |
| Atom order | `ftyp` + `moov` + `mdat` with `shouldOptimizeForNetworkUse = true`; else `ftyp` + `mdat` + `moov` |
| Crash recovery | With `movieFragmentInterval` set, fragments are independently decodable even if `finishWriting` is never called |
| Writer choice | **AVAssetWriter** — required for bitrate control (AVAudioFile ignores `AVEncoderBitRateKey` for compressed formats) |
| `afinfo` field | Shows `priming` = 2112 in the valid/priming/remainder line |
| QuickTime compat | Full: opens cleanly in QuickTime Player, Music.app, VLC |

### 6.2 wav (Linear PCM in RIFF/WAVE)

| Property | Details |
|---|---|
| Container | RIFF/WAVE |
| Codec | Linear PCM (`kAudioFormatLinearPCM`) |
| Priming pad | None — PCM has no encoder delay |
| Byte order | Little-endian (WAV standard) |
| Bit depth | 16-bit signed integer (per FR-7 default; 24-bit via `--bit-depth 24`) |
| Float32 input | `AVAudioFile` with `commonFormat: .pcmFormatFloat32` accepts Float32 and converts to the on-disk format automatically |
| Known issue | Passing `buffer.format.settings` directly to `AVAudioFile(forWriting:settings:...)` triggers a runtime conflict; always construct the dictionary manually |
| Writer choice | **AVAudioFile** — simpler API, correct behavior for PCM |
| Crash recovery | WAV file is written sequentially; the RIFF chunk size in the header will be wrong if the file is truncated, but the sample data is intact and recoverable with most tools |

### 6.3 caf (CoreAudio Format)

| Property | Details |
|---|---|
| Container | CoreAudio Format (Apple-specific) |
| Codec for our use | Linear PCM (AAC-in-CAF is possible but not recommended for this project) |
| Priming pad | For PCM-CAF: none. For AAC-CAF: the `.caf` spec has an explicit packet table chunk (`pakt`) that carries priming and remainder exactly — more accurate than m4a's `iTunSMPB` heuristic |
| Byte order | Big-endian by default for CAF |
| Bit depth | 24-bit PCM is cleanly supported (unlike WAV where float-to-int conversion has known CoreAudio bugs) |
| Float support | CAF supports Float32 on-disk (unlike WAV) |
| Writer choice | **AVAudioFile** for PCM-CAF — cleaner and correct. AVAssetWriter for AAC-CAF if required (not in our v1 scope) |
| QuickTime compat | CAF is readable by QuickTime and AVPlayer but not by most non-Apple players — recommend m4a for broad compatibility |

### 6.4 Pipeline Differences Summary

```
m4a (AAC):
  Float32/48kHz/stereo → AVAssetWriterInput (outputSettings=AAC)
  → AVAssetWriter handles: AAC encoding, priming metadata, moov atom

wav (PCM):
  Float32/48kHz/stereo → AVAudioFile.write(from: AVAudioPCMBuffer)
  → AVAudioFile handles: Float32→Int16 conversion, RIFF header

caf (PCM):
  Float32/48kHz/stereo → AVAudioFile.write(from: AVAudioPCMBuffer)
  → AVAudioFile handles: format conversion, pakt chunk
  (no priming concern; no encoder delay in PCM)
```

---

## 7. Open Issues

### 7.1 Priming With `.zero` Session Start vs. Host-Clock Session Start (CONFIDENCE: MEDIUM)

The Nonstrict blog uses `startSession(atSourceTime: .zero)` and retimes every buffer. This produces cleaner-looking timestamps in QuickTime but adds allocations per buffer. Our recommendation (use the host-clock time at recording start) avoids per-buffer allocation but means the file timeline does not start at zero. The impact on AC-4 / AC-12 has not been directly validated; desk research indicates both approaches are valid.

**Clarifying question:** Does the downstream transcription/analysis pipeline (mentioned as a future phase) care whether the file timeline starts at zero or at a large host-time value?

### 7.2 `movieFragmentInterval` + `shouldOptimizeForNetworkUse` Interaction (CONFIDENCE: MEDIUM)

Apple's docs state that `finishWriting` defragments the output if `movieFragmentInterval` is set. It is unclear whether `shouldOptimizeForNetworkUse = true` affects the defragmentation order or introduces extra overhead. Community reports confirm both can be set simultaneously without errors, but the exact output structure has not been verified.

**Action item:** After implementing M4ARecorder, run `afinfo` and `mp4info` on a recording to confirm the atom order and priming values are as expected.

### 7.3 Hard-Kill Recovery (CONFIDENCE: LOW)

If the process receives `SIGKILL` (not `SIGINT` or `SIGTERM`), no cleanup code runs. The temp file left by `AVAssetWriter` has a randomized name in the output directory. Its content is raw mdat data without a moov atom. With `movieFragmentInterval` set, the temp file should be a valid fragmented mp4 that VLC can open; `ffmpeg -i tempfile.mp4 -c copy recovered.m4a` may recover the content. This has not been tested.

**Recommendation:** Document the temp file location in `docs/tools/macrec.md` troubleshooting section.

### 7.4 `finishWriting` Duration for 60-Minute File (CONFIDENCE: MEDIUM)

The 2–8 second estimate for `finishWriting` duration on Apple Silicon is based on file size calculation and general SSD throughput, not a direct measurement. Actual time will depend on system load, SSD model, and file caching. The 30-second timeout is conservative.

**Action item:** Time `finishWriting` during AC-11 acceptance testing (60-minute recording) and adjust the timeout if needed.

### 7.5 `AVAssetWriterInput` Non-Interleaved Float32 Acceptance (CONFIDENCE: HIGH)

The requirement that input be "linear PCM" when `outputSettings` is non-nil is well-documented. Float32 non-interleaved is a valid LPCM format. However, the AVAssetWriter header and SDK documentation do not explicitly enumerate all accepted LPCM subtypes. The community consensus (Apple Forum threads, open-source implementations) is that Float32 works correctly.

### 7.6 AAC at 48 kHz vs. 44.1 kHz Priming Count (CONFIDENCE: HIGH)

TN2258 states 2112 priming samples as the standard. This count is sample-count-based, not time-based, so it applies to 48 kHz sources identically: 2112 samples at 48 kHz = 44 ms of silence. `afinfo` will show `2112 priming` regardless of sample rate. The priming duration in seconds differs by sample rate (2112/44100 ≈ 47.9 ms vs. 2112/48000 = 44 ms) but the sample count remains 2112.

---

## 8. Sources

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Apple Technical Note TN2258 — AAC Encoder Delay and Synchronization | https://developer.apple.com/library/archive/technotes/tn2258/_index.html | Definitive reference on 2112-frame priming, remainder, and how QuickTime/CoreAudio handle trimming. States that m4a and caf both support explicit priming metadata. |
| 2 | Nonstrict — Recording to disk with ScreenCaptureKit | https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/ | Canonical AVAssetWriter lifecycle walkthrough (startWriting → startSession → append → endSession → finishWriting). Code for retiming buffers relative to firstSampleTime. `startSession(atSourceTime: CMClock.hostTimeClock.time)` pattern. |
| 3 | Nonstrict — Handling audio capture gaps on macOS | https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos/ | `nextExpectedAudioTime` pattern for gap detection and silence-fill insertion. Confirms the issue exists on macOS 14 with both AVCaptureSession and AVAudioEngine. |
| 4 | Apple Developer Forums — Writing video and audio via AVAssetWriter | https://developer.apple.com/forums/thread/3655 | Lifecycle ordering; endSession is optional; finishWriting auto-marks inputs as finished; temp file mechanism explanation. |
| 5 | Apple Developer Forums — Why is my AVAssetWriterInput failing to append | https://developer.apple.com/forums/thread/683994 | "Input buffer must be in an uncompressed format" error cause and fix; compressed-input vs. outputSettings=nil distinction. |
| 6 | Apple Developer Forums — Write AAC files in a way that they are always playable | https://developer.apple.com/forums/thread/720691 | `shouldOptimizeForNetworkUse = true` moves moov to front; recommended for crash-safe recordings. |
| 7 | Apple Developer Forums — AVAssetWriter takes too long time | https://developer.apple.com/forums/thread/687733 | `finishWriting` duration scales with recording length; temp file behavior; `movieFragmentInterval` as mitigation. |
| 8 | Apple Developer Forums — Temp file used in AVAssetWriter | https://developer.apple.com/forums/thread/109896 | Confirms temp file is in the same directory as the output; file is not readable until `finishWriting` completes (without fragmentation). |
| 9 | HaishinKit.swift GitHub Discussion — Prevent File Record Loss | https://github.com/HaishinKit/HaishinKit.swift/discussions/1189 | `movieFragmentInterval` confirmed to preserve data when the process is killed mid-recording. Fragmented file remains readable. |
| 10 | Fandom Engineering / Grzegorz Aperliński — Priming CMSampleBuffer containing AAC-encoded data | https://medium.com/fandom-engineering/priming-cmsamplebuffer-containing-aac-encoded-data-using-apples-core-media-api-c5b2bf0e62a1 | Detailed walkthrough of `kCMSampleBufferAttachmentKey_TrimDurationAtStart` for pass-through AAC; confirms AVAssetWriter handles this automatically for LPCM→AAC path. (403 on direct fetch; summary from web search.) |
| 11 | Apple Developer Forums — AAC encoder delay | https://developer.apple.com/forums/thread/81268 | Community confirmation that AVAssetWriter embeds priming metadata; `afinfo` shows 2112 priming line. |
| 12 | AVAssetWriterInput header (MacOSX SDK) | https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/AVFoundation.framework/Versions/A/Headers/AVAssetWriterInput.h | Authoritative list of required and unsupported output settings keys; `AVChannelLayoutKey` required only for > 2 channels; unsupported: `AVEncoderAudioQualityKey`, `AVSampleRateConverterAudioQualityKey`. |
| 13 | Apple Developer Documentation — `finishWriting(completionHandler:)` | https://developer.apple.com/documentation/avfoundation/avassetwriter/1390432-finishwriting | API reference; completion runs on internal queue; synchronous variant deprecated. |
| 14 | Apple Developer Documentation — `endSession(atSourceTime:)` | https://developer.apple.com/documentation/avfoundation/avassetwriter/1389921-endsession | Confirms endSession is optional; without it, effective end time = last sample's PTS + duration. |
| 15 | Signal capture and graceful shutdown in Swift (prodisup.com) | https://prodisup.com/posts/2022/10/signal-capture-and-graceful-shutdown-in-swift/ | `DispatchSource.makeSignalSource` + `Darwin.signal(SIGINT, SIG_IGN)` pattern; `terminateLater`/`reply(toApplicationShouldTerminate:)` flow. |
| 16 | AVAudioFile — Apple Developer Forums thread on bitrate | https://developer.apple.com/forums/thread/112203 | Confirms AVAudioFile ignores `AVEncoderBitRateKey` for compressed formats; justifies using AVAssetWriter for AAC m4a. |
| 17 | AVAudioFile for WAV — settings dictionary research | https://developer.apple.com/documentation/avfaudio/avaudiofile | `AVLinearPCMBitDepthKey`, `AVLinearPCMIsFloatKey`, `AVLinearPCMIsBigEndianKey`, `AVLinearPCMIsNonInterleaved` reference. |
| 18 | AVAudioPCMBuffer to CMSampleBuffer conversion (aibo-cora gist) | https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c | Concrete Swift code for `CMAudioFormatDescriptionCreate` + `CMSampleBufferCreate` + `CMSampleBufferSetDataBufferFromAudioBufferList`. |
| 19 | `afinfo` output format explanation (osxdaily) | https://osxdaily.com/2010/10/19/get-mp3-file-info-on-mac/ | `afinfo` field meanings; priming line format confirmation. |
| 20 | WWDC20 — Author fragmented MPEG-4 content with AVAssetWriter | https://developer.apple.com/videos/play/wwdc2020/10011/ | `movieFragmentInterval` usage for live recording crash recovery; defragmentation on successful `finishWriting`. |
| 21 | Apple Developer Forums — `overallDurationHint` | https://developer.apple.com/documentation/avfoundation/avassetwriter/overalldurationhint | Optional hint to pre-allocate container structures; useful for fixed-duration recordings (e.g., `--max-duration`). |

### Recommended for Deep Reading

- **TN2258** (source #1): The only authoritative Apple reference on AAC priming. Read fully before touching `kCMSampleBufferAttachmentKey_TrimDurationAtStart`.
- **Nonstrict SCK Recording article** (source #2): The clearest available walkthrough of the complete AVAssetWriter lifecycle for live capture. The GitHub example is directly applicable.
- **Nonstrict gap handling article** (source #3): Directly implements the aligner pattern required for AC-12 (drift ≤ ±20 ms).
- **WWDC20 fragmented MPEG-4** (source #20): Explains `movieFragmentInterval` properly; required reading for understanding the AC-7 crash-recovery trade-offs.

---

## Assumptions and Uncertainties

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| AVFoundation automatically applies `TrimDurationAtStart` when encoding LPCM→AAC via `outputSettings` | HIGH | If wrong, the first 2112 samples will play as silence; fix by manually setting the attachment on the first output packet (requires intercepting encoder output, complex) |
| `shouldOptimizeForNetworkUse = true` produces a playable file on SIGINT if `finishWriting` completes | HIGH | If wrong, AC-7 fails; fallback: `movieFragmentInterval` alone |
| `finishWriting` completes in < 30 seconds for a 60-minute AAC stereo file on Apple Silicon | MEDIUM | If wrong, increase watchdog timeout; measure during AC-11 testing |
| `movieFragmentInterval = 2s` and `shouldOptimizeForNetworkUse = true` can be set simultaneously without issues | MEDIUM | If conflicts, drop `movieFragmentInterval` and rely solely on moov-at-front |
| Float32 non-interleaved LPCM input is accepted by `AVAssetWriterInput` with AAC `outputSettings` | HIGH | If wrong, must convert to interleaved Int16 before appending (one extra `vDSP` step) |
| `startSession(atSourceTime: CMClock.hostTimeClock.time)` produces correct duration in `afinfo` and QuickTime | MEDIUM | If wrong, switch to `.zero` session start + per-buffer retiming (Nonstrict alternative) |

---

*Research conducted 2026-04-26. Apple framework behavior reflects macOS 14.0+ (AVFoundation, CoreMedia, AudioToolbox). All code is desk-research quality — verify against the actual SDK headers before shipping.*
