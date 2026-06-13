# plan-014 — AEC stability smoke test

Supersedes `plan-013-aec-smoke.md`. Verifies the v5 `SoftwareAECProcessor`
under both no-bleed (headphones) and real-bleed (speakers) conditions,
plus the default-off opt-in behaviour. The acceptance criteria below
match `docs/design/plan-014-aec-stability.md` §1.

## Prerequisites

```sh
cd /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
swift build -c release --product ntakker-cli
mkdir -p sample
which ffmpeg                       # required for peak analysis
```

## §0. Default is now off (AC-4)

```sh
.build/release/ntakker-cli start --output sample/p014-default.m4a --layout split --max-duration 5
```

Expected stderr near session start (look for the `mic source` log line):

```
… mic source = AVMicrophoneSource (AEC processor=off)
```

Pass: AEC processor is **off** by default. No `SoftwareAECProcessor v5 …
initialised` line in the log.

## §1. AEC ON, no-bleed setup (AC-1, AC-3)

**Setup.** Plug in headphones (or set system output volume to 0). Start
playing speech / music through the *system* (the recorder will still
capture it from the system tap). Speak into the mic while the system
audio plays. The mic genuinely receives no acoustic bleed.

```sh
.build/release/ntakker-cli start --output sample/p014-noBleed.wav --layout split --max-duration 30 --mic-aec on
```

> Recording to `.wav` (not `.m4a`) bypasses the AAC encoder so we can
> verify the **pre-encoder** waveform peaks. AAC overshoot was a major
> source of confusion in plan-013 §11.

Expected stderr:

```
… mic source = AVMicrophoneSource (AEC processor=on)
… SoftwareAECProcessor v5 (plan-014: PTS-aligned NLMS + ref-activity gate + double-talk detector + divergence reset + soft limiter) initialised: filterLength=4096 (~85 ms) μ=0.01 reg=0.01 stepMax=0.001 leak=1e-05 …
… SoftwareAECProcessor first reference: frames=… channels=2 bufferStartPTS=…
… SoftwareAECProcessor first mic processed: frames=… channels=2 micFirstPTS=…
```

Verification — extract mic-channel peak:

```sh
ffmpeg -hide_banner -i sample/p014-noBleed.mic.wav \
       -af "astats=measure_perchannel=Peak_level:measure_overall=Peak_level" -f null - 2>&1 \
  | grep "Peak level dB"
```

**Pass (AC-1):** every reported `Peak level dB` ≤ **0.0 dB** (negative,
i.e. below 0 dBFS). The soft limiter ceiling is 0.95 ≈ -0.45 dBFS, so a
healthy run stays a few tenths of a dB under that.

**Pass (AC-3):** spot-check the same window in the raw mic against an
AEC-off reference of the same scene (re-record once with `--mic-aec
off`). The AEC-on RMS over any 1 s window should be ≤ AEC-off RMS over
the same window — the filter must not amplify the mic. (`ffmpeg
astats=measure_overall=RMS_level` on each.)

**Fail signature.** Any positive `Peak level dB`. Inspect stderr for
`AEC divergence reset fired …` lines — if those appear repeatedly, the
gates are letting through too much; tune
`referenceActivityRMSThreshold` or `doubleTalkRatio` upward.

## §2. AEC ON, real-bleed setup (AC-2)

