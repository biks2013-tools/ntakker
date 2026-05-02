# Refined Request: `convo-coach` — LLM-Powered Conversational Coaching CLI

## Category
Development (TypeScript CLI tool, project-internal, installable on `PATH`)

---

## Goal

Deliver a new TypeScript CLI tool named **`convo-coach`** that reads a transcript produced by `macrec` (single-channel or dual-channel) and asks a configurable LLM provider for in-the-moment conversational guidance — phrased as: _"advise me on what I could ask, suggest, request, or answer right now."_ The advice is streamed token-by-token to `stdout` and is **always** also persisted to a markdown sidecar file next to the source transcript. The tool plugs into the project's existing four-tier configuration chain, supports the full standard set of LLM providers, follows the project's no-fallback configuration rule, and is installable as a direct command via `npm link` (same pattern as `dual-transcript-merger`).

---

## Scope

### In scope
1. A new TypeScript package under `tools/convo-coach/` with `package.json`, `tsconfig.json`, `src/`, `dist/`, `test/`, and a CLI entry point shebanged at `dist/cli.js`.
2. Reading transcripts from three input modes: explicit `--transcript <path>`, piped `stdin`, or auto-detection of the most recent `macrec` sidecar in the macrec recordings folder.
3. Parsing both single-channel macrec sidecars and dual-channel sidecars (Channel A = Apple on-device, Channel B = Apple Cloud) — using the schema documented in `docs/tools/macrec.md` (§"Sidecar conventions") and `docs/tools/dual-transcript-merger.md`.
4. Conversation-window slicing by `--last <duration>` and/or `--since <timestamp>`.
5. LLM provider abstraction supporting all eight standard providers mandated by `~/.claude/agents/tool-doc-config-architect.md`.
6. Token-by-token streaming to `stdout` AND simultaneous persistence to `<transcript-basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source transcript.
7. Configuration via the project's four-tier chain (shell env → `~/.tool-agents/convo-coach/.env` → local `./.env` → CLI flags) using vendor-canonical env-var names.
8. Strict no-fallback enforcement: missing required configuration raises an explicit error and exits non-zero.
9. Tool documentation scaffolded by `/tool-conventions scaffold convo-coach` (NOT hand-rolled), and a concise reference entry added to the project's `CLAUDE.md` "Tools" section pointing at `docs/tools/convo-coach.md`.
10. Unit tests, an integration smoke test against a recorded sidecar fixture, and any defects/pending items captured in `Issues - Pending Items.md`.

### Out of scope
- Any changes to `macrec` itself (capture, transcription, sidecar formats).
- Modifications to `dual-transcript-merger` (the merger remains the canonical pre-processor; `convo-coach` consumes raw macrec sidecars or merger output, not via merger invocation).
- A daemon / long-running watcher mode beyond what is implied by stdin streaming (no inotify, no WebSocket server, no GUI).
- Rewriting or wrapping `macrec-ui` to embed coaching inside the menu-bar app.
- Multi-turn dialogue with memory between invocations (each invocation is a single LLM request).
- Caching, prompt-template management, or fine-tuning workflows.
- Real-time audio capture or transcription (the tool consumes existing transcripts only).

---

## Functional Requirements

### FR-CC-1 — Project location & language
- Implementation language: **TypeScript** (strict). The Swift exception (CLAUDE.md, Exception 001) is scoped exclusively to `macrec`; `convo-coach` MUST be TypeScript.
- Source tree: `tools/convo-coach/` with the same structural conventions as `tools/dual-transcript-merger/` (ESM, Node ≥20, `bin` mapping, `prepare`/`postbuild` scripts that emit and chmod `dist/cli.js`).
- Package name in `package.json`: `convo-coach`. Binary name on `PATH`: `convo-coach`.

### FR-CC-2 — Installation
- Must be installable via `cd tools/convo-coach && npm install && npm link`, after which `convo-coach --help` works from any directory.
- The `prepare` script must run `tsc` and `chmod +x dist/cli.js` so the binary is executable immediately after `npm install`.

### FR-CC-3 — Transcript input modes (precedence: highest first)
1. **Stdin**: if `process.stdin.isTTY === false` (i.e. piped/redirected), read from stdin regardless of other flags.
2. **Explicit**: `--transcript <path>` — reads the given file.
3. **Auto-detect**: if neither stdin nor `--transcript` is provided, locate the most recent macrec sidecar in macrec's recordings folder and use it.
   - The recordings folder is discovered by reading macrec's configuration chain in this order (lowest → highest): shell env `MACREC_RECORDINGS_DIR` → `~/.tool-agents/macrec/.env` (key `MACREC_RECORDINGS_DIR`) → local `./.env` (same key).
   - If no recordings directory is configured anywhere, the tool MUST raise a clear `MissingMacrecRecordingsDirError` with exit code 78 (`EX_CONFIG`) and print a remediation hint that suggests passing `--transcript` explicitly or setting `MACREC_RECORDINGS_DIR`.
   - "Most recent" = newest `*.transcript.jsonl`, `*.transcript.txt`, `*.transcript.srt`, or `*.transcript.vtt` file in the recordings folder by `mtime`. If multiple sidecar segments exist for the same recording (e.g. `…part01.transcript.jsonl`, `…part02.transcript.jsonl`), pick the newest single file (NOT a concatenation).
4. If both `--transcript` and stdin are supplied, stdin wins and a `warning` log line is emitted to `stderr` noting the override.

### FR-CC-4 — Sidecar format support
The tool MUST correctly parse:
- **Single-channel JSONL** as documented in `docs/tools/macrec.md` (one `TranscriptSegment` JSON object per line).
- **Dual-channel JSONL** with the optional `channel` field (`"A"` for `apple` / on-device, `"B"` for `apple-cloud`), per `docs/tools/macrec.md` §DT-7 and `docs/tools/dual-transcript-merger.md`.
- **Plain text TXT** sidecars (timestamped lines `[HH:MM:SS.mmm] text` or dual-tagged `[HH:MM:SS.mmm] [LANG] text`).
- **SRT** and **VTT** as a best-effort: parse cue text with timestamps; channel/voice tags (`EN: …`, `<v EN>…</v>`) are preserved as channel labels.

Lines/cues that fail to parse MUST be skipped with a single `warning` log line summarising the count (not one warning per line).

### FR-CC-5 — Conversation-window filtering
- `--last <duration>` accepts compound durations: `30s`, `5m`, `1h`, `1h30m`, `90s`. Parser MUST reject malformed values with a clear error (exit 64, `EX_USAGE`).
- `--since <timestamp>` accepts:
  - Wall-clock `HH:MM:SS` or `HH:MM:SS.mmm` (interpreted in the local timezone of the host).
  - ISO-8601 (`2026-05-02T14:32:10Z`, `2026-05-02T14:32:10+02:00`).
  - Relative-from-recording-start `+MM:SS` or `+HH:MM:SS` (the `+` prefix is mandatory for this form to disambiguate from wall-clock).
- When both flags are provided, the **later** of the two boundaries is used (i.e. the more restrictive window).
- When neither is provided, the entire transcript is used.
- "Now" for `--last` semantics:
  - For finite files (a closed `.jsonl` / `.txt` / `.srt` / `.vtt` on disk) — "now" = the timestamp of the last segment in the file.
  - For stdin streams — "now" = wall-clock time of the trigger that initiates the LLM request (see FR-CC-6).

### FR-CC-6 — Stdin streaming semantics
When stdin is piped (e.g. `tail -f sidecar.jsonl | convo-coach`):
- The tool reads stdin line-by-line and accumulates segments into an in-memory ring buffer that respects the active `--last` / `--since` window.
- An LLM request is triggered on user-initiated events. Recommended (default) behaviour: **pressing Enter on the controlling TTY** dispatches a request using the current window. This MUST work even though stdin is piped — the controlling TTY (`/dev/tty`) is opened directly for keystroke detection.
- If `/dev/tty` is unavailable (e.g. fully non-interactive pipeline), the tool falls back to **debounced auto-trigger** controlled by `--debounce <duration>` (default: `15s` of stdin silence triggers a request). When `/dev/tty` is unavailable AND `--debounce 0` is specified, only EOF triggers a single final request.
- Each triggered request produces ONE sidecar `.advice-<YYYYMMDD-HHMMSS>.md` file (multiple requests in one session produce multiple sidecars with distinct timestamps).

### FR-CC-7 — LLM providers
Support the **eight standard providers** mandated by `tool-doc-config-architect`:
1. **Direct OpenAI** — `OPENAI_API_KEY`, optional `OPENAI_BASE_URL`, `OPENAI_ORG_ID`.
2. **Direct Anthropic** — `ANTHROPIC_API_KEY`, optional `ANTHROPIC_BASE_URL`.
3. **Google Gemini** — `GOOGLE_API_KEY` (accept `GEMINI_API_KEY` as alias).
4. **Azure OpenAI** — `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`, optional `AZURE_OPENAI_API_VERSION`.
5. **Azure AI Inference (Foundry, including Azure-hosted Anthropic)** — `AZURE_AI_INFERENCE_KEY`, `AZURE_AI_INFERENCE_ENDPOINT`.
6. **Ollama** (local) — `OLLAMA_HOST`.
7. **LiteLLM proxy** — `LITELLM_PROXY_URL`, `LITELLM_MASTER_KEY`.
8. **MLX-LM** (local) — reuses `OPENAI_BASE_URL` (no dedicated env convention; documented in the tool's `.env` template).

> **Provider count clarification** — the request brief mentions "7 or 8". The authoritative `tool-doc-config-architect` spec lists **eight** (the eighth being MLX-LM, which reuses `OPENAI_BASE_URL`). The implementation MUST wire all eight; MLX support is satisfied by allowing OpenAI-compatible base-URL override.

The tool MUST NOT introduce additional provider-specific transcription APIs (Soniox, ElevenLabs, etc.) — those vendors do not expose general chat/completion endpoints suitable for coaching, and the brief's caveat _"plus the project's existing transcription providers where they offer chat/completion APIs"_ resolves to **none** beyond the eight standard ones once filtered for chat-capable APIs.

### FR-CC-8 — Provider/model selection
- `--provider <name>` — one of `openai | anthropic | gemini | azure-openai | azure-ai-inference | ollama | litellm | mlx`. Resolved through the four-tier chain via env var `CONVO_COACH_PROVIDER`.
- `--model <id>` — provider-specific model id. Resolved via env var `CONVO_COACH_MODEL`.
- Default model per provider when `--model` is omitted (documented in `docs/tools/convo-coach.md`):
  - openai → `gpt-4o-mini`
  - anthropic → `claude-haiku-4-5`
  - gemini → `gemini-2.5-flash`
  - azure-openai → uses the deployment name from `AZURE_OPENAI_DEPLOYMENT` (no model override unless `--model` is passed)
  - azure-ai-inference → `claude-haiku-4-5` (verifiable model id on Azure Foundry; documented as overridable)
  - ollama → `llama3.1:8b`
  - litellm → no default; `--model` (or `CONVO_COACH_MODEL`) is REQUIRED → raises if missing
  - mlx → no default; `--model` REQUIRED → raises if missing
- CLI flags ALWAYS beat env vars on the same key (per the project's four-tier chain).

### FR-CC-9 — Configuration resolution chain
Identical to `macrec` and `dual-transcript-merger`, lowest → highest priority:
1. Shell `process.env`
2. `~/.tool-agents/convo-coach/.env` (folder mode `0700`, file mode `0600`)
3. Local `./.env` in the current working directory
4. CLI flags

The tool MUST create `~/.tool-agents/convo-coach/` with mode `0700` on first invocation if absent. The tool MUST NOT write to that folder beyond creating the directory and (if not present) seeding an empty `.env` skeleton with mode `0600`. **Do not hand-roll either of these — the `/tool-conventions scaffold convo-coach` slash command is responsible for the initial `.env` template.**

### FR-CC-10 — No-fallback rule
- Missing required config (provider key, endpoint, deployment, model when required, recordings dir for auto-detect) MUST raise a typed error and exit with the appropriate code. Errors MUST identify the missing variable name AND the four-tier locations the resolver inspected.
- The tool MUST NOT substitute placeholder values, dummy keys, or "best-effort guesses".
- Default model per provider (FR-CC-8) is NOT a fallback — it is a documented, hard-coded provider default explicitly stated in the user-facing docs. Defaults are forbidden ONLY for credentials, endpoints, and the recordings directory.

### FR-CC-11 — Output behaviour
- Streaming: tokens (or smallest streamable unit the provider exposes) are flushed to `stdout` as they arrive. Output MUST NOT be line-buffered; use `process.stdout.write` directly.
- Sidecar: simultaneously, every emitted token is appended to `<transcript-basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source transcript.
  - `<transcript-basename>` = the source transcript path with the extension and (if present) the `.transcript` infix stripped. E.g. `~/recordings/talk.transcript.jsonl` → basename `~/recordings/talk` → sidecar `~/recordings/talk.advice-20260502-141503.md`.
  - When stdin is the input, `<transcript-basename>` defaults to `./convo-coach-stdin` in the current working directory; `--advice-out <dir>` overrides the directory and `--advice-basename <name>` overrides the basename stem.
  - Timestamp is local time, `YYYYMMDD-HHMMSS`.
  - Sidecar format is markdown with a YAML front-matter header containing: provider, model, transcript source path, window (`--last` / `--since` resolved values), token count (filled at end), elapsed seconds, and approximate cost if the provider exposes usage metrics.
  - The sidecar is created at request start (with the front-matter and a placeholder body) and finalised on stream-end. If the LLM request fails mid-stream, the sidecar is preserved with a `# ERROR` footer noting the failure cause (exit code is still non-zero).

