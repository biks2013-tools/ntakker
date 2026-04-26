# SCStream Audio-Only Configuration and Long-Run Stability

> Research for `MacrecCore/Capture/SCKitSystemAudioSource.swift`
> Depth: Moderate — code-level. Swift 5.9+, macOS 14.0 minimum target.

---

## 1. TL;DR — Ready-to-Paste Snippets

### SCStreamConfiguration (audio-only, macOS 14.0+)

```swift
import ScreenCaptureKit
import CoreMedia

func makeAudioOnlyConfiguration() -> SCStreamConfiguration {
    let cfg = SCStreamConfiguration()

    // ── Audio knobs ──────────────────────────────────────────────────────────
    cfg.capturesAudio              = true
    cfg.excludesCurrentProcessAudio = true   // keeps our own AVCaptureSession mic out
    cfg.sampleRate                 = 48_000  // only valid values: 8000,16000,24000,48000
    cfg.channelCount               = 2       // stereo

    // ── Video suppression ────────────────────────────────────────────────────
    // CMTimeScale.max makes the minimum frame interval astronomically long,
    // so no video frames are ever generated. This is the approach used by the
    // Azayaka recorder (the most production-tested open-source SCStream
    // audio-only implementation). An alternative of CMTime(value:1,timescale:1)
    // (1 fps) also works, but generates one real frame per second; .max is cleaner.
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)

    cfg.width         = 2            // smallest valid dimension; frames are discarded
    cfg.height        = 2
    cfg.queueDepth    = 5            // Apple's recommended mid-range (valid: 3–8)
    cfg.showsCursor   = false        // no cursor needed when frames are discarded
    // pixelFormat: leave at default (kCVPixelFormatType_32BGRA). Since we
    // set width=2/height=2 and minimumFrameInterval=.max, no pixel buffers
    // are ever allocated at meaningful size; format choice has zero runtime cost.

    // ── macOS 15+ ONLY — do NOT set on 14 ────────────────────────────────────
    // cfg.captureMicrophone = false  // we capture the mic via AVCaptureSession;
    //                                // this flag is only for SCStream-native mic
    //                                // (macOS 15+). Leaving it unset is correct.
    // cfg.microphoneCaptureDeviceID  // same — do not touch

    return cfg
}
```

### SCContentFilter (entire system submix)

```swift
// Preferred: excludingApplications with empty array.
// This is Apple's own sample-code pattern and captures all running-app audio.
// Note: init(display:excludingWindows:) with an empty array has historically
// caused the callback to never fire on older macOS (12.x bug, fixed in 13+).
// The excludingApplications variant is safe on macOS 13+.
func makeSystemAudioFilter() async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true
    )
    guard let display = content.displays.first else {
        throw SystemAudioError.noDisplayAvailable
    }
    return SCContentFilter(
        display: display,
        excludingApplications: [],   // empty = capture all app audio
        exceptingWindows: []
    )
}
```

### Stream setup, output registration, and teardown

```swift
// ── Setup ────────────────────────────────────────────────────────────────────
let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
// IMPORTANT: register audio output BEFORE calling startCapture
try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoDiscardQueue)
try stream.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)
try await stream.startCapture()

// ── Buffer callback ──────────────────────────────────────────────────────────
func stream(_ stream: SCStream,
            didOutputSampleBuffer sb: CMSampleBuffer,
            of type: SCStreamOutputType) {
    switch type {
    case .screen: return   // discard; we only want audio
    case .audio:  handleAudio(sb)
    default:      return
    }
}

// ── Teardown ─────────────────────────────────────────────────────────────────
// Do NOT call removeStreamOutput before stopCapture — it is not required and
// adds unnecessary complexity. stopCapture atomically stops the stream and
// unhooks all outputs.
try await stream.stopCapture()
// Then nil-out the SCStream reference; do NOT reuse the instance.
stream = nil
```

---

## 2. Configuration Reference

