# plan-013 — manual AEC smoke test

Verifies the four user-facing surfaces added by plan-013:

1. `--mic-aec` CLI flag honoured on the `start` subcommand.
2. `MACREC_MIC_AEC` env var honoured.
3. macrec-ui popover toggle persists and is honoured.
4. Default (no flag / env / toggle change) routes through `VPMicrophoneSource`.

The test material is intentionally informal — the change is a capture-path swap, so the gating evidence is the **log line** the new code emits at session start (`mic source = VPMicrophoneSource (AEC=on, voice-processing)` vs `mic source = AVMicrophoneSource (raw, AEC=off)`) plus an audible / visual check on the resulting audio file.

## Setup

```sh
cd /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
swift build -c release --product macrec
mkdir -p sample
```

Pick something distinctive to play through the speakers (a 30 s music clip, a YouTube video, etc.). Position the laptop so the built-in mic can hear the speakers — i.e. **do NOT wear headphones for this test**. Headphones would mask the bleed before AEC even runs and the test would be inconclusive.

## 1. Default (AEC on) — CLI

```sh
.build/release/macrec start --output sample/aec-on.m4a --layout split --max-duration 15
```

Start playing the test audio out the speakers. Speak a few words into the mic at the same time. Wait for the `--max-duration` to elapse.

Expected log line on stderr (look at the early lines):

```
… mic source = VPMicrophoneSource (AEC=on, voice-processing)
```

