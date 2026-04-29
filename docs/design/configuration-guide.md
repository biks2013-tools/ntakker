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

Plan-003 introduced the first credential subject to expiration —
`GOOGLE_API_KEY` for Gemini transcription. The CLAUDE.md
configuration-guide rule for expiring credentials applies: a companion
variable `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` (§2.22) captures the ISO-8601
expiry date so `macrec` can warn the user proactively. See §2.21 and
§2.22 for the full pair. Future credentials (e.g. additional providers
like `OPENAI_API_KEY`) should follow the same pattern: pair the secret
with an `<X>_EXPIRES_AT` ISO-8601 companion.

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

## 2.bis Live transcription (plan-003 / plan-004 / plan-005)

The variables in §2.16 .. §2.22 were added by plan-003 to drive the
live-transcription side-channel (FR-45 .. FR-58, FR-AS-1 .. FR-AS-12,
project-design §LT-5 + §AS). All seven keys resolve through the same
four-tier chain documented in §1 and apply equally to the `macrec` CLI
and the `macrec-ui` menu-bar app (with the user `.env` tier scoped to
`~/.tool-agents/macrec/.env` for the CLI and
`~/.tool-agents/macrec-ui/.env` for the UI). Setting
`MACREC_TRANSCRIBE=none` makes every other key in this section a no-op
— note that plan-005 (2026-04-28) flipped the default from `none` to
`apple`, so users who want the legacy "no transcription" behaviour must
set `MACREC_TRANSCRIBE=none` explicitly.

### 2.16 `MACREC_TRANSCRIBE` — live-transcription provider selector

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--transcribe <provider>`                                          |
| Env-var name           | `MACREC_TRANSCRIBE`                                                |
| Type                   | enum string                                                        |
| Default                | `apple` (changed from `none` in plan-005)                          |
| Allowed values         | `none`, `apple` (default — NEW, on-device via `SpeechAnalyzer`, plan-005), `gemini` (REST-batch via Google Gemini), `gemini-live` (deprecated alias for `gemini` — accepted for one release with a `.notice` log line). |
| Recommended storage    | user `.env` for a personal default; CLI flag for per-recording opt-in |
| Notes                  | With `none`, no API keys are read, no network connections are opened, no sidecar files are written (AC-LT-1). Setting `gemini` (or its deprecated alias) with no API key configured raises `MacrecError.transcriptionApiKeyMissing` (exit 78) BEFORE any audio capture begins (AC-LT-4). The `apple` provider runs entirely on-device (no API key) but requires the user to grant Speech Recognition in System Settings → Privacy & Security on first run (FR-AS-8). Per plan-004 the detach + transcribe combination is now valid (the REST architecture has no terminal-output dependency); `MacrecError.transcriptionDetachUnsupported` is removed. |

> **Default flipped to `apple` in plan-005 (2026-04-28).** To restore the
> legacy "no transcription by default" behavior, set
> `MACREC_TRANSCRIBE=none` in your `.env`. The flip is justified because
> the new `apple` provider is on-device, has no per-call cost, requires
> no API key, and produces ≤ 250 ms first-partial latency on macOS 26.

How to obtain it: pick a provider from the table; `gemini` requires
a Google AI Studio API key (see §2.21); `apple` requires only that the
user grants the one-time `NSSpeechRecognitionUsageDescription` TCC
prompt (no key, no network).

> **Naming note.** Plan-003 §4 Phase C originally used the longer name
> `MACREC_TRANSCRIBE_PROVIDER`. The as-built implementation adopted the
> shorter `MACREC_TRANSCRIBE` (per the user-prompt direction at Phase H);
> project-design §LT-5.2 records the rationale. `MACREC_TRANSCRIBE` is
> the canonical name; `MACREC_TRANSCRIBE_PROVIDER` is **not** read by
> the resolver.

> **Provider-name migration (plan-004).** Plan-003 used the value
> `gemini-live` to identify the WebSocket Live API provider. Plan-004
> replaces that pipeline with a REST-batch provider whose canonical
> value is `gemini`. The resolver accepts `gemini-live` as a
> deprecated alias for one release (logs a `.notice`-level
> deprecation warning, then resolves to `gemini`). New `.env` files
> and CLI invocations should use `gemini`.

### 2.17 `MACREC_TRANSCRIBE_SOURCE` — transcription audio source

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--transcribe-source <source>`                                     |
| Env-var name           | `MACREC_TRANSCRIBE_SOURCE`                                         |
| Type                   | enum string                                                        |
| Default                | `mixed`                                                            |
| Allowed values         | `system` (system audio only), `mic` (microphone only), `mixed` (post-`BufferSummer` summed signal), `both` (two parallel streams, labelled by source) |
| Recommended storage    | user `.env` (consistent per workflow)                              |
| Notes                  | independent of the recording's `--layout`. v1 ships a single transcription driver; `both` outside a `split`-layout recording falls back to `mixed` (see `Issues - Pending Items.md` for the v2 follow-up). |

