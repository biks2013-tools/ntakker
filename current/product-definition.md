# Product Definition — `recording-tool` (macrec ecosystem)

> **Version:** v1 — 2026-05-12
> **Status:** Reverse-engineered from the current implementation on `master`. Synthesises `docs/design/project-design.md`, `docs/design/project-functions.md`, `docs/tools/{macrec,macrec-ui,dual-transcript-merger,convo-coach}.md`, plan-001 … plan-014, and the source tree under `Sources/`.
> **Audience:** Future product, design, and engineering sessions that need a single document describing **what `recording-tool` is** before they refine requirements, plan a new feature, or scope a change.
> **Scope of this document:** The product as it exists today. New behaviour goes through the items/ → current/requirements.md pipeline; this document is the baseline against which those proposals are diffed.

---

## 1. Identity

| Field | Value |
|---|---|
| **Product family** | `recording-tool` (project name) |
| **Anchor tool** | `macrec` — macOS dual-source audio recorder |
| **Companion UI** | `macrec-ui` — menu-bar status item with a popover panel |
| **Companion CLIs** | `dual-transcript-merger`, `convo-coach` |
| **Platform** | macOS 26 (Tahoe) — universal binary (`arm64` + `x86_64`) |
| **Implementation language** | Swift 5.9 for `macrec` / `macrec-ui` / `MacrecCore` / `MacrecUIKit`; TypeScript for `dual-transcript-merger` and `convo-coach` |
| **Distribution** | Local install only — no signed bundle distribution channel yet. `macrec` is a SwiftPM `executableTarget`; `macrec-ui` is built into a `.app` bundle via `scripts/package-macrec-ui-app.sh` and dropped into `/Applications/`. The TypeScript CLIs install via `npm link`. |
| **Bundle identifier (UI)** | `com.local.macrec-ui` (independent TCC grants from the CLI's terminal-host) |
| **Licence** | Project-internal; not currently published. |

### 1.1 One-line description

> "Record macOS system audio and the microphone at the same time, get a transcript next to the audio, optionally coach a conversation in real time — all on your own machine, no virtual audio devices required."

---

## 2. Why it exists — problem statement

1. **macOS has no first-class way to record system audio + mic together** without installing a virtual audio device (BlackHole, Loopback, Soundflower) that requires kernel extensions, system reconfiguration, and ages poorly across OS upgrades.
2. **`ScreenCaptureKit`** (introduced macOS 13, refined further in macOS 14 / 26) provides a sanctioned, kext-free system-audio capture path. No mainstream consumer app yet packages it ergonomically alongside a microphone recorder and a transcription side-channel.
3. **Live-conversation tooling** (transcripts, coaching, summarisation) is increasingly available as cloud or on-device services, but the connective tissue — capture, time-align, persist, hand-off to STT, hand-off to coaching LLM — is missing on the desktop in a way that respects local-first privacy posture.
4. **A single user on a single Mac** should be able to run all of this, fully scriptable, fully configurable, with auditable on-disk artifacts (audio + JSONL transcript + advice markdown) — and never be required to trust a server they don't control.

The product addresses all four.

---

## 3. Audience & use cases

### 3.1 Primary personas

- **Knowledge worker in meetings.** Uses `macrec-ui` from the menu bar before joining a Zoom / Teams / Meet call. Wants a clean recording of the call (their voice + everyone else's voice via the system-audio path), a transcript on disk, and — at the end — an optional summary or live coaching during long discussions.
- **Researcher / interviewer.** Records podcasts, interviews, lectures. Wants high-fidelity, split-channel recording (mic on one channel, system on the other) so they can edit afterwards in a DAW. Often wants a transcript per channel.
- **Power-user / script-friendly user.** Invokes `macrec start --detach` from a shell or a Hammerspoon binding; runs `macrec stop` to finalize. Routes the resulting JSONL transcript into their own pipeline (search index, summariser, RAG).
- **Live conversation coach.** Runs `macrec --transcribe soniox --transcribe-source both` to get a dual-channel diarized transcript, then pipes the sidecar into `convo-coach` to get streaming LLM coaching as the conversation continues.

### 3.2 Use cases (representative, not exhaustive)

1. **Meeting recording with on-device transcript** — `macrec start --transcribe apple` produces `recording-<ts>.m4a` plus `recording-<ts>.transcript.jsonl` with everything transcribed on-device via `SpeechAnalyzer` (macOS 26).
2. **Conference call with both channels labelled** — `macrec start --layout split --transcribe soniox --transcribe-source both` produces two audio files (`*.mic.m4a`, `*.system.m4a`) and two source-split transcripts.
3. **Detached background recording** — `macrec start --detach --output ~/Recordings/long.m4a --max-duration 7200` daemonises, writes a PID file, and continues recording for up to 2 hours. `macrec stop` terminates it cleanly.
4. **Interactive recording with the menu-bar UI** — open `macrec-ui` from the status bar, pick a folder, pick an STT provider, click record, see live level meters and a live transcript panel.
5. **Dual-mode transcription for accuracy comparison** — `macrec --transcribe dual` runs Apple on-device on Channel A and Apple Cloud on Channel B against the same audio; the merged sidecar makes the divergence visible.
6. **Post-recording coaching** — `convo-coach --transcript recording-<ts>.transcript.jsonl --provider azure-openai` streams advice to stdout and saves a dated `.advice-*.md` next to the transcript.
7. **Merging dual transcripts for human review** — `dual-transcript-merger sidecar.jsonl --filter aggressive --format txt` interleaves Channel A + Channel B, suppresses cross-language hallucinations, and emits a clean reading-friendly file.

---

## 4. Capabilities — what the product does today

Capability statements describe **observable behaviour**, not implementation. Each is mapped to the relevant functional requirement family on `master` for traceability.

### 4.1 Audio capture

| Capability | Notes | FR family |
|---|---|---|
| Simultaneous system-audio + microphone capture | `ScreenCaptureKit` (system) and `AVCaptureSession` (mic), no virtual audio device required | FR-1, FR-2, FR-3 |
| Time-alignment within ±20 ms | `HostClockAligner` per-source ring buffers, host-clock-synced microphone PTS | FR-22, NFR-4 |
| Configurable sample rate | 44.1 kHz or 48 kHz (internal pipeline runs at 48 kHz Float32 stereo) | FR-7, FR-17 |
| Configurable bit depth | 16-bit or 24-bit (PCM outputs only) | FR-7 |
| Configurable channel layout | Always stereo; mono inputs upmix/duplicate cleanly | FR-9 |
| Microphone device selection | `--mic-device <name|uid>`; defaults to the system default; UI picker tracks device hotplug | FR-3, FR-39 |
| Permission handling | Screen Recording + Microphone TCC checked before any capture session opens; `.notDetermined` triggers the prompt and exits 75; `.denied` exits 77 with a deep link to System Settings | FR-10 |
| Watchdog-driven SCStream restart | 5 s poll + 10 s staleness threshold; up to 3 restarts in 60 s; otherwise exit 70 | FR-19 |
| Crash-resilient AAC output | `shouldOptimizeForNetworkUse = true` and 2 s `movieFragmentInterval` so SIGKILL leaves a playable file | FR-21 |
| Finalization timeout | `finishWriting` aborts and exits 2 if not done within 30 s | FR-20 |

### 4.2 Output formats and track layouts

| Capability | Notes | FR family |
|---|---|---|
| Output containers | `m4a` (AAC-LC, default), `wav` (PCM, RIFF), `caf` (PCM, CoreAudio) | FR-4 |
| AAC bitrate | Default 192 kbps; range 64–320 kbps via `--bitrate` | FR-8, FR-17 |
| Mixed layout | Mic + system summed into a single stereo file | FR-5 (`mixed`) |
| Split layout | Two separate files, `.mic.<ext>` and `.system.<ext>`, sharing basename | FR-5 (`split`) |
| Stereo-split layout | Single stereo file with mic on one channel and system on the other; `--mic-channel left\|right` selects which side | FR-5 (`stereo-split`) |
| Output path safety | Refuses to write if parent directory missing, or output exists without `--overwrite` | FR-15, FR-24 |
| Segment file naming | `partNN` infix for multi-segment runs; preserves `.mic`/`.system` token positioning | FR-34 |

### 4.3 Lifecycle & process model

| Capability | Notes | FR family |
|---|---|---|
| Foreground recording | `macrec start` runs attached to the terminal; SIGINT / SIGTERM is the canonical clean-stop trigger; the file is finalized atomically | FR-1, FR-6 |
| Detached background recording | `macrec start --detach` double-forks, writes a PID file at `~/.tool-agents/macrec/macrec.pid`, redirects stdout/stderr to `~/.tool-agents/macrec/macrec.log`, parent exits 0 immediately | FR-25, FR-27, FR-29 |
| `stop` subcommand | Reads PID file, SIGTERMs the running process, waits up to `--stop-timeout` (default 35 s); distinguishes "no PID file" / "stale" / "stopped cleanly" / "did not exit in time" | FR-26 |
| Already-recording guard | Detached `start` refuses to start if a live PID file points at a running process; stale PID files are cleaned up automatically | FR-28 |
| Max duration cap | `--max-duration <seconds>` auto-stops at the cap | FR-6 |
| Pause / resume (UI) | Stop-and-stitch semantics: pause finalizes the current `partNN` file; resume opens the next one | FR-31, FR-34 |
| Manual split (UI) | `RecordingSession.split(nextOutput:)` rotates the encoder without stopping capture — gap ≤ 250 ms | FR-32 |
| Session state stream | `RecordingSession` exposes `AsyncStream<SessionState>` with cases `{ idle, starting, recording, pausing, paused, resuming, splitting, stopping, stopped, failed(MacrecError) }` — the UI reacts to transitions, never polls | FR-33 |

### 4.4 CLI surface

| Capability | Notes | FR family |
|---|---|---|
| `start` subcommand | Begin a recording (with all flags) | FR-11 |
| `stop` subcommand | Terminate a detached recording cleanly | FR-26 |
| `list-devices` subcommand | Print input audio devices (UID, name, channels, sample rate, default marker) | FR-11 |
| `check-permissions` subcommand | Print Screen Recording / Microphone / Speech Recognition TCC state without starting | FR-11 |
| `--help` / `--version` | Global flags from `swift-argument-parser` | FR-11 |
| Documented exit-code table | 0 / 1 / 2 / 64 / 66 / 70 / 75 / 77 / 78 — every error path returns one of these | FR-18 |
| Range validation at parse time | All numeric / enum config values validated; invalid → exit 64 with a one-line stderr message | FR-17 |

### 4.5 Configuration

| Capability | Notes | FR family |
|---|---|---|
| Four-tier env-var resolution | Shell env → `~/.tool-agents/<tool>/.env` → local `./.env` → CLI flags (low to high priority) | FR-12 |
| Per-user durable defaults bootstrap | On every invocation, `~/.tool-agents/macrec/` is ensured (`0700`); `.env` seeded at `0600` if absent | FR-13 |
| No silent fallback | Required values that are missing in the chain raise `transcriptionApiKeyMissing` / `transcriptionConfigConflict` / `invalidConfigValue` with exit 78 / 64 — never a substituted default | FR-14 |
| Vendor-canonical LLM env-var names | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `AZURE_OPENAI_*`, `AZURE_AI_INFERENCE_*`, `OLLAMA_HOST`, `LITELLM_*`, `MLX_*` | tool-conventions |
| Expiration-aware tokens | `*_API_KEY_EXPIRES_AT` companion env vars per `<configuration-guide>` rule; warning surfaced ~7 days before expiry | FR-AZ-12, FR-EL-13 |
| Project Memory Exception 003 | `convo-coach` defaults `COACH_PROVIDER` to `azure-openai` when unset (the user's primary access). Credentials still required from the chain. |

### 4.6 Live transcription (STT) — opt-in side-channel

The transcription subsystem is **opt-in** (`--transcribe none` is the default). When enabled, captured audio is downsampled to 16 kHz mono Float32 inside `MacrecCore`, buffered, and submitted to the chosen provider; results are written to a sidecar file alongside the audio without ever blocking recording.

| Provider | id | Mode | Audio path | Cost / privacy |
|---|---|---|---|---|
| **None** | `none` | n/a | No network, no sidecar, no key reads | Free, no audio leaves the machine |
| **Apple on-device** | `apple` | Streaming, per-utterance partials + finals (~80–250 ms first-partial latency) | `SpeechAnalyzer` (macOS 26) | Free; on-device; no network |
| **Apple Cloud** | `apple-cloud` | Streaming, on `SFSpeechRecognizer` cloud path | Apple Cloud STT | Free; audio sent to Apple per their privacy policy. **Only works from the bundled `macrec-ui.app`**, not the raw CLI |
| **Google Gemini** | `gemini` | Batch-REST per chunk (`generateContent`) | 16 kHz mono PCM16 WAV multipart | Paid; audio sent to Google |
| **Soniox** | `soniox` | Streaming over WebSocket; default-on speaker diarization (`[S1]`/`[S2]` labels in sidecar) | 16 kHz mono Int16 frames | Paid; audio streamed live to Soniox |
| **Azure OpenAI (batch)** | `azure` | Batch REST (`gpt-4o-mini-transcribe`) | Multipart WAV up to 25 MB | Paid; audio sent to Azure; per-tenant control |
| **Azure OpenAI (realtime)** | `azure-openai-realtime` | Streaming over WebSocket; 24 kHz PCM16 in `input_audio_buffer.append` JSON frames; VAD configurable; reconnect-with-replay; pre-emptive reconnect at 58 min | 16→24 kHz resample inside the provider | Paid; audio streamed live to Azure |
| **ElevenLabs** | `elevenlabs` | Batch REST (`scribe_v2`); optional diarization, entity detection (+30% cost), tag_audio_events | 16 kHz Int16 PCM WAV | Paid; audio sent to ElevenLabs |
| **WhisperKit** | `whisperkit` | Batch on-device (Apple Silicon Neural Engine) | Local `WhisperKit` model | Free; on-device |
| **Parakeet (TDT V3 multilingual)** | `parakeet` | Streaming on-device via `FluidAudio`; multilingual | Local model | Free; on-device |

#### 4.6.1 Cross-cutting transcription behaviour

- **Per-chunk buffering** (~2.5 s) before submission; `processLoop` wakes every ~2.0 s.
- **Energy gate** (peak < 0.01 ≈ −40 dBFS) skips near-silent chunks.
- **Hallucination filter** suppresses known-noise tokens (`"thank you"`, `"thanks for watching"`, etc.) end-to-end.
- **Segment coalescer** extends the most-recent same-source segment when the new chunk arrives within 12 s and the prior text does not end with sentence-final punctuation; otherwise appends.
- **Sidecar formats**: `jsonl` (default, in-place rewrites for growing segments), `txt`, `srt`, `vtt`. All carry the mandatory `.transcript.` infix in the filename.
- **Per-source labelling**: `--transcribe-source both` runs one `SourceBuffer` per source and tags each segment with `"source": "mic"` or `"source": "system"`. A single sidecar in non-split layouts; two sidecars in `--layout split`.
- **Source-split transcription** (`--transcribe-source both` with split-layout): each source gets its own transcription driver and its own sidecar (`*.system.transcript.<ext>` + `*.microphone.transcript.<ext>`) — two parallel pipelines, two lanes in the live UI.
- **Dual-mode transcription** (`--transcribe dual`): Apple on-device on Channel A and Apple Cloud on Channel B run concurrently against identical audio; one merged channel-tagged sidecar.
- **Bounded queue** — buffers cap at 2× `chunkSamples`; over-cap drops the oldest half and increments `bufferOverflowCount`. Recording is never blocked.
- **Clean stop drain** — on stop, in-flight provider calls are awaited up to 5 s; residual sample frames flushed with `final: true`; sidecar writers closed.
- **Metrics emitted on stop**: chunks sent, billable seconds, error count, last RTT, buffer overflow count, estimated USD cost.
- **Privacy disclosure** — first-time use of any non-on-device provider triggers a one-time per-provider confirmation dialog (in `macrec-ui`) or an stderr notice (in the CLI). Persisted per provider id.
- **Sidecar rotates on `split(nextOutput:)`** — close current writer(s), open fresh ones at the new path, reset the segment coalescer.

### 4.7 Microphone acoustic echo cancellation (AEC)

| Capability | Notes |
|---|---|
| Software NLMS adaptive filter | Custom `SoftwareAECProcessor` between the capture sources and the aligner. Reference signal = captured system audio. Subtracts the estimated speaker-to-mic acoustic bleed-back. |
| Preserves native mic frequency response | No AGC, no noise suppression, no band narrowing — only the speaker-bleed signal is removed. |
| Stability rewrite (plan-014, v5) | PTS-aligned reference windowing, reference-activity gating, double-talk detection, 50 ms windowed divergence reset, soft-knee output limiter. |
| Opt-in default | `--mic-aec on` (CLI), `MACREC_MIC_AEC=on` (env), or popover toggle. Default is **off** as of plan-014. |
| Use case | Prevents the speaker-emitted side of a video call from polluting the mic transcript; makes `--transcribe-source mic` produce a clean "your-voice-only" transcript when the other party is on speakers. |

### 4.8 macrec-ui — menu-bar app

| Capability | Notes |
|---|---|
| Menu-bar status item + popover | `NSStatusItem` + `NSPopover` panel; SwiftUI `App` shell with `Settings { EmptyView() }`; NOT `MenuBarExtra`. |
| In-process engine | Links `MacrecCore` directly; NOT a subprocess wrapper around the `macrec` CLI. |
| Independent TCC bundle | Bundle id `com.local.macrec-ui` so its Microphone / Screen Recording / Speech Recognition grants are separate from the CLI's terminal-host grants. |
| Controls | Start, Pause, Resume, Stop, Split (manual). |
| Live elapsed time | Segment + cumulative, `HH:MM:SS`, 1 Hz, paused-aware. |
| Recording-state icon | `idle` (neutral) / `recording` (red dot) / `paused` (yellow/hollow) / `failed` (red exclamation). Glanceable without opening the popover. |
| Per-source level meters | Peak + RMS at 30 Hz via post-converter Float32 stream; vDSP, non-blocking, `.bufferingNewest(2)` `AsyncStream`. |
| Format / layout / mic / folder pickers | Persisted in `UserDefaults`. Disabled during recording. |
| Permission status indicators | Three states each (granted / denied / not-determined). Polls 2 s while popover visible; refreshes on app activation; deep-links to System Settings on denial. |
| Live transcript panel | Renders `.segmentAppended` (new line) and `.segmentUpdated` (in-place rewrite). Auto-scroll with "Jump to live" affordance when scrolled away. Single-mode and dual-mode (stacked-lane) views. |
| Provider picker + key entry | Inline `ProviderKeyField` per provider with status chip (key present / missing / expiring soon). |
| Privacy disclosure sheet | First-time-per-provider explanation of where audio goes. Per-provider acknowledgement key in `UserDefaults`. |
| Dual / Single mode switch | Plan-010 — Single (one provider) vs Dual (Apple on-device + Apple Cloud in parallel) with per-channel locale / format / metrics panel. |
| Mic AEC toggle | Plan-013 / plan-014. Toggle in the General section; default off; effective immediately on next session. |
| Theming | Light / Dark / System mode (plan-008); appearance switcher in the header. |
| Logging | Through the existing `LoggerFactory` / swift-log pipeline. Default `.info`; hidden "Show debug log" toggle switches to `.debug`. Logs go to `~/.tool-agents/macrec-ui/macrec-ui.log` (`0600`, append). |

### 4.9 dual-transcript-merger (TypeScript CLI)

| Capability | Notes |
|---|---|
| Merge dual JSONL sidecars | Interleaves Channel A (`apple` on-device) and Channel B (`apple-cloud`) by timestamp into a single chronologically-ordered file. |
| Cross-language hallucination filter | `conservative` / `aggressive` / `off` modes; suppresses known hallucination phrases that appear in only one channel. |
| Output format | `jsonl` (metadata-preserving) or `txt` (human-readable). |
| Install path | `npm link` from `tools/dual-transcript-merger/` installs `dual-transcript-merger` on PATH globally. |
| Documentation | `docs/tools/dual-transcript-merger.md`. |

### 4.10 convo-coach (TypeScript CLI)

| Capability | Notes |
|---|---|
| Live coaching from transcript | Reads a single-channel or dual-channel JSONL sidecar and streams LLM-driven coaching to stdout. |
| Dated `.advice-*.md` sidecar | Every response written to a dated markdown sidecar next to the source transcript. |
| Eight standard LLM providers | OpenAI, Anthropic, Google, Azure OpenAI, Azure AI Inference, Ollama, LiteLLM, MLX-LM — via Vercel AI SDK. |
| Default provider | `azure-openai` when `--provider` / `COACH_PROVIDER` is unset (Project Memory Exception 003). |
| Conversation-window slicing | `--last <N>` / `--since <duration>` to bound the prompt; `--stream` for stdin streaming mode. |
| Auto-detect transcript | Picks the most-recent `*.transcript.jsonl` if no `--transcript` is given. |
| Configuration model | Standard four-tier resolution; no silent fallback for credentials. |
| Documentation | `docs/tools/convo-coach.md`. |

---

## 5. Architecture overview

### 5.1 Component map

```
recording-tool/
├── Sources/
│   ├── macrec/                  CLI executable (swift-argument-parser)
│   │   ├── Commands/            start / stop / list-devices / check-permissions / RootCommand
│   │   └── main.swift           ToolAgentsBootstrap → LoggerFactory → RootCommand
│   │
│   ├── macrec-ui/               Menu-bar app executable
│   │   ├── MacrecUIApp.swift    SwiftUI App shell (Settings { EmptyView() })
│   │   ├── PopoverController/   NSStatusItem + NSPopover orchestration
│   │   ├── Settings/            Per-provider settings sections
│   │   ├── Theme/               Appearance / Palette / SemanticColors
│   │   └── Views/               Header / Footer / Sections / Transcription
│   │
│   ├── MacrecCore/              Core library (engine — linked in-process by both executables)
│   │   ├── Bootstrap/           ToolAgentsBootstrap, EnvFileStore
│   │   ├── Capture/             SCKitSystemAudioSource, AVMicrophoneSource, SoftwareAECProcessor, FakeAudioSource
│   │   ├── Aligning/            HostClockAligner, SilenceBufferFactory, AlignedFrame
│   │   ├── Mixing/              BufferSummer (mixed / stereo-split / split)
│   │   ├── Encoding/            Recorder protocol + M4ARecorder / WAVRecorder / CAFRecorder
│   │   ├── Daemon/              Daemonizer, PidFile
│   │   ├── Permissions/         ScreenRecordingPermission, MicrophonePermission, SpeechPermission, PermissionGate
│   │   ├── Devices/             AudioDeviceEnumerator (CoreAudio HAL)
│   │   ├── Config/              ConfigResolver, DotEnvParser, RecordingOptions
│   │   ├── Errors/              MacrecError (typed, LocalizedError, +Dual)
│   │   ├── Logging/             LoggerFactory (swift-log)
│   │   ├── RecordingSession.swift   orchestrator state machine
│   │   ├── SessionState.swift       state stream
│   │   └── Transcription/       Manager + Providers + Persistence + Dual + Source-split
│   │
│   └── MacrecUIKit/             Shared UI-layer logic (importable by XCTest)
│       ├── FilenameGenerator, SegmentNamer, SessionCoordinator
│       ├── LevelMeterTap / LevelMeterPublisher / LevelSample
│       ├── RecordingController
│       └── Theme/AppearanceMode
│
├── tools/                       TypeScript companion CLIs
│   ├── dual-transcript-merger/
│   └── convo-coach/
│
├── Resources/                   Info.plist, MacrecUI-Info.plist
├── scripts/                     build-macrec-cli.sh, package-macrec-ui-app.sh
├── docs/                        design / reference / research / tools
└── Tests/                       MacrecCoreTests, MacrecUITests
```

### 5.2 Audio pipeline (CMSampleBuffer journey)

```
ScreenCaptureKit                 AVCaptureSession
(replayd XPC)                    (CoreAudio HAL → mic)
       │                                 │
       ▼                                 ▼
SCKitSystemAudioSource           AVMicrophoneSource
(.system tag)                    (.microphone tag)
       │                                 │
       ▼                                 ▼
AVAudioConverter (no-op)         AVAudioConverter (resample to 48k Float32 stereo)
       │                                 │
       │                                 ▼
       │                       [optional: SoftwareAECProcessor]
       │                                 │
       └─────────────┬───────────────────┘
                     ▼
              HostClockAligner   (queue: macrec.aligner)
                     │ AlignedFrame { system, microphone }
                     ▼
            ┌────────┼────────┐
       mixed│        │stereo- │split
            ▼        ▼split   ▼
       BufferSummer  pin L/R  passthrough×2
            │        │        │   │
            ▼        ▼        ▼   ▼
     M4A/WAV/CAFRecorder (per layout)
            │
            ▼
  output file(s) on disk
            │
     (parallel side-channel)
            ▼
     AudioDownsampler (16 kHz mono Float32)
            ▼
     SourceBuffer (per source) → flush every ~2.5 s
            ▼
     TranscriptionProvider (NoOp / Fake / Apple / AppleCloud / Gemini / Soniox / Azure(×2) / ElevenLabs / WhisperKit / Parakeet)
            ▼
     SegmentCoalescer → TranscriptEvent stream
            ▼
   JSONL / TXT / SRT / VTT sidecar writer    ⇄    live UI transcript panel
```

### 5.3 Threading model (highlights)

| Queue | Purpose |
|---|---|
| `macrec.capture.system` | SCStream audio buffers (`.userInteractive`) |
| `macrec.capture.mic` | `AVCaptureAudioDataOutput` delegate (`.userInteractive`) |
| `macrec.aligner` | Drains per-source ring buffers in lockstep |
| `macrec.recorder.{main,mic,system}` | Serial writer queues — only callers of `Recorder.append` |
| `macrec.session` | `RecordingSession` orchestrator; idempotent stop |
| `macrec.signals` | `DispatchSourceSignal` for SIGINT/SIGTERM |
| `macrec.watchdog.scstream` | Polls `lastBufferArrival` (FR-19) |
| `macrec.heartbeat` | Per-source RMS heartbeat every 10 s when `--log-level debug` |

Concurrency rules: capture delegates return in O(1) audio cost — they convert and enqueue, never call `Recorder.append` directly. `RecordingSession.stop()` is the only method invokable from any queue.

### 5.4 Configuration precedence

Resolved per key, lowest-to-highest priority (higher overrides lower):

1. Shell environment (`ProcessInfo.processInfo.environment`)
2. `~/.tool-agents/macrec/.env`
3. `./.env` in the current working directory
4. CLI flags

`~/.tool-agents/<tool>/` is created on every invocation with mode `0700`; its `.env` is seeded empty at mode `0600` if absent. Missing required values raise typed errors with documented exit codes — never silent fallback.

### 5.5 Permission model

| Permission | Required by | Behaviour |
|---|---|---|
| Screen Recording (TCC) | `SCStream` (system audio) | `.notDetermined` → trigger prompt + exit 75; `.denied` → exit 77 with deep link |
| Microphone (TCC) | `AVCaptureSession` | Same triage |
| Speech Recognition (TCC) | Apple on-device / Apple Cloud STT | Same triage; surfaced through `SpeechPermission` |

The CLI inherits grants from its parent terminal (Terminal.app, iTerm, etc.). The UI has its own bundle id (`com.local.macrec-ui`) and therefore its own independent grant set.

---

## 6. Output artifacts

A complete recording session produces a deterministic set of files under the chosen output directory:

```
recording-2026-05-12-094215.m4a                  # mixed layout (default)
recording-2026-05-12-094215.transcript.jsonl     # transcript sidecar (--transcribe non-none)
```

```
recording-2026-05-12-094215.mic.m4a              # split layout
recording-2026-05-12-094215.system.m4a
recording-2026-05-12-094215.mic.transcript.jsonl       # --transcribe-source both with split
recording-2026-05-12-094215.system.transcript.jsonl
```

```
recording-2026-05-12-094215.part01.m4a           # multi-segment (pause/resume or manual split)
recording-2026-05-12-094215.part02.m4a
recording-2026-05-12-094215.part01.transcript.jsonl
recording-2026-05-12-094215.part02.transcript.jsonl
```

```
recording-2026-05-12-094215.transcript.advice-20260512-095002.md   # convo-coach output
```

### 6.1 JSONL sidecar line shape (canonical)

```json
{
  "id": "seg-0007",
  "source": "mic",
  "language": "en-US",
  "startTime": 12.480,
  "endTime": 18.120,
  "lastUpdated": "2026-05-12T09:42:33.412Z",
  "text": "[S1] So the main concern is throughput, right?",
  "model": "soniox",
  "final": true,
  "channel": null,
  "metrics": { "rtt": 0.412 }
}
```

- `channel` is set in dual-mode sidecars (`"A"` / `"B"`); null otherwise.
- `[S1]` / `[S2]` speaker tokens appear when diarization is on (Soniox default; ElevenLabs opt-in).
- `final: false` segments are rewritten in place when the segment grows; `final: true` is the last write for the segment.

### 6.2 advice sidecar (`.advice-*.md`) line shape

Plain markdown stream, one timestamped block per LLM response. Generated by `convo-coach`; deterministic name pattern `<transcript-basename>.advice-YYYYMMDD-HHMMSS.md`.

---

## 7. Non-functional requirements (current bar)

| NFR | Requirement |
|---|---|
| Time-alignment | Mic ↔ system audio drift ≤ ±20 ms (NFR-4) |
| UI responsiveness | Every button click → visible state change within 100 ms (NFR-11) |
| Resident memory (UI idle) | < 80 MB (NFR-13) |
| Resident memory (UI + engine recording) | ≤ 250 MB; ≤ 25% of one core (NFR-5 / NFR-13) |
| Build constraint | `swift build` succeeds on Apple Command-Line Tools (no full Xcode) (NFR-14) |
| Architecture parity | Universal binary `arm64` + `x86_64` for both `macrec` and `macrec-ui` (NFR-15) |
| Crash isolation | A recoverable engine error MUST NOT bring the UI process down (NFR-12) |
| Privacy disclosure | First non-on-device transcription per launch surfaces a one-time disclosure (NFR-20) |
| Transcription failure is non-fatal | Recording always continues; audio file always finalizes (NFR-17, NFR-21) |
| Configuration validation | All values range-checked at parse time; out-of-range → exit 64 (FR-17) |
| Exit codes | Documented table (0/1/2/64/66/70/75/77/78); every error path returns one (FR-18) |

---

## 8. Constraints

### 8.1 Hard constraints

- **macOS 26+** deployment target (per Project Memory Exception 002). Older macOS cannot build or run `macrec`.
- **Swift / SwiftPM** for `macrec` and `macrec-ui` (per Project Memory Exception 001). Companion tools are TypeScript.
- **No virtual audio device** dependency, ever. System-audio capture must use `ScreenCaptureKit`.
- **Local-first**: no required server, no required cloud account. Cloud STT and cloud LLM are strictly opt-in and disclosed.
- **No silent fallback for configuration**: missing required value ⇒ typed error + documented exit code.

### 8.2 Soft constraints

- The third-party SwiftPM dependency surface is intentionally minimal: `swift-argument-parser` 1.5.x and `swift-log` 1.5.x are the only ones for the core; transcription providers add `WhisperKit` and `FluidAudio` (Parakeet) on the on-device path.
- TypeScript tools use the Vercel AI SDK for the LLM surface; no provider-specific SDKs are vendored.
- Apple Cloud Speech Recognition (`--transcribe apple-cloud` / `dual`) **only works from the bundled `macrec-ui.app`**, not from the raw CLI — a TCC + Apple Speech entitlement quirk documented in plan-010.

### 8.3 Known non-goals

- No multi-track timeline editor / DAW features.
- No mixing console, effects, or post-processing chain.
- No automatic phone-system / SIP integration.
- No multi-user / team workspace concept.
- No app-signed distribution channel yet (the user builds + drops the `.app` into `/Applications/` locally).
- No telemetry / analytics phone-home.

---

## 9. Extension points

Future contributions should land in one of these seams without bespoke surgery:

- **New STT provider** — add a `TranscriptionProvider` conformer under `Sources/MacrecCore/Transcription/Providers/`; register in `TranscriptionProviderFactory`; add provider id enum case; provide config keys via the four-tier chain; ship privacy-disclosure copy in `PrivacyDisclosureSheet`; document config in `configuration-guide.md`; surface in `TranscriptionPicker` (UI). The protocol is `Sendable` and supports both batch (`transcribe`) and streaming (`openStreamingSession`) modes.
- **New output format** — add a `Recorder` conformer under `Sources/MacrecCore/Encoding/`; register in the recorder-factory mapping; add to `--format` enum; validate via FR-17.
- **New CLI subcommand** — add an `AsyncParsableCommand` under `Sources/macrec/Commands/`; wire into `RootCommand`. The subcommand inherits `ConfigResolver` resolution and `MacrecError` typing.
- **New UI section** — add a SwiftUI view under `Sources/macrec-ui/Views/` (logical section under `Sections/` if it's a popover row). UI-only state lives in `UserDefaults` under `com.macrec.ui.*` keys (NOT the four-tier config chain).
- **New TypeScript companion tool** — scaffold via `/tool-conventions scaffold <name>` (NEVER by hand). The scaffolder creates `tools/<name>/`, `docs/tools/<name>.md`, and `~/.tool-agents/<name>/`, and wires the four-tier env-var resolution + the eight standard LLM providers if applicable.
- **New transcription sidecar format** — add a `TranscriptFormatWriter` conformer under `Sources/MacrecCore/Transcription/Persistence/`; register in the format-picker mapping; add to `--transcript-format` enum.
- **New AEC strategy** — `SoftwareAECProcessor` is the current implementation; the seam is between the capture sources and the aligner, so an alternative strategy can plug in without touching either side.

---

## 10. Current state of the implementation (as of 2026-05-12)

### 10.1 Plan history

| Plan | Subject | Status |
|---|---|---|
| plan-001 | Recording-tool MVP (capture + format + layout + lifecycle) | Implemented |
| plan-002 | Toolbar UI (`macrec-ui` v1.1) | Implemented |
| plan-003 | Live transcription (Gemini Live WebSocket — superseded) | Superseded by plan-004 |
| plan-004 | REST-batch transcription (Gemini `generateContent`) | Implemented |
| plan-005 | Apple Speech Streaming (`SpeechAnalyzer`, macOS 26) | Implemented; default `--transcribe` flipped to `apple` |
| plan-006 | Soniox streaming + WebSocket | Implemented; plan-009 fix applied |
| plan-007 | Additional STT engines (Azure OpenAI batch + realtime, ElevenLabs) | Implemented |
| plan-008 | UI redesign + Light/Dark/System theming | Implemented |
| plan-009 | Soniox aggregator protocol fix | Implemented |
| plan-010 | Dual transcription (Apple on-device + Apple Cloud) | Implemented |
| plan-011 | `convo-coach` TypeScript CLI | Implemented |
| plan-012 | STT enhancements: Parakeet provider, Soniox diarization default-on, true source-split | Implemented |
| plan-013 | Microphone AEC (original attempt — Apple voice-processing; failed) → custom NLMS adaptive filter | Implemented |
| plan-014 | AEC stability rewrite (v5); default flipped to off | Implemented |

### 10.2 Provider matrix coverage

| Provider | Batch | Streaming | On-device | Diarization | Multilingual |
|---|---|---|---|---|---|
| Apple SpeechAnalyzer | — | ✓ | ✓ | — | ✓ (dual-locale) |
| Apple Cloud | — | ✓ | — | — | ✓ |
| Gemini | ✓ | — | — | — | ✓ |
| Soniox | — | ✓ | — | ✓ (default-on) | ✓ |
| Azure OpenAI (batch) | ✓ | — | — | — | ✓ |
| Azure OpenAI (realtime) | — | ✓ | — | — | ✓ |
| ElevenLabs | ✓ | — | — | ✓ (opt-in) | ✓ |
| WhisperKit | ✓ | — | ✓ | — | ✓ |
| Parakeet | — | ✓ | ✓ | — | ✓ |

### 10.3 Active known limitations / pending items

(See `Issues - Pending Items.md` on `master` for the authoritative list; the entries below are the high-level ones a product session needs to know about.)

- Apple Cloud STT (`--transcribe apple-cloud` / `dual`) is only accessible from the bundled `macrec-ui.app`, not from the raw CLI (TCC + Speech Recognition entitlement is bundle-id-bound).
- No signed distribution channel yet — installation is "build locally and drop into `/Applications/`".
- No automated update path; the user manually re-runs `scripts/package-macrec-ui-app.sh` after pulling a new commit.
- AEC default is **off** since plan-014 — users must explicitly opt in per session.

---

## 11. Glossary

- **System audio** — anything currently playing through the Mac's audio output (Music, Spotify, browsers, video calls). Captured via `ScreenCaptureKit`.
- **Microphone audio** — the system's selected audio input device, captured via `AVCaptureSession`.
- **Sidecar** — a transcript file written next to the audio file using the same basename plus a mandatory `.transcript.` infix and a format-specific extension (`.jsonl`, `.txt`, `.srt`, `.vtt`).
- **Layout** — how the captured sources are arranged in the output file(s): `mixed` (sum into one stereo file), `split` (two files), `stereo-split` (one stereo file, one source per channel).
- **Mode** (transcription) — `single` (one provider drives one transcript) or `dual` (two providers run in parallel against the same audio, results merged with channel tags).
- **Source** (transcription) — `mic` / `system` / `mixed` / `both`. With `both` and split-layout, two parallel pipelines run, each producing its own sidecar.
- **Detach mode** — `macrec start --detach` daemonises the process via double-fork; a `stop` subcommand later terminates it via PID file + SIGTERM.
- **Stop-and-stitch** — pause semantics: pause finalizes the current segment file, resume opens a new `partNN` file. There is no in-place audio gap.
- **Diarization** — speaker labels (`[S1]`, `[S2]`, …) inserted into the transcript text. Soniox provides this by default; ElevenLabs as an opt-in.
- **TCC** — Apple's Transparency, Consent, and Control privacy framework. Governs Screen Recording, Microphone, Speech Recognition prompts.
- **Four-tier resolution chain** — the configuration precedence used by every tool in the project: shell env → `~/.tool-agents/<tool>/.env` → local `./.env` → CLI flags.

---

## Changelog

- **v1 (2026-05-12)** — Initial reverse-engineered baseline from the `master` implementation. Covers capture, output layouts, lifecycle, configuration, all transcription providers including dual-mode and source-split, microphone AEC, the `macrec-ui` surface, and the two TypeScript companions (`dual-transcript-merger`, `convo-coach`). Maps every capability statement to its FR family on `master` for traceability.
