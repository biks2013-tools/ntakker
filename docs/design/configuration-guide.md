# macrec — Configuration Guide

> Authoritative reference for every configuration value `macrec` reads.
> Source of truth for the resolver implementation:
> `Sources/MacrecCore/Config/ConfigResolver.swift`
> (env-var key constants live in `ConfigResolver.Keys`).

---

## 1. Configuration sources and precedence

`macrec` resolves every configuration value from up to four sources. Higher-
priority sources override lower-priority sources on a per-key basis:

| Priority | Source                                        | Notes                                                                                                                                                              |
|----------|-----------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 (lowest)  | Shell environment                          | Anything exported in the current shell (`export OUTPUT_PATH=…`). Read via `ProcessInfo.processInfo.environment`.                                                   |
| 2          | User `.env` at `~/.tool-agents/macrec/.env` | Per-user durable defaults. Folder is auto-created at mode `0700`, file at mode `0600`. Same `KEY=VALUE` syntax as a typical `.env`; `#` comments and quoted values supported. |
| 3          | Local `.env` in the current working dir    | `./.env`. Highest of the env-variable sources. Same syntax.                                                                                                        |
| 4 (highest) | CLI flag                                  | Always wins.                                                                                                                                                       |

If the same key is defined in multiple sources, the highest-priority source
wins for that key only — the resolution is not all-or-nothing.

If a required value (currently only `OUTPUT_PATH`) is missing from every
source, `macrec` exits with `MacrecError.missingRequiredConfig` (exit 78,
`EX_CONFIG`). **There are no fallback defaults for required values.**

### What is NOT configurable here

- TCC permissions (Screen Recording, Microphone) — granted in System
  Settings, not via env vars.
- Audio device names — `--mic-device` accepts a name or UID, but the
  authoritative list comes from `macrec list-devices`.

### Expiring parameters

`macrec` has **no parameters that expire** (no PAT keys, OAuth tokens, or
API credentials). The CLAUDE.md "expiration date" provision therefore does
not apply. Should a future revision add a credential (e.g. for a cloud
upload destination), an `<X>_EXPIRES_AT` ISO-8601 companion variable should
be introduced at that time.

---

## 2. Per-variable reference

Each row lists: the CLI flag, the env-var name, the data type, default
value, allowed values, a short description, and the recommended storage
tier.

### 2.1 `OUTPUT_PATH` — output file path (required)

| Field                  | Value                                                                                  |
|------------------------|----------------------------------------------------------------------------------------|
| CLI flag               | `-o`, `--output <path>`                                                                |
| Env-var name           | `OUTPUT_PATH` (intentionally **unprefixed** — predates the `MACREC_*` convention)       |
| Type                   | filesystem path (`~` is expanded)                                                      |
| Default                | _none — required_                                                                      |
| Allowed values         | any writable file path; `-` (stdout streaming) is **not supported**                    |
| Recommended storage    | local `.env` (per-project) or CLI flag (per-recording)                                  |
| Notes                  | parent directory must exist; if file exists, pass `--overwrite` or use a different path |

How to obtain it: pick a path on local disk. There is no acquisition step.

### 2.2 `MACREC_FORMAT` — output container

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--format <format>`                                                |
| Env-var name           | `MACREC_FORMAT`                                                    |
| Type                   | enum string                                                        |
| Default                | `m4a`                                                              |
| Allowed values         | `m4a` (AAC), `wav` (linear PCM, little-endian), `caf` (linear PCM, big-endian) |
| Recommended storage    | user `.env` (`~/.tool-agents/macrec/.env`) for a personal default, or CLI flag |

Pick `m4a` for size; `wav`/`caf` for archival or downstream DSP work that
prefers PCM.

### 2.3 `MACREC_LAYOUT` — track layout

| Field                  | Value                                                                                                            |
|------------------------|------------------------------------------------------------------------------------------------------------------|
| CLI flag               | `--layout <layout>`                                                                                              |
| Env-var name           | `MACREC_LAYOUT`                                                                                                  |
| Type                   | enum string                                                                                                      |
| Default                | `mixed`                                                                                                          |
| Allowed values         | `mixed` (single stereo file with mic + system summed), `split` (two files: `<base>.mic.<ext>` and `<base>.system.<ext>`), `stereo-split` (one stereo file: mic on `--mic-channel`, system on the other) |
| Recommended storage    | CLI flag — layout is usually decided per-recording                                                                |

### 2.4 `MACREC_MIC_CHANNEL` — stereo-split mic channel

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--mic-channel <left|right>`                                       |
| Env-var name           | `MACREC_MIC_CHANNEL`                                               |
| Type                   | enum string                                                        |
| Default                | `left`                                                             |
| Allowed values         | `left`, `right`                                                    |
| Recommended storage    | user `.env` — preferred channel is usually consistent per user      |
| Notes                  | only consulted when `MACREC_LAYOUT=stereo-split`                   |

