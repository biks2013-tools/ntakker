# plan-013 — Microphone Acoustic Echo Cancellation (AEC)

**Status:** Approved 2026-05-09. **Revised 2026-05-09 (same day) after the Apple voice-processing approach failed** — see §0 below.
**Owner / requester:** primary user (recording-tool).
**Scope:** `macrec` (CLI) + `macrec-ui` (menu-bar app), shared `MacrecCore`.

---

## 0. Implementation history & approach pivot

The first plan-013 implementation tried to use Apple's built-in voice-processing AEC by introducing a new mic source (`VPMicrophoneSource`) that wrapped `AVAudioEngine` with `setVoiceProcessingEnabled(true)`. **It did not work in this codebase.** Empirical evidence collected against three successive builds (2026-05-09 morning sessions):

- **First build (PATH binary 08:06).** `AVAudioEngine` started cleanly, `setVoiceProcessingEnabled(true)` returned without throwing, and the input tap delivered exactly **one** buffer of 4800 silent frames at the moment the engine started — then stopped delivering for the rest of the session. The single buffer arrived in the ≈ 2-second window before `SCKitSystemAudioSource` started; once SCStream came online, the VP IO unit halted permanently.
- **Second build (with `_ = engine.mainMixerNode`).** Attempted to "complete" the engine graph so VP IO had a render-side sink. Engine refused to initialise at all — `kAudioUnitErr_FailedInitialization` (-10875). Cause: with voice processing enabled, AVAudioEngine's `inputNode` and `outputNode` are both backed by a single shared `AUVoiceProcessingIO` unit; forcing the implicit `inputNode → mainMixer → outputNode` graph creates a self-loop on that one unit, which the AU refuses to instantiate.
- **Third build (mainMixerNode line removed, `OSAllocatedUnfairLock` replacing `stateQueue.sync` in the audio render thread, `CMSampleBufferSetDataReady` added).** Same 1-buffer-then-stop pattern as build #1. The audio-render-thread cleanup and the SetDataReady fix were correct on their own merits, but they don't address the structural problem.

**Diagnosis:** `AUVoiceProcessingIO` (the audio unit `setVoiceProcessingEnabled(true)` activates under the hood) requires unobstructed access to the system OUTPUT device for its AEC reference signal. `SCStream` taps the same OS-level audio mix. Empirically the two cannot coexist on macOS 26 — the moment SCStream takes its claim, VP IO loses its reference and stops delivering input frames. There is no public API to feed VP IO a custom reference signal, so the conflict is structural, not a bug we can patch.

**Conclusion:** AVAudioEngine voice processing is not a viable AEC mechanism for this project. `VPMicrophoneSource` was deleted; this plan was revised to use a custom software AEC (NLMS adaptive filter) wired downstream of the existing capture sources instead. The user-facing surface (`micAEC` field, `MACREC_MIC_AEC` env var, `--mic-aec` CLI flag, popover toggle) is unchanged — only the implementation behind it is different.

---

## 1. Problem

When `macrec` or `macrec-ui` records system audio + microphone simultaneously, the **microphone channel is contaminated by system audio**: anything playing through the speakers (Music, Spotify, browser tabs, Zoom remote-party voices, etc.) is acoustically picked up by the built-in mic and re-recorded on the mic channel. Result:

- In `--layout split` / `stereo-split`: the mic track is no longer a clean local-mic recording — it carries a delayed, attenuated copy of the system audio.
- In `--layout mixed`: system audio is double-counted (once from the system source, once from the leaked path through the mic), producing comb-filter coloration and a +3 dB elevation around the bleed band.
- In `--transcribe …` (single-mode and dual-mode): the transcriber's "microphone" stream contains both speakers, so any source-split routing (`--transcribe-source mic`) is misleading.

This is **acoustic bleed**, not a code defect — speakers play, mic listens. The fix has to suppress the leaked signal at capture time.

## 2. Root cause

The mic source (`AVMicrophoneSource`, `Sources/MacrecCore/Capture/AVMicrophoneSource.swift`) uses `AVCaptureSession` + `AVCaptureDeviceInput` + `AVCaptureAudioDataOutput`. That stack is the lowest-latency macOS path for raw HAL audio capture — **and it has no echo-cancellation knob.** `AVCaptureSession` exposes neither a "voice processing" toggle nor a reference-audio input.

Apple's first-class AEC ships only via two surfaces, both outside `AVCaptureSession`:

