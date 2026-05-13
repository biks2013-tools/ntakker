# macrec — macOS dual-source audio recorder + live transcription + in-recording Q&A

A native macOS tool that captures **system audio** (Music, Spotify, browsers, Zoom, Teams, …) and the **microphone** simultaneously, streams them to a live transcription provider, and lets you ask questions about what's been said while it's still being said.

Three surfaces, one engine:

| Component   | Kind                       | Purpose                                                                  |
|-------------|----------------------------|--------------------------------------------------------------------------|
| `macrec`    | Swift CLI                  | Headless recording + transcription. Drives CI, scripts, terminal use.    |
| `macrec-ui` | Swift menu-bar app         | Menu-bar popover with mode toggle (Transcription / Asking), Save flow, Settings. |
| `convo-coach` | Node CLI (TypeScript)    | Reads a recorded transcript and streams coaching advice from an LLM.     |

Local-first by design — audio capture is fully on-device; only the streams you explicitly opt into (transcription provider, Q&A LLM) leave the machine.

---

## Quickstart

### 1. Build everything

```sh
swift build -c release --product macrec
swift build -c release --product macrec-ui
```

### 2. Launch the menu-bar app

The recommended path — package it as a proper `.app` so TCC grants stick and Apple Cloud Speech works:

```sh
bash scripts/package-macrec-ui-app.sh
open dist/macrec-ui.app
```

(Or install system-wide — see [`docs/tools/macrec-ui.md`](docs/tools/macrec-ui.md) for the `/Applications/` deploy recipe.)

A speaker-icon should appear in the menu bar. Click it → grant Microphone + Screen Recording when macOS prompts → press the red record button.

### 3. (Optional) Use the CLI

```sh
swift run macrec --help
swift run macrec list-devices
swift run macrec start --output ~/Recordings/test.m4a
# Ctrl-C to stop
```

---

## Features

### Recording (`macrec` + `macrec-ui`)

- **System audio** via `ScreenCaptureKit`, **microphone** via `AVFoundation`, captured in parallel.
- Output formats: `m4a`, `wav`, `caf`.
- Track layouts: `mixed` (one file, sources merged), `split` (mic + system as separate tracks in one file), `stereo-split` (mic = L, system = R).
- Detached background recording paired with `macrec stop`.
- Manual segment split mid-recording (rotates the encoder without dropping audio).
- **Software acoustic echo cancellation (AEC)** — custom NLMS adaptive filter subtracts speaker-to-mic bleed using the captured system audio as reference. Opt-in: `--mic-aec on` / `MACREC_MIC_AEC=on` / popover toggle. See [plan-013](docs/design/plan-013-microphone-aec.md) / [plan-014](docs/design/plan-014-aec-stability.md).

### Live transcription

Pluggable provider matrix, configured via the popover picker or `MACREC_TRANSCRIBE`:

| Provider              | Where it runs        | Languages              | Notes                                      |
|-----------------------|----------------------|------------------------|--------------------------------------------|
| `apple`               | On-device            | macOS-shipped locales  | `SpeechAnalyzer` (macOS 26+)               |
| `apple-cloud`         | Apple cloud          | broad                  | UI-only (TCC scope)                        |
| `whisperkit`          | On-device            | Whisper large-v3       | Argmax `WhisperKit`                        |
| `parakeet`            | On-device            | ~25 European locales   | NVIDIA Parakeet TDT V3 via `FluidAudio`    |
| `soniox`              | Cloud (WS streaming) | dual-locale ready      | Speaker diarization on by default          |
| `gemini`              | Cloud (REST batch)   | broad                  | Google AI                                  |
| `azure`               | Cloud (REST batch)   | broad                  | Microsoft no-training contract             |
| `azure-openai-realtime` | Cloud (WS)         | broad                  | Auto-reconnects at 58 min                  |
| `elevenlabs`          | Cloud (REST batch)   | broad                  | Scribe v2; key-term boosting               |

Sidecar formats: `jsonl` (default), `txt`, `srt`, `vtt`. Source-split (`--transcribe-source both`) produces two parallel sidecars + a two-lane live UI.

