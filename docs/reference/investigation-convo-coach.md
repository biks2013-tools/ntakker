# Investigation: `convo-coach` — TypeScript CLI Building Blocks

## Executive Summary

`convo-coach` is a greenfield TypeScript CLI under `tools/convo-coach/` that consumes `macrec` JSONL/TXT/SRT/VTT sidecars, slices a recent window, and asks one of eight LLM providers to stream back coaching advice — to both `stdout` and a `.advice-<timestamp>.md` sidecar. The investigation covers eight implementation choices.

**Headline recommendations:**

1. **Multi-provider LLM client** → **Vercel AI SDK** (`ai` v5 + `@ai-sdk/openai`, `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/azure`, `@ai-sdk/openai-compatible`). Single `streamText({ model, system, prompt })` + `for await (const delta of result.textStream)` + `await result.usage` covers all eight providers (Ollama, LiteLLM and MLX-LM are reached via the OpenAI-compatible adapter). It's the only option that gives one streaming abstraction without writing eight bespoke SSE parsers, and it directly satisfies NFR-CC-1 (sub-3s TTFT — no client-side buffering) and NFR-CC-5 (provider isolation — one factory per provider).
2. **CLI parsing** → **stay dependency-free** (hand-rolled `parseArgs(argv)` exactly like `tools/dual-transcript-merger/src/cli.ts:84-157`). `convo-coach`'s flag surface is roughly the same size as the merger's (~12 flags); pulling in `commander`/`yargs` would break the project's zero-runtime-dep convention for no real win.
3. **Env-var + four-tier resolution** → **port `tools/dual-transcript-merger/src/config.ts`** verbatim, parameterising the tool name and key list. Continue rejecting `dotenv` and other env libraries; they violate the no-fallback discipline (silent defaulting, type coercion).
4. **Duration parsing for `--last`** → **hand-rolled regex** (`^(\d+h)?(\d+m)?(\d+s)?$`, must consume entire string, must be non-empty). `ms` and `parse-duration` are tiny but neither rejects gibberish strictly enough for the no-fallback rule.
5. **Stdin trigger semantics** → **YES, the OD-7 default is implementable cleanly.** Open `/dev/tty` via `fs.createReadStream('/dev/tty')` + `readline`; if open fails (ENXIO/ENOENT), fall back to `--debounce` countdown reset on every stdin line. Edge cases (`tail -f` never closes, mid-stream stdin close) are handled by EOF-as-final-trigger rule.
6. **Token-budget overflow** → **two-tier estimator**. `js-tiktoken` (zero-dep, no native code, ~250 KB) for the OpenAI/Azure-OpenAI/LiteLLM-routed-OpenAI/MLX-via-OpenAI-compatible families; **4-chars-per-token heuristic** for Anthropic/Gemini/Ollama. Combine with a static `model-context-windows.ts` map. Truncate-start the segment array before sending, and log dropped count to sidecar front matter.
7. **Default model per provider** (as of 2026-05) → `gpt-4o-mini` (openai), `claude-haiku-4-5-20251001` (anthropic), `gemini-2.5-flash` (gemini), `${AZURE_OPENAI_DEPLOYMENT}` (azure-openai), `claude-haiku-4-5` (azure-ai-inference), `llama3.1:8b` (ollama), no default (litellm), no default (mlx).
8. **Sidecar collision** → confirmed: append `-<n>` (n = 2, 3, …) to the timestamp suffix on collision; pick the lowest free `n`. Trivial — no further analysis needed.

A "Technical Research Guidance" section at the end flags one follow-up topic for the planner: validating the AI SDK's per-provider event names and Azure OpenAI deployment-name semantics against the actual v5 release the implementer pins.

---

## Context

- **What was investigated**: the eight implementation-choice questions enumerated in the user's investigation request, intended to close out remaining ambiguity in `docs/design/refined-request-convo-coach.md` so the planner can produce a step-by-step implementation plan.
- **Key requirements driving evaluation** (from refined request):
  - Eight standard LLM providers, all wired out of the box (FR-CC-7, C-3).
  - No-fallback rule for credentials/endpoints (FR-CC-10, C-4).
  - Token-by-token streaming to stdout AND simultaneous append to a markdown sidecar (FR-CC-11).
  - Sub-3s TTFT, no client-side buffering (NFR-CC-1).
  - Streaming line-reader for >100 MB sidecars (NFR-CC-2).
  - Pure-JS, no native deps, Node ≥20, ESM (C-8/9/10/11).
  - Adding a 9th provider must require zero CLI-layer changes (NFR-CC-5).
- **Refined request file**: `docs/design/refined-request-convo-coach.md`.
- **Codebase scan**: `docs/reference/codebase-scan-convo-coach.md` (especially the `MACREC_RECORDINGS_DIR` correction in §4 "macrec Recordings Folder — CRITICAL FINDING" and the JSONL schema in §4 "macrec JSONL Sidecar Schema").

### Correction to refined-request assumption A-1

**A-1 in the refined request says** the macrec recordings folder is "reachable from the user's shell environment (either as `MACREC_RECORDINGS_DIR` or in macrec's `.env`)". The codebase scan invalidates the second clause: `MACREC_RECORDINGS_DIR` is **not** a macrec-native env var. macrec stores its UI-chosen folder in `@AppStorage("com.macrec.ui.outputFolder")` (UserDefaults, not env), and the CLI takes a per-recording `--output <path>`. `~/.tool-agents/macrec/.env` exists but contains no folder key.