1. `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` (macOS 10.15+ / `setVoiceProcessingEnabled(_:)` is the documented API; throws on failure).
2. `kAudioUnitSubType_VoiceProcessingIO` (the AU layer Apple's own apps — FaceTime, Zoom, the SystemUIServer voice-call mixer — use directly).

Both share the same DSP. The reference signal for the cancellation step is the **default system OUTPUT device** — i.e. exactly the audio path that bleeds back into the mic. Enabling voice processing causes the OS to subtract the playing-out signal from the captured-in signal in real time. Side effects, all enabled together (cannot be split):

- Acoustic Echo Cancellation (the wanted behaviour).
- Adaptive Gain Control (AGC).
- Stationary noise suppression (NS).
- Frequency-band narrowing (telephony band ~100 Hz – 8 kHz).
- A small added latency (~10–30 ms typical on Apple Silicon).

The user has explicitly **accepted** these trade-offs (see Project Memory, AskUserQuestion answer 2026-05-09: *"Accept voice-AEC side effects (AGC + NS + narrowed band)"*).

## 3. Solution (revised — software AEC)

`AVMicrophoneSource` (the existing `AVCaptureSession`-based source) is the only mic source. When `RecordingOptions.micAEC == true` (the default), `RecordingSession.run()` constructs a `SoftwareAECProcessor` that sits between the mic source and the aligner. The processor takes the system-audio buffers (already captured by `SCKitSystemAudioSource`) as its reference signal and runs an NLMS adaptive filter on each mic sample to subtract the estimated echo before the cleaned mic flows into the aligner / recorder.

**Default: `micAEC = true`.** The user explicitly requested AEC-by-default; opt-out is exposed on every entry point. The flag, env-var, and toggle plumbing are unchanged from the original plan-013 — only what they switch on changed.

```
                ┌─────────────────────┐
                │ SCKitSystemAudio    │── system buffer ──┐
                │   (reference)       │                   │
                └─────────────────────┘                   │
                          │                               │
                          ▼ tee                           ▼
                  ┌──────────────┐                ┌──────────────────┐
                  │   aligner    │                │ SoftwareAEC      │
                  └──────────────┘                │   feedReference  │
                          ▲                       │                  │
                          │                       │   NLMS per-      │
                          │                       │   channel filter │
                          │                       │                  │
                          │     cleaned mic       │                  │
                          ◀───────────────────────┤   processMic     │
                                                  └──────────────────┘
                                                          ▲
                                                          │
                                              ┌─────────────────────┐
                                              │ AVMicrophoneSource  │
                                              │   (raw mic)         │
                                              └─────────────────────┘
```

When `micAEC == false`, the processor is not constructed; mic and system buffers go directly to the aligner exactly as they did pre-plan-013.

### 3.1 New component — `SoftwareAECProcessor` (revised)

Path: `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift`.

Public surface:

```swift
public final class SoftwareAECProcessor {
    public struct Configuration {
        let filterLength: Int      // default 4096 (~85 ms @ 48 kHz)
        let stepSize: Float        // default 0.1 (NLMS μ)
        let regularization: Float  // default 1e-6
        let channels: Int          // default 2
        let sampleRate: Double     // default 48 000
    }
    public init(config: Configuration, logger: Logging.Logger?)
    public var onCleanedMic: ((CaptureBuffer) -> Void)?
    public func feedReference(_ buffer: CaptureBuffer)   // called from system source's queue
    public func processMic(_ buffer: CaptureBuffer)      // called from mic source's queue
}
```

Algorithm:

1. **Reference ingest (`feedReference`).** System-audio CaptureBuffer arrives → extract the per-channel non-interleaved Float32 samples → append into a per-channel ring buffer of size `2 × filterLength` using the **double-write trick** (every sample written to both `ring[p % L]` AND `ring[(p % L) + L]`) so any L-sample window can be read contiguously without wrap-around branching inside the per-sample inner loop.
2. **Mic processing (`processMic`).** Mic CaptureBuffer arrives → extract per-channel Float32 samples → for each sample `n` in each channel:
   - Read the contiguous L-sample reference window (`ring[(writeIdx % L) ..< (writeIdx % L) + L]`).
   - Compute filter output (the echo estimate) `y_hat = vDSP_dotpr(weights, window)`.
   - Compute reference power `refPower = vDSP_svesq(window)`.
   - Cleaned sample `e = mic[n] − y_hat`.
   - NLMS weight update: `weights += (μ · e / (refPower + reg)) × window` via `vDSP_vsma`.
3. **Output.** Wrap the cleaned per-channel arrays in a fresh CMSampleBuffer (same PTS / duration / format description as the input mic buffer, ensuring host-clock alignment is preserved for the aligner) and emit via `onCleanedMic`.

All hot-loop math runs SIMD-vectorised through `Accelerate` (`vDSP_dotpr`, `vDSP_svesq`, `vDSP_vsma`). The per-channel state (filter weights + reference ring + write index) is guarded by an `OSAllocatedUnfairLock` held for the duration of one mic-buffer call; `feedReference` takes the lock briefly to append. Both methods are safe to call concurrently from different capture queues.

**Computational budget.** L=4096, sampleRate=48 kHz, channels=2: per second per channel ≈ 4096 × 48 000 × 2 (one MAC for output, one for update) = 393 M MACs/s. Stereo total ≈ 786 M MACs/s. With Accelerate's NEON SIMD that's ~5–8 % of a single Apple Silicon performance core — comfortable headroom.

**Convergence.** The NLMS filter starts with all weights = 0 (no echo cancellation initially). As reference and mic flow in, the taps that correspond to the actual speaker→air→mic delay grow toward the true echo-path impulse response; earlier and later taps stay near zero. Practical convergence time on white-noise-like test signals: 1–3 s. On realistic music / speech: 3–10 s. During convergence, the cleaned mic sounds like raw mic + decreasing residual bleed; after convergence the residual drops 15–25 dB below the bleed level. Slow- or non-convergence indicates either (a) the echo path is changing faster than μ can track (e.g. user moving the laptop), or (b) the reference and mic time-alignment exceeds the filter window — both addressable by tuning, see §7.

### 3.1.5 Removed component — `VPMicrophoneSource`

Deleted. The original plan-013 attempt at this path is documented in §0 above for posterity — anyone considering reviving the AVAudioEngine-VP approach should re-read that section first.

### 3.1.9 (legacy text — original VPMicrophoneSource description, retained for context)

Path: `Sources/MacrecCore/Capture/VPMicrophoneSource.swift`.

Conforms to `MicrophoneSource` with the same surface as `AVMicrophoneSource`:

- Same `formatDescription` semantics (Float32 / 48 kHz / stereo / non-interleaved after the per-source converter).
- Same `onSampleBuffer` callback, fired on a `userInteractive` queue.
- Same `levelTap` secondary tap (so the UI level meters keep working).
- Same `terminalError` surface for the orchestrator's error poll.
- Same TCC + sleep/wake parity.
- Same 1 Hz `mic_health: …` heartbeat log line so debugging is unchanged.

Implementation outline:

1. Build an `AVAudioEngine`. Resolve the desired input device (UID/name → `AVAudioInputNode` device-binding via `AudioDeviceID` set on the engine's `inputNode.auAudioUnit.deviceID` on macOS, or default if nil — same algorithm `AVMicrophoneSource.resolveCaptureDevice` uses).
2. Call `try inputNode.setVoiceProcessingEnabled(true)`. **This must happen BEFORE the engine has been configured / started**, per the API's documented constraint. If the call throws, surface the error as a terminal error and let the orchestrator fall back to `AVMicrophoneSource` for the next session (no silent fallback for this session — fail explicitly per CLAUDE.md "no fallback for missing config" spirit; AEC-on-failure surfaces as `MacrecError.micAECUnavailable(underlying:)`).
3. Install a tap on `inputNode.bus 0` with the node's natural format (typically mono Float32 at device rate). Inside the tap closure:
   - Convert to Float32 / 48 kHz / stereo NI via a per-source `AVAudioConverter` (lazy-built on first buffer once the input format is known).
   - Compute the host-clock PTS from `AVAudioTime.hostTime` (mach_absolute_time → CMTime via `CMTimeMakeWithSeconds` against `CMClockGetHostTimeClock()`'s timescale). This keeps the aligner contract (FR-22, `CaptureBuffer.swift` header) intact: every `CaptureBuffer.buffer.presentationTimeStamp` lives in the host-clock domain.
   - Wrap into a `CMSampleBuffer` with the converted PCM payload + the host-clock PTS, tag as `.microphone`, fire `onSampleBuffer` then `levelTap` (same order as `AVMicrophoneSource`).
4. `start()`: `engine.prepare()` then `try engine.start()`, on a lifecycle queue, wrapped in `withCheckedThrowingContinuation` like the existing source.
5. `stop()`: `engine.stop()`, remove the tap, release the engine.
6. Subscribe to `AVAudioEngine.configurationChangeNotification` for the audio-route-change parity (the user plugs/unplugs headphones during a recording — the engine reconfigures; we log it and keep going).

### 3.2 Why a new source rather than retrofit `AVMicrophoneSource`?

- `AVCaptureSession` and `AVAudioEngine` have completely different lifecycle / configuration models. Trying to switch between them inside one class would balloon the code and obscure the synchronization-clock comment block (which is load-bearing for `AVMicrophoneSource` and irrelevant for `VPMicrophoneSource`).
- Both classes are small (~700 lines) and most of the work is independent — keeping them separate lets either evolve without disturbing the other.
- Tests that already cover `AVMicrophoneSource`'s contract continue to apply unchanged; new tests target `VPMicrophoneSource` only.

## 4. Configuration plumbing

### 4.1 `RecordingOptions`

Add a stored property:

```swift
/// When true (default), the microphone is captured through
/// `AVAudioEngine` with `setVoiceProcessingEnabled(true)` so Apple's
/// AEC subtracts system-output bleed from the mic signal. When false,
/// the raw `AVCaptureSession` path is used (no AEC, native mic
/// frequency response, no AGC).
///
/// Trade-offs of `true`: AGC + stationary noise suppression are
/// applied, the captured band narrows toward telephony quality
/// (~100 Hz – 8 kHz), and ~10–30 ms added latency. Acceptable for
/// meeting/coaching capture; not acceptable for music capture.
public let micAEC: Bool
```

Default in `init`: `micAEC: Bool = true`. Threaded through `withOutput(_:)` (the codebase scan flagged this method as load-bearing — every new field MUST be forwarded or pause/resume / segment rotation silently loses it).

### 4.2 `ConfigResolver`

- Add `Keys.micAEC = "MACREC_MIC_AEC"`.
- Resolve via `parseBool(key: Keys.micAEC, raw: value(Keys.micAEC), default: true)` — same shape as `overwrite` / `detach`.
- Pass the resolved `Bool` to `RecordingOptions(micAEC:)`.

Resolution chain (lowest priority first, per CLAUDE.md):

1. process env (`MACREC_MIC_AEC=true` in the user's shell).
2. `~/.tool-agents/macrec/.env`.
3. local `./.env`.
4. CLI flag `--mic-aec on|off`.

### 4.3 `StartCommand` (CLI)

Add:

```swift
@Option(name: .long, help: "Microphone echo cancellation (on | off). Default: on. Subtracts system-output bleed from the mic via Apple's voice-processing AEC. Off disables AEC and gives the raw mic signal (wider band, no AGC, no NS). Env: MACREC_MIC_AEC.")
public var micAEC: String?
```

Accepts `on`/`off`/`true`/`false`/`1`/`0` (the same `parseBool` value range used by `--overwrite` / `--detach`); maps to `MACREC_MIC_AEC` in `buildCLIOverrides()`.

Why `String?` instead of `Bool?`: ArgumentParser's `Bool?` form requires `--mic-aec=true` (no space-separated value) which is awkward; `String?` accepts `--mic-aec on` and `--mic-aec=on` uniformly.

### 4.4 `macrec-ui`

Add a Toggle to the popover, placed next to the microphone picker:

```swift
@AppStorage("com.macrec.ui.micAEC") private var micAEC: Bool = true
…
Toggle("Mic echo cancellation", isOn: $micAEC)
    .help("On (default) subtracts system-audio bleed from the mic. Off captures the raw mic (wider band, no AGC).")
```

`ControlBar.assembleOptions()` (line 476 in ControlBar.swift) passes `micAEC: micAEC` into `RecordingOptions(...)`.

## 5. Acceptance criteria

1. Default behaviour change: every fresh recording (CLI or UI, with no env / flag / toggle changes) captures the mic through `VPMicrophoneSource`. The mic-channel `.split` / `.stereo-split` track must contain noticeably less system-audio bleed than the pre-plan-013 baseline (verified manually with `sample/aec-bleed-test.m4a` produced by the smoke script).
2. Opt-out works on both surfaces:
   - `macrec start --mic-aec off …` ⇒ `RecordingSession` constructs `AVMicrophoneSource` (verified by log line `mic source = AVMicrophoneSource (raw, AEC=off)`).
   - macrec-ui popover toggle off ⇒ same log line and same source.
3. Env var works: `MACREC_MIC_AEC=false macrec start …` ⇒ AEC off; `MACREC_MIC_AEC=true` (or unset) ⇒ AEC on.
4. Pipeline contract preserved: `VPMicrophoneSource` emits `CaptureBuffer`s in the canonical format (Float32 / 48 kHz / stereo / NI) with host-clock PTSs. Aligner stats (`session.stats.framesEmitted`) tick at the same rate as `AVMicrophoneSource` would.
5. Level meters keep working with AEC on: the popover's mic VU shows non-zero amplitude when the user speaks.
6. Build is clean for both targets: `swift build -c debug --product macrec` and `swift build -c debug --product macrec-ui` succeed with zero warnings introduced by this change.
7. Documentation updated: `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, project `CLAUDE.md` "Tools" entries, and `Issues - Pending Items.md` reflect the new flag / env / toggle and the AEC trade-off note.

## 6. Phases (Claude-executable)

| # | Action | Files | Verifies |
|---|--------|-------|----------|
| 1 | Add `RecordingOptions.micAEC` (default `true`) + thread through `withOutput`. | `RecordingOptions.swift` | Compiles. |
| 2 | Add `MACREC_MIC_AEC` to `ConfigResolver.Keys` + resolve with default `true` + pass to `RecordingOptions(micAEC:)`. | `ConfigResolver.swift` | Compiles + `swift test --filter ConfigResolverTests` (if present). |
| 3 | Implement `VPMicrophoneSource`. | new `Sources/MacrecCore/Capture/VPMicrophoneSource.swift` | Compiles. |
| 4 | Branch in `RecordingSession.run()` to construct `VPMicrophoneSource` when `options.micAEC == true`. | `RecordingSession.swift` line 426. | Compiles + log inspection at runtime. |
| 5 | Add `--mic-aec` to `StartCommand` + map into overrides. | `StartCommand.swift`. | `macrec start --help` shows the new flag. |
| 6 | Add `@AppStorage` + Toggle in `ControlBar`/popover; pass `micAEC:` to `RecordingOptions(…)` at line 476. | `ControlBar.swift`, possibly `MicrophonePicker.swift` for placement. | UI launches; toggle persists across relaunch. |
| 7 | Update docs (`docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, `CLAUDE.md` tool entries). | Docs only. | `git diff --name-only` matches expected file list. |
| 8 | Update `Issues - Pending Items.md` (resolve "system audio bleeds into mic channel"). | `Issues - Pending Items.md`. | Item moves from pending → completed. |
| 9 | Build both products: `swift build -c debug --product macrec`, `swift build -c debug --product macrec-ui`. | n/a | Both succeed. |
| 10 | Smoke-test plan in `test_scripts/plan-013-aec-smoke.md`. | new test_scripts file. | Manual verification per AC-1. |

## 7. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| `setVoiceProcessingEnabled(true)` throws on a particular device (e.g. some USB interfaces). | `VPMicrophoneSource.start()` surfaces the error via `MacrecError.micAECUnavailable`. The orchestrator logs the error and aborts the session. The user can then pass `--mic-aec off` (or toggle off in UI) and retry — explicit per project rule "no fallback for missing config". |
| Voice-processing band-narrowing surprises a user trying to capture music. | Documented loud and clear in `docs/tools/macrec.md` AEC section; CLI `--help` text mentions the trade-off; UI toggle help text mentions it. |
| Format-conversion CPU cost rises slightly (AVAudioConverter on every tap). | The pipeline already runs an `AVAudioConverter` per source by design; the additional cost is negligible on Apple Silicon. The 1 Hz heartbeat log will still show healthy buffer counts. |
| Tests that mocked `AVMicrophoneSource` may now miss the new code path. | New tests in `Tests/MacrecCoreTests/VPMicrophoneSourceTests.swift` cover the new source independently. Existing `RecordingSession` tests continue to inject a `FakeAudioSource` and are unaffected. |

## 8. Out of scope (deliberate)

- Custom adaptive-filter AEC (LMS/NLMS) — deferred. Apple's voice processing is good enough and doesn't require us to maintain DSP code.
- Per-app reference signal selection — voice processing always uses the default output device. If the user routes system audio to a non-default device while AEC is on, bleed will be reduced but not eliminated. Documented as a known limitation.
- A "headphones detected → auto-disable AEC" heuristic — would surprise users; left as a manual toggle.

## 11. Post-ship defect — NLMS divergence (2026-05-09)

> **Superseded by plan-014 (2026-05-09).** The v4 fix described in
> §11 (per-sample reference slide + leakage + 0.99 hard clip) reduced
> peaks from +10 dBFS to +3.7 dBFS but did not eliminate divergence
> in the no-bleed case (headphones / low speaker volume). The
> remaining "filtering distortion" was traced to (a) NLMS adapting
> to spurious correlations whenever there was reference activity but
> no real echo, and (b) AAC MDCT ringing on hard-clipped square-wave
> residuals. plan-014 ships the v5 stability rewrite — PTS-aligned
> reference windowing, reference-activity gate, double-talk detector,
> 50 ms divergence reset, soft-knee limiter — and flips the AEC
> default to off (opt-in). Section §11 is preserved for historical
> context. See `docs/design/plan-014-aec-stability.md` for the
> current implementation.

### Symptom
After plan-013 (revised) shipped, recording with `--mic-aec on` (the default) produced an audibly distorted mic track. Sample artefacts in `sample/aec-on.{mic,system}.m4a` show the mic peaking at **+10.56 dBFS** (max sample magnitude **3.37**) — well past the 0 dBFS encoder ceiling. Distortion is time-progressive: clean for the first ~6 s, occasional excursions to 1.4–1.8 between 6–11 s, and repeated excursions to 2.5–3.4 from 11 s onwards. Catastrophic NLMS divergence.

### Root cause
`SoftwareAECProcessor.processMic(_:)` v3 snapshotted the reference-window phase **outside** the per-sample inner loop:

```swift
let writeIdxStart = self.refWriteIdx[ch]
for n in 0..<frameCount {
    let phase = (writeIdxStart % L)        // ← does NOT depend on n
    let window = ringPtr.baseAddress!.advanced(by: phase)
    ...
    vDSP_vsma(window, 1, &scale, wPtr…)    // weight update vs. constant input
}
```

For every one of the ~1024 mic samples in a buffer the **same** reference window was used, both to compute `yHat` and to update the weights. NLMS therefore performed `frameCount` consecutive weight updates against an identical input vector with varying `d`, growing the weights along that one direction unboundedly. When the next buffer arrived with a slightly different `x`, projecting the (now-large) weights onto it produced a huge `yHat`, the residual `e = d − yHat` blew past 0 dBFS, and the AAC encoder clipped. The block comment at the snapshot site even documented that the position should advance per sample — the loop body just never did.

### Fix (`SoftwareAECProcessor` v4)
1. **Per-sample reference advancement.** For mic sample `n` in a buffer the ref window now ends at logical position `writeIdxStart − frameCount + n` (rates are identical at 48 kHz, so the buffer's `frameCount` mic samples correspond to the latest `frameCount` reference samples). Phase is `(endIdx + 1) % L` per the double-write invariant. During the first `L + frameCount` samples of a session — before a full reference window exists — the mic is passed through untouched and weight updates are skipped.
2. **Weight leakage.** New `Configuration.leakage` field (default `1e-5`, ~2 s time constant at 48 kHz). Each NLMS update applies `w := (1 − leak) · w` before the gradient step via `vDSP_vsmul`, so any residual weight growth bleeds off rather than accumulating.
3. **Larger regularisation.** `Configuration.regularization` default `1e-6` → `1e-3`, so a near-silent reference no longer turns `μ · e / (‖x‖² + reg)` into a five-orders-of-magnitude amplification.
4. **Output safety net.** New `Configuration.clipThreshold` (default `0.99`); the cleaned residual is hard-clipped before being re-packed into the CMSampleBuffer. Guarantees the encoder cannot ever again receive samples > 0 dBFS, even if a future regression re-introduces divergence.

### Verification gate
- Both products build clean (`swift build -c release --product macrec`, `swift build -c release --product macrec-ui`).
- Manual re-record of a 30 s sample with `--mic-aec on`, then `ffmpeg -i <mic>.m4a -af astats=measure_overall=Peak_level -f null -` must report **Peak level ≤ 0 dBFS**. Documented in `test_scripts/plan-013-aec-smoke.md` step §peak-amplitude.

### Files touched by the fix
- `Sources/MacrecCore/Capture/SoftwareAECProcessor.swift` — `Configuration` gains `leakage` + `clipThreshold`; `processMic` inner loop rewritten.
- `docs/design/plan-013-microphone-aec.md` — this section.
- `Issues - Pending Items.md` — `PLAN-013-DEFECT-1` entry.
- `test_scripts/plan-013-aec-smoke.md` — peak-amplitude check appended.
