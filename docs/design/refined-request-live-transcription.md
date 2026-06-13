# Refined Request: Live Transcription Side-Channel for `macrec` / `macrec-ui`

## Category
Development (feature addition spanning investigation, design, implementation, and testing across `MacrecCore`, the `macrec` CLI, and the `macrec-ui` menu-bar app).

## Objective
Add an opt-in, model-pluggable, **side-channel live transcription** capability to the recording tool. While a recording is in progress, the captured audio (in addition to being written to disk by the existing recorder) is streamed in parallel to a real-time, audio-in / text-out LLM service — the user's preferred provider being **Google Gemini Live (Gemini 2.5 / 3.x "Live" family)** — and the resulting partial and final transcripts are surfaced to the user in the menu-bar UI and persisted alongside the audio file. The user must be able to choose, from a UI control, **which transcription model to use, including a "None" option that disables transcription entirely**. Transcription must never degrade, block, drop samples from, or otherwise interfere with the primary recording pipeline.

## Scope

### In scope
- **Investigation phase** confirming feasibility of streaming `macrec`'s Float32/48 kHz/stereo internal PCM (or a downsampled mono variant) to **Gemini Live** and to at least one alternate provider, given:
  - Gemini Live's supported input audio formats (PCM 16 kHz mono is the documented input for the Gemini Live API as of 2026-Q2; verify in investigation deliverable),
  - the existing audio pipeline tap-points (post-`AVAudioConverter`, post-`HostClockAligner`, or post-`BufferSummer`),
  - WebSocket / gRPC streaming behaviour, partial vs. final transcript event shapes, max session duration, and reconnection semantics,
  - cost per minute and rate-limit ceilings.
- A new **provider-agnostic transcription subsystem** inside `MacrecCore` (new module / namespace `MacrecCore.Transcription`) consisting of:
  - A `TranscriptionProvider` Swift protocol abstracting any streaming audio→text service,
  - A first-party `GeminiLiveTranscriptionProvider` implementation,
  - A `NoOpTranscriptionProvider` (selected when the user picks "None"),
  - A non-blocking PCM tap that copies frames out of the live audio path into a bounded, lossy queue feeding the provider (drop-newest-when-full policy; never back-pressure capture),
  - A `TranscriptSink` that fans transcript events out to the UI and to disk-persistence.
