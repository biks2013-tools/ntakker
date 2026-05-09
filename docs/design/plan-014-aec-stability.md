# plan-014 — AEC stability rewrite (v5) + default-off

> Successor plan to plan-013 (revised). plan-013 §0 + §11 capture the failed
> `VPMicrophoneSource` attempt and the v3-era NLMS divergence; this plan
> ships the **stable** implementation.

**Approved 2026-05-09. Owner: Claude (autonomous).**

## 0. Why this plan exists

After `SoftwareAECProcessor` v4 shipped earlier today (per-sample reference
slide + leakage + 0.99 hard-clip), a fresh sample recording (`sample/aec-on.{mic,system}.m4a`)
shows the mic still peaking at **+3.7 dBFS** during system-audio activity.
Investigation found four compounding root causes:

1. **No actual acoustic bleed in the recording** — cross-correlation between
   mic and system in the 7–9 s window is essentially zero (≤ 0.06 across
   ±500 ms of lag). The user is on headphones (or speakers off / very low),
   so the optimal AEC weights are 0. Yet the filter actively diverges away
   from 0 and produces "filtering distortion" — the symptom the user
   reported.
2. **NLMS without safeguards diverges in the no-echo case**. With μ=0.1 and
   a strong reference + a strong but uncorrelated mic, the algorithm
   chases short-term spurious correlations between music/speech (`x`) and
   user voice (`d`). v4's leakage (1e-5) is too slow to bleed the drift
   off; v4's μ is too aggressive to stay near zero.
3. **Hard clip + AAC = MDCT overshoot**. The pre-encoder samples are
   correctly clipped to ±0.99 (verified — the v4 binary contains the
   `SoftwareAECProcessor v4 (per-sample ref slide + leakage + safety
   clip)` init line). But a square-wave-like clipped residual rings
   through AAC's MDCT and the *decoded* peaks reach +3.7 dB. The audible
   distortion is the underlying square wave, not the AAC overshoot.
4. **Buffer-cadence mismatch invalidates v4's ref-window assumption**.
   `AVCaptureAudioDataOutput` typically delivers ~512–1024-sample mic
   buffers; `ScreenCaptureKit` delivers larger blocks at less regular
   intervals. v4 assumed "the latest `frameCount` ref samples align with
   this mic buffer" — only true under lockstep cadence, which doesn't
   hold in practice. So even if echo existed, the filter would be
   learning a misaligned impulse response.

## 1. Acceptance criteria

- **AC-1.** With `--mic-aec on` and headphones (no real bleed), a 30 s
  recording shows mic peak ≤ 0 dBFS at the **encoder boundary** (verify
  via `--format wav`, not AAC).
- **AC-2.** With `--mic-aec on` and speakers (real bleed), the mic
  channel after 5 s of warm-up has ≥ 12 dB residual-bleed reduction vs
  `--mic-aec off` baseline, **and** mic peak ≤ 0 dBFS.
- **AC-3.** Filter never amplifies the mic above its raw input level
  (residual RMS ≤ raw mic RMS at all times after warm-up).
- **AC-4.** Default is **off** — bare `macrec start` / fresh launch of
  `macrec-ui` records with the raw `AVMicrophoneSource` path. AEC is
  explicit opt-in via `--mic-aec on`, `MACREC_MIC_AEC=on`, or the
  popover toggle.
- **AC-5.** A divergence-recovery test: record 30 s of music through
  speakers loud enough to clip the mic preamp, then immediately stop
  and record again — the filter weights are zeroed between sessions
  (already true since the processor is a per-session instance). During
  a single session, if the filter starts diverging it self-resets
  within 200 ms.
- **AC-6.** The user-facing surface is unchanged in shape: same flag
  name, same env var, same toggle. Only the *default* moves from `on`
  to `off`.

## 2. Five algorithmic layers (A–E)

All five run inside the per-mic-sample inner loop. The order is:

```
read mic sample d
compute reference window x (PTS-aligned — see §3)
compute yHat = w · x, refPower = ||x||²
update short-term envelopes (refEnv, micEnv)         ← layer (info gather)
e = d - yHat
update residual envelope (resEnv)                    ← layer C input

soft-limit e → out                                   ← layer E (always applied)
write out to cleaned[ch][n]

# adaptation gate (layers A + B + C)
if refRMS < refActivityThreshold:                    ← layer A
    skip update
elif micEnv > refEnv * doubleTalkRatio:              ← layer B
    skip update
elif resEnv > micEnv (sustained > divergenceMs):     ← layer C
    reset weights to 0
    skip update
else:
    w := (1 - leak) * w  +  step * x                 ← layer D (calmer step)
    where step = clamp(μ · e / (refPower + reg),  ±stepMax)
```