### FR-CC-12 — Prompt construction
- A built-in default system prompt frames the LLM as a "real-time conversational coach" and instructs it to suggest 3–5 concrete things the user could ask, suggest, request, or answer next, given the recent conversation. Exact prompt text is finalised during design phase (see Open Decisions §OD-1).
- The user message contains the windowed transcript, formatted as `[HH:MM:SS.mmm] [<channel-or-source>] text` per segment so the model sees timing and speaker/channel context.
- Channel labels in dual-channel transcripts are mapped to human-readable speaker hints in the prompt: `A` → `Speaker-A (on-device, primary)`, `B` → `Speaker-B (cloud)`. The mapping is documented in the sidecar front matter as `channelLabels`.
- `--system-prompt <path>` MAY be supported as a v1 feature (see Open Decisions §OD-6); recommendation is YES, accepting a path to a markdown/text file whose contents replace the built-in system prompt verbatim.
- `--language <bcp-47>` (optional) hints the model to respond in the requested language; default is to mirror the dominant language of the transcript window (model decides).

### FR-CC-13 — Token-budget handling
When the constructed prompt would exceed the model's context window:
- Default behaviour: **truncate from the start** of the window (oldest segments dropped first), preserving the most recent N segments that fit. The number of dropped segments is logged at `info` and recorded in the sidecar front-matter as `droppedSegments: <count>`.
- `--on-overflow <strategy>` flag with allowed values `truncate-start | truncate-end | error` (default `truncate-start`).
- Per-model context-window sizes are stored in a small static lookup table inside the tool (`src/providers/model-context-windows.ts`); unknown models fall back to a conservative 8 192-token assumption with a `warning` log line. (This is NOT a configuration fallback — it is a model metadata default and is therefore allowed.)