### In-recording Q&A ("Asking")

While a recording is in progress, switch to the **Asking** pane and type a question. The last N minutes of transcript + your question are sent to an LLM and the answer streams back token-by-token. On stop, a `<basename>.questions.jsonl` sidecar is written next to the audio.

Eight provider families supported (same vendor-canonical env vars as `convo-coach`):

```
openai · anthropic · google · azure-openai · azure-ai-inference · ollama · litellm · mlx
```

Configure via **Settings → Asking (Q&A)** in the menu-bar app, or the env vars:

```sh
MACREC_ASK_PROVIDER=azure-openai
MACREC_ASK_MODEL=…                # optional, falls back to provider default
MACREC_ASK_CONTEXT_MINUTES=5      # 1..30
```

Privacy: cloud providers trigger a one-time disclosure sheet per provider. Missing credential → typed inline error in the pane (no fallback, no silent failure).

### Session bundling (Save…)

After Stop, hit **Save…** to bundle everything into `~/Recordings/<your-folder-name>/`:

```
~/Recordings/<folder>/
  ├── transcript.md       — live transcript, Markdown with timestamps
  ├── qa.md               — Q&A exchanges, chronological
  ├── recording-001.m4a   — audio (copied, originals stay put)
  └── *.transcript.jsonl  — any sidecars that were next to the audio
```

Folder names are Unicode-safe (Greek, Cyrillic, CJK, accented Latin all work). Collisions get an ISO timestamp suffix instead of overwriting.

---

## Configuration

Every tool follows the same four-tier resolution chain (lowest → highest priority):

1. **Shell environment** — `export MACREC_…=…`
2. **`~/.tool-agents/<tool-name>/.env`** — durable per-tool defaults (mode `0600`)
3. **Local `.env`** — per-project overrides
4. **CLI flags** — `--transcribe gemini`, etc.

The UI's Settings panel writes to the `~/.tool-agents/macrec-ui/.env` file, atomically, with mode `0600`. Edits are also `setenv`'d into the running process so the next recording picks them up without a restart.

**No fallback rule.** Missing required credentials raise a typed error (`MacrecError.missingRequiredConfig`) — the app never substitutes a default value for a secret.

For the full env-var catalogue see:
- [`docs/tools/macrec.md`](docs/tools/macrec.md) — CLI reference
- [`docs/tools/macrec-ui.md`](docs/tools/macrec-ui.md) — UI reference
- [`docs/tools/convo-coach.md`](docs/tools/convo-coach.md) — Coaching CLI reference

---

## Project layout

```
recording-tool/
├── Sources/
│   ├── macrec/              — CLI executable target
│   ├── macrec-ui/           — Menu-bar SwiftUI app
│   ├── MacrecUIKit/         — Reusable UI domain layer (RecordingController, …)
│   └── MacrecCore/          — Engine: capture, encoding, transcription, Q&A
│       ├── Capture/         — ScreenCaptureKit + AVFoundation sources
│       ├── Encoding/        — m4a/wav/caf writers
│       ├── Transcription/   — Provider matrix (Apple, WhisperKit, Soniox, …)
│       └── Asking/          — Q&A: provider clients (OpenAI / Anthropic / Gemini), config, sidecar
├── Tests/
├── tools/
│   └── convo-coach/         — TypeScript companion CLI
├── docs/
│   ├── tools/               — Per-tool reference docs
│   ├── design/              — Plans (plan-001 … plan-015)
│   └── reference/           — External material
├── scripts/                 — Packaging scripts (.app bundle)
├── Resources/               — Info.plist files for the two binaries
└── Package.swift
```

---

## Requirements