### Layer A — Reference-activity gate
Skip weight updates whenever the most recent `~20 ms` of reference is
below `referenceActivityRMSThreshold` (default `3e-3` ≈ -50 dBFS RMS).
No reference signal → no echo to learn. Pre-empts adaptation during
system silence (which was producing spurious updates in v4 because
`refPower` was tiny and `reg` couldn't fully suppress the gradient).

### Layer B — Double-talk detector
Skip weight updates whenever `micEnv > refEnv * doubleTalkRatio`
(default `4.0`). When the mic is much louder than the reference,
either (i) the user is talking and there is no real echo, or (ii) the
echo path attenuation is very high and the residual is dominated by
voice. Either way, adapting biases the filter toward voice
suppression — actively harmful. This is the layer the user's
"headphones + voice + system audio" case needs most.

### Layer C — Divergence reset
Track residual envelope vs mic envelope. If `resEnv > micEnv` for
> `divergenceResetMs` (default `50 ms`), the filter is making things
worse than no filter at all → reset all weights to 0. The next
adaptation cycle starts from a known-good state. This is the
self-healing safety net for whatever the gates miss.

### Layer D — Calmer step + step clamp
Move μ from 0.1 → **0.01**. Move regularization from 1e-3 → **1e-2**.
Add a per-sample step-magnitude clamp: `step = clamp(μ·e/(refPower+reg),
±stepMax)` with `stepMax = 1e-3`. With one tenth the step size, the
filter cannot move far enough in any single buffer to diverge before
the gates above can intervene. Trade-off: convergence on a real echo
takes ~3–10 s instead of ~1–3 s.

### Layer E — Soft-knee limiter
Replace the hard clip at ±0.99 with a tanh-style soft limiter. Below
`limiterKnee` (default `0.7`) the signal is unchanged. Between knee
and `limiterCeiling` (default `0.95`), a smooth quadratic roll-off:

```swift
let t = (|x| - knee) / (ceiling - knee)         // 0..1
let mapped = knee + (ceiling - knee) * (1 - (1-t)*(1-t))
```

Output stays band-limited (no high-frequency content from a hard-clip
edge), so AAC's MDCT no longer rings → decoded mic peaks stay ≤ 0
dBFS regardless of pre-encoder waveform shape.

## 3. Layer F — PTS-based reference alignment (structural)

**Problem.** v4 indexes the reference ring buffer by *count of samples
received*. With independent capture cadences the count drifts away
from real time, so `processMic` reads a window that does not
correspond temporally to the mic samples it is processing.

**Fix.** Index the ring by **logical sample position derived from the
buffer's PTS**, with a single shared anchor (`refAnchorPTS`, set on
the first `feedReference` call).

Per-channel state:

```swift
private var refAnchorPTS: CMTime?      // set once, shared across channels
private var refLastWriteEnd: [Int]     // logical index after the most-recent write, per ch
private let ringCapacity = filterLength * 2     // 8192 = ~170 ms at 48 kHz
private var refRing: [[Float]]         // size 2 × ringCapacity per channel (double-write)
```

`feedReference(buffer)`:

1. Convert `buffer.pts` (already host-clock-aligned per `CaptureBuffer`
   contract) to seconds; if `refAnchorPTS` is nil, set it.
2. Compute `bufferStartLogical = round((buffer.pts - refAnchorPTS) ·
   sampleRate)`.
3. If `bufferStartLogical < refLastWriteEnd[ch]` (overlap / out-of-order),
   drop the buffer.
4. If `bufferStartLogical > refLastWriteEnd[ch]` (gap), zero-fill the
   gap region of the ring before writing the new samples. (Otherwise
   stale data would sit in the gap and corrupt the next read.)
5. Write each sample to `ring[(p % C)]` AND `ring[(p % C) + C]` for the
   double-write invariant. Advance `refLastWriteEnd[ch]`.

`processMic(buffer)`:

1. Compute `micFirstLogical = round((buffer.pts - refAnchorPTS) ·
   sampleRate)`. (Same anchor — both streams share the host clock.)
2. For mic sample `n`, the desired ref window ends at logical position
   `p = micFirstLogical + n`.
3. Validate the window is currently in the ring:
   - `p >= filterLength - 1` (full L samples behind p),
   - `p <= refLastWriteEnd[ch] - 1` (data has been written),
   - `p >= refLastWriteEnd[ch] - ringCapacity` (samples not yet
     overwritten).
   If any fails → passthrough (write `d` to output, skip adapt).
4. Otherwise read the window at `phase = (p + 1) % C`.

`refAnchorPTS` is set when the very first reference buffer arrives. If
the first mic buffer arrives BEFORE any ref buffer, all its samples
fail validation (no ref data exists yet) → passthrough. That's the
right behaviour during the cold-start window.

## 4. Default flip — opt-in instead of opt-out

User policy decision (2026-05-09): the AEC is now off by default. The
fix above makes the AEC **safe** to leave on (no distortion when no
real echo exists), but for users on headphones it costs ~5–8 % CPU
doing nothing useful. Flipping the default to `false` aligns the
behaviour with explicit user intent.