### 2.18 `MACREC_TRANSCRIBE_FORMAT` — sidecar transcript format

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--transcribe-format <fmt>`                                        |
| Env-var name           | `MACREC_TRANSCRIBE_FORMAT`                                         |
| Type                   | enum string                                                        |
| Default                | `jsonl`                                                            |
| Allowed values         | `jsonl` (one JSON object per `TranscriptEvent`; richest), `txt` (plain final-only text, no timestamps), `srt` (SubRip cues), `vtt` (WebVTT cues) |
| Recommended storage    | user `.env` for a personal default; CLI flag per recording          |
| Notes                  | `srt` and `vtt` only emit `final` events; partials are dropped. The JSONL header line records run-time metrics (FR-58). See project-design §LT-7 for the on-disk schemas. |

### 2.19 `MACREC_TRANSCRIBE_MODEL` — provider model id override

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--transcribe-model <id>`                                          |
| Env-var name           | `MACREC_TRANSCRIBE_MODEL`                                          |
| Type                   | string (provider-specific)                                         |
| Default                | `gemini-3-flash-preview` (the documented Google REST audio model per <https://ai.google.dev/gemini-api/docs/audio>) |
| Allowed values         | for `gemini`: `gemini-3-flash-preview` (default), `gemini-3.1-flash-live-preview` (Live-API SKU — returns HTTP 404 on REST; kept in the allow-list only for backward-compat configs), `gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-2.0-flash`. Values outside the list log a warning at start and are sent through. |
| Recommended storage    | user `.env` only when overriding the default; otherwise leave unset |
| Notes                  | The plan-004 brainstorming session (2026-04-28) initially pinned `gemini-3.1-flash-live-preview` as the default per user direction. PEND-LT-6 was empirically resolved 2026-04-28 — that model id is the Live (WebSocket) API SKU and returns HTTP 404 on `:generateContent`. The default was switched to `gemini-3-flash-preview`, the model id Google's official REST audio examples use. If you see HTTP 4xx errors with a non-default model, fall back to `gemini-3-flash-preview`. |

### 2.20 `MACREC_TRANSCRIBE_LANGUAGE` — spoken-language hint

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--transcribe-language <bcp-47-list>`                              |
| Env-var name           | `MACREC_TRANSCRIBE_LANGUAGE`                                       |
| Type                   | comma-separated BCP-47 language list (e.g. `en-US` or `en-US,el-GR`) |
| Default                | unset — provider auto-detect                                       |
| Allowed values         | one or more BCP-47 strings the provider accepts (e.g. `en-US`, `el-GR`, `fr-FR`, `en-US,el-GR`) |
| Recommended storage    | user `.env`                                                        |
| Notes                  | For `apple`, multiple values activate parallel recognizers — one per locale, picking the higher-confidence final per utterance (FR-AS-5, FR-AS-7). For `gemini`, only the first value is used as a hint. v1 does not validate against the provider's supported list (apple raises `transcriptionConfigConflict` exit 64 at start time on unsupported locale per FR-AS-9; gemini silently auto-detects). Translation (target-language selection) is explicitly out of scope for v1 — refined-request §Out of scope. |

### 2.21 `GOOGLE_API_KEY` — Gemini API key

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | _(none — by design)_                                               |
| Env-var name           | `GOOGLE_API_KEY` (vendor-canonical name per CLAUDE.md tool-conventions) |
| Type                   | API key string                                                     |
| Default                | unset                                                              |
| Allowed values         | any valid Google AI Studio API key                                 |
| Recommended storage    | `~/.tool-agents/macrec/.env` (mode `0600`) for the CLI and `~/.tool-agents/macrec-ui/.env` (mode `0600`) for the UI |
| Notes                  | resolved only when `MACREC_TRANSCRIBE=gemini` (or the deprecated alias `gemini-live`). **Missing key with provider != `none` raises `MacrecError.transcriptionApiKeyMissing` (exit 78) — no audio file is created.** No `--google-api-key` CLI flag exists; keys are never accepted on the command line (avoids leakage into shell history and `ps` output). Pair with `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` (§2.22) for proactive expiry warnings. |

How to obtain it:

1. Visit <https://aistudio.google.com/app/apikey>.
2. Sign in with a Google account.
3. Click **Create API key** (optionally inside an existing GCP project).
4. Copy the key.
5. Append it to `~/.tool-agents/macrec/.env` (and / or
   `~/.tool-agents/macrec-ui/.env`) as `GOOGLE_API_KEY=…`. Verify the
   file is mode `0600` (`chmod 0600 ~/.tool-agents/macrec/.env`).

> **Privacy reminder.** Enabling Gemini transcription causes the
> captured audio to be uploaded to Google's servers (see
> `docs/tools/macrec.md` → "Live transcription"). Review your
> organisation's data-handling policy before enabling on calls
> containing confidential content.

### 2.22 `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` — proactive expiry warning

| Field                  | Value                                                              |
|------------------------|--------------------------------------------------------------------|
| CLI flag               | `--transcribe-key-expires-at <iso-8601>`                            |
| Env-var name           | `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`                                 |
| Type                   | ISO-8601 date string (e.g. `2026-12-31` or `2026-12-31T00:00:00Z`) |
| Default                | unset — no warning emitted                                         |
| Allowed values         | any parseable ISO-8601 instant                                     |
| Recommended storage    | next to `GOOGLE_API_KEY` in the same `.env` file (so the pair is updated together) |
| Notes                  | introduced per the CLAUDE.md configuration-guide rule for expiring credentials. When set, the resolver compares the value against `Date()` at recording start: |

Behaviour:

- If the configured expiry is **already in the past**, an `info`-level
  log line is emitted (`Your GOOGLE_API_KEY expired on <date>; recording
  will start but transcription may fail`). Recording is **NOT** blocked
  — the user may have rotated the key without updating the `.env` file.
- If the configured expiry is within the next **7 days**, an
  `info`-level log line is emitted as a soft renewal reminder (`Your
  GOOGLE_API_KEY expires on <date>; consider renewing soon`).
- If the configured expiry is more than 7 days out, no log line is
  emitted.

The 7-day window is fixed in v1; future revisions may make it
configurable via `MACREC_TRANSCRIBE_KEY_EXPIRY_WARN_DAYS`.

> **Operational tip.** If your provider rotates keys on a fixed cadence
> (e.g. quarterly), set `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` to the
> rotation date when you paste the new key. The 7-day warning then
> nudges you ahead of the actual expiry.

### Resolution chain reminder for §2.16–§2.22

Every key in §2.16 .. §2.22 follows the same four-tier resolution
documented in §1 (lowest → highest priority):

```
shell env → ~/.tool-agents/<tool>/.env → ./.env → CLI flag
```

Higher tiers override lower ones on a per-key basis. `<tool>` is
`macrec` for the CLI and `macrec-ui` for the UI. `GOOGLE_API_KEY` is
NOT accepted via CLI flag — its highest-priority tier is the local
`./.env`.

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
| `MACREC_TRANSCRIBE`  | user `.env` or CLI          | personal default; CLI for per-recording opt-in                     |
| `MACREC_TRANSCRIBE_SOURCE` | user `.env`           | consistent per workflow                                            |
| `MACREC_TRANSCRIBE_FORMAT` | user `.env`           | consistent per workflow                                            |
| `MACREC_TRANSCRIBE_MODEL`  | user `.env` (when overriding the pinned default) | only if Phase I smoke test demands fallback model       |
| `MACREC_TRANSCRIBE_LANGUAGE` | user `.env`         | constant per user                                                  |
| `GOOGLE_API_KEY`     | user `.env` (mode `0600`)   | secret — never CLI, never shell history                            |
| `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` | user `.env` (next to `GOOGLE_API_KEY`) | rotated together with the key                       |

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
| `transcription api key missing for provider 'gemini-live': checked GOOGLE_API_KEY in …`  | `--transcribe gemini-live` (or `MACREC_TRANSCRIBE=gemini-live`) without `GOOGLE_API_KEY` set anywhere in the chain | obtain a key at <https://aistudio.google.com/app/apikey> and add `GOOGLE_API_KEY=…` to `~/.tool-agents/macrec/.env` (mode `0600`); see §2.21. |
| `--detach is incompatible with --transcribe <provider != none>`                          | combined `--detach` + a non-`none` provider                       | run the recording in foreground (drop `--detach`) or set `--transcribe none`. Detach-mode transcription is excluded in v1 (OQ-LT-5). |
| `Your GOOGLE_API_KEY expired on YYYY-MM-DD; recording will start but transcription may fail` | `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` is in the past                | renew the key at <https://aistudio.google.com/app/apikey>, update `GOOGLE_API_KEY`, and bump `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`. See §2.22. |

For configuration-precedence puzzles specifically, the
`ConfigResolverTests` suite (`Tests/MacrecCoreTests/ConfigResolverTests.swift`)
documents the matrix exhaustively. Reading those tests is often faster
than tracing through `.env` files by hand.