### 2.5 `MACREC_SAMPLE_RATE` — sample rate (Hz)

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--sample-rate <rate>`                                             |
| Env-var name           | `MACREC_SAMPLE_RATE`                                               |
| Type                   | integer                                                            |
| Default                | `48000`                                                            |
| Allowed values         | `44100`, `48000`                                                   |
| Recommended storage    | user `.env`                                                        |
| Notes                  | `48000` matches the `ScreenCaptureKit` default and avoids resampling on the system path |

### 2.6 `MACREC_BIT_DEPTH` — PCM bit depth

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--bit-depth <16|24>`                                              |
| Env-var name           | `MACREC_BIT_DEPTH`                                                 |
| Type                   | integer                                                            |
| Default                | `16`                                                               |
| Allowed values         | `16`, `24`                                                         |
| Recommended storage    | user `.env`                                                        |
| Notes                  | only honored for `MACREC_FORMAT=wav` or `caf`. Ignored for `m4a` (AAC). |

### 2.7 `MACREC_BITRATE` — AAC bitrate

| Field                  | Value                                                                                                |
|------------------------|------------------------------------------------------------------------------------------------------|
| CLI flag               | `--bitrate <kbps>`                                                                                   |
| Env-var name           | `MACREC_BITRATE`                                                                                     |
| Type                   | integer (interpreted as kbps if `< 1000`, otherwise as bps)                                          |
| Default                | `192` (kbps)                                                                                         |
| Allowed values         | kbps in `[64, 320]`, equivalently bps in `[64000, 320000]`                                           |
| Recommended storage    | user `.env`                                                                                          |
| Notes                  | only honored for `MACREC_FORMAT=m4a`. Out-of-range values fail with `MacrecError.invalidConfigValue` (exit 64). |

### 2.8 `MACREC_MIC_DEVICE` — microphone device selection

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--mic-device <name-or-uid>`                                       |
| Env-var name           | `MACREC_MIC_DEVICE`                                                |
| Type                   | string (device name or `kAudioDevicePropertyDeviceUID`)            |
| Default                | system default input device                                        |
| Allowed values         | any value listed by `macrec list-devices` (matched by name first, then UID) |
| Recommended storage    | user `.env` (typically constant per user)                           |
| How to obtain          | run `macrec list-devices`; copy the `uid=` token for an exact match |

### 2.9 `MACREC_LOG_LEVEL` — log verbosity

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--log-level <level>`                                              |
| Env-var name           | `MACREC_LOG_LEVEL`                                                 |
| Type                   | enum string                                                        |
| Default                | `info`                                                             |
| Allowed values         | `quiet`, `info`, `debug`                                           |
| Recommended storage    | shell env (per-session) or CLI flag                                 |
| Notes                  | `debug` includes per-buffer aligner and recorder traces; very verbose |