**Resolution adopted in this investigation**: `MACREC_RECORDINGS_DIR` is a `convo-coach`-owned env var, defined and read exclusively from `convo-coach`'s own four-tier chain (shell env → `~/.tool-agents/convo-coach/.env` → local `./.env` → CLI flag). The default value is `~/Recordings` (resolved via `path.join(homedir(), 'Recordings')`) when none of the four tiers set it. Because that default is a **directory location**, not a credential or endpoint, it does NOT violate FR-CC-10 (no-fallback applies to credentials/endpoints/deployments per the user's clarification). FR-CC-3 in the refined request must be updated by the planner: drop the "read macrec's configuration chain" wording, replace with "read `convo-coach`'s own four-tier chain for `MACREC_RECORDINGS_DIR`; default to `~/Recordings` if absent". AC-CC-7 verification stays semantically identical.

---

## Options Identified

### Question 1 — Multi-provider LLM client library

#### Option 1A: Vercel AI SDK (`ai` v5 + provider packages) — **recommended**

- **Description**: `ai` is the unified runtime; provider packages (`@ai-sdk/openai`, `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/azure`, `@ai-sdk/openai-compatible`) plug into it. Single API: `streamText({ model: anthropic('claude-haiku-4-5-20251001'), system, prompt })`, then `for await (const delta of result.textStream) process.stdout.write(delta)` and `const usage = await result.usage`. Provider switching is one factory per provider — the consuming code is identical.
- **Strengths**:
  - Covers 5 of the 8 providers natively (OpenAI, Anthropic, Google, Azure-OpenAI, the OpenAI-compatible adapter handles Ollama / LiteLLM / MLX with `createOpenAICompatible({ name, baseURL, headers })`).
  - The 6th–8th providers (Ollama, LiteLLM, MLX) are all OpenAI-compatible servers in 2026 and are routed through the same `@ai-sdk/openai-compatible` adapter — confirmed by the AI SDK community-providers documentation pattern (e.g. NVIDIA NIM, OLLM examples in [Vercel AI SDK docs](https://github.com/vercel/ai)).
  - **`textStream`** is an `AsyncIterable<string>` of text deltas — exactly what `process.stdout.write(delta)` wants. No client-side buffering, satisfies NFR-CC-1.
  - **`result.usage`** is a `Promise<LanguageModelUsage>` exposing `inputTokens`, `outputTokens`, `totalTokens` after stream-end — populates sidecar `Metrics` block per OD-7.
  - **Azure AI Inference (Foundry)** — Foundry exposes the OpenAI-compatible `/openai/deployments/.../chat/completions` interface; either `@ai-sdk/azure` (with a custom `endpoint`) or `createOpenAICompatible` works. Confirmation needed at planning time (flagged in Technical Research Guidance below).
  - Zero per-provider SSE parsing in `convo-coach`'s codebase. Adding a 9th provider in the future = one new file in `src/providers/` (NFR-CC-5).
  - Active maintenance, official Vercel SDK, large user base. Versioned (`v5.0.0` stable as of 2026; `v6.0.0-beta` in flight).
- **Weaknesses**:
  - Brings in `ai` + 4–5 provider packages (~3 MB compressed total). This is the only material deviation from the project's zero-runtime-dep pattern (`tools/dual-transcript-merger/package.json:6` has no `dependencies` block at all). Justification: implementing eight bespoke SSE parsers + reconnection + auth schemes is materially more code, more bug surface, and harder to keep current as providers rev their wire formats.
  - The unified abstraction occasionally hides provider-specific quirks (`providerOptions.anthropic.effort`, `providerOptions.google.safetySettings`); for v1 these are not needed.
  - `@ai-sdk/openai-compatible` requires the implementer to assemble the `Authorization` header for LiteLLM (`Bearer ${LITELLM_MASTER_KEY}`) — small amount of glue.
- **Effort/Complexity**: Low. ~150 lines for the eight provider factories combined.
- **Risk**: Low–Medium. Risk source is supply-chain (now depending on 5 npm packages). Mitigation: pin exact versions in `package.json`, generate `package-lock.json`, document the pinned versions in `docs/tools/convo-coach.md`.
- **Best suited when**: the goal is to minimise per-provider implementation effort and keep the streaming surface uniform.

#### Option 1B: LangChain.js

- **Description**: `langchain` + `@langchain/openai`, `@langchain/anthropic`, `@langchain/google-genai`, `@langchain/community/llms/ollama`, etc.
- **Strengths**: Provider catalogue is large; abstractions for chains, agents, memory.
- **Weaknesses**: Heavyweight; the abstractions (Runnables, LCEL, Chains) are massively over-scoped for a single one-shot prompt → stream out. Documentation and APIs change frequently between minor versions. Adds ~10 MB of transitive deps. Streaming API (`.stream()` returns `IterableReadableStream<AIMessageChunk>`) is more verbose than AI SDK's `textStream`.
- **Effort/Complexity**: Medium.
- **Risk**: Medium. Frequent breaking changes between versions; the framework's "value add" (chains, agents) is unused.
- **Best suited when**: the tool needs multi-step reasoning, retrieval-augmented generation, or stateful agents. None of these apply to `convo-coach`.

#### Option 1C: LlamaIndex.ts

- **Description**: Same shape as LangChain — a framework for RAG-centric workflows with provider abstractions.
- **Strengths/Weaknesses**: Same as LangChain. Even more retrieval-heavy.
- **Effort/Complexity**: Medium.
- **Risk**: Medium.
- **Best suited when**: building retrieval pipelines. Not applicable.

#### Option 1D: LiteLLM proxy + OpenAI SDK only

- **Description**: Run LiteLLM as a proxy server (locally or remote); `convo-coach` talks only to it via `openai`'s SDK pointed at `LITELLM_PROXY_URL`. LiteLLM internally routes to all eight providers.
- **Strengths**: One client SDK (`openai`); LiteLLM handles auth and routing; provider list is huge.
- **Weaknesses**: **Adds a mandatory deployment dependency** — every user must run a LiteLLM proxy. That's contrary to FR-CC-7's "Direct OpenAI", "Direct Anthropic" wording (the spec wants direct vendor calls, with LiteLLM as **one** option among eight, not the only option). Also: streaming token usage is sometimes lost in the proxy hop.
- **Effort/Complexity**: Low (in `convo-coach`); High (in user setup).
- **Risk**: High. Hard dependency on user infra.
- **Best suited when**: the user already runs a LiteLLM proxy and wants a single point of routing. Not the convo-coach architectural intent.

#### Option 1E: Per-provider native SDKs hand-wired

- **Description**: Add `openai`, `@anthropic-ai/sdk`, `@google/generative-ai`, `@azure/openai`, plus hand-rolled SSE parsers for Ollama / LiteLLM / MLX. Wrap each in a thin `ProviderClient { stream(prompt): AsyncIterable<string>; usage(): Promise<Usage> }` interface.
- **Strengths**: Direct vendor SDKs — no abstraction layer hides per-provider features. Each provider's idiomatic auth/retry patterns are preserved.
- **Weaknesses**: 4 SDK packages + 4 hand-rolled HTTP clients = a lot of code surface (~700 LOC vs ~150 LOC for AI SDK). Inconsistent streaming APIs across SDKs (callbacks vs async iterators vs events). Each SDK has its own tokens-usage shape that must be normalised. Maintenance burden when SDKs rev. A 9th provider = a new SDK + new wrapper.
- **Effort/Complexity**: High.
- **Risk**: Medium. Higher implementation cost; lower abstraction risk.
- **Best suited when**: the project needs deep per-provider feature access (function calling, vision, batch). Not applicable for v1's plain text-in/text-out coaching.

---

### Question 2 — CLI argument parsing

#### Option 2A: Hand-rolled `parseArgs(argv)` — **recommended**

- **Description**: Replicate the pattern in `tools/dual-transcript-merger/src/cli.ts:84-157` — a single switch statement over `argv`, throwing typed errors for unknown flags or missing values.
- **Strengths**: Zero runtime deps (already the project convention). Direct control over error messages — important for FR-CC-14's exit-code mapping. No silent default substitution. Existing precedent in the repo means no learning curve for the next reviewer.
- **Weaknesses**: A bit of boilerplate (~60 lines for ~12 flags). No automatic `--help` generation.
- **Effort/Complexity**: Low.
- **Risk**: Low.

#### Option 2B: `commander` v12

- **Description**: Most popular Node CLI library. `program.option('--provider <name>').action(...)`.
- **Strengths**: Familiar, stable API. Auto-`--help`.
- **Weaknesses**: Adds a runtime dep; auto-`--help` formatting is opinionated and doesn't match the merger's existing format. Commander silently coerces values (e.g. `'0'` → `0`) unless explicitly told not to; small but real friction with the no-fallback rule.
- **Effort/Complexity**: Low.
- **Risk**: Low.

#### Option 2C: `yargs`

- **Description**: Older sibling of commander; richer parser, more configurable.
- **Strengths**: Widely used, mature.
- **Weaknesses**: Larger; verbose API; more dependencies than commander.
- **Effort/Complexity**: Low–Medium.
- **Risk**: Low.

#### Option 2D: `citty`, `mri+manual`, `clipanion`

- **Description**: Smaller alternatives. `citty` (UnJS) is modern and slim; `mri` is a minimal flag parser; `clipanion` is class-based with TS types.
- **Strengths**: All are smaller than commander.
- **Weaknesses**: All add a dep for what the merger already proves can be done in 60 lines of plain TS.
- **Effort/Complexity**: Low.
- **Risk**: Low.

**Verdict for Q2**: stay dependency-free (Option 2A). The merger's hand-rolled parser is already the project's established pattern; deviating would be unjustified novelty.

---

### Question 3 — Env-var + config layering (four-tier chain)

#### Option 3A: Port `tools/dual-transcript-merger/src/config.ts` — **recommended**

- **Description**: The merger's `resolveDefaults()` (lines 103-153) is the canonical four-tier resolver: `process.env` → `~/.tool-agents/<tool>/.env` → `<cwd>/.env` → CLI flags. `parseDotEnv()` (lines 53-65) handles `KEY=value`, `#` comments, blank lines. Reuse the structure verbatim, parameterising the tool name (`dual-transcript-merger` → `convo-coach`) and the keys to resolve.
- **Strengths**: Already proven in this codebase. Zero deps. Strict validation per tier — invalid values throw `MergerError("BAD_CONFIG", ...)` immediately, matching FR-CC-10. The same provenance-tracking pattern (`provenance: { OPENAI_API_KEY: "process.env" }`) feeds the `--show-config` debugging output and the FR-CC-10 error message ("checked: process.env, ~/.tool-agents/convo-coach/.env, ./.env, CLI").
- **Weaknesses**: No support for quoted values or multi-line values in `.env`. Acceptable: API keys are single-line opaque strings.
- **Effort/Complexity**: Low. ~200 LOC including the eight-provider key list.
- **Risk**: Low.
- **Swift parallel**: `Sources/MacrecCore/Bootstrap/EnvFileStore.swift` and `ToolAgentsBootstrap.swift` implement the same chain in Swift; the TS port is a literal mirror.

#### Option 3B: `dotenv` (+ `dotenv-expand`)

- **Description**: The dominant `.env` library.
- **Strengths**: Familiar, handles quoting and variable expansion.
- **Weaknesses**: Mutates `process.env` by default — silently merges values, breaking the explicit per-tier provenance the no-fallback rule needs. Variable expansion (`KEY=$OTHER_KEY`) is a fallback mechanism by definition. Adds a dep where none is needed.
- **Effort/Complexity**: Low.
- **Risk**: Medium (silent mutation semantics).

#### Option 3C: `c12`, `unjs/jiti`, `envalid`, `zod-config`

- **Description**: Modern config loaders. `c12` supports layered configs (defaults → file → env → overrides); `envalid` validates env shapes with TS types; `zod-config` chains zod parsers.
- **Strengths**: Layering and validation are first-class.
- **Weaknesses**: All assume a defaults-then-overrides world where missing values silently fall through. None match the four explicit tiers + no-fallback discipline cleanly. Adding a dep for ~150 LOC of config logic that already exists in the merger is unjustified.
- **Effort/Complexity**: Low–Medium.
- **Risk**: Medium.

**Verdict for Q3**: Option 3A. Direct port from `tools/dual-transcript-merger/src/config.ts`, parameterised. Add a `bootstrapToolAgentsDir()` mirror of `cli.ts:167-176`. The bootstrap MUST also seed `~/.tool-agents/convo-coach/.env` with mode `0600` if it doesn't exist — but that file is created by `/tool-conventions scaffold convo-coach`, not by the runtime. Runtime only creates the **directory** with mode `0700` (per the merger's existing comment at `cli.ts:160-166`).

---

### Question 4 — Duration parsing for `--last`

#### Option 4A: Hand-rolled regex — **recommended**

- **Description**:

  ```typescript
  const DURATION_RE = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/;
  function parseDuration(input: string): number /* ms */ {
      const m = DURATION_RE.exec(input);
      if (!m || (m[1] === undefined && m[2] === undefined && m[3] === undefined)) {
          throw new ConvoCoachError("BAD_USAGE", `--last='${input}' is not a valid duration (expected: 30s | 5m | 1h | 1h30m | 90s)`);
      }
      const h = m[1] ? parseInt(m[1], 10) : 0;
      const min = m[2] ? parseInt(m[2], 10) : 0;
      const s = m[3] ? parseInt(m[3], 10) : 0;
      return ((h * 60 + min) * 60 + s) * 1000;
  }
  ```

- **Strengths**: Strict (rejects `5x`, empty string, negative numbers, decimal seconds — all of which `ms` accepts). Zero deps. Trivial to test.
- **Weaknesses**: Only supports `h`/`m`/`s` (no `ms`/`d`/`w`). Accepted — matches the FR-CC-5 grammar exactly.
- **Effort/Complexity**: Low (~15 LOC + tests).
- **Risk**: Low.

#### Option 4B: `ms` (npm)

- **Description**: Vercel's tiny duration parser (`ms('5m')` → `300000`).
- **Strengths**: Tiny; widely used.
- **Weaknesses**: Accepts a wide grammar (`'5 minutes'`, `'2 days'`, `'-3s'`). Returns `undefined` for invalid strings — caller must check, easy to miss. Doesn't enforce the FR-CC-5 grammar.
- **Effort/Complexity**: Low.
- **Risk**: Low–Medium (loose validation).

#### Option 4C: `parse-duration`

- **Description**: Similar to `ms` but with more units.
- **Strengths/Weaknesses**: Same trade-offs as `ms`. Even broader grammar.
- **Effort/Complexity**: Low.
- **Risk**: Low–Medium.

#### Option 4D: `human-interval`

- **Description**: Parses English-language intervals (`'2 hours and 30 minutes'`).
- **Strengths**: Human-friendly.
- **Weaknesses**: Way out of scope for FR-CC-5's grammar.
- **Effort/Complexity**: Low.
- **Risk**: Medium.

**Verdict for Q4**: Option 4A. Hand-rolled regex is 15 lines, exact, testable, zero deps. Same logic for `--debounce` and `--since`'s relative form (`+MM:SS` / `+HH:MM:SS`).

---

### Question 5 — Stdin trigger semantics for piped input

#### Sanity check of OD-7 default

The refined request specifies: trigger on Enter from `/dev/tty` if a TTY is attached, else fall back to `--debounce <duration>` (default 15s). **This is implementable cleanly in Node.** Pattern:

```typescript
import { createReadStream, openSync } from "node:fs";
import { createInterface } from "node:readline";

let ttyInput: NodeJS.ReadableStream | null = null;
try {
    // Open /dev/tty directly. If stdin is piped, this is the only way to get keystrokes.
    const fd = openSync("/dev/tty", "r");
    ttyInput = createReadStream("", { fd, encoding: "utf8" });
} catch (e) {
    // ENXIO (no controlling terminal) or ENOENT (e.g. inside a Docker container without -it)
    ttyInput = null;
}

if (ttyInput !== null) {
    const tty = createInterface({ input: ttyInput });
    tty.on("line", () => triggerAdviceRequest());
} else {
    // Debounce fallback: reset a timer on every stdin line.
    let debounceTimer: NodeJS.Timeout | null = null;
    stdinReader.on("line", (line) => {
        ringBuffer.push(parseSegment(line));
        if (debounceMs > 0) {
            if (debounceTimer) clearTimeout(debounceTimer);
            debounceTimer = setTimeout(triggerAdviceRequest, debounceMs);
        }
    });
}

stdinReader.on("close", () => {
    // EOF — always emit one final advice request unless we just emitted one
    if (lastTriggerWasRecent()) return;
    triggerAdviceRequest();
});
```

#### Edge cases to handle

1. **`tail -f sidecar.jsonl | convo-coach`** — stdin never closes. The Enter-key trigger on `/dev/tty` is the only sensible mechanism; debounce alone would either fire constantly (low debounce) or never (`tail -f` may emit lines steadily). **Mitigation**: Enter-on-`/dev/tty` is the primary path; debounce is the explicit fallback for `--debounce 15s` style use.
2. **stdin closes mid-stream (broken pipe)** — `stdinReader.on('close', …)` fires; emit one final advice request if any new segments arrived since the last trigger; then exit 0.
3. **`/dev/tty` unavailable** — try/catch around `openSync('/dev/tty', 'r')` swallows ENXIO/ENOENT; the tool transparently falls through to the debounce mode.
4. **User wants both Enter and debounce** — Enter wins (it's "make me a request now"); debounce's purpose is the no-`/dev/tty` fallback. Document this clearly in `--help`.
5. **Re-entrant trigger while a request is in-flight** — the simple rule: ignore Enter presses while a request is streaming; log to stderr `info: previous request still streaming, ignoring trigger`. Don't queue.
6. **Empty ring buffer (no segments yet)** — emit `warning: no segments accumulated, skipping trigger` and don't burn provider quota.

**Verdict for Q5**: OD-7 is sound and implementable. Adopt the pattern above. ~80 LOC including all six edge cases.

---

### Question 6 — Token-budget overflow strategy

#### Estimating tokens cheaply across 8 providers

Per-provider tokenizers are diverse: OpenAI uses `tiktoken` (cl100k_base/o200k_base); Anthropic uses a proprietary BPE roughly counted as `chars / 3.5`; Gemini uses SentencePiece; Llama-family uses its own SentencePiece. Bundling all four would add ~10 MB of binary tokenizer data. **Pragmatic approach for v1:**

- **OpenAI / Azure-OpenAI / LiteLLM (when routed to OpenAI) / MLX (when serving an OpenAI-compatible model)** → use `js-tiktoken` (~250 KB, pure JS, no native deps) with the appropriate encoding.
- **Anthropic / Google Gemini / Ollama** → use a 4-chars-per-token heuristic (`Math.ceil(text.length / 4)`). This is the documented Anthropic rule of thumb and is conservatively close enough for context-window budgeting in a coaching prompt.
- **Unknown model** → 4-chars-per-token heuristic + `warning` log line + 8 192-token assumed window (per FR-CC-13).

#### Truncation algorithm

1. Compute token count of system prompt + user-message scaffolding (the channel-mapping table, the `[HH:MM:SS.mmm] [Speaker-X] text` formatting overhead).
2. Reserve `min(2048, context_window / 4)` tokens for the model's response.
3. Available budget for transcript segments = `context_window − reserved − scaffolding`.
4. Walk segments **from most recent to oldest** (truncate-start strategy default), accumulating their token estimate. Stop when adding the next segment would exceed the budget. Drop everything older.
5. Reverse the kept segments back to chronological order.
6. Record `droppedSegments: <n>` in sidecar front-matter (FR-CC-13).
7. For `--on-overflow truncate-end`, walk oldest-first and truncate the tail.
8. For `--on-overflow error`, exit 64 with `error: prompt would exceed context window of <n> tokens for model <id>; pass --last <smaller> or --on-overflow truncate-start`.

#### Static lookup table

`src/providers/model-context-windows.ts` — a `Record<string, number>` of model id → context-window. Initial seed (verify-at-implementation):

| Model id | Context window |
|---|---|
| `gpt-4o-mini` | 128 000 |
| `gpt-4o` | 128 000 |
| `gpt-4.1` | 1 047 576 |
| `o1-mini` | 128 000 |
| `claude-haiku-4-5-20251001` | 200 000 |
| `claude-sonnet-4-6` | 200 000 |
| `claude-opus-4-7` | 200 000 |
| `gemini-2.5-flash` | 1 048 576 |
| `gemini-2.5-pro` | 2 097 152 |
| `llama3.1:8b` | 131 072 |
| `llama3.1:70b` | 131 072 |
| _(unknown)_ | 8 192 (fallback per FR-CC-13) |

This is model **metadata**, not configuration — defaults here are explicitly allowed by FR-CC-10's last paragraph.

**Verdict for Q6**: Two-tier estimator (`js-tiktoken` for OpenAI-family, 4-chars heuristic for everything else) + static context-window map + truncate-from-array-front. ~120 LOC.

---

### Question 7 — Default model per provider (as of 2026-05)

| # | Provider | Default model id | Context window | Notes / source |
|---|---|---|---|---|
| 1 | openai | `gpt-4o-mini` | 128 000 | Cheap fast streaming SKU. OpenAI model docs. |
| 2 | anthropic | `claude-haiku-4-5-20251001` | 200 000 | Cheapest Claude 4.x family member; per system-prompt model list. |
| 3 | gemini | `gemini-2.5-flash` | 1 048 576 | Google's stable cheap streaming model in 2026; documented in Gemini API docs. |
| 4 | azure-openai | `${AZURE_OPENAI_DEPLOYMENT}` | (deployment-specific) | Azure OpenAI uses **deployment names**, not model ids — the user provisions a deployment in the Azure portal that maps to an OpenAI model. The default IS the deployment env var; `--model` overrides only when the user has multiple deployments and wants to pick at invocation time. |
| 5 | azure-ai-inference | `claude-haiku-4-5` | 200 000 | Azure AI Foundry hosts Claude under the same family ids; verify the exact id at planning time (some Azure regions tag with suffixes). |
| 6 | ollama | `llama3.1:8b` | 131 072 | Widely available local model, runs on consumer Macs. |
| 7 | litellm | _(no default — required)_ | — | LiteLLM's whole point is multi-provider routing — there's no sensible default; require `--model` or `CONVO_COACH_MODEL`. |
| 8 | mlx | _(no default — required)_ | — | MLX-LM serves whatever model the user has loaded; require explicit `--model`. |

**Authoritative model-id sources** (cited in the implementation; verify URLs at planning):

- Anthropic: model ids `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001` are the latest 4.x family per the system prompt's authoritative note.
- OpenAI: `gpt-4o-mini`, `gpt-4o`, `gpt-4.1`, `o1-mini` per OpenAI's published model catalog.
- Google: `gemini-2.5-flash`, `gemini-2.5-pro` per Google AI Studio model catalog.
- Azure OpenAI: deployment-name semantics per Azure OpenAI service docs.
- Ollama: `llama3.1:8b` is the default local model in Ollama's library.

These defaults are documented in `docs/tools/convo-coach.md` (the help text and the `<convoCoach>` doc block) and surfaced via `--show-config`.

---

### Question 8 — Sidecar collision handling

**Confirmed strategy**: when `<basename>.advice-<YYYYMMDD-HHMMSS>.md` already exists, append `-<n>` (n = 2, 3, …) and pick the lowest free `n`. Implementation:

```typescript
function uniqueSidecarPath(baseDir: string, basename: string, ts: string): string {
    let candidate = path.join(baseDir, `${basename}.advice-${ts}.md`);
    let n = 2;
    while (existsSync(candidate)) {
        candidate = path.join(baseDir, `${basename}.advice-${ts}-${n}.md`);
        n += 1;
        if (n > 99) {
            throw new ConvoCoachError("EX_SOFTWARE", `cannot allocate unique sidecar name (>99 collisions in same second)`);
        }
    }
    return candidate;
}
```

~15 LOC. Trivial. NFR-CC-3 satisfied.

---

## Comparison Matrix

### Q1 — LLM client library

| Criterion | Vercel AI SDK | LangChain.js | LlamaIndex.ts | LiteLLM-only | Per-provider SDKs |
|---|---|---|---|---|---|
| Covers all 8 providers | Yes (5 native + 3 via openai-compatible) | Yes | Partial | Yes (via proxy) | Yes (4 SDKs + 4 hand-rolled) |
| Streaming token-by-token | Excellent (`textStream`) | Good (verbose) | Good | Good | Inconsistent |
| Maintenance burden | Low | Medium | Medium | Low (in tool) | High |
| Footprint | ~3 MB | ~10 MB+ | ~10 MB+ | ~1 MB | ~5 MB |
| Adds 9th provider | Trivial | Trivial | Trivial | Free (proxy) | New SDK + wrapper |
| Direct vendor calls | Yes | Yes | Yes | No | Yes |
| Effort | Low | Medium | Medium | Low+High user setup | High |
| Risk | Low–Medium | Medium | Medium | High (user infra) | Medium |
| **Recommended** | **Yes** | No | No | No | No |

### Q2 — CLI parsing

| Criterion | Hand-rolled | commander | yargs | citty | clipanion |
|---|---|---|---|---|---|
| Project precedent (merger) | Yes | No | No | No | No |
| Zero runtime deps | Yes | No | No | No | No |
| Strict (no silent coercion) | Yes | Configurable | Configurable | Yes | Yes |
| Effort | Low | Low | Low | Low | Medium |
| **Recommended** | **Yes** | No | No | No | No |

### Q3 — Config layering

| Criterion | Port merger config | dotenv | c12 | envalid |
|---|---|---|---|---|
| Project precedent | Yes (verbatim) | No | No | No |
| Four-tier semantics | Yes | No (mutates env) | Partial | No |
| No-fallback alignment | Strict | Loose | Loose | Loose |
| Effort | Low | Low | Low–Medium | Low |
| **Recommended** | **Yes** | No | No | No |

### Q4 — Duration parsing

| Criterion | Hand-rolled regex | ms | parse-duration | human-interval |
|---|---|---|---|---|
| Strict grammar match (FR-CC-5) | Yes | No | No | No |
| Zero deps | Yes | No | No | No |
| Effort | Low | Trivial | Trivial | Trivial |
| **Recommended** | **Yes** | No | No | No |

---

## Recommendation

### Stack of choices for `convo-coach` v1

1. **LLM client**: `ai` (v5, pinned exact) + `@ai-sdk/openai`, `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/azure`, `@ai-sdk/openai-compatible`. Provider factory in `src/providers/factory.ts` returns a `LanguageModel` based on `--provider`. CLI calls `streamText({ model, system, prompt })`, iterates `result.textStream` writing each delta to both `process.stdout` and the sidecar `WriteStream`.
2. **CLI parser**: hand-rolled `parseArgs(argv)` mirroring `tools/dual-transcript-merger/src/cli.ts:84-157`.
3. **Config**: port `tools/dual-transcript-merger/src/config.ts` to a `src/config.ts` with the eight LLM-provider key list + `MACREC_RECORDINGS_DIR` + `CONVO_COACH_PROVIDER` + `CONVO_COACH_MODEL` + `CONVO_COACH_LOG_LEVEL` + `CONVO_COACH_DEBOUNCE`.
4. **Duration**: hand-rolled regex per Q4 §A.
5. **Stdin trigger**: `/dev/tty` Enter detection with try/catch fallback to debounce timer; EOF always emits one final request.
6. **Token budget**: `js-tiktoken` for OpenAI-family models, 4-chars-per-token heuristic for the rest, static `model-context-windows.ts` lookup, truncate-start by default.
7. **Default models**: per the table in Q7.
8. **Sidecar collision**: `-<n>` suffix loop, abort at n>99.

### Why this stack tips the decision

- Five of the eight implementation choices are **"reuse the merger's pattern verbatim"** — that's by design. The merger has been in production for plan-010 and is the only proven TS precedent in this repo. Deviating without cause would create two competing patterns for future tools.
- The one **material new dependency**, the Vercel AI SDK, is justified by the absence of any TS LLM-client code in this repo (greenfield) and the eight-provider requirement. The alternative (per-provider SDKs + hand-rolled SSE for 4 OpenAI-compatibles) is roughly 5x more code with no offsetting benefit.
- Every choice respects FR-CC-10 (no-fallback): hand-rolled config validation throws on bad values; the AI SDK surfaces credential errors as exceptions (which `convo-coach` maps to exit 78); duration parsing throws on malformed input.

### Conditions under which the recommendation would change

- If Vercel AI SDK v5 turns out to drop a provider's streaming-usage hook between minor versions during implementation (unlikely but possible), fall back to per-SDK clients for the affected provider.
- If the project later adopts a strict "zero npm runtime dependencies" rule for **all** TS tools (currently it's a strong preference, not a rule), Option 1E (per-provider SDKs hand-wired) becomes the only legal option and the implementation cost rises ~5x.

---

## Technical Research Guidance

**Research needed**: Yes — narrow scope, ahead of the planner finalising the provider abstraction.

### Topic 1: Vercel AI SDK v5 streaming-event API

- **Why**: The investigation confirmed the high-level pattern (`streamText` → `textStream` async-iterable + `usage` promise) but the implementation will need exact event names and error shapes per provider. Specifically, the implementer must verify that `result.textStream` emits **only text deltas** (not tool calls, not reasoning tokens) by default, and that `result.usage` resolves with `{ inputTokens, outputTokens, totalTokens }` consistently across all 5 providers we use.
- **Focus**: streaming-text iteration; usage-promise shape; error-event handling (network drop mid-stream); how to gracefully handle a provider returning a non-streaming response (Anthropic in some configs).
- **Depth**: Intermediate — read the AI SDK v5 `streamText` reference + the per-provider provider docs (OpenAI, Anthropic, Google, Azure, OpenAI-compatible).
- **Relevance**: Drives the exact shape of `src/providers/factory.ts` and the streaming loop in `src/cli.ts`.

### Topic 2: Azure OpenAI deployment-name semantics under AI SDK

- **Why**: Azure OpenAI is unique among the eight — `--model` doesn't map to a vendor model id, it maps to a **deployment name** the user provisioned in the Azure portal. The AI SDK's `@ai-sdk/azure` package needs `resourceName`, `apiKey`, optionally `apiVersion`, and the deployment is selected via `azure(deploymentName)`. The implementer must confirm whether `AZURE_OPENAI_ENDPOINT` is the resource URL or the full chat-completions URL, and which fields populate `apiVersion`.
- **Focus**: env-var → `createAzure()` argument mapping; whether `azure-ai-inference` (Foundry) is also handled by `@ai-sdk/azure` or needs `@ai-sdk/openai-compatible` with a manual base URL.
- **Depth**: Intermediate.
- **Relevance**: Decides whether the eight providers are 5+3 (AI SDK native + OpenAI-compatible) or 4+4.

### Topic 3: Ollama base-URL config + LiteLLM proxy auth header under `@ai-sdk/openai-compatible`

- **Why**: Both providers are reached via the OpenAI-compatible adapter but each needs a different `Authorization` header (Ollama: none by default; LiteLLM: `Bearer ${LITELLM_MASTER_KEY}`). The implementer must verify Ollama's chat-completions endpoint is at `${OLLAMA_HOST}/v1/chat/completions` and that streaming SSE works through the adapter.
- **Focus**: `createOpenAICompatible({ baseURL, headers })` shape; SSE event format compatibility; usage-token reporting (Ollama may not report tokens at all → need a graceful "usage unavailable" path in the sidecar Metrics block).
- **Depth**: Overview — a 30-minute spike against a local Ollama server is sufficient.
- **Relevance**: Confirms the simplest possible glue code for providers 6/7/8.

### Topics NOT requiring further research

- The merger config-resolver pattern (already read, already in repo).
- The macrec JSONL schema (already documented in `docs/tools/macrec.md` and the codebase scan).
- Hand-rolled CLI parsing (already implemented in the merger).
- Duration regex (trivial).
- `/dev/tty` trick (well-documented Node pattern).
- Tokenizer choice (`js-tiktoken` is well-known).
- Default model ids (covered above, sourced from authoritative model lists).
- Sidecar-collision algorithm (trivial).

---

## Implementation Considerations

### Decisions still to be made (by planner / designer)

1. **Pin exact AI SDK versions** — the implementer should pin `ai`, `@ai-sdk/openai`, `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/azure`, `@ai-sdk/openai-compatible` to exact patch versions and lock them via `package-lock.json`. Document the pinned set in `docs/tools/convo-coach.md`.
2. **System prompt wording** (OD-1) — the refined request gives an indicative draft; the designer finalises and stores in `src/prompts/default-system-prompt.ts`.
3. **`tiktoken` encoding selection per OpenAI model** — a small lookup table mapping model id → encoding name (`o200k_base` for `gpt-4o*`, `cl100k_base` for `gpt-4`/`gpt-3.5`). Lives in `src/providers/openai-tokenizer.ts`.

### Dependencies / prerequisites

- Node ≥20 (matches merger).
- `npm install` adds ~3 MB of `@ai-sdk/*` packages — the only material runtime dep increase from the merger's zero-dep baseline. Document explicitly in `docs/tools/convo-coach.md`.
- `/tool-conventions scaffold convo-coach` MUST be run **before** the implementation begins (per C-2). It produces `docs/tools/convo-coach.md` skeleton and `~/.tool-agents/convo-coach/.env` with all eight provider env-var groups commented out.

### Potential pitfalls

1. **AI SDK provider packages change between minor versions.** Pin exact versions; bump deliberately.
2. **`textStream` drops empty deltas** — fine, but ensure the sidecar writer doesn't swallow newlines because the SDK splits at token boundaries. Use `process.stdout.write(delta)` and `sidecarStream.write(delta)` exactly as received.
3. **Stdout buffering** — `process.stdout` is line-buffered when not connected to a TTY. Use `process.stdout.write()` directly (not `console.log`) and don't `\n`-buffer. The AI SDK's deltas already arrive sub-token, so this should already work — verify in an integration test.
4. **`/dev/tty` and detached shells** — under `nohup`, `screen`, `tmux` detached, or background `&`, `/dev/tty` may not be writeable. The fallback to `--debounce` handles this; integration test should cover at least one of these cases.
5. **`js-tiktoken` cold-start cost** — first call loads the encoding (~50 ms). Negligible for a CLI invocation, but if the provider isn't OpenAI-family, don't load the tokenizer at all.
6. **Sidecar created at request start, finalised at stream end** (FR-CC-11) — if the LLM request fails before the first token, the sidecar still exists with the YAML front-matter and an `# ERROR` footer. Tests should cover this path explicitly (AC-CC-2 + an error variant).

### Suggested first steps for the implementer

1. **Run** `/tool-conventions scaffold convo-coach` — produces the docs file and the `.env` template.
2. **Copy** `tools/dual-transcript-merger/{package.json,tsconfig.json}` to `tools/convo-coach/`, change `name`, `bin` key, `description`. Add `dependencies` block with the five AI SDK packages.
3. **Port** `config.ts` first — it's the foundation everything else builds on. Write its tests against the eight provider env-var keys + `MACREC_RECORDINGS_DIR`.
4. **Build** the JSONL/TXT/SRT/VTT parser next, copying the merger's `parseStream` pattern.
5. **Build** the windowing function (`--last`, `--since`).
6. **Build** the provider factory + the `streamText` loop.
7. **Wire** the CLI; run AC-CC-1 (`npm install && npm link && convo-coach --help`).
8. **Add** the `/dev/tty` + debounce logic last — it's the most complex and least foundational.

---

## References

| # | Source | URL | What was learned |
|---|---|---|---|
| 1 | Refined request | `docs/design/refined-request-convo-coach.md` | 16 acceptance criteria, 15 functional requirements, 8 NFRs, 8 open decisions with default recommendations. |
| 2 | Codebase scan | `docs/reference/codebase-scan-convo-coach.md` | `MACREC_RECORDINGS_DIR` is convo-coach-owned, not macrec-native; merger is the canonical TS precedent; eight providers are greenfield. |
| 3 | Merger CLI source | `tools/dual-transcript-merger/src/cli.ts` | Hand-rolled parseArgs pattern (lines 84-157); bootstrap mkdir 0700 (lines 167-176). |
| 4 | Merger config source | `tools/dual-transcript-merger/src/config.ts` | Four-tier resolver with provenance tracking and strict per-tier validation (lines 53-153). |
| 5 | macrec sidecar schema | `docs/tools/macrec.md` §"Sidecar conventions" + §DT-7 | Single-channel JSONL fields; dual-channel `channel: "A" \| "B"` extension. |
| 6 | dual-transcript-merger schema | `docs/tools/dual-transcript-merger.md` | Wire shape the merger sees; serves as the canonical reference for parsing. |
| 7 | Vercel AI SDK Anthropic provider docs | https://github.com/vercel/ai/blob/main/content/providers/01-ai-sdk-providers/05-anthropic.mdx | `streamText` API shape, `providerOptions.anthropic` knobs. |
| 8 | Vercel AI SDK NIM example | https://github.com/vercel/ai/blob/main/content/providers/02-openai-compatible-providers/35-nim.mdx | `createOpenAICompatible({ baseURL, headers })` pattern reusable for Ollama / LiteLLM / MLX. |
| 9 | Vercel AI SDK token-usage cookbook | https://github.com/vercel/ai/blob/main/content/cookbook/05-node/45-stream-object-record-token-usage.mdx | `result.usage` Promise shape with `inputTokens`, `outputTokens`, `totalTokens`. |
| 10 | Vercel AI SDK multi-modal chatbot guide | https://github.com/vercel/ai/blob/main/content/cookbook/00-guides/02-multi-modal-chatbot.mdx | Provider switching pattern: same `streamText` call, swap the `model` factory. |
| 11 | Anthropic model id list | system-prompt note | `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001` are the latest 4.x family. |
| 12 | Project CLAUDE.md (recording-tool) | `CLAUDE.md` | Exception 001 (Swift scope), Exception 002 (macOS 26), Tools section conventions, `/tool-conventions scaffold` mandate. |
| 13 | tool-doc-config-architect spec | `~/.claude/agents/tool-doc-config-architect.md` | Authoritative list of eight standard LLM providers and their vendor-canonical env var names. |
| 14 | Bootstrap pattern (Swift) | `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift`, `EnvFileStore.swift` | Reference implementation for the four-tier chain TS port. |

---

## Original Request

The investigation request specified eight focus areas, all addressed above. The refined request file (`docs/design/refined-request-convo-coach.md`) is the authoritative source-of-truth for scope, requirements, constraints, and open decisions; the codebase scan file (`docs/reference/codebase-scan-convo-coach.md`) is the authoritative source for project precedent and integration points.