| Property | Recommended Value | Rationale |
|---|---|---|
| `capturesAudio` | `true` | Required to receive `.audio` buffers. Default is `false`. Available macOS 13.0+. |
| `excludesCurrentProcessAudio` | `true` | Prevents our own process's audio (e.g., playback from the tool itself) from appearing in the system capture. Irrelevant to `AVCaptureSession` microphone capture — the mic is a separate input device, not process audio. Default is `false`. |
| `sampleRate` | `48_000` | Only four values are valid: 8000, 16000, 24000, 48000. Any other value silently defaults to 48000. Matches our internal canonical format (Float32 / 48 kHz / stereo). |
| `channelCount` | `2` | Stereo. If hardware delivers mono it is upmixed automatically. Values other than 1 or 2 default to 2. |
| `minimumFrameInterval` | `CMTime(value: 1, timescale: CMTimeScale.max)` | Sets the minimum interval between video frames to the largest possible value, effectively suppressing all video frame generation. Production-validated by Azayaka. Alternative `CMTime(value:1, timescale:1)` (1 fps) also works but wastes one tiny allocation per second. |
| `width` | `2` | Minimum viable dimension. No meaningful pixel data is produced because frame interval is suppressed. |
| `height` | `2` | Same as width. |
| `queueDepth` | `5` | Apple's own sample code default. Valid range is 3–8. Lower values (3) save a few MB of WindowServer memory. Higher values (8) give the consumer thread more headroom under spike load. For audio-only, 5 is a safe default with negligible memory cost. |
| `showsCursor` | `false` | No cursor rendering needed when frames are discarded. Eliminates one compositor pass. |
| `pixelFormat` | _(default — `kCVPixelFormatType_32BGRA`)_ | Leave unset. With `width=2/height=2` and `.max` frame interval, no pixel buffers of consequence are ever allocated. Do not set `420YpCbCr8` unnecessarily — that format requires a YUV conversion path that costs more on the compositor, not less. |
| `captureMicrophone` | _(do not set — macOS 15+ only)_ | This flag enables SCStream-native mic capture as a separate `.microphone` output type (introduced macOS 15.0). We capture the mic via `AVCaptureSession` instead, which gives us uniform `CMSampleBuffer` delivery and settable `synchronizationClock`. Setting `captureMicrophone = true` in addition to our `AVCaptureSession` mic is redundant and has been reported to cause stream instability and corrupted output files. Leave unset. |
| `microphoneCaptureDeviceID` | _(do not set)_ | Companion to `captureMicrophone`. Same reasoning — irrelevant to our architecture. |

### macOS version matrix for audio configuration properties

| Property | macOS 13.0 | macOS 14.0 | macOS 15.0 |
|---|---|---|---|
| `capturesAudio` | Available | Available | Available |
| `excludesCurrentProcessAudio` | Available | Available | Available |
| `sampleRate` | Available | Available | Available |
| `channelCount` | Available | Available | Available |
| `captureMicrophone` | Not available | Not available | Added |
| `microphoneCaptureDeviceID` | Not available | Not available | Added |
| `SCStreamOutputType.microphone` | Not available | Not available | Added |
| `captureDynamicRange` | Not available | Not available | Added |
| `showMouseClicks` | Not available | Not available | Added |

---

## 3. Long-Run Stability Findings

### The "silent-stop" bug

**Status as of April 2026: unfixed by Apple. Affects all macOS 13–15.x releases.**