Expected file: `sample/aec-on.m4a` is a `--layout split` recording. Open it in QuickTime / VLC. Channel 1 (system) plays the test audio cleanly. Channel 2 (mic) carries your voice with **noticeably reduced bleed** of the test audio (Apple's voice processing cancels most of it).

## 2. AEC off via CLI

```sh
.build/release/macrec start --output sample/aec-off.m4a --layout split --max-duration 15 --mic-aec off
```

Replay the same test. Expected log line:

```
… mic source = AVMicrophoneSource (raw, AEC=off)
```

Expected file: `sample/aec-off.m4a` Channel 2 (mic) clearly contains the test audio bleeding from the speakers in addition to your voice — i.e. the pre-plan-013 baseline. This is the *negative control* — without AEC the bleed should be obvious.

A/B comparison: open both files in a DAW or `ffplay` side by side. The mic channel of `aec-on.m4a` should be much quieter on the system-audio frequencies than `aec-off.m4a`'s mic channel.

## 3. AEC off via env var

```sh
MACREC_MIC_AEC=off .build/release/macrec start --output sample/aec-env-off.m4a --layout split --max-duration 10
```

Same expected log line as Test 2 (`AVMicrophoneSource (raw, AEC=off)`). Confirms the env var path resolves correctly.

```sh
MACREC_MIC_AEC=on .build/release/macrec start --output sample/aec-env-on.m4a --layout split --max-duration 10
```

`VPMicrophoneSource` log line. Confirms the env var also flips the resolver back on (and that `on` / `off` spellings are accepted alongside `true` / `false`).

## 4. macrec-ui popover toggle

```sh
bash scripts/package-macrec-ui-app.sh
open dist/macrec-ui.app
```

Open the popover. Under **General** there should be a new "Mic echo cancellation" toggle. By default it is on (the toggle's switch is on the right).

- Click Start with the toggle on → in the macrec-ui log file (`~/.tool-agents/macrec-ui/macrec-ui.log` or the app's stderr), you should see the `VPMicrophoneSource (AEC=on, voice-processing)` line.
- Stop, flip the toggle off, click Start again → the log should now print `AVMicrophoneSource (raw, AEC=off)`.
- Quit the app and re-launch. The toggle should remember its last state (persisted via `@AppStorage("com.macrec.ui.micAEC")`).

## 5. Mic-health heartbeat parity

For each of the runs above, the 1 Hz `mic_health: …` heartbeat log line should fire and report non-zero `buffers=…` and a non-zero `recentPeakAmp` while you are speaking. Examples:

```
mic_health: buffers=42 totalFrames=43008 lastSize=1024 recentPeakAmp=0.1234 sinceLastBuf=0.02s aec=on
mic_health: buffers=21 totalFrames=2048 lastSize=… recentPeakAmp=0.0987 sinceLastBuf=0.01s
```

The `aec=on` suffix appears only on the `VPMicrophoneSource` heartbeat — it is the easy way to confirm at a glance which source the orchestrator picked.

## 6. Negative — invalid flag

```sh
.build/release/macrec start --output /tmp/x.m4a --mic-aec maybe
```

Should fail with exit code 64 (EX_USAGE) and the stderr message:

```
macrec: error: invalid value for MACREC_MIC_AEC: 'maybe' (expected: boolean (true/false, 1/0, yes/no, on/off))
```

This confirms the no-fallback rule still applies — bogus values are rejected, not silently treated as `true`.

## Expected pass criteria

| Test | Log line                                              | Mic-channel content (audibly)                      |
| ---- | ----------------------------------------------------- | -------------------------------------------------- |
| 1    | `VPMicrophoneSource (AEC=on, voice-processing)`       | Voice clear; system-audio bleed clearly reduced.   |
| 2    | `AVMicrophoneSource (raw, AEC=off)`                   | Voice + obvious system-audio bleed (baseline).     |
| 3a   | `AVMicrophoneSource (raw, AEC=off)`                   | Same as Test 2.                                    |
| 3b   | `VPMicrophoneSource (AEC=on, voice-processing)`       | Same as Test 1.                                    |
| 4-on | `VPMicrophoneSource (AEC=on, voice-processing)`       | Same as Test 1.                                    |
| 4-off| `AVMicrophoneSource (raw, AEC=off)`                   | Same as Test 2.                                    |
| 5    | Heartbeat fires every ~1 s; `recentPeakAmp > 0` on speech. | n/a                                          |
| 6    | Exit code 64; stderr message above.                   | n/a                                                |

If every row matches, plan-013 ships.

## 7. Peak amplitude (regression guard for PLAN-013-DEFECT-1)

The v3 software AEC suffered NLMS divergence — the mic track in `sample/aec-on.mic.m4a` peaked at +10.56 dBFS and clipped audibly. The v4 fix added per-sample reference advancement, weight leakage, and a hard-clip at ±0.99. This step is the regression guard.

Re-record a 30 s clip with AEC on while playing distinct content out the speakers and speaking into the mic:

```sh
.build/release/macrec start --output sample/aec-peak-check.m4a --layout split --max-duration 30
```

Then check the mic-channel peak (use whatever filename split-layout produces; macrec writes `<base>.mic.m4a` for `--layout split`):

```sh
ffmpeg -hide_banner -i sample/aec-peak-check.mic.m4a \
       -af "astats=measure_perchannel=Peak_level:measure_overall=Peak_level" -f null - 2>&1 \
  | grep "Peak level dB"
```

**Pass:** every reported `Peak level dB` value is **≤ 0.0** (i.e. negative, meaning the mic track stays under 0 dBFS). A small headroom margin (≤ −0.1 dB) is normal because of the 0.99 hard-clip ceiling.

**Fail:** any positive value — the filter is diverging again. Inspect the `macrec.aec` logger output (look for `SoftwareAECProcessor v4` init line and follow with the per-buffer level meters).

> **Note (2026-05-09):** the smoke-test prose above (sections 1–6) still references the failed `VPMicrophoneSource` strategy. The actual log line emitted by the current code is `mic source = AVMicrophoneSource (AEC processor=on|off)` — the `VPMicrophoneSource (AEC=on, voice-processing)` strings predate the plan-013 revision. A follow-up should rewrite §1–§6 against the software-AEC log surface; that rewrite is unrelated to PLAN-013-DEFECT-1 and is tracked separately.