**Setup.** Take the headphones off. Set system output volume to a
normal listening level (~50 %). Position the laptop so the built-in
mic clearly captures the speakers (don't cover the mic with anything).

Two recordings of the same scene — same playback content, same time of
day, same mic position:

```sh
# Baseline — AEC off.
.build/release/ntakker-cli start --output sample/p014-bleed-off.wav --layout split --max-duration 30 --mic-aec off

# Treatment — AEC on.
.build/release/ntakker-cli start --output sample/p014-bleed-on.wav  --layout split --max-duration 30 --mic-aec on
```

For both, **after the first 5 s** (filter convergence window),
compute the mic-channel RMS:

```sh
for f in sample/p014-bleed-off.mic.wav sample/p014-bleed-on.mic.wav; do
  echo "$f"
  ffmpeg -hide_banner -ss 5 -i "$f" -af "astats=measure_overall=RMS_level" -f null - 2>&1 \
    | grep "RMS level dB"
done
```

**Pass (AC-2):** `(bleed-off mic RMS) - (bleed-on mic RMS) ≥ 12 dB` over
the 5–30 s window. v5 typically achieves 15–25 dB residual reduction at
steady state.

**Pass (AC-2 ceiling):** `bleed-on mic` peak ≤ 0 dBFS (use the same
`astats … Peak_level` invocation as §1).

**Fail signature.** RMS reduction < 8 dB across multiple takes — the
filter isn't converging. Check the `ntakker-cli.aec` log for high
`updatesSkippedDoubleTalk` counts (visible in the snapshot statistics if
diagnostics-level logging is on); if the gate is too aggressive,
`doubleTalkRatio` may need to be tuned.

## §3. Divergence reset works (AC-5)

**Setup.** This is intentionally adversarial — play loud, abrupt
content (e.g. drum hits or claps) through speakers while moving the
laptop / covering the mic / unplugging headphones. The goal is to push
the filter into momentary divergence and verify the reset recovers it.

```sh
.build/release/ntakker-cli start --output sample/p014-divergence.wav --layout split --max-duration 60 --mic-aec on
```

During the recording, watch stderr. If divergence is triggered, you
will see:

```
… AEC divergence reset fired N time(s) — weights re-zeroed (cumulative resets=…)
```

**Pass (AC-5):** the reset fires when audibly bad behaviour starts, and
the mic recovers to a clean signal within ~1 s after the reset (the
filter re-converges from zero). Cumulative resets over a 1-minute
session should typically be ≤ 3 even under adversarial conditions.

**Fail signature.** Reset fires continuously (> 1/s) and the filter
never settles. Either the test setup is genuinely incompatible with AEC
(e.g. periodic signal that defeats NLMS by design), or the reset hold
window is too short.

## §4. CLI / env / toggle parity (AC-6)

```sh
# Env override.
NTAKKER_MIC_AEC=on .build/release/ntakker-cli start --output /tmp/p014-env-on.m4a --max-duration 5
NTAKKER_MIC_AEC=off .build/release/ntakker-cli start --output /tmp/p014-env-off.m4a --max-duration 5

# Bogus value rejected (no fallback rule).
.build/release/ntakker-cli start --output /tmp/p014-bogus.m4a --mic-aec maybe
```

**Pass:** the first command logs `AEC processor=on`. The second logs
`AEC processor=off`. The third exits 64 with the existing
`invalid value for NTAKKER_MIC_AEC: 'maybe'` error — same as plan-013 §6.

For the ntakker popover:

```sh
bash scripts/package-ntakker-app.sh
open dist/ntakker.app
```

- Open the popover. The "Mic echo cancellation" toggle in the General
  section is **off** by default (AC-4).
- Flip it on, click Start. Stderr / `~/.tool-agents/ntakker/ntakker.log`
  shows `AEC processor=on`.
- Stop, quit the app, relaunch. Toggle remembers its last state.

## Pass / fail summary

| AC  | Test | Pass criterion |
|-----|------|----------------|
| 1   | §1 (no-bleed, WAV) | mic peak ≤ 0 dBFS |
| 2   | §2 (real-bleed, WAV) | bleed-off RMS - bleed-on RMS ≥ 12 dB; bleed-on peak ≤ 0 dBFS |
| 3   | §1 (no-bleed) | AEC-on mic RMS ≤ AEC-off mic RMS in matched windows |
| 4   | §0 + §4 | default is off; CLI / env / toggle all work |
| 5   | §3 (adversarial) | reset fires, recovery within 1 s, ≤ 3 resets/min |
| 6   | §4 | flag name, env name, toggle behaviour all unchanged |

If every row passes, plan-014 ships.