- **CLI surface (`macrec`)**: new flags `--transcribe <provider>`, `--transcribe-source <system|mic|mixed|both>`, `--transcript-output <path>`, `--transcript-format <jsonl|txt|srt|vtt>`, env-var equivalents, and exit-code mappings for transcription-specific errors. Defaults to `none` (disabled), preserving current CLI behaviour exactly.
- **UI surface (`macrec-ui`)**: new "Live transcription" picker in the popover with at minimum the options `None` (default), `Gemini Live`, and any other providers that ship in v1. Plus the side controls necessary to expose source selection, an inline live-transcript panel, an "API key not configured" affordance, and a clear privacy disclosure.
- **Configuration surface**: API keys and transcription defaults resolved through the existing four-tier chain (shell env → `~/.tool-agents/macrec/.env` → `./.env` → CLI flags) for the CLI, and through the analogous `~/.tool-agents/macrec-ui/.env` chain for the UI.
- **Persistence**: Transcripts written to a sidecar file next to the audio recording, with a deterministic naming scheme that follows the segmentation rules of the recorder (single-segment, `.partNN`, and `--layout split` variants).
- **Documentation**: Updates to `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, `docs/design/configuration-guide.md`, `docs/design/project-design.md` (new section), `docs/design/project-functions.md` (new FRs and NFRs), and a new `plan-003-live-transcription.md` driving execution.
- **Tests**: Unit tests for the provider protocol, a **`FakeTranscriptionProvider`** for deterministic UI / pipeline tests, an integration test gated on the presence of a real `GEMINI_API_KEY`, and end-to-end shell scripts in `test_scripts/`.

### Out of scope
- **On-device / offline transcription** (e.g. Apple Speech, whisper.cpp, MLX-Whisper). The objective is explicit: "send the same voice stream to a fast LLM". On-device alternatives may be added in a v2 once the streaming abstraction is proven, but they must NOT block delivery of v1.
- **Speaker diarization beyond the trivial `system` vs. `mic` source label.** True speaker-ID (Speaker A / Speaker B inside the system audio submix) is out of scope for v1.
- **Translation** (audio-in / text-out in a *different* language). The provider returns whatever language the underlying model emits; the user does not pick a target language in v1.
- **Editing or post-processing transcripts** inside the UI (no in-app editor, no merge-with-audio re-export).
- **Re-transcribing an existing finished recording.** v1 is strictly real-time-during-recording. Offline transcription of a completed `.m4a` is a follow-up.
- **Detached / `--detach` mode transcription in v1.** The feasibility of streaming to a remote API while the recorder is a backgrounded daemon (no foreground process to display partial transcripts) is uncertain. v1 ships transcription only when the recorder runs in the foreground (CLI without `--detach`, or via `macrec-ui`). Detach-mode transcription is a flagged follow-up (see "Open Questions").
- **Cost-tracking / billing dashboards.** A simple per-recording byte/minute counter is in scope; a multi-recording aggregator UI is not.

## Requirements

### Functional Requirements (proposed FR-45 .. FR-58, to be confirmed at registration)

- **FR-45 — Provider abstraction.** `MacrecCore` must expose a `TranscriptionProvider` protocol that accepts a stream of PCM frames (with sample-rate, channel-count, and source-tag metadata) and emits a stream of `TranscriptEvent` values. Concrete providers in v1: `GeminiLiveTranscriptionProvider`, `NoOpTranscriptionProvider`. The protocol must be designed so an additional provider (OpenAI Realtime, Deepgram streaming, AssemblyAI streaming, etc.) can be added without touching call sites.
- **FR-46 — Non-blocking tap.** The live PCM tap that feeds the transcription provider must NOT block, slow, or starve the existing capture / aligner / recorder queues. Implemented via a bounded `AsyncStream<TranscriptionPCMChunk>` with `.bufferingNewest(N)` (drop-newest-when-full); dropped frames must be counted and surfaced as a metric. The recording on disk is unaffected by any transcription back-pressure or failure.
- **FR-47 — Source selection.** The user must be able to choose which audio source feeds transcription: `system` (system audio only), `mic` (microphone only), `mixed` (post-`BufferSummer` summed signal), or `both` (two parallel transcription streams labeled by source). Default: `mixed` (matches the user's stated framing of "the current conversation"). The selection is independent of the recording's `--layout`.
- **FR-48 — Provider selection (CLI).** `macrec start` must accept `--transcribe <none|gemini-live|...>`. Default `none`. Selecting any non-`none` value with no API key configured must fail fast with a clear `MacrecError.transcriptionApiKeyMissing` (proposed exit code `78` / `EX_CONFIG`).
- **FR-49 — Provider selection (UI).** The `macrec-ui` popover must include a **"Live transcription"** dropdown with `None` (default) and one entry per registered provider. When set to `None`, no transcription work happens. When set to a provider whose API key is missing from the resolved config chain, the dropdown must visually flag the missing-key state (red badge / tooltip) and the Start button must remain enabled — but starting will route to the same `transcriptionApiKeyMissing` error and the UI must surface it inline (without crashing the recording).
- **FR-50 — Transcript event model.** `TranscriptEvent` must distinguish at minimum:
  - `partial(text:source:startedAt:hostTime:)` — interim hypothesis, may be replaced.
  - `final(text:source:startedAt:endedAt:hostTime:)` — committed segment.
  - `error(reason:isFatal:)` — provider-side error; non-fatal events do not stop the recording.
  - `sessionEnded(reason:)` — provider closed the session (timeout, max duration, etc.).
- **FR-51 — Transcript persistence.** When transcription is enabled, a sidecar transcript file must be written alongside the audio file using the same basename and segmentation rules:
  - Single segment, `mixed`/`stereo-split`: `recording-….<format>` → `recording-….transcript.<ext>`.
  - Multi-segment (`partNN`): `recording-….part01.<format>` → `recording-….part01.transcript.<ext>`.
  - `--layout split`: `recording-….mic.<format>` + `recording-….system.<format>` → if the user's `--transcribe-source` is `both`, write `recording-….mic.transcript.<ext>` AND `recording-….system.transcript.<ext>`; if it's `mixed`/`system`/`mic`, write a single `recording-….transcript.<ext>` reflecting that one stream.
  - Sidecar formats supported in v1: `jsonl` (default — one JSON object per `TranscriptEvent`), `txt` (plain final-only text), `srt`, `vtt`.
- **FR-52 — Live transcript display in UI.** The popover must render a **live, scrollable transcript panel** below the level meters. Partial events appear in a muted style and are replaced in place; finals are committed in a normal style. The panel auto-scrolls to the bottom unless the user has scrolled away, in which case a "Jump to live" affordance appears. Closing the popover does not stop transcription, only its rendering; on reopen the most recent N finals are visible.
- **FR-53 — Privacy disclosure.** Selecting any non-`None` provider for the first time on a given launch must surface a one-time confirmation explaining that "the audio captured during this recording will be sent to a third-party API (`<provider name>`) for transcription". A "Don't show again" checkbox suppresses the dialog for subsequent launches; the disclosure remains discoverable in a tooltip on the picker.
- **FR-54 — Persisted UI defaults.** The selected provider, the source selection, and the sidecar format are persisted across launches in `UserDefaults` under (proposed) `com.macrec.ui.transcribeProvider`, `com.macrec.ui.transcribeSource`, `com.macrec.ui.transcriptFormat`. Default on first launch: `None`, `mixed`, `jsonl`.
- **FR-55 — API key configuration.** Provider API keys resolve through the same four-tier chain the CLI already uses. Canonical keys (using vendor-canonical names per CLAUDE.md) include at minimum:
  - `GOOGLE_API_KEY` — Gemini Live (vendor-canonical name).
  - `MACREC_TRANSCRIBE_PROVIDER` — default provider when neither CLI flag nor UI selection overrides.
  - `MACREC_TRANSCRIBE_SOURCE` — default source.
  - `MACREC_TRANSCRIPT_FORMAT` — default sidecar format.
  - `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` — optional ISO-8601 date for proactive expiration warning (per CLAUDE.md configuration-guide rule for expiring credentials).
  - Future providers add their own canonical key (e.g. `OPENAI_API_KEY`, `DEEPGRAM_API_KEY`, `ASSEMBLYAI_API_KEY`).
- **FR-56 — Watchdog / reconnect.** If the transcription provider connection drops mid-recording (network blip, provider 5xx, idle timeout), the subsystem must transparently reconnect at least once, log the gap, emit a `TranscriptEvent.error(isFatal:false)`, and continue. Repeated failures (configurable threshold, default 3 within 60 s) escalate to a non-fatal "transcription paused for this recording" state — the recording itself never stops.
- **FR-57 — Clean shutdown.** On Stop / SIGINT / SIGTERM, the transcription session must drain pending finals (bounded wait, default 5 s), close the provider connection, flush the sidecar file, and surface the final on-disk transcript path through the same post-stop disclosure panel that already lists the audio files.
- **FR-58 — Cost / volume metrics.** The subsystem must track and log (at `info` level on stop) the number of audio seconds streamed, the number of partial / final events received, the number of dropped tap frames, and the wall-clock duration. These metrics are written into the sidecar file's header (jsonl) and to the existing logger.

### Non-Functional Requirements (proposed NFR-17 .. NFR-21)

- **NFR-17 — Recording integrity isolation.** A failure or hang in the transcription path must NOT affect the on-disk recording. Verified by an integration test that injects a hanging fake provider and asserts that the audio file is byte-for-byte identical to a control recording without transcription enabled.
- **NFR-18 — Latency budget.** Median time from spoken word to corresponding *final* transcript event in the sidecar / UI must be under **2.5 s** under nominal network conditions (Wi-Fi, < 100 ms RTT to provider). Median time to *first partial* must be under **1.0 s**. These are observability targets, not hard SLOs — failures to meet them log a warning but never stop the recording.
- **NFR-19 — Memory ceiling.** The transcription tap's bounded queue must not exceed 8 MB of in-flight PCM at any time (≈ 21 s of mono Int16 16 kHz, or ≈ 5 s of stereo Float32 48 kHz), regardless of provider stall.
- **NFR-20 — Privacy posture.** Audio is transmitted to a third-party API, but no PII metadata (filename, mic device name, host name, user name) is transmitted. The only payload is raw PCM and the source label (`system` / `mic`).
- **NFR-21 — Provider extensibility.** Adding a new provider must require zero changes to `MacrecCore` orchestration code, only a new file conforming to `TranscriptionProvider` and a single registration line. Verified by code-review checklist.

### Investigation deliverables (gating Phase 0)

A short investigation report saved at `docs/research/live-transcription-feasibility.md` that confirms:

1. Gemini Live API audio input format (PCM linear16, sample rate, mono/stereo, chunk size) and the conversion needed from `macrec`'s internal Float32/48 kHz/stereo.
2. Gemini Live transport (WebSocket vs. gRPC), authentication, partial / final event distinction in the wire protocol, max session duration, and reconnection / resumption semantics.
3. At least one alternate provider candidate evaluated for the same dimensions (proposed: OpenAI Realtime API).
4. Approximate per-minute cost for both providers at 2026-Q2 pricing.
5. A go / no-go recommendation.

If investigation surfaces a blocker (e.g. Gemini Live unavailable in the user's region, or fundamentally incompatible with the platform), the plan must be revised before execution begins.

## Constraints

### Technical
- **Language: Swift.** Per the approved Exception 001 in `CLAUDE.md`, this project is Swift, not TypeScript. The transcription module ships as part of `MacrecCore` (SwiftPM library target).
- **macOS 14+.** Same minimum target as the rest of the project. No bumping required.
- **Networking.** Pure `URLSession` (WebSocket task) and / or `URLSession.bytes` for streaming. **No new SwiftPM dependencies** unless the chosen provider's reference SDK is unavoidable; if a Gemini Swift SDK is added, it goes through the same locked-stack approval review the original `swift-argument-parser` and `swift-log` got.
- **Concurrency.** Swift Concurrency (`AsyncStream`, `Task`, `actor`) for the new module. The provider implementation runs on a dedicated `Task` outside of the existing capture / aligner / recorder queues; it MUST NOT post work back onto `macrec.capture.system`, `macrec.capture.mic`, `macrec.aligner`, or any `macrec.recorder.*` queue.
- **No fallback configuration values** (CLAUDE.md). A missing API key when a non-`None` provider is selected must raise `MacrecError.transcriptionApiKeyMissing`, never default-to-disabled silently.
- **Audio format conversion.** The existing `AVAudioConverter` instances must NOT be reused for the transcription downsample. A new dedicated `AVAudioConverter` per transcription stream lives inside the transcription module; the existing recording converters stay untouched.

### Process
- Follows the same phased workflow used for `plan-001` and `plan-002`: investigation → refined-request (this document) → designer → planner → parallel coders → reviewer → dependency validator → test builders → integration verifier.
- Documentation of the new tool capability lives **inside the existing `docs/tools/macrec.md` and `docs/tools/macrec-ui.md`** — this is a feature of those tools, not a new tool. **Do NOT scaffold a new `~/.tool-agents/...` folder for transcription**; the configuration belongs in the existing `~/.tool-agents/macrec/.env` and `~/.tool-agents/macrec-ui/.env`.
- New API keys treated as **expiring credentials**: a `*_KEY_EXPIRES_AT` companion variable is offered per the configuration-guide convention.

### Resource
- **Third-party API cost.** Gemini Live and any alternate provider charge per minute / per token. Cost-tracking is a v1 feature (FR-58), not a v2 follow-up.
- **Network dependency.** v1 explicitly requires an internet connection while transcription is enabled. Offline / air-gapped use is supported only with the `None` provider.
- **macOS Network entitlement.** No new TCC permission is needed (network access does not gate on TCC), but if the binary is later sandboxed, a `com.apple.security.network.client` entitlement will be required.

## Acceptance Criteria

Each criterion below is testable or demonstrable. Phase 9 (Test Builders) and Phase 10 (Integration Verifier) own enforcement.

### Behavioural

- **AC-LT-1 — None is the default and is a true no-op.** With `--transcribe none` (or no flag) on the CLI, and with the UI dropdown set to `None`, no network connections are opened, no API keys are read, and no sidecar files are written. Asserted by `nettop`/`lsof` in an e2e script and by the absence of any `*.transcript.*` files in the output folder.
- **AC-LT-2 — Recording integrity unaffected by transcription presence.** A 60 s control recording (transcription off) and a 60 s test recording (transcription on, fake provider) over the same fixture audio produce **byte-identical** audio outputs. Verified by `shasum` comparison.
- **AC-LT-3 — Recording integrity unaffected by transcription failure.** Inject a `FakeTranscriptionProvider` that hangs after the first chunk; the recording still reaches its `--max-duration` and finalizes cleanly. The audio file is byte-identical to AC-LT-2's control. The exit code is `0`.
- **AC-LT-4 — Recording integrity unaffected by missing API key when later providers selected.** Selecting `Gemini Live` with no `GOOGLE_API_KEY` configured fails Start with `MacrecError.transcriptionApiKeyMissing` (exit 78) **before** any audio capture begins; no audio file is created.
- **AC-LT-5 — Sidecar naming follows segmentation.** A recording paused once produces `…part01.m4a` + `…part01.transcript.jsonl` and `…part02.m4a` + `…part02.transcript.jsonl`. Verified by directory listing in an e2e script.
- **AC-LT-6 — Sidecar formats are valid.** `jsonl` files parse line-by-line as JSON; `srt` / `vtt` files validate against their grammar; `txt` files contain only finalized text without timestamps.
- **AC-LT-7 — Live UI panel shows partials, then commits finals.** Demonstrated in the manual UI walkthrough script; partial events appear in muted style, are replaced in place, and a final commits the text.
- **AC-LT-8 — UI surfaces missing-key state.** With `Gemini Live` selected and no key configured, the UI dropdown displays a red "Key not configured" badge; clicking it opens an inline help popover that names the env var and the path to `~/.tool-agents/macrec-ui/.env`.
- **AC-LT-9 — Privacy disclosure shown on first opt-in.** First time a user picks a non-`None` provider on a fresh `~/Library/Preferences/com.local.macrec-ui.plist`, the disclosure dialog is presented.
- **AC-LT-10 — Reconnect on transient failure.** Inject a fake provider that disconnects after 5 s and accepts reconnection; transcription continues, the gap is logged, no fatal error is raised, the recording finishes cleanly.
- **AC-LT-11 — Bounded queue drops, never blocks.** Inject a fake provider that consumes 1 chunk every 10 s while audio arrives at 50 chunks/s. The drop counter increases monotonically, in-flight memory stays under NFR-19's 8 MB ceiling, and the recording's audio output remains byte-identical to AC-LT-2's control.
- **AC-LT-12 — Source selection routes correctly.** With `--transcribe-source mic`, the fake provider receives only mic frames (verified by tagged chunks); with `system`, only system frames; with `mixed`, post-summer frames; with `both`, two independent streams.
- **AC-LT-13 — Clean shutdown drains finals.** Pressing Stop while a partial is in flight produces a sidecar that ends with the corresponding final (or, after the 5 s drain timeout, with that partial promoted to a final-with-`{drained:true}` flag). The audio file finalizes within its existing budget.
- **AC-LT-14 — Cost metrics emitted.** The `info`-level log line at session end and the sidecar header both contain seconds-streamed, partial-count, final-count, dropped-frames-count.

### CLI surface

- **AC-LT-15 — `macrec start --help` lists all new flags** with default values matching this spec.
- **AC-LT-16 — `--transcribe none` is the default** and produces zero behavioural change vs. the current build (regression-asserted by re-running every existing AC-1..AC-20 e2e script unchanged).
- **AC-LT-17 — Invalid provider name fails with `EX_USAGE` (exit 64)** and a remediation hint listing the registered providers.

### UI surface

- **AC-LT-18 — Live transcription picker present in popover** with at minimum `None`, `Gemini Live`, and any other v1 providers, persisted across launches.
- **AC-LT-19 — Picker disabled while recording.** Once Start is pressed, the dropdown is read-only until Stop returns to `idle`. Same lock posture as Format / Layout / Mic pickers.
- **AC-LT-20 — Transcript panel survives Pause/Resume across segments.** A pause finalizes one sidecar, opens the next; the in-popover panel shows a horizontal-rule separator with the new `partNN` label.

### Documentation & registration

- **AC-LT-21 — `docs/tools/macrec.md` updated** with the new flags, env vars, sidecar naming table, and a worked example.
- **AC-LT-22 — `docs/tools/macrec-ui.md` updated** with the new picker, the privacy disclosure, the missing-key affordance, the live transcript panel.
- **AC-LT-23 — `docs/design/configuration-guide.md` updated** with each new env var (purpose, allowed values, default, recommended storage tier, how to obtain the key, expiration handling).
- **AC-LT-24 — `docs/design/project-functions.md` updated** with FR-45..FR-58 and NFR-17..NFR-21 (or the renumbered range chosen at registration time).
- **AC-LT-25 — `Issues - Pending Items.md` updated** with any residual risks (e.g. Gemini Live regional availability, detach-mode follow-up, on-device-transcription v2).

## Assumptions

The following were inferred from project context or standard practice and were NOT explicitly confirmed by the user. They should be challenged before implementation begins.

- **A-LT-1 — Default source is `mixed`.** The user wrote "the current conversation", which most naturally maps to the post-`BufferSummer` mixed signal (both speakers in one stream). If the user intended speaker-labeled `both`, this should be revisited.
  *Basis*: Phrasing "the current conversation" + UX simplicity (one transcript pane vs. two).
- **A-LT-2 — Default sidecar format is `jsonl`.** Richest information density, machine-parseable, supports partial / final / timing / source-tag without losing data. `srt` / `vtt` / `txt` are also offered.
  *Basis*: Project convention is to favour structured logs (swift-log JSON encoder pattern); jsonl is the closest analog for transcript events.
- **A-LT-3 — v1 ships with two providers maximum** (`None` + `Gemini Live`), with the protocol designed to accept more later. Adding OpenAI Realtime / Deepgram / AssemblyAI is in scope of the protocol design but not necessarily of the v1 implementation.
  *Basis*: The user named only Gemini explicitly. Shipping more providers expands the testing surface.
- **A-LT-4 — Detach mode (`--detach`) is excluded from v1 transcription.** A daemonised recorder has no UI to render partials; sidecar-only transcription in detach mode is feasible but adds risk. Deferred to a flagged follow-up.
  *Basis*: Project's own detach mode is a recent addition (FR-25..FR-29); layering live transcription on top of it in the same release multiplies risk.
- **A-LT-5 — Gemini Live is the *Live* (streaming, audio-in / text-or-audio-out) variant of Google's Gemini API.** The user wrote "Gemini 3.1 Live"; the closest published product as of 2026-Q2 is the Gemini Live API (Gemini 2.5/2.6 Live and the 3.x family are emerging). The investigation deliverable confirms the exact model id at refinement time.
  *Basis*: The user explicitly framed it as "fast LLM" + "live transcription"; Gemini Live is the only Google product fitting both.
- **A-LT-6 — Sample-rate conversion to 16 kHz mono Int16 happens at the tap, not earlier.** The recording pipeline keeps its Float32/48 kHz/stereo internal format; only the side-channel downsamples.
  *Basis*: NFR-17 (recording integrity isolation) requires the recording path to be untouched.
- **A-LT-7 — Per-recording opt-in via UI dropdown is the primary control;** there is no separate "default on / default off" application-wide preference beyond what the persisted dropdown remembers.
  *Basis*: The user wrote the option lives in the UI, with `None` meaning off. The persisted dropdown value is the de-facto default.
- **A-LT-8 — Transcripts are persisted by default whenever transcription is enabled.** No separate "transcribe but don't save" toggle in v1.
  *Basis*: Sidecar persistence is cheap, the user did not request a save-suppression switch, and recovery after a crash benefits from on-disk transcripts.
- **A-LT-9 — Cost / privacy disclosure is a one-time-per-bundle dialog, not a per-recording prompt.** A per-recording prompt would degrade UX for power users; a once-per-install disclosure with a discoverable tooltip is the standard macOS pattern.
  *Basis*: Standard macOS UX (Dictation, Siri, etc.).
- **A-LT-10 — `MacrecError.transcriptionApiKeyMissing` exit code is `78` (`EX_CONFIG`)**, matching the existing `missingRequiredConfig` mapping. New error cases for transcription-fatal (`transcriptionProviderUnavailable`, `transcriptionSessionMaxDurationExceeded`) map to existing buckets where the semantics fit; only genuinely new categories get new codes.
  *Basis*: §9.5 of `project-design.md` already locks the exit-code structure.

## Open Questions

These could not be confidently resolved from project context. Downstream work should address them, ideally during the investigation phase.

- **OQ-LT-1 — Exact Gemini model id ("Gemini 3.1 Live").** The user named "Gemini 3.1 Live"; verify against Google's published model catalog at investigation time and pick the closest available live-streaming variant. Document the resolved id in the investigation deliverable and pin it in `RecordingOptions`.
- **OQ-LT-2 — Source default: `mixed` vs. `both`?** A-LT-1 picks `mixed`. If the user prefers speaker-labeled output (`both` → two transcripts, one per source), this changes the default UI option and the default sidecar layout under `--layout split`. Worth a single confirming question before Phase D coding begins.
- **OQ-LT-3 — Should the live transcript panel be in the popover or in a separate window?** The popover is cramped; a long-running meeting could produce a transcript that exceeds reasonable popover height. Options: (a) inline, scrolling, fixed-max-height (this spec's default); (b) a separate `NSWindow` opened on demand from the popover; (c) tail-only (last 3 lines) inline + "Open transcript window" button. Phase E (Designer) should pick one.
- **OQ-LT-4 — Streaming transport: WebSocket vs. gRPC for Gemini Live.** Decided in the investigation deliverable; preference for `URLSessionWebSocketTask` to avoid adding a gRPC SwiftPM dep.
- **OQ-LT-5 — Detach-mode transcription scope.** Excluded from v1 by A-LT-4. Confirm the user accepts that, or upgrade to in-scope (which would require a foreground-helper or a sidecar-only output mode).
- **OQ-LT-6 — Maximum session length.** Gemini Live (and similar APIs) typically cap a single streaming session at 10–30 minutes. The reconnection logic in FR-56 handles this transparently — but a recording longer than the cap will have a brief gap at every rotation. Acceptable for v1?
- **OQ-LT-7 — Should the existing `--max-duration` propagate to the transcription session as a hard ceiling?** Default assumption: yes, transcription stops when the recording stops, but transcription cannot extend the recording.

## Original Request

```
Can you investigate if we could allow the user to enable, while recording, sending the same voice stream to a fast LLM trying to get back the transcription of the current conversation?

My preference for this task is the use of Gemini 3.1 Live model.

If it is feasible, it must be an option on the user interface where the user will decide which model he will use to transcribe the conversation.

If he chooses None, that means that the conversation will not be transcribed.
```