### 2.10 `MACREC_MAX_DURATION` — auto-stop after N seconds

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--max-duration <seconds>`                                         |
| Env-var name           | `MACREC_MAX_DURATION`                                              |
| Type                   | positive number (seconds; fractional accepted)                     |
| Default                | unset (record until SIGINT / SIGTERM / `macrec stop`)              |
| Allowed values         | any value `> 0`                                                    |
| Recommended storage    | CLI flag (typically per-recording)                                  |

### 2.11 `MACREC_OVERWRITE` — overwrite existing output file

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--overwrite` (boolean flag, no value)                             |
| Env-var name           | `MACREC_OVERWRITE`                                                 |
| Type                   | boolean (`true`/`false`, `1`/`0`, `yes`/`no` — case-insensitive)   |
| Default                | `false`                                                            |
| Allowed values         | as above                                                           |
| Recommended storage    | CLI flag — opt-in per recording                                     |

### 2.12 `MACREC_DETACH` — run as a background daemon

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--detach` (boolean flag, no value)                                |
| Env-var name           | `MACREC_DETACH`                                                    |
| Type                   | boolean                                                            |
| Default                | `false` (foreground)                                               |
| Allowed values         | as above                                                           |
| Recommended storage    | CLI flag — almost always per-invocation                             |
| Notes                  | when `true`, the resolved `runMode` is `.detached`; otherwise `.foreground`. |

### 2.13 `MACREC_PID_FILE` — PID file path

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--pid-file <path>`                                                |
| Env-var name           | `MACREC_PID_FILE`                                                  |
| Type                   | filesystem path (`~` expanded)                                     |
| Default                | `~/.tool-agents/macrec/macrec.pid`                                 |
| Allowed values         | any writable path                                                   |
| Recommended storage    | user `.env` — only override if you run multiple concurrent recordings |
| Notes                  | both `start --detach` and `stop` consult this value; they MUST agree on the path |

### 2.14 `MACREC_LOG_FILE` — daemon log file path

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--log-file <path>`                                                |
| Env-var name           | `MACREC_LOG_FILE`                                                  |
| Type                   | filesystem path                                                    |
| Default                | `~/.tool-agents/macrec/macrec.log`                                 |
| Allowed values         | any writable path                                                   |
| Recommended storage    | user `.env`                                                        |
| Notes                  | only consulted in `--detach` mode. Opens in append mode at 0600. No rotation in v1 (FR-29 limitation). |

### 2.15 `MACREC_STOP_TIMEOUT` — `stop` SIGTERM grace period

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--stop-timeout <seconds>`                                         |
| Env-var name           | `MACREC_STOP_TIMEOUT`                                              |
| Type                   | positive number (seconds)                                          |
| Default                | `35`                                                               |
| Allowed values         | `> 0` and `<= 600`                                                 |
| Recommended storage    | user `.env` (e.g. raise to 60 if your recordings are very long)     |
| Notes                  | only consulted by `macrec stop`. After timeout, `MacrecError.stopTimeout` (exit 70) fires. |

---

## 3. Recommended storage strategy

| Variable             | Suggested tier              | Rationale                                                         |
|----------------------|-----------------------------|-------------------------------------------------------------------|
| `OUTPUT_PATH`        | local `.env` or CLI         | per-project / per-recording                                        |
| `MACREC_FORMAT`      | user `.env`                 | personal default                                                   |
| `MACREC_LAYOUT`      | CLI                         | per-recording                                                      |
| `MACREC_MIC_CHANNEL` | user `.env`                 | personal default                                                   |
| `MACREC_SAMPLE_RATE` | user `.env`                 | personal default                                                   |
| `MACREC_BIT_DEPTH`   | user `.env`                 | personal default                                                   |
| `MACREC_BITRATE`     | user `.env`                 | personal default                                                   |
| `MACREC_MIC_DEVICE`  | user `.env`                 | constant per user                                                  |
| `MACREC_LOG_LEVEL`   | shell env or CLI            | per-session (`MACREC_LOG_LEVEL=debug macrec start ...`)            |
| `MACREC_MAX_DURATION`| CLI                         | per-recording                                                      |
| `MACREC_OVERWRITE`   | CLI                         | opt-in per recording                                               |
| `MACREC_DETACH`      | CLI                         | per-invocation                                                     |
| `MACREC_PID_FILE`    | user `.env`                 | only override for multi-recording setups                           |
| `MACREC_LOG_FILE`    | user `.env`                 | rarely changed                                                     |
| `MACREC_STOP_TIMEOUT`| user `.env`                 | preference per user                                                |