Touch-points:

| File | Change |
|------|--------|
| `Sources/MacrecCore/Config/RecordingOptions.swift` | `micAEC: Bool = false` (init default), update doc-comment to reflect opt-in semantics. |
| `Sources/MacrecCore/Config/ConfigResolver.swift` | `parseBool(default: false)` for `Keys.micAEC`. |
| `Sources/macrec-ui/Views/MicEchoCancellationToggle.swift` | `@AppStorage … = false`. |
| `Sources/macrec-ui/Views/ControlBar.swift` | same `@AppStorage` default. |
| `Sources/macrec/Commands/StartCommand.swift` | `--mic-aec` help text — change "Default: on" to "Default: off". |
| `docs/tools/macrec.md` / `docs/tools/macrec-ui.md` | update descriptions. |
| Project `CLAUDE.md` tool entries | "default-on" → "opt-in" wording. |

## 5. Files touched

```
Sources/MacrecCore/Capture/SoftwareAECProcessor.swift   (full rewrite to v5)
Sources/MacrecCore/Config/RecordingOptions.swift        (default: false + doc)
Sources/MacrecCore/Config/ConfigResolver.swift          (default: false + doc)
Sources/macrec/Commands/StartCommand.swift              (help text)
Sources/macrec-ui/Views/MicEchoCancellationToggle.swift (AppStorage default)
Sources/macrec-ui/Views/ControlBar.swift                (AppStorage default)
Sources/macrec-ui/Views/Sections/GeneralSection.swift   (help-text only)
docs/design/plan-014-aec-stability.md                   (this file)
docs/design/plan-013-microphone-aec.md                  (pointer to plan-014)
docs/tools/macrec.md                                    (default flip + algorithm note)
docs/tools/macrec-ui.md                                 (default flip)
CLAUDE.md (project root)                                (tool entries)
Issues - Pending Items.md                               (PLAN-014 entry)
test_scripts/plan-014-aec-stability-smoke.md            (new — supersedes plan-013 smoke)
```

## 6. Phases

| # | Action | Verifies |
|---|--------|----------|
| 1 | Rewrite `SoftwareAECProcessor` to v5 (layers A–F + soft limiter). | `swift build -c release --product macrec` clean. |
| 2 | Flip defaults in `RecordingOptions`, `ConfigResolver`, both `@AppStorage`. | Same build. |
| 3 | Update CLI / help-text strings. | `macrec start --help` shows new wording. |
| 4 | Update `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, project `CLAUDE.md` tool entries. | `git diff --name-only` matches list above. |
| 5 | Append plan-014 reference to plan-013 §11. | grep finds the link. |
| 6 | Add `PLAN-014` entry at the top of `Issues - Pending Items.md`. | Issue file lints. |
| 7 | Write `test_scripts/plan-014-aec-stability-smoke.md` with the WAV peak verification (AC-1 / AC-2). | Manual run produces pass/fail per AC. |

## 7. Risks

| Risk | Mitigation |
|------|------------|
| Layer C reset thrashes if envelopes are noisy. | Use a 50 ms sustained-violation window (not a single sample) before resetting. Log every reset at INFO; if logs show > 1 reset/min in steady state, retune. |
| Layer A threshold too high → real quiet echo never adapts. | Default `3e-3 ≈ -50 dBFS` is below normal speech reference levels (-15 to -25 dBFS) by 25+ dB. Manual tune-knob remains via `MACREC_AEC_REF_ACTIVITY_DBFS` follow-up if needed. |
| Layer F PTS arithmetic overflows on long recordings. | `Int` logical index at 48 kHz overflows `Int32` after ~12 hours; we use `Int` (64-bit on macOS) — no realistic overflow. |
| Soft-limiter knee colours real loud mic content (loud speech). | Knee at 0.7 (-3 dBFS) only affects samples already very loud. The limiter is also self-disengaging: when the filter is healthy, residual stays well below 0.7. |
| Default-off surprises existing power users. | Documented in `docs/tools/macrec.md` migration note and CLAUDE.md tool entry. Existing `--mic-aec on` invocations and any persisted UI toggle = on continue to work. |

## 8. Out of scope

- Dynamic μ control (NLMS-PNLMS or affine projection) — overkill for
  the use case. The fixed μ=0.01 + gates is the right engineering
  trade-off here.
- Cross-channel echo (multichannel AEC). Same as plan-013 — not
  worth the cost for laptop stereo speakers.
- Frequency-domain block AEC (PFDAF). Future work. Time-domain NLMS
  with the gates above is sufficient for laptop speaker → built-in mic
  bleed levels.
- Persisting filter weights across sessions to a per-device cache. Real
  echo path varies with laptop position, mic mute state, plugged-in
  USB devices, etc. Not worth the cache management.