- macOS 26 (Tahoe) or later — required for `SpeechAnalyzer` ([Exception 002](CLAUDE.md#exception-002))
- Xcode 16 / Swift 6.2 toolchain
- For `convo-coach` only: Node.js ≥ 20
- TCC grants on first launch: Microphone, Screen Recording, (optional) Speech Recognition

---

## Build matrix

| Goal                                            | Command                                                 |
|-------------------------------------------------|---------------------------------------------------------|
| Quick dev iteration, attached to terminal       | `swift run macrec-ui`                                   |
| Release binary, raw                             | `swift build -c release --product macrec-ui`            |
| Proper `.app` bundle (TCC, Dock, Spotlight)     | `bash scripts/package-macrec-ui-app.sh`                 |
| Sign with a real identity                       | `CODESIGN_IDENTITY="Developer ID …" bash scripts/package-macrec-ui-app.sh` |
| Install system-wide                             | `cp -R dist/macrec-ui.app /Applications/`              |
| Run tests                                       | `swift test`                                            |
| Install `convo-coach` on PATH                   | `cd tools/convo-coach && npm install && npm link`       |

---

## Troubleshooting

| Symptom                                                                     | Fix                                                                                                                                                                            |
|-----------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Microphone / Screen Recording prompts never appear                          | TCC associates grants with the bundle id. For CLI use, prompts attach to the terminal app; for UI use, build the `.app` bundle (`scripts/package-macrec-ui-app.sh`) and `open` it. |
| Apple Cloud Speech Recognition does nothing from `swift run macrec`         | Apple Cloud is UI-only — the CLI does not get speech recognition entitlement. Use the bundled `.app`.                                                                          |
| `MACREC_ASK_PROVIDER` error in the Asking pane                              | Open Settings → Asking (Q&A) → pick a provider. The required credentials for that provider must already be present (`AZURE_OPENAI_*`, `OPENAI_API_KEY`, etc.).                  |
| Azure OpenAI returns `OperationNotSupported` / `api-version not supported`  | `unset AZURE_OPENAI_API_VERSION` (or clear it in Settings → Azure OpenAI) so the SDK uses the new v1 GA path that supports current chat models.                                |
| Stale `macrec-ui` instance blocks the new build's TCC prompts                | `pkill -f '\.build/.*macrec-ui' \|\| true` before relaunching.                                                                                                                |
| Mic echo cancellation distorts speech                                       | The v5 NLMS filter is opt-in — toggle it off in Settings or set `MACREC_MIC_AEC=off`. See [plan-014](docs/design/plan-014-aec-stability.md) for the stability story.            |

For deeper diagnostics, every component logs to OSLog under the `macrec.*` subsystem. View live:

```sh
log stream --predicate 'subsystem CONTAINS "macrec"' --info
```

---

## Documentation map

- **CLI reference:** [`docs/tools/macrec.md`](docs/tools/macrec.md)
- **UI reference:** [`docs/tools/macrec-ui.md`](docs/tools/macrec-ui.md)
- **Coach CLI reference:** [`docs/tools/convo-coach.md`](docs/tools/convo-coach.md)
- **Project design** (architecture, threading, file layout): [`docs/design/project-design.md`](docs/design/project-design.md)
- **Functional requirements:** [`docs/design/project-functions.MD`](docs/design/project-functions.MD)
- **Active plans:** [`docs/design/plan-*.md`](docs/design/) — most recent are plan-013 / plan-014 (AEC) and plan-015 (in-recording Q&A).
- **Issues / pending items:** [`Issues - Pending Items.md`](Issues%20-%20Pending%20Items.md)
- **Project rules and approved exceptions:** [`CLAUDE.md`](CLAUDE.md)

---

## Conventions in a nutshell

- **Swift** for the recording engine and UI (approved exception to the project-wide "TypeScript for tools" rule — system-audio capture needs `ScreenCaptureKit` + `AVFoundation`; see [Exception 001](CLAUDE.md#exception-001) in `CLAUDE.md`).
- **TypeScript** for everything else (e.g. `convo-coach`).
- **No fallback** for configuration: every missing required key raises `MacrecError.missingRequiredConfig` instead of silently filling in a default.
- **Vendor-canonical env-var names** — `OPENAI_API_KEY`, `AZURE_OPENAI_*`, `GOOGLE_API_KEY`, etc. — shared across `macrec-ui`, `convo-coach`, and any future tool.
- **Recording-integrity invariant**: nothing (transcription, Q&A, sidecar writes) is allowed to compromise the audio file. Failures degrade gracefully.

---

## License

Local-first, single-user project. Not currently published; see the repo owner for redistribution terms.