---

## 4. Quick start

A typical setup blends all four sources:

```sh
# 1. Shell environment — applies to every macrec invocation in this shell.
export MACREC_LOG_LEVEL=info

# 2. Per-user durable defaults — apply across all working directories.
cat > ~/.tool-agents/macrec/.env <<'EOF'
MACREC_FORMAT=m4a
MACREC_SAMPLE_RATE=48000
MACREC_BITRATE=192
MACREC_MIC_DEVICE=BuiltInMicrophoneDevice
MACREC_STOP_TIMEOUT=60
EOF
chmod 0600 ~/.tool-agents/macrec/.env

# 3. Per-project override — drop a .env in the project working directory.
cd ~/projects/podcast
cat > .env <<'EOF'
OUTPUT_PATH=./recordings/episode.m4a
MACREC_LAYOUT=split
EOF

# 4. CLI override for this single recording — wins over everything above.
macrec start --max-duration 1800 --overwrite
```

---

## 5. Troubleshooting

When a recording doesn't behave as expected, start by raising the log level:

```sh
macrec start --output /tmp/diag.m4a --max-duration 5 --log-level debug --overwrite
```

The debug stream logs (in order):

- The resolved `RecordingOptions` snapshot (with the source that won each
  key — useful for confirming precedence).
- TCC permission state for Screen Recording and Microphone.
- `ScreenCaptureKit` configuration values.
- `AVCaptureSession` device selection and format negotiation.
- Aligner gap-fill events and PTS arithmetic.
- Recorder finalization timeline.

Common failure modes and their stderr cues:

| Symptom (stderr line)                                                                  | Likely cause                                                     | Fix                                                                                              |
|----------------------------------------------------------------------------------------|------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `missing required config: OUTPUT_PATH (checked: …)`                                     | no `--output` flag and no `OUTPUT_PATH` in any `.env` / shell    | pass `--output <path>`, or define `OUTPUT_PATH` in `~/.tool-agents/macrec/.env` or `./.env`.      |
| `invalid value for MACREC_BITRATE: '999' (expected: kbps in [64, 320] or bps in …)`     | bitrate outside the AAC range                                    | choose a value in `[64, 320]` kbps.                                                              |
| `output file already exists: <path>`                                                    | path exists and `--overwrite` not passed                         | pass `--overwrite`, or pick a different `--output`.                                              |
| `Screen Recording permission not yet granted; system prompt has been triggered`         | first run; user has not yet approved the prompt                  | approve in System Settings, then re-run (same-process state can't be re-read).                   |
| `Screen Recording permission denied`                                                    | TCC denial                                                       | System Settings > Privacy & Security > Screen Recording > enable `macrec`.                       |
| `microphone device not found: 'XYZ'`                                                    | typo in `--mic-device` or device disconnected                    | run `macrec list-devices` and copy the `uid=` token.                                             |
| `Another macrec recording is already running (PID …)`                                   | `start --detach` while a prior detached recording is alive       | run `macrec stop` first, or use a different `--pid-file`.                                        |
| `No active macrec recording found (PID file at … does not exist).`                      | `stop` invoked without a prior `start --detach`                  | start one first; or check that `--pid-file` matches what `start` used.                           |
| `Stale PID file at … referenced PID … which is no longer running. The file has been removed.` | previous detached recording crashed without cleanup              | safe to start a new recording immediately.                                                       |
| `macrec process … did not exit within …s of SIGTERM.`                                   | finalization is slow or hung                                     | wait, then `ps -p <pid>`; if hung, `kill -KILL <pid>` (loses the recording).                     |

For configuration-precedence puzzles specifically, the
`ConfigResolverTests` suite (`Tests/MacrecCoreTests/ConfigResolverTests.swift`)
documents the matrix exhaustively. Reading those tests is often faster
than tracing through `.env` files by hand.