### FR-CC-14 — Logging & exit codes
- Log levels: `quiet | info | debug` via `--log-level` (env `CONVO_COACH_LOG_LEVEL`). Logs go to `stderr`; only the streamed advice and the final summary line go to `stdout`.
- Exit codes (aligned with `macrec`'s convention):
  - `0` — success (full advice streamed and sidecar finalised).
  - `1` — generic / unexpected failure.
  - `64` (`EX_USAGE`) — invalid CLI argument or malformed `--last`/`--since`.
  - `66` (`EX_NOINPUT`) — transcript file not found, not readable, or unparseable.
  - `70` (`EX_SOFTWARE`) — provider request failure (5xx, network drop, malformed response).
  - `78` (`EX_CONFIG`) — missing required config (API key, endpoint, deployment, recordings dir, etc.).

### FR-CC-15 — CLAUDE.md "Tools" section entry
After the tool is built and `docs/tools/convo-coach.md` is in place (scaffolded by `/tool-conventions scaffold convo-coach`), the project `CLAUDE.md` MUST get a concise entry of this form (final wording produced by the scaffold subagent):

```
### convo-coach

LLM-powered conversational coach: reads a macrec transcript (single- or dual-channel), slices a recent window with `--last` / `--since`, asks any of the eight standard LLM providers for in-the-moment advice on what to ask / suggest / answer next, and streams the response token-by-token to stdout while persisting it to a `.advice-<timestamp>.md` sidecar next to the source transcript.

Documentation: [docs/tools/convo-coach.md](docs/tools/convo-coach.md)
```

---

## Non-Functional Requirements

- **NFR-CC-1 — Streaming latency**: time from CLI start to first stdout token MUST NOT exceed 3 seconds wall-clock under normal network conditions, dominated by the provider's TTFT (no artificial buffering on the client side).
- **NFR-CC-2 — Memory footprint**: tool MUST NOT load full transcript into memory if only a window is needed; for large JSONL files (>100 MB) a streaming line-reader is required and the windowing pass MUST be O(N) in segments without holding all parsed segments at once.
- **NFR-CC-3 — Determinism of sidecar naming**: two invocations within the same second on the same transcript MUST NOT collide. If a collision is detected (sidecar exists), append `-<n>` (e.g. `…-141503-2.md`).
- **NFR-CC-4 — Cross-platform behaviour**: tool MUST run on macOS (primary) and Linux (best-effort, used by CI). Windows is out of scope.
- **NFR-CC-5 — Provider isolation**: each provider implementation lives in its own module under `src/providers/`. Adding a 9th provider in the future MUST require zero changes to the CLI layer.
- **NFR-CC-6 — Secret hygiene**: API keys MUST NEVER be logged at any log level. Sidecar front-matter MUST NEVER include the API key. The `--help` text and any error message that mentions a missing key MUST refer to it by env-var name only.
- **NFR-CC-7 — Test coverage**: ≥80% line coverage on `src/` excluding the provider HTTP shims (which are exercised by integration tests, not unit tests).
- **NFR-CC-8 — Reproducible builds**: `npm install` followed by `npm run build` from a clean tree MUST produce a working binary on Node ≥20 without warnings or peer-dependency complaints.

---

## Acceptance Criteria

Each criterion MUST have a clear pass/fail outcome demonstrable by an integration test or a manual procedure.

| ID | Criterion | Verification |
|----|-----------|--------------|
| AC-CC-1 | `convo-coach --help` works after `cd tools/convo-coach && npm install && npm link`. | Manual: run the three commands; `which convo-coach` resolves; `--help` prints non-empty usage to stdout; exit 0. |
| AC-CC-2 | With a valid provider configured (e.g. `OPENAI_API_KEY` exported and `--provider openai`), running `convo-coach --transcript <path>` streams advice to stdout and writes `<basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source file. | Integration test using a fixture transcript and a mocked OpenAI streaming endpoint. |
| AC-CC-3 | All eight standard providers are wired and selectable via `--provider`. Attempting an unknown provider exits 64 with a clear error. | Unit tests for the provider-factory; smoke test invoking each provider with mocked HTTP. |
| AC-CC-4 | Missing required config (e.g. `--provider openai` with no `OPENAI_API_KEY` anywhere in the four-tier chain) exits 78 with an error message naming the missing env-var AND listing the four resolution tiers inspected. No sidecar file is written. | Integration test with cleared env; assert exit code, stderr substring, and absence of sidecar file. |
| AC-CC-5 | `--provider` and `--model` CLI flags override values present in `~/.tool-agents/convo-coach/.env` and `./.env`. | Unit test on the resolver; integration test asserting the chosen provider name appears in sidecar front-matter. |
| AC-CC-6 | `--last 5m` and `--since 14:32:10` slice the transcript correctly; combined → later boundary; absent → full transcript. | Unit tests on the windowing function with a synthetic 1-hour transcript fixture. |
| AC-CC-7 | Auto-detect locates the most recent `*.transcript.*` sidecar in the directory specified by `MACREC_RECORDINGS_DIR` (resolved via macrec's chain) when no `--transcript` and no piped stdin. | Integration test creating two sidecars with distinct mtimes; assert the newer one is chosen. |
| AC-CC-8 | Piped stdin is consumed instead of auto-detect / `--transcript` when `process.stdin.isTTY === false`. | Integration test piping a fixture file to stdin and asserting the same advice content as supplying it via `--transcript`. |
| AC-CC-9 | Dual-channel JSONL parses correctly: per-segment `channel: "A" \| "B"` and `language` fields are preserved and rendered as `Speaker-A (on-device, primary)` / `Speaker-B (cloud)` in the prompt sent to the LLM. | Unit test on the prompt-builder + integration test with a captured dual-channel sidecar fixture. |
| AC-CC-10 | `docs/tools/convo-coach.md` exists, follows the `<convoCoach>` XML structure mandated by `tool-doc-config-architect`, AND a concise entry has been added to project `CLAUDE.md` "Tools" section pointing at that file. The doc was created by `/tool-conventions scaffold convo-coach` (NOT hand-rolled). | Manual review + `/tool-conventions audit convo-coach` returns `status: completed` with no critical findings. |
| AC-CC-11 | `~/.tool-agents/convo-coach/` exists at mode `0700` after first invocation; `~/.tool-agents/convo-coach/.env` exists at mode `0600` with all eight standard provider env-var groups as commented placeholders. | `stat` check during integration test. |
| AC-CC-12 | The four-tier resolution order is shell env (lowest) → user `.env` → local `.env` → CLI flag (highest). | Resolver unit tests covering each pairwise override. |
| AC-CC-13 | When the transcript window exceeds the model's context window, the default `truncate-start` strategy drops oldest segments and records `droppedSegments: <n>` in the sidecar front-matter; `--on-overflow error` exits 64 instead. | Unit test on the budget calculator with a synthetic oversize transcript. |
| AC-CC-14 | Stdin streaming mode triggers an LLM request on Enter (or after `--debounce` silence when `/dev/tty` is unavailable); each trigger produces a separate timestamped sidecar. | Integration test driving stdin with a synthetic stream. |
| AC-CC-15 | Streamed tokens reach `stdout` AND are appended to the sidecar in lock-step (no buffering divergence > 1 second). | Integration test reading sidecar concurrently and diffing against captured stdout. |
| AC-CC-16 | API keys are never logged at any log level (including `debug`) and never appear in the sidecar front matter. | Unit test scanning captured stderr and sidecar contents for known fixture key substrings. |

---

## Open Decisions (Recommendations Provided — Do Not Re-Ask the User)

The following items were intentionally left to the implementer per the brief. Recommendations below SHOULD be adopted unless a downstream design step surfaces a strong reason otherwise.

### OD-1 — Default system prompt template
**Recommendation**: ship a built-in default approximately of the form:

> _You are a real-time conversational coach. The user is in a live conversation; below is the most recent portion of the dialogue. Suggest 3–5 concrete, actionable things the user could say, ask, suggest, request, or answer right now to move the conversation productively forward. Be specific to what was just discussed. Use bullet points. If the conversation is in a non-English language, respond in that language. Do not summarise the conversation; do not explain what was said; respond only with the suggestions._

Final wording is owned by the designer; the prompt MUST be a single string constant in `src/prompts/default-system-prompt.ts` and overridable via `--system-prompt` (see OD-6).

### OD-2 — Channel/speaker tags in the prompt context
**Recommendation**: YES, include them (per FR-CC-12). Both single-source `[system]` / `[mic]` tags and dual-channel `[Speaker-A]` / `[Speaker-B]` tags help the model attribute utterances. The mapping table is included verbatim at the top of the user message so the model knows what the labels mean.

### OD-3 — Default model per provider
**Recommendation**: per FR-CC-8 — `gpt-4o-mini` (openai), `claude-haiku-4-5` (anthropic), `gemini-2.5-flash` (gemini), the deployment name (azure-openai), `claude-haiku-4-5` (azure-ai-inference), `llama3.1:8b` (ollama), no default for litellm and mlx (require explicit `--model`). Rationale: cheapest fast streaming SKUs that still produce coherent multi-bullet output; users override via `--model` when they need higher quality.

### OD-4 — Stdin streaming trigger semantics
**Recommendation**: Enter on `/dev/tty` is the default trigger; `--debounce <duration>` is the fallback for fully non-interactive pipelines. See FR-CC-6 for the full rule. This avoids the worst behaviour of triggering on every line (which would burn provider quota) and the worst behaviour of never triggering (which would be useless in pipelines).

### OD-5 — Token-budget overflow handling
**Recommendation**: per FR-CC-13 — `truncate-start` default, with `--on-overflow {truncate-start | truncate-end | error}`. Truncating from the start preserves the most recent dialogue, which is exactly what the coaching prompt cares about. Summarisation as an overflow strategy is intentionally NOT offered in v1 (would require a second LLM round-trip and complicates cost accounting).

### OD-6 — `--system-prompt <path>` flag
**Recommendation**: YES, ship this in v1. Cost to implement is trivial (read a file, pass as system message), and several plausible downstream use cases (translation coach, sales coach, technical-interview coach) are unlocked by it. Documented in the tool's help text and in `docs/tools/convo-coach.md`.

### OD-7 — Sidecar markdown structure (NEW — surfaced during refinement)
**Recommendation**: YAML front-matter (provider, model, source path, window, mapping) followed by:
```
# Conversational coaching — <YYYY-MM-DD HH:MM:SS local time>

## Source window
- File: <path>
- Range: <window-start> → <window-end>
- Segments: <n> (dropped due to context limit: <m>)

## Advice
<streamed body>

## Metrics
- Provider: <name>
- Model: <id>
- Latency to first token: <ms>
- Total elapsed: <s>
- Prompt tokens: <n> (if reported)
- Completion tokens: <n> (if reported)
```

### OD-8 — Auto-detect: which sidecar formats to consider (NEW)
**Recommendation**: consider all four (`*.transcript.{jsonl,txt,srt,vtt}`) but prefer JSONL when multiple formats with the same basename exist. JSONL preserves channel/language metadata that the prompt builder uses; the others are lossy.

---

## Constraints

### Project-mandated (non-negotiable)
- **C-1** — TypeScript only. Swift exception (CLAUDE.md Exception 001) is `macrec`-scoped.
- **C-2** — Tool docs and config folder MUST be created via `/tool-conventions scaffold convo-coach`. Hand-rolling `docs/tools/convo-coach.md` or `~/.tool-agents/convo-coach/` is forbidden.
- **C-3** — Vendor-canonical LLM env-var names only (no `CONVO_COACH_OPENAI_API_KEY` style prefixes). The only `CONVO_COACH_*` env vars allowed are tool-internal knobs (`CONVO_COACH_PROVIDER`, `CONVO_COACH_MODEL`, `CONVO_COACH_LOG_LEVEL`, `CONVO_COACH_DEBOUNCE`, etc.).
- **C-4** — No fallback values for missing credentials, endpoints, deployment names, or the macrec recordings directory. Raise typed errors instead.
- **C-5** — `~/.tool-agents/convo-coach/` MUST be mode `0700`; `.env` MUST be mode `0600`. Created on first invocation if missing.
- **C-6** — Update `Issues - Pending Items.md` for any defect, inconsistency, or follow-up surfaced during implementation. Pending items go on top, completed items below.
- **C-7** — All test scripts MUST live under `test_scripts/` (project-level convention) for end-to-end shell scripts; package-local TS tests live under `tools/convo-coach/test/`.

### Technical
- **C-8** — Node ≥20 (matches `dual-transcript-merger`).
- **C-9** — ESM module type (`"type": "module"` in `package.json`).
- **C-10** — TypeScript strict mode (`"strict": true`).
- **C-11** — No native dependencies (pure JS/TS). HTTP via Node's built-in `fetch` plus `EventSource`-style streaming parsing where needed.
- **C-12** — License consistent with the rest of the repo (likely MIT or unlicensed; designer to confirm).

---

## Dependencies

### Project-internal
- `macrec` — produces the transcripts consumed by `convo-coach`. Sidecar formats are stable per `docs/tools/macrec.md`. No code dependency, only file-format dependency.
- `dual-transcript-merger` — code-level precedent for project structure (`package.json` shape, `prepare`/`postbuild` scripts, `dist/cli.js` shebang). Optional consumer of `dual-transcript-merger` output (the merger's `.merged.jsonl` is one of the supported input formats).
- `/tool-conventions scaffold convo-coach` slash command — MUST be invoked to create `docs/tools/convo-coach.md` and `~/.tool-agents/convo-coach/{,.env}`.

### External
- Node ≥20 runtime.
- `typescript` ^5.6, `tsx` ^4.19 (dev), `@types/node` ^22 (dev) — same versions as `dual-transcript-merger` to keep the toolchain uniform.
- A small CLI argument parser (recommendation: `commander` ^12 or stay dependency-free using a hand-rolled parser like `dual-transcript-merger`'s — designer to choose; staying dependency-free is preferred for the no-fallback discipline).
- Provider SDKs are NOT required (HTTP via `fetch`); however, if the designer prefers official SDKs (`openai`, `@anthropic-ai/sdk`, `@google/generative-ai`, etc.) for streaming robustness, that is acceptable provided they are pinned and audited. Recommendation: hand-rolled SSE parsing for OpenAI/Azure/LiteLLM/MLX, official SDKs for Anthropic and Gemini if their streaming protocols are awkward to implement directly.

### Reference materials (must be read by the investigator/designer)
- `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/tools/macrec.md` — sidecar schema and recordings-folder convention.
- `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/tools/dual-transcript-merger.md` — dual-channel JSONL schema and TS-tool installation precedent.
- `/Users/giorgosmarinos/.claude/agents/tool-doc-config-architect.md` — authoritative spec for docs/config layout and the eight standard LLM providers.
- `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/tools/dual-transcript-merger/` — code-level precedent (esp. `package.json`, `tsconfig.json`, `src/cli.ts`, `dist/cli.js` shebang).
- `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/docs/design/project-design.md` and `docs/design/project-functions.md` — current project state.
- `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/CLAUDE.md` — Exception 001 (Swift scope), Exception 002 (macOS 26 deployment target), Tools section, structure & conventions.

---

## Assumptions

1. **A-1** — The macrec recordings folder is reachable from the user's shell environment (either as `MACREC_RECORDINGS_DIR` or in macrec's `.env`). If neither is set, auto-detect raises 78 with a remediation hint; the user must pass `--transcript` explicitly. Basis: macrec's documented configuration chain.
2. **A-2** — Users running `convo-coach` already have at least one of the eight provider credentials configured in their environment OR in `~/.tool-agents/convo-coach/.env`. Basis: alignment with how `macrec`'s transcription providers are credentialled.
3. **A-3** — The transcript file is encoded UTF-8 (matches macrec's output). Non-UTF-8 input is treated as a parse error.
4. **A-4** — Streaming is supported by every provider in their canonical SSE-style API. For providers without streaming (none in the standard eight, but theoretical), the tool would buffer and emit the whole response at end — implementation does not need to special-case this for v1.
5. **A-5** — Wall-clock timestamps in macrec sidecars are local time without timezone for the JSONL `timestamp` field's date-only conversion. Basis: macrec sidecars use ISO-8601 `Z`-suffixed UTC timestamps (verified in `docs/tools/macrec.md` JSONL example).
6. **A-6** — A single LLM round-trip per invocation is sufficient. No multi-turn conversation, no chained reasoning. Basis: brief explicitly frames the request as "ask an LLM for advice".

---

## Out-of-Band Notes for Downstream Workflow Stages

- **Investigator** — confirm the macrec recordings-folder env var name (`MACREC_RECORDINGS_DIR` is the assumed name in this spec; verify against macrec's codebase and `docs/design/configuration-guide.md`. If the actual name differs, update FR-CC-3 and AC-CC-7.).
- **Planner** — produce `docs/design/plan-xxx-convo-coach.md` (next sequential plan number) covering: scaffold phase (slash command), provider abstraction, transcript parser, windowing, prompt builder, streaming loop, sidecar writer, CLI wiring, tests.
- **Designer** — finalise the default system prompt (OD-1), the YAML front-matter schema (OD-7), and confirm provider SDK choices (Dependencies §External).
- **Coders** (parallel) — natural split: (a) transcript-parsing module, (b) provider abstraction + 8 implementations, (c) CLI / windowing / config-resolver, (d) sidecar writer + streaming pipeline.
- **Code reviewer** — verify no fallback values exist, all eight providers are wired, the four-tier chain order is correct, secrets are never logged.
- **Dependency validator** — verify `npm install && npm run build && npm link` from a clean clone produces a working `convo-coach --help` on macOS and Linux.
- **Test builders** (parallel) — unit tests for parser, windowing, resolver, prompt builder; integration tests with mocked HTTP for each provider; one end-to-end test per acceptance criterion.
- **Integration verifier** — execute every AC-CC-* row above and produce a pass/fail table.

---

## Original Request (verbatim)

> Create a new TypeScript tool named `convo-coach` (a direct-on-PATH command) for the recording-tool project.
>
> ## Functional requirements
> - Reads a transcription produced by `macrec` and asks an LLM for conversational help — phrased as: "advise me on what I could ask, suggest, request, or answer right now."
> - Streams the LLM response token-by-token to stdout AND always also writes the response to a sidecar `<transcript-basename>.advice-<timestamp>.md` next to the source transcript.
> - Supports the FULL set of LLM providers we use across the other LLM-based tools in this project (the same eight standard providers mandated by `tool-doc-config-architect`: OpenAI, Anthropic, Google Gemini, Azure OpenAI, Azure AI Inference, Ollama, LiteLLM, plus the project's existing transcription providers where they offer chat/completion APIs).
> - Must read configuration from the same environment/config layers as `macrec`: shell env → `~/.tool-agents/convo-coach/.env` → local `.env` → CLI flags (lowest → highest priority). Reuses the project's vendor-canonical env-var names (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `AZURE_OPENAI_*`, `AZURE_AI_INFERENCE_*`, `OLLAMA_HOST`, `LITELLM_*`).
> - CLI overrides for `--provider <name>` and `--model <id>` that beat any config-file value.
>
> ## Transcript-input modes (combined modes 2 + 3 from clarifying questions, already decided by user)
> - Auto-detect: when no input is supplied, find the most recent macrec sidecar in macrec's recordings folder (read macrec's config to discover that folder).
> - Explicit: `--transcript <path>` overrides auto-detect.
> - Stdin: if stdin is piped (e.g. `tail -f sidecar.jsonl | convo-coach`), read from stdin instead. Stdin streaming should let the user re-trigger advice as new lines arrive (or define a clear semantics — the implementer should propose the simplest sensible behavior).
>
> ## Conversation-window filter (already decided by user)
> - `--last <duration>` (e.g. `--last 5m`, `--last 30s`, `--last 1h`) — relative window from "now" (or from end of transcript when reading a finalized file).
> - `--since <timestamp>` (e.g. `--since 14:32:10` or ISO-8601) — absolute anchor.
> - Both flags can be combined; when both are given, use the later boundary.
> - When neither is given, use the full transcript.
> - Must correctly parse macrec's dual-channel JSONL format (Channel A = Apple on-device, Channel B = Apple Cloud) — see the `dual-transcript-merger` tool docs for the schema.
>
> ## Output (already decided by user)
> - Stream to stdout token-by-token AND always also write the full response to a sidecar `<transcript-basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source transcript.
>
> ## Hard rules from project CLAUDE.md (non-negotiable)
> - TypeScript only. The Swift exception in this repo's CLAUDE.md applies ONLY to the macOS audio-capture tool (`macrec`) — all other tools must remain TypeScript.
> - Tool MUST be scaffolded via `/tool-conventions scaffold convo-coach` — do NOT hand-roll `docs/tools/convo-coach.md` or the `~/.tool-agents/convo-coach/` config folder. The slash command dispatches the `tool-doc-config-architect` subagent which owns the full spec (folder modes 0700/0600, four-tier env resolution, eight standard LLM providers).
> - No fallback values for missing config — raise a clear error instead.
> - Tool must be installable as a direct command on the OS (e.g. via `npm link`, like `dual-transcript-merger`).
> - After the tool is built, add a concise reference entry to the project's CLAUDE.md "Tools" section pointing at `docs/tools/convo-coach.md`.
> - Maintain `Issues - Pending Items.md` if defects/pending items surface during implementation.
>
> ## Reference material to consult
> - `docs/tools/macrec.md` — recordings-folder default and `--transcribe` sidecar schema.
> - `docs/tools/dual-transcript-merger.md` — dual-channel JSONL format and the precedent on how a TS tool gets installed as a direct command (`npm link`, `prepare`/`postbuild` scripts in `package.json`).
> - `~/.claude/agents/tool-doc-config-architect.md` — the authoritative spec for docs/config layout and the eight standard LLM providers.
> - `tools/dual-transcript-merger/` (existing TS tool) — code-level precedent for project structure, package.json scripts, and the `dist/cli.js` shebang pattern.
> - `docs/design/project-design.md` and `docs/design/project-functions.md` — current project state.