The `replayd` daemon (Apple's internal screen/audio capture daemon) can crash or enter a bad state after several minutes of streaming, with two observed manifestations:

1. **Delegate not called**: The stream stops delivering `CMSampleBuffer`s silently. `stream(_:didStopWithError:)` is **never invoked** by the framework.
2. **Delegate called with a malformed error**: `stream(_:didStopWithError:)` fires, but the `error` argument contains invalid memory, causing `EXC_BAD_ACCESS` in `swift_getErrorValue` when Swift's error handling runtime tries to introspect the error type. This has been confirmed on macOS 14.6.1 with native Swift code (not only PyObjC).

**Does it affect our audio-only configuration?** Community reports indicate the silent-stop is more likely to manifest in audio-only configurations (versus full video+audio capture). The underlying cause is `replayd` exhaustion, which can be triggered by long-running single streams or by multiple concurrent `SCStream` instances sharing the daemon. Since we run exactly one `SCStream` (no other app streams are our responsibility), the risk exists but is lower than in multi-stream scenarios.

**Apple Feedback numbers filed:** FB16310901 (multi-stream replayd exhaustion). The `EXC_BAD_ACCESS` in `didStopWithError` was separately reported but no public FB number found in research.

**Note about `captureMicrophone = true`**: The investigation doc mentioned "silent stop after ~10–15 min for `captureMicrophone = true` combined paths." This is distinct from our architecture — we do not set `captureMicrophone`. Our mic comes from `AVCaptureSession`. This specific silent-stop trigger is sidestepped by our design.

### Mitigation strategy — watchdog + restart

Because `stream(_:didStopWithError:)` is not reliably called, the primary mitigation is a **buffer-arrival watchdog**:

```swift
final class SCKitSystemAudioSource: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var lastBufferArrival: Date = .now
    private var watchdogTask: Task<Void, Never>?

    func startCapture() async throws {
        // ... build filter, cfg, create stream, addStreamOutput, startCapture ...
        lastBufferArrival = .now
        watchdogTask = Task { [weak self] in
            await self?.runWatchdog()
        }
    }

    private func runWatchdog() async {
        // Poll every 5 seconds. If no audio buffer has arrived in 10 seconds
        // while the stream is nominally running, treat it as a stall and restart.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { break }
            let staleness = Date.now.timeIntervalSince(lastBufferArrival)
            if staleness > 10 {
                logger.warning("SCStream audio stall detected (\(staleness)s). Restarting.")
                await restartStream()
            }
        }
    }

    // SCStreamOutput
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lastBufferArrival = .now   // heartbeat reset
        // ... deliver sb downstream ...
    }

    // SCStreamDelegate — wrap in Task to avoid EXC_BAD_ACCESS in swift_getErrorValue
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        // userStopped (-3817): expected; the user cancelled via system UI
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
           nsError.code == -3817 {
            logger.info("SCStream stopped by user via system UI.")
            return
        }
        logger.error("SCStream stopped with error: \(nsError). Scheduling restart.")
        Task { [weak self] in
            await self?.restartStream()
        }
    }

    private func restartStream() async {
        // Always create a FRESH SCStream — do not call startCapture on the old one.
        try? await stream?.stopCapture()
        stream = nil
        // Re-build filter (in case display list changed) and re-call startCapture.
        try? await startCapture()
    }
}
```

**Important**: always wrap delegate work in a `Task { }` when coming from `didStopWithError`. The Swift runtime crash (`EXC_BAD_ACCESS` in `swift_getErrorValue`) occurs when you try to access the error's type synchronously in a context where the framework has passed a dangling pointer.

### Do NOT match against `SCStreamError` directly

There is a known macOS 12.x availability annotation gap in `SCStreamError` that causes binaries to fail to launch on older systems. Match against the error domain string and raw code instead:

```swift
// Safe pattern — no direct SCStreamError type reference
extension NSError {
    var isSCStreamUserStopped: Bool {
        domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3817
    }
    var isSCStreamConnectionInvalid: Bool {
        domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3805
    }
}
```

### Memory leak reports

No credible native-Swift `CMSampleBuffer` retain-cycle reports were found for the audio-only path. The typical concern is retaining `CMSampleBuffer`s inside closures after the buffer has been consumed. The standard mitigation is to always copy data out of the buffer synchronously in the `stream(_:didOutputSampleBuffer:of:)` callback and not store the `CMSampleBuffer` itself past the callback's return.

### Display configuration changes mid-recording

Audio in ScreenCaptureKit is filtered at the application level, not the display level. The system submix (`excludingApplications: []`) continues to deliver audio even when display topology changes (monitor plugged/unplugged), because the audio capture is not tied to the physical display — only to the `SCDisplay` object used to anchor the filter. No action is needed in the audio path when a display is added or removed.

One known edge case: with multiple virtual displays, `SCStream` can route video output to the wrong display after a reconnection event. This affects the video stream only — our audio path is unaffected since we discard video frames.

### Sleep / lid-closed behavior

When the MacBook lid is closed without an external display or keep-awake utility, the system enters sleep and `SCStream` stops delivering buffers. The watchdog will detect this (staleness > 10 s) and attempt to restart, but `SCStream` cannot run while the system is asleep. The stream will resume automatically once the Mac wakes, because `restartStream()` will be called on wake. No special sleep/wake notification handling is required for correctness, but we should reset `lastBufferArrival` on wake to prevent a false-positive watchdog trigger. Listen for `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification` to bracket the sleep period.

---

## 4. Coexistence with AVCaptureSession

**Core question: does `excludesCurrentProcessAudio = true` accidentally exclude the microphone captured by our `AVCaptureSession`?**

No. `excludesCurrentProcessAudio` excludes audio that our process is *playing back* (i.e., rendered to an output device), not audio we are *receiving* on an input device. `AVCaptureSession` microphone input is an inbound capture path. The two are entirely independent:

- `AVCaptureSession` reads audio samples from the mic hardware → delivers `CMSampleBuffer` to our `AVCaptureAudioDataOutput` delegate.
- `SCStream` reads the system audio mix → delivers `CMSampleBuffer` to our `SCStreamOutput` delegate.
- `excludesCurrentProcessAudio = true` suppresses any audio our process *plays back* (e.g., if we were to call `AVAudioPlayer.play()`) from appearing in the `SCStream` system capture. It does not affect what the mic hears.

**Confirmed by documentation**: "A Boolean value that indicates whether to exclude audio from your app during capture." "Your app" means audio your process writes to an output device, not audio it reads from an input device.

**Feedback-loop risk**: A potential feedback loop can arise if the `SCStream` audio output is routed to speakers and the mic picks up the speaker sound. This is a physical acoustic problem, not an API conflict. It is prevented by users using headphones (which is the common use case for meeting recording).

**AVAudioEngine / mainMixerNode conflict**: We do NOT use `AVAudioEngine` for mixing (per the investigation doc, we use manual `AVAudioPCMBuffer` summation). This eliminates the known `mainMixerNode → speakers` feedback loop that affects developers who mix SCStream audio through `AVAudioEngine` in realtime mode. The feedback loop only occurs when using `AVAudioEngine` in live (non-manual-rendering) mode.

**Sample rate coexistence**: `AVCaptureSession` with `synchronizationClock = CMClockGetHostTimeClock()` and `SCStream` both stamp `CMSampleBuffer.presentationTimeStamp` from the host clock. They do not interact at the Core Audio layer. There are no documented conflicts from running both simultaneously in the same process.

**AVCaptureSession run-loop requirement**: `AVCaptureSession` requires an active `CFRunLoop`/`NSRunLoop` to deliver delegate callbacks. For a CLI (non-GUI app) this means we must spin the `RunLoop` while recording is active (typically via `RunLoop.main.run()` in the main thread, or by using Swift concurrency with `@main` and an async main). The investigation doc already specifies `AsyncParsableCommand`; the Swift concurrency runtime keeps the process alive and maintains a run loop compatible with `AVCaptureSession` callbacks.

---

## 5. First-Buffer Latency

**No official Apple documentation specifies a first-buffer latency guarantee for `SCStream` audio.**

From community observations and the Nonstrict blog:

- `await stream.startCapture()` completes (the completion handler fires) before the first buffer arrives. The gap between completion and first buffer is **not deterministic**.
- Reported first-buffer delays for audio are in the range of **50–300 ms** post-`startCapture()` completion, varying by system load and macOS version. No rigorous measurement was found in the research.
- Video first-buffer latency tends to be longer (100 ms–1 s) because the video path waits for a composited frame. Audio buffers typically arrive sooner since they flow from an OS audio mix that is always running.

**Implication for our pre-roll design**: Register the `SCStreamOutput` before calling `startCapture()` (confirmed as the correct order by Apple's sample code: `addStreamOutput` first, then `startCapture`). Use the first received audio buffer's `presentationTimeStamp` as the true recording start time, not the timestamp at which `startCapture` completes. This is exactly the approach the Nonstrict SCK recording example uses (record `firstSampleTime` from the first buffer, offset all subsequent PTSs relative to it).

**No pre-roll buffer is required** for our use case because we pass raw SCStream PTSs through our pipeline; we do not need a fixed pre-roll window. The `assetWriter.startSession(atSourceTime:)` should be called using the PTS of the first appended buffer (or `.zero` with retimed buffers), not a hardcoded timestamp.

---

## 6. Stop / Restart Recipe

### Normal stop (SIGINT / SIGTERM / `--max-duration` reached)

```swift
// 1. Signal the watchdog to stop — cancel its Task before stopping the stream,
//    so we don't trigger a spurious restart.
watchdogTask?.cancel()
watchdogTask = nil

// 2. Stop the SCStream. Async — awaiting it ensures no more buffer callbacks
//    fire after this point.
try await stream.stopCapture()

// 3. Nil-out the stream. SCStream instances are NOT safely reusable after
//    stopCapture. The framework has documented that a stopped stream should
//    be released and a new one created for subsequent recordings.
stream = nil

// 4. Finalize any downstream writers (AVAssetWriter, AVAudioFile) AFTER
//    confirming no more buffers will arrive (step 2 guarantees this).
```

**`removeStreamOutput` is not required before `stopCapture`.** Apple's own documentation and the Azayaka source both call `stopCapture` directly. `removeStreamOutput` is only needed if you want to stop recording while keeping the stream live (e.g., to detach a file writer mid-stream without stopping capture). For our use case (stop = end of recording), skip `removeStreamOutput`.

### Watchdog-triggered restart (silent-stop recovery)

```swift
// Do NOT call removeStreamOutput. Just stop, nil out, rebuild.
try? await stream?.stopCapture()
stream = nil
// Re-fetch SCShareableContent (display list may have changed).
let filter = try await makeSystemAudioFilter()
let cfg    = makeAudioOnlyConfiguration()
stream = SCStream(filter: filter, configuration: cfg, delegate: self)
try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoDiscardQueue)
try stream.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)
lastBufferArrival = .now   // reset watchdog baseline
try await stream.startCapture()
```

### Key ordering rules

1. `addStreamOutput` before `startCapture` — required; Apple's sample code is explicit.
2. `startCapture` before writer `startSession` — you need a real PTS from the first buffer to anchor the writer.
3. `stopCapture` (await) before writer `markAsFinished` / `finishWriting` — guarantees no more buffers arrive after finalization begins.
4. Never call `startCapture` on a previously stopped `SCStream` — always create a new instance.

---

## 7. Error Handling Matrix

All error matching uses the raw domain string and code to avoid the `SCStreamError` availability annotation bug (see Section 3).

| Error Code | Domain Code | Name | Recoverable? | Our Action |
|---|---|---|---|---|
| `-3817` | `SCStreamErrorDomain` | `userStopped` | Yes — expected | Log at info level; do not restart; clean up writers normally. |
| `-3805` | `SCStreamErrorDomain` | `connectionInvalid` | Sometimes | `replayd` XPC connection broke. Wait 1–2 s, then attempt one restart. If restart fails, surface error to user and exit. |
| `-3808` | `SCStreamErrorDomain` | `attemptToStopStreamState` | Yes | Stream received a stop while already stopping. Log and ignore; no restart needed. |
| No callback fired (watchdog timeout) | n/a | _(silent stop)_ | Yes | Watchdog restarts stream. Log at warning level. Count restarts; if >3 restarts within 60 s, declare fatal and exit. |
| `EXC_BAD_ACCESS` in `didStopWithError` | n/a | Framework bug | Fatal | Unavoidable without the `Task { }` wrapper. With the wrapper, the crash is prevented; falls into the "no callback" case handled by the watchdog. |
| Any other error | Any | Unknown | Unknown | Log at error level. Attempt one restart. If restart fails, surface to user and exit with non-zero code. |

### Safe delegate implementation

```swift
func stream(_ stream: SCStream, didStopWithError error: Error) {
    // Dispatch off the XPC callback thread BEFORE inspecting the error,
    // to avoid touching potentially-invalid memory from the framework.
    Task { [weak self, error] in
        let nsError = error as NSError
        let domain  = nsError.domain
        let code    = nsError.code
        guard let self else { return }
        if domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3817 {
            self.logger.info("Stream stopped by user (userStopped).")
            await self.handleNormalStop()
        } else {
            self.logger.warning("Stream stopped unexpectedly: \(domain) \(code). Restarting.")
            await self.restartStream()
        }
    }
}
```

---

## 8. Open Issues

Items that research could not definitively resolve. Flag these for the implementer to spike or monitor.

**OI-1 — Minimum reliable `width`/`height` value.**
Research consistently points to `2` as the smallest dimension used in production (Azayaka uses `2`). Apple's documentation does not specify a floor. If `width=2, height=2` causes a stream initialization failure on any macOS version, fall back to `32` (safe upper bound). This should be validated in a spike before shipping.

**OI-2 — `CMTimeScale.max` vs `CMTime(value:1, timescale:1)` stability.**
Azayaka uses `CMTimeScale.max`. The investigation doc originally proposed 1 fps. No documented regression was found for either value. `CMTimeScale.max` is the cleaner design (no video frames ever) but has less community mileage than 1 fps. The implementer should validate both on macOS 14.0 and 15.x and confirm audio callback stability.

**OI-3 — Watchdog restart count limit.**
The proposed threshold of "3 restarts within 60 s declares fatal" is a heuristic. The right number depends on how often `replayd` legitimately needs to be given time to recover vs. how quickly we should surface an unrecoverable failure to the user. Tune after field testing.

**OI-4 — Audio output device changes mid-recording.**
Research found that SCStream's audio capture is anchored to the system submix at the time of filter creation, and that audio filtering is at the app level (not display or device level). However, whether the audio path automatically follows the user changing the default output device (e.g., switching from headphones to built-in speakers) mid-recording was not definitively confirmed. The investigation doc's assumption A-4 covers this. A spike recording through a device switch would validate it.

**OI-5 — `SCStream` on macOS 26.x (Tahoe) audio-only behavior.**
Only preliminary information is available for macOS 26 (Darwin 25.x). No audio-specific regressions were reported in research, but the TCC listing regression for plain-binary CLIs (noted in the investigation doc) is confirmed. Audio capture behavior is assumed to be the same as macOS 15; this must be validated once macOS 26 is generally available.

**OI-6 — First-buffer latency measurement.**
The 50–300 ms range cited in Section 5 is from community reports, not a controlled measurement. A spike that prints the delta between `startCapture()` completion and first buffer arrival on the implementer's hardware would give a concrete number to dimension any pre-roll buffer.

**OI-7 — NSWorkspace sleep/wake notification wiring.**
Section 3 recommends listening for `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification` to reset `lastBufferArrival`. The exact integration point in `SCKitSystemAudioSource` needs to be designed. For a CLI app without a GUI, the `NSWorkspace.shared.notificationCenter` observer still functions but requires an active `RunLoop` on the registration thread.

---

## 9. Sources

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Apple Developer — `SCStreamConfiguration` | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration | Full property listing; `capturesAudio`, `sampleRate`, `channelCount`, `excludesCurrentProcessAudio` docs |
| 2 | Apple Developer — `SCStreamConfiguration.capturesAudio` | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio | Confirms available macOS 13.0+; default false |
| 3 | Apple Developer — `SCStreamConfiguration.sampleRate` | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate | Confirms only 8000/16000/24000/48000 valid; default 48 kHz |
| 4 | Apple Developer — `SCStreamConfiguration.channelCount` | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/channelcount | Mono or stereo; default stereo |
| 5 | Apple Developer — `SCStreamConfiguration.excludesCurrentProcessAudio` | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio | Default false; excludes app's own output audio |
| 6 | Apple Developer — Capturing Screen Content in macOS | https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos | Apple sample code; `queueDepth=5`, `minimumFrameInterval=1/60s`, `capturesAudio`, `excludesCurrentProcessAudio`, `SCContentFilter` with `excludingApplications` |
| 7 | Apple Developer — `SCStreamDelegate.stream(_:didStopWithError:)` | https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/stream%28_%3Adidstopwitherror%3A%29 | `userStopped` is expected/recoverable; delegate is optional |
| 8 | Apple Developer — `SCStreamError` / `SCStreamError.Code` | https://developer.apple.com/documentation/screencapturekit/scstreamerror/code | Error codes; availability annotation gotcha |
| 9 | Apple Developer — `SCContentFilter` initializers | https://developer.apple.com/documentation/screencapturekit/sccontentfilter | `init(display:excludingApplications:exceptingWindows:)` for full-display audio |
| 10 | Apple Developer — `captureMicrophone` (macOS 15) | https://developer.apple.com/documentation/screencapturekit (WWDC24 notes) | `captureMicrophone` and `microphoneCaptureDeviceID` added macOS 15; `SCStreamOutputTypeMicrophone` new output type |
| 11 | Apple Developer Forum — SCStream crash / replayd (FB16310901) | https://developer.apple.com/forums/thread/772365 | Multi-stream replayd exhaustion; relaunch required; bug filed |
| 12 | GitHub — PyObjC Issue #647 (macOS 15 SCStreamErrorDomain -3805) | https://github.com/ronaldoussoren/pyobjc/issues/647 | `-3805 connectionInvalid` on macOS 15; stream starts but no callbacks; confirms framework-level issue |
| 13 | GitHub — Azayaka / Recording.swift | https://raw.githubusercontent.com/Mnpn/Azayaka/main/Azayaka/Recording.swift | Production audio-only SCStream implementation; `width=2, height=2`, `minimumFrameInterval=CMTime(value:1,timescale:CMTimeScale.max)`, `queueDepth=5`, `capturesAudio=true`, SCContentFilter pattern |
| 14 | Nonstrict — Recording to disk with ScreenCaptureKit | https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/ | `AVAssetWriter` + `SCStream`; first-buffer timing pattern; `CMClock.hostTimeClock`; end-session timing |
| 15 | Nonstrict — Handling audio capture gaps on macOS | https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos/ | `nextExpectedAudioTime` pattern for gap detection; silence-fill; observed on macOS 14; seen during device switches |
| 16 | GitHub — nonstrict-hq / ScreenCaptureKit-Recording-example | https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example | Complete recording example; start-session / end-session ordering; retiming first buffer |
| 17 | GitHub — nonstrict-hq / scstreamerror-sample | https://github.com/nonstrict-hq/scstreamerror-sample | Workaround for `SCStreamError` availability annotation bug; use raw domain string |
| 18 | GitHub — Fidetro / CapturingScreenContentInMacOS (Apple sample mirror) | https://github.com/Fidetro/CapturingScreenContentInMacOS | Canonical `SCContentFilter(display:excludingApplications:exceptingWindows:)` pattern; `queueDepth=5`; addStreamOutput before startCapture |
| 19 | Federico Terzi Blog — SCK failing to capture entire display | https://federicoterzi.com/blog/screencapturekit-failing-to-capture-the-entire-display/ | `init(display:excludingWindows:[])` bug on macOS 12.x (empty callback); `excludingApplications` variant is safe; fixed in 13+ |
| 20 | Apple Developer Forum — Mixing SCKit audio with microphone | https://developer.apple.com/forums/thread/747303 | `AVAudioEngine mainMixerNode` feedback loop; manual rendering workaround; `outputVolume=0` workaround for macOS 13–15; confirms AVCaptureSession is the correct separate mic path |
| 21 | OBS Project GitHub — SCStream stops after sleep | https://github.com/obsproject/obs-studio/issues/8928 | macOS screen capture stops after wake from sleep; consistent with our watchdog restart approach |
| 22 | WWDC22 — Meet ScreenCaptureKit (Session 10156) | https://developer.apple.com/videos/play/wwdc2022/10156/ | Foundational; `SCStream` overview; content filter; audio configuration |
| 23 | WWDC22 — Take ScreenCaptureKit to the next level (Session 10155) | https://developer.apple.com/videos/play/wwdc2022/10155/ | `queueDepth` valid range 3–8; frame loss / queue depth relationship |
| 24 | WWDC24 — Capture HDR content with ScreenCaptureKit (Session 10088) | https://developer.apple.com/videos/play/wwdc2024/10088/ | `captureMicrophone`, `microphoneCaptureDeviceID`, `SCStreamOutputTypeMicrophone` added macOS 15; `captureDynamicRange` added |

### Recommended for Deep Reading

- **Azayaka / Recording.swift** (source 13): The most production-representative open-source audio-only SCStream Swift implementation. Read the full `record(audioOnly:filter:)` function and `stopRecording` to understand the exact pattern this research recommends following.
- **Nonstrict blog posts** (sources 14 and 15): The two most authoritative practitioner write-ups on SCStream + AVAssetWriter + gap handling. These directly validate the `nextExpectedAudioTime` approach for our `SampleAligner`.
- **Apple Developer Forum thread 772365** (source 11): The best documented example of the `replayd` crash and its error code. Read the original post and the "please file a bug" exchange — it confirms Apple has acknowledged the issue.

---

## Assumptions & Scope

### Assumptions Made

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| `width=2, height=2` is valid on macOS 14.0 and 15.x | HIGH — used by Azayaka in production | If invalid, increase to `32` as a safe floor |
| `CMTimeScale.max` for `minimumFrameInterval` suppresses all video frames without breaking the audio path | MEDIUM — validated by Azayaka but not by Apple documentation | If it causes issues, fall back to `CMTime(value:1, timescale:1)` (1 fps); audio still works |
| `excludesCurrentProcessAudio = true` does not affect `AVCaptureSession` microphone | HIGH — confirmed by documentation semantics | If wrong, mic buffers disappear from our pipeline; would be immediately visible in testing |
| Setting `captureMicrophone` on macOS 15 alongside AVCaptureSession mic causes instability | MEDIUM — based on community reports; not formally confirmed by Apple | If wrong, could add SCStream-native mic as a redundant path, but architecture stays same |
| `replayd`-related silent-stop is more likely in audio-only vs. full video+audio mode | LOW-MEDIUM — several reports suggest this but no controlled comparison exists | If audio-only is actually more stable than reports suggest, the watchdog is still correct defensive engineering |

### Items Explicitly Out of Scope

- Per-process audio filtering (`SCContentFilter` with specific `SCRunningApplication` inclusions) — v2 feature
- `SCRecordingOutput` API (macOS 14+) — we use `AVAssetWriter` directly; `SCRecordingOutput` was investigated but not recommended (its `recordingOutputDidFinishRecording` lifecycle is confusing and it adds complexity without benefit for our use case)
- `AudioHardwareCreateProcessTap` (CoreAudio process taps) — v2 alternative path; covered in the investigation doc
- macOS 12.x and 13.x specific behavior differences — our target is macOS 14.0+

### Clarifying Questions for Follow-Up

1. **Should the watchdog restart reset the writer session or continue it?** If `SCStream` restarts mid-recording, the new audio buffers will have PTSs that continue from where the old stream left off (or slightly later). The writer must keep writing without calling `startSession` again — only one `startSession` per `AVAssetWriter` lifetime. The gap between old and new buffers should be filled with silence by the `SampleAligner`. This architecture is implied but not explicitly designed.

2. **What is the user-visible behavior during a watchdog-triggered restart?** There will be a silence gap of up to 10 s (watchdog threshold) before restart completes. Should the user be notified? The OQ-9 recommendation (RMS logging every 10 s) would cover this via debug logs, but no user-visible indication (stderr message at info level) has been designed.

3. **How does the watchdog interact with `--max-duration`?** If the stream stalls and the watchdog restarts it, does the stall time count toward `--max-duration`? Presumably yes (wall-clock time), but the silence gap means the audio file will be shorter than `--max-duration` by the stall duration. This edge case should be documented.
