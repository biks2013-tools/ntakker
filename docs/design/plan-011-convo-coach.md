# plan-011 — `convo-coach` TypeScript CLI tool

**Type:** new feature plan (greenfield TypeScript package).
**Date:** 2026-05-02.
**Scope:** new `tools/convo-coach/` package; project-doc updates (`CLAUDE.md`,
`docs/design/project-design.md`, `docs/design/project-functions.md`); scaffolded
`docs/tools/convo-coach.md` and `~/.tool-agents/convo-coach/` via
`/tool-conventions scaffold convo-coach`.
**Cross-references:**
- Refined request: `docs/design/refined-request-convo-coach.md`
  (16 ACs / 15 FRs / 8 NFRs / 8 ODs).
- Investigation: `docs/reference/investigation-convo-coach.md` (recommends
  Vercel AI SDK + hand-rolled CLI parser + ports of dual-transcript-merger
  patterns).
- Codebase scan: `docs/reference/codebase-scan-convo-coach.md` (canonical TS
  precedent in `tools/dual-transcript-merger/`; `MACREC_RECORDINGS_DIR` is
  convo-coach-owned, NOT macrec-native).
- Technical reference: `docs/research/vercel-ai-sdk-v5-multiprovider.md`
  (eight-provider matrix, `streamText` API surface, gotchas).
- Workflow checkpoint: `docs/reference/workflow-checkpoint.json`
  (`decisions_baked_in_for_planner` — apply directly, do not re-litigate).
- Precedent: `tools/dual-transcript-merger/{package.json,tsconfig.json,src/*}`.

---

## 0. Pre-baked decisions (from the workflow checkpoint — applied verbatim)

These are NOT re-debated by this plan. They are inputs.

| # | Decision |
|---|---|
| D1 | Use Vercel AI SDK with `ai@^6` (latest stable). Use `textStream` (stable across v5/v6) for token streaming. `await result.usage` after the loop for metrics. |
| D2 | Two Azure providers: `@ai-sdk/azure` (deployment-name based) + `@ai-sdk/openai-compatible` for Azure AI Inference / Foundry (URL-based, `/openai/v1` path). NO `@ai-sdk/azure-inference` package exists. |
| D3 | Three providers route through `@ai-sdk/openai-compatible`: Ollama (apiKey placeholder `"ollama"`), LiteLLM, MLX-LM. Only differences are baseURL / apiKey / default-model. |
| D4 | Default model IDs: `gpt-4o-mini`, `claude-haiku-4-5-20251001`, `gemini-2.5-flash`, `llama3.1:8b`. Azure OpenAI default = `${AZURE_OPENAI_DEPLOYMENT}`. Azure AI Inference default = `claude-haiku-4-5`. LiteLLM and MLX have no default — `--model` required. |
| D5 | Config resolver reads spec env-var names (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, …) and passes explicitly to provider constructors. Does NOT rely on SDK auto-read (`AZURE_RESOURCE_NAME`, `AZURE_API_KEY`). |
| D6 | `GEMINI_API_KEY` accepted as a fallback alias for `GOOGLE_API_KEY`. |
| D7 | `convo-coach` owns `MACREC_RECORDINGS_DIR` (it is NOT a macrec env var). Default `~/Recordings` when absent. This default is a directory, not a credential — does not violate the no-fallback rule. |
| D8 | Test framework: `node --test --import tsx test/*.test.ts` (mirrors dual-transcript-merger). |
| D9 | CLI parser: hand-rolled `parseArgs`, mirror `tools/dual-transcript-merger/src/cli.ts`. |
| D10 | Token-budget guard: `js-tiktoken` for OpenAI-family models, 4-chars-per-token heuristic everywhere else, truncate-start by default. |

---

## 0.5 Open items to confirm with the user post-plan (NOT blockers)

These are surfaced explicitly per the planner's instructions. They have
recommended defaults (already in the plan); the user should accept or veto
before Phase 6 (Coders) starts.

| ID | Question | Recommended default |
|---|---|---|
| OI-A | Ship `--system-prompt <path>` override in v1? | **YES** (per FR-CC-12 / OD-6). The cost is trivial (read a file, pass as `system`). Several plausible coach personas (sales, technical-interview, translation) only become possible with this. |
| OI-B | Bundle the default system prompt as `prompt/default-system-prompt.md` (file resource) or hard-code it as a string constant in `prompt/build.ts`? | **String constant in `prompt/build.ts`**. The file route requires `fs.readFile` at startup with a path resolved relative to `import.meta.url`, which complicates bundled-binary distribution and `npm link` resolution. A constant is simpler, faster, and avoids one runtime I/O. The file-override path (OI-A) only loads from disk when the user explicitly passes `--system-prompt`. |
| OI-C | Sidecar YAML front-matter — include run metadata? | **YES** (per FR-CC-11 / OD-7). Provider, model, transcript source, window, segments, dropped, TTFT, elapsed, input/output tokens. Trivial cost; massively eases post-hoc analysis ("which Haiku run was that?") and is necessary for AC-CC-13's `droppedSegments: <n>` assertion. |

If the user vetoes any of these, the affected unit reduces in scope but the
overall phase structure and dependencies do not change.

---

## 1. Goal

Deliver a TypeScript CLI tool `convo-coach` under `tools/convo-coach/` that:

1. Reads a `macrec` transcript via three input modes (stdin > `--transcript` >
   auto-detect), supporting JSONL (single + dual channel), TXT, SRT, VTT.
2. Slices a recent conversation window via `--last <duration>` and/or
   `--since <timestamp>`; "later boundary wins" when both are given.
3. Builds a prompt from a built-in default system message (overridable via
   `--system-prompt <path>`) plus the channel-tagged windowed transcript.
4. Calls one of eight standard LLM providers via the Vercel AI SDK
   (`streamText` + `textStream`), defaulting to per-provider model IDs.
5. Streams tokens to `stdout` AND simultaneously appends them to a markdown
   sidecar `<basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source
   transcript, with YAML front-matter and a Metrics block.
6. Resolves configuration through the project's four-tier chain (shell env →
   `~/.tool-agents/convo-coach/.env` → `./.env` → CLI flags), uses
   vendor-canonical env-var names, and raises typed errors (no fallback) for
   missing credentials / endpoints / required deployments.
7. Is installable as a direct command via `npm install && npm link`, so
   `convo-coach --help` works from any directory.

The plan satisfies all 16 acceptance criteria (AC-CC-1 .. AC-CC-16) and all
15 functional requirements (FR-CC-1 .. FR-CC-15) from the refined request.

---

## 2. Risks and mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | AI SDK v5 vs v6 `fullStream` field naming (`textDelta` vs `delta`) drift breaks streaming. | Medium | High | Use `result.textStream` (plain async iterable of strings, stable across v5/v6 per `docs/research/vercel-ai-sdk-v5-multiprovider.md` §1.2). Avoid `fullStream` entirely in v1. Pin `ai` and all `@ai-sdk/*` packages to exact patch versions in `package.json`; commit `package-lock.json`. |
| R2 | Azure OpenAI deployment-name vs model-name confusion logs misleading model labels. | High | Low | The factory passes `AZURE_OPENAI_DEPLOYMENT` to the SDK as the deployment id; the sidecar Metrics block records `model: "<deployment-name>"`. Documentation in `docs/tools/convo-coach.md` MUST explicitly state: "for `azure-openai`, `--model` overrides the deployment name shown in the sidecar; the actual underlying OpenAI model is determined by what was provisioned in the Azure portal." |
| R3 | Azure AI Inference (Foundry) endpoint URL has trailing slash → `${endpoint}/openai/v1` becomes `…//openai/v1`, some reverse proxies 404. | Medium | Medium | Config resolver strips trailing slashes from `AZURE_AI_INFERENCE_ENDPOINT`, `LITELLM_PROXY_URL`, `OLLAMA_HOST`, `OPENAI_BASE_URL` at the validation step (per `docs/research/vercel-ai-sdk-v5-multiprovider.md` §6 gotcha #3 + #4). |
| R4 | Token usage counts return `undefined` or `NaN` from some providers (Azure OpenAI NaN bug; Ollama may not report). | High | Low | Always guard `usage.inputTokens ?? undefined` in the sidecar Metrics writer. When both counts are absent, write `Input tokens: N/A` rather than crashing. Log a `debug` warning to stderr. |
| R5 | `/dev/tty` is unavailable in detached / containerised / `nohup`'d shells; Enter-trigger never fires. | Medium | Medium | Wrap `openSync('/dev/tty', 'r')` in try/catch (ENXIO, ENOENT). On failure, fall back to `--debounce <duration>` mode (default `15s` of stdin silence triggers a request). EOF always emits one final request unless the last trigger was within ~1s. Document the caveat in `--help`. |
| R6 | Sidecar created at request start, but the LLM request fails before any token arrives → empty file. | Low | Medium | Sidecar writer pre-writes the YAML front-matter + Metrics-block placeholder synchronously at request start. On stream error, append `# ERROR\n\n<message>\n` footer and `end()` the stream. Exit code 70. Sidecar is preserved for debugging. |
| R7 | Stdout is line-buffered when not attached to a TTY (e.g. piping `convo-coach > advice.txt`); tokens visible only at line ends. | Medium | Low | Use `process.stdout.write(delta)` directly, not `console.log`. The AI SDK's `textStream` chunks are sub-line; explicit `write` calls bypass `console`'s line-buffering layer. Verified by the integration test for AC-CC-15 (lock-step diff vs sidecar). |
| R8 | `js-tiktoken` cold-start (~50 ms for first call) adds latency for non-OpenAI providers. | Low | Low | Lazy-require: only `import('js-tiktoken')` inside the OpenAI-family branch of the budget guard. Non-OpenAI providers (Anthropic, Gemini, Ollama, MLX in non-OpenAI mode) never load it. |
| R9 | Dual-channel JSONL `isFinal` field (mentioned in the docs example) is not in the actual `TranscriptSegment` Swift struct — parser may reject. | Low | Low | Parser MUST treat unknown JSON keys as `extras: Record<string, unknown>` (mirror `tools/dual-transcript-merger/src/parser.ts` line 23-32 pattern). Tombstone lines (`{"_tombstone":true,"id":…}`) MUST be skipped silently. |
| R10 | New `npm` runtime dependencies (~3 MB of `@ai-sdk/*` packages) deviate from the merger's zero-dep baseline. | Accepted | Low | Justified explicitly in `docs/tools/convo-coach.md` and `docs/design/project-design.md`. The alternative — eight bespoke SSE parsers, four official SDKs + four hand-rolled clients — is 5× the code with no offsetting benefit (per `docs/reference/investigation-convo-coach.md` §Q1 verdict). Pin exact versions; commit `package-lock.json`. |
| R11 | `npm link` global install conflicts with an existing `convo-coach` binary on `PATH`. | Low | Low | The package name is unique to the project; collision is unlikely. Documented in `docs/tools/convo-coach.md` Installation section: "If you already have a global `convo-coach` package, `npm unlink -g convo-coach` first." |
| R12 | Auto-detect picks the wrong sidecar when multiple recordings have the same basename in different formats (e.g. `talk.transcript.jsonl` + `talk.transcript.txt`). | Medium | Low | Per OD-8: prefer JSONL when multiple formats with the same basename exist (it preserves channel/language metadata). Within a single format, sort by `mtime` descending and pick the newest. |

---

## 3. Architecture overview

```
tools/convo-coach/
├── package.json                  ← name:"convo-coach", bin:{convo-coach:"./dist/cli.js"},
│                                   type:"module", engines.node:">=20",
│                                   dependencies:{ai,@ai-sdk/openai,@ai-sdk/anthropic,
│                                   @ai-sdk/google,@ai-sdk/azure,@ai-sdk/openai-compatible,
│                                   js-tiktoken}, devDependencies same as merger.
├── tsconfig.json                 ← copy from merger verbatim.
├── .gitignore                    ← node_modules/, dist/, *.log, .env
├── README.md                     ← terse pointer to docs/tools/convo-coach.md
├── src/
│   ├── cli.ts                    ← #!/usr/bin/env node — hand-rolled parseArgs,
│   │                                top-level orchestration, exit-code mapping.
│   ├── index.ts                  ← run() entry consumed by cli.ts; testable.
│   ├── config.ts                 ← four-tier resolver (port of merger config.ts).
│   ├── errors.ts                 ← typed ConvoCoachError + exit-code mapping.
│   ├── log.ts                    ← {quiet,info,debug} → stderr writer; redacts secrets.
│   ├── transcript/
│   │   ├── reader.ts             ← orchestrates which mode (file/stdin/auto) to use.
│   │   ├── jsonl.ts              ← parseLine + parseStream (mirrors merger/parser.ts).
│   │   ├── txt.ts                ← `[HH:MM:SS.mmm] [LANG?] text` parser.
│   │   ├── srt.ts                ← SRT cue parser; channel from `EN: ` prefix.
│   │   ├── vtt.ts                ← VTT cue parser; channel from `<v EN>...</v>`.
│   │   ├── duration.ts           ← parseDuration (regex `^(\d+h)?(\d+m)?(\d+s)?$`).
│   │   ├── window.ts             ← --last / --since slicer; "later boundary" rule.
│   │   ├── autodetect.ts         ← discover newest *.transcript.* in MACREC_RECORDINGS_DIR.
│   │   ├── stdin.ts              ← line-by-line stdin + /dev/tty Enter trigger + debounce.
│   │   └── types.ts              ← TranscriptSegment, Window, NormalisedRecord.
│   ├── llm/
│   │   ├── factory.ts            ← createProviderModel(provider, modelId, cfg).
│   │   ├── providers/
│   │   │   ├── openai.ts         ← createOpenAI(...).
│   │   │   ├── anthropic.ts      ← createAnthropic(...).
│   │   │   ├── google.ts         ← createGoogleGenerativeAI(...).
│   │   │   ├── azure-openai.ts   ← createAzure(...) + deriveResourceName().
│   │   │   ├── azure-ai-inference.ts ← createOpenAICompatible({…/openai/v1}).
│   │   │   ├── ollama.ts         ← createOpenAICompatible({apiKey:'ollama',…/v1}).
│   │   │   ├── litellm.ts        ← createOpenAICompatible({apiKey:LITELLM_MASTER_KEY,…}).
│   │   │   └── mlx.ts            ← createOpenAICompatible({apiKey:'mlx',…}).
│   │   ├── default-models.ts     ← per-provider DEFAULT_MODEL_IDS lookup.
│   │   ├── budget.ts             ← prompt token estimation + truncate-start/end/error.
│   │   └── model-context-windows.ts ← static map of model id → context window.
│   ├── prompt/
│   │   └── build.ts              ← buildSystemPrompt() + buildUserMessage(segments).
│   │                                Default system prompt is a string constant inside
│   │                                this file (see OI-B). --system-prompt overrides it.
│   └── output/
│       ├── stream.ts             ← run streamText loop; write to stdout + sidecar in lockstep.
│       └── sidecar.ts            ← uniqueSidecarPath(); openSidecar(); writeFrontMatter();
│                                    finaliseMetrics(); writeErrorFooter().
├── test/                         ← node --test --import tsx test/*.test.ts
│   ├── config.test.ts            ← four-tier resolver, no-fallback assertions.
│   ├── duration.test.ts          ← parseDuration grammar.
│   ├── window.test.ts            ← --last / --since / later-boundary.
│   ├── jsonl.test.ts             ← single + dual channel parsing, _tombstone skip,
│   │                                unknown extras preservation.
│   ├── txt.test.ts               ← TXT parsing.
│   ├── srt.test.ts               ← SRT parsing + channel-prefix extraction.
│   ├── vtt.test.ts               ← VTT parsing + voice-tag extraction.
│   ├── autodetect.test.ts        ← newest mtime, JSONL preferred, missing-dir error.
│   ├── stdin.test.ts             ← /dev/tty trigger (mocked), debounce fallback.
│   ├── budget.test.ts            ← truncate-start drops oldest; error mode exits.
│   ├── factory.test.ts           ← all 8 providers wire correctly + error on unknown.
│   ├── prompt.test.ts            ← channel→speaker mapping; --system-prompt override.
│   ├── sidecar.test.ts           ← path naming, collision -<n> suffix, front matter.
│   ├── stream.test.ts            ← stream loop with mocked LanguageModel.
│   ├── logging.test.ts           ← API keys never leaked at any log level.
│   └── e2e.test.ts               ← end-to-end with mocked SDK; covers every AC-CC-N.
└── fixtures/                     ← test data (not committed as src; under test/)
    ├── single-channel.transcript.jsonl
    ├── dual-channel.transcript.jsonl
    ├── plain.transcript.txt
    ├── plain.transcript.srt
    ├── plain.transcript.vtt
    └── system-prompts/coach.md
```

`docs/tools/convo-coach.md` and `~/.tool-agents/convo-coach/{,.env}` are NOT
hand-rolled — the `/tool-conventions scaffold convo-coach` slash command
produces them in U10.

---

## 4. Phase plan

The work is partitioned into **eleven implementation units** (U1..U11),
grouped into eight execution phases. Phases are sequential; within a phase,
units may run in parallel by independent coder agents.

### Dependency graph

```
                                 [U1: skeleton]
                                       │
                                  [U2: config]
                          ┌────────────┼────────────┐
                          ▼            ▼            ▼
                   [U4: transcript] [U6: LLM    [U8: prompt]
                          │         factory]         │
                          ▼            │             │
                   [U5: stdin/        ▼             ▼
                    autodetect]   [U9: budget]      │
                          │            │             │
                          └────────────┼─────────────┘
                                       ▼
                                [U7: stream/sidecar]
                                       │
                                  [U3: CLI/main]
                                       │
                                  [U10: docs]
                                       │
                                  [U11: tests]
```

### Phase mapping

| Phase | Name | Units | Parallelism |
|---|---|---|---|
| **P0** | Pre-flight scaffold | `/tool-conventions scaffold convo-coach` (out-of-band; NOT a coder unit) | sequential, must run first |
| **P1** | Skeleton | U1 | single agent |
| **P2** | Config foundation | U2 | single agent (everything else depends on it) |
| **P3** | Parallel core | U4, U6, U8, U9 | **4 coder agents in parallel** |
| **P4** | Stdin / auto-detect | U5 | single agent (depends on U4) |
| **P5** | Streaming + sidecar | U7 | single agent (depends on U2, U6, U8, U9) |
| **P6** | CLI orchestration | U3 | single agent (depends on all of U2..U9) |
| **P7** | Documentation | U10 (post-scaffold finalisation) | single agent |
| **P8** | Tests | U11 | parallel by file (test runner) |

> **Note on U10:** the `/tool-conventions scaffold convo-coach` slash command
> in P0 produces the *initial* `docs/tools/convo-coach.md` skeleton and
> `~/.tool-agents/convo-coach/.env` template. U10 in P7 is the
> *finalisation* pass that fills in the doc body now that the implementation
> is complete (CLI flag table, env-var table with verified default model
> IDs, examples, troubleshooting). U10 also updates project-level docs.

---

## 5. Implementation units (detailed)

### U1 — Project skeleton

**Phase:** P1. **Sequential, blocking.**

#### Files

- `tools/convo-coach/package.json` (NEW)
- `tools/convo-coach/tsconfig.json` (NEW; copy verbatim from merger)
- `tools/convo-coach/.gitignore` (NEW)
- `tools/convo-coach/README.md` (NEW; one-paragraph pointer to
  `docs/tools/convo-coach.md`)

#### `package.json` shape

```jsonc
{
  "name": "convo-coach",
  "version": "0.1.0",
  "description": "LLM-powered conversational coach for macrec transcripts.",
  "type": "module",
  "bin": { "convo-coach": "./dist/cli.js" },
  "scripts": {
    "build":     "tsc -p tsconfig.json",
    "postbuild": "chmod +x dist/cli.js",
    "watch":     "tsc -p tsconfig.json --watch",
    "start":     "node dist/cli.js",
    "test":      "node --test --import tsx test/*.test.ts",
    "clean":     "rm -rf dist",
    "prepare":   "tsc -p tsconfig.json && chmod +x dist/cli.js"
  },
  "engines": { "node": ">=20" },
  "dependencies": {
    "ai":                            "^6.0.0",
    "@ai-sdk/openai":                "^3.0.55",
    "@ai-sdk/anthropic":             "^3.0.74",
    "@ai-sdk/google":                "^3.0.64",
    "@ai-sdk/azure":                 "^3.0.59",
    "@ai-sdk/openai-compatible":     "^2.0.41",
    "js-tiktoken":                   "^1.0.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "tsx":         "^4.19.0",
    "typescript":  "^5.6.0"
  }
}
```

> **Pinning policy:** caret ranges as above for Phase 8 (Dependency Validator)
> to do an `npm install` and observe what was actually pulled, then convert
> to exact versions and commit `package-lock.json`. Per R10.

#### `tsconfig.json`

Copy verbatim from `tools/dual-transcript-merger/tsconfig.json` (per
codebase scan §3 conventions): `target:"ES2022"`, `module:"ES2022"`,
`moduleResolution:"Bundler"`, `strict:true`, `noUncheckedIndexedAccess:true`,
`noImplicitOverride:true`, `noFallthroughCasesInSwitch:true`,
`esModuleInterop:true`, `forceConsistentCasingInFileNames:true`,
`skipLibCheck:true`, `declaration:true`, `sourceMap:true`,
`resolveJsonModule:true`, `outDir:"./dist"`, `rootDir:"./src"`.

#### `.gitignore`

```
node_modules/
dist/
*.log
.env
```

#### Acceptance criteria satisfied

- AC-CC-1 (foundation: package can be installed and linked).
- FR-CC-1, FR-CC-2 (location, ESM, Node ≥20, bin mapping, prepare/postbuild).

---

### U2 — Config layering (four-tier chain)

**Phase:** P2. **Sequential, blocks P3..P8.**

#### Files

- `tools/convo-coach/src/config.ts` (NEW)
- `tools/convo-coach/src/errors.ts` (NEW)
- `tools/convo-coach/src/log.ts` (NEW)

#### Behaviour

Port `tools/dual-transcript-merger/src/config.ts` (lines 53-153) verbatim,
parameterising:

- Tool name: `"convo-coach"` (used to derive `~/.tool-agents/convo-coach/.env`).
- Key list: see table below.
- The dotenv parser: same hand-rolled `parseDotEnv()` (lines 53-65 of merger
  config); no `dotenv` package dependency.

#### Resolution order (lowest → highest)

1. `process.env`
2. `~/.tool-agents/convo-coach/.env` (created with mode `0700` if absent;
   the file itself is seeded by `/tool-conventions scaffold` with mode
   `0600`).
3. `<cwd>/.env`
4. CLI flags (applied in `src/cli.ts`, not `src/config.ts`).

The `ResolvedConfig` returned by `resolveDefaults()` carries a `provenance`
map (`Record<string, "process.env" | "~/.tool-agents/convo-coach/.env" | "./.env" | "cli">`)
for the `--show-config` debug output and for the FR-CC-10 error message
("checked: process.env, ~/.tool-agents/convo-coach/.env, ./.env, CLI").

#### Recognised keys

| Key | Required for | Optional? | Notes |
|---|---|---|---|
| `OPENAI_API_KEY` | `openai`, `mlx` (when `OPENAI_BASE_URL` is unset) | Yes if other provider | Vendor-canonical. |
| `OPENAI_BASE_URL` | `mlx` | Yes | Strip trailing slash at validation. |
| `OPENAI_ORG_ID` | — | Yes | OpenAI organization. |
| `ANTHROPIC_API_KEY` | `anthropic` | Yes if other provider | |
| `ANTHROPIC_BASE_URL` | — | Yes | Strip trailing slash. |
| `GOOGLE_API_KEY` | `gemini` | Yes if other provider | `GEMINI_API_KEY` accepted as alias (D6) — if `GOOGLE_API_KEY` is absent and `GEMINI_API_KEY` is set, the resolver copies the value into the `GOOGLE_API_KEY` slot with provenance noting the alias. |
| `GEMINI_API_KEY` | (alias) | Yes | See above. |
| `AZURE_OPENAI_API_KEY` | `azure-openai` | Yes if other provider | |
| `AZURE_OPENAI_ENDPOINT` | `azure-openai` | Yes if other provider | Full URL `https://my-resource.openai.azure.com`. Strip trailing slash. Resource name is derived as `new URL(endpoint).hostname.split('.')[0]`. |
| `AZURE_OPENAI_DEPLOYMENT` | `azure-openai` | Yes if other provider | The default model name when `--model` is not passed. |
| `AZURE_OPENAI_API_VERSION` | — | Yes | Default `v1`. |
| `AZURE_AI_INFERENCE_KEY` | `azure-ai-inference` | Yes if other provider | |
| `AZURE_AI_INFERENCE_ENDPOINT` | `azure-ai-inference` | Yes if other provider | Strip trailing slash; factory appends `/openai/v1`. |
| `OLLAMA_HOST` | `ollama` | Yes if other provider | Default `http://127.0.0.1:11434` is **not** auto-applied (no fallback rule). User must set it explicitly when selecting `--provider ollama`. |
| `LITELLM_PROXY_URL` | `litellm` | Yes if other provider | Strip trailing slash. |
| `LITELLM_MASTER_KEY` | `litellm` | Yes if other provider | |
| `MACREC_RECORDINGS_DIR` | auto-detect mode | Yes | **Owned by convo-coach (D7)**. Default `path.join(homedir(), 'Recordings')` — directory location, not credential, so the default is allowed per FR-CC-10's last paragraph. |
| `CONVO_COACH_PROVIDER` | resolves `--provider` | Yes | One of the eight valid names; rejected with exit 64 otherwise. |
| `CONVO_COACH_MODEL` | resolves `--model` | Yes | Free-form string; provider factory validates indirectly. |
| `CONVO_COACH_LOG_LEVEL` | resolves `--log-level` | Yes | `quiet|info|debug`; default `info`. |
| `CONVO_COACH_DEBOUNCE` | resolves `--debounce` | Yes | Duration string; default `15s`. |

#### `errors.ts`

Typed error class with code → exit-code mapping (per FR-CC-14):

```typescript
export type ConvoCoachErrorCode =
  | 'BAD_USAGE'              // exit 64
  | 'NO_INPUT'               // exit 66
  | 'PROVIDER_FAILURE'       // exit 70
  | 'MISSING_CONFIG'         // exit 78
  | 'GENERIC';               // exit 1

export class ConvoCoachError extends Error {
  constructor(
    public readonly code: ConvoCoachErrorCode,
    message: string,
    public readonly details?: Record<string, unknown>,
  ) { super(message); }
}

export const EXIT_CODES: Record<ConvoCoachErrorCode, number> = {
  BAD_USAGE: 64, NO_INPUT: 66, PROVIDER_FAILURE: 70, MISSING_CONFIG: 78,
  GENERIC: 1,
};
```

#### `log.ts`

`{ quiet, info, debug }` levels writing to `stderr`. Includes a
`redactSecrets(line: string): string` filter that scans for any value
present in `cfg.provenance` whose key matches one of the credential env-var
names (`*_API_KEY`, `*_KEY`, `*_MASTER_KEY`, `*_TOKEN`) and replaces it with
`<REDACTED:KEY_NAME>`. Used to satisfy NFR-CC-6 / AC-CC-16.

#### Acceptance criteria satisfied

- AC-CC-4 (missing config → exit 78 + named env-var + tier list).
- AC-CC-5 (CLI flags override env vars).
- AC-CC-12 (four-tier chain order).
- AC-CC-16 (secret hygiene — secrets never appear in any log line).
- FR-CC-9, FR-CC-10, FR-CC-14, NFR-CC-6.

---

### U3 — CLI parser + main entry

**Phase:** P6. **Sequential, depends on U2 + all of U4..U9.**

#### Files

- `tools/convo-coach/src/cli.ts` (NEW)
- `tools/convo-coach/src/index.ts` (NEW)

#### `cli.ts`

- `#!/usr/bin/env node` shebang on line 1.
- Hand-rolled `parseArgs(argv)` mirroring
  `tools/dual-transcript-merger/src/cli.ts:84-157`.
- Bootstrap step: ensure `~/.tool-agents/convo-coach/` exists with mode `0700`
  (mirrors merger `cli.ts:167-176`). The `.env` file inside is seeded by
  `/tool-conventions scaffold`, NOT by this code.
- Top-level try/catch maps every `ConvoCoachError` to its exit code via
  `EXIT_CODES`; unknown exceptions exit 1 after logging to stderr.

#### Flags

| Flag | Type | Resolved env | Default | Notes |
|---|---|---|---|---|
| `--provider <name>` | enum | `CONVO_COACH_PROVIDER` | none (required) | One of the eight provider names. Unknown → exit 64. |
| `--model <id>` | string | `CONVO_COACH_MODEL` | per-provider (D4) | Required for `litellm`, `mlx`. |
| `--transcript <path>` | path | — | — | Explicit input. |
| `--last <duration>` | string | — | — | E.g. `30s`, `5m`, `1h`, `1h30m`. |
| `--since <timestamp>` | string | — | — | `HH:MM:SS[.mmm]`, ISO-8601, or `+MM:SS` / `+HH:MM:SS`. |
| `--debounce <duration>` | string | `CONVO_COACH_DEBOUNCE` | `15s` | Stdin fallback trigger. |
| `--system-prompt <path>` | path | — | built-in | OI-A. |
| `--language <bcp-47>` | string | — | — | Optional response-language hint. |
| `--advice-out <dir>` | path | — | — | Override sidecar directory (stdin mode). |
| `--advice-basename <stem>` | string | — | `convo-coach-stdin` (stdin mode) | Override sidecar basename. |
| `--on-overflow <strategy>` | enum | — | `truncate-start` | `truncate-start | truncate-end | error`. |
| `--log-level <level>` | enum | `CONVO_COACH_LOG_LEVEL` | `info` | `quiet | info | debug`. |
| `--show-config` | flag | — | false | Print resolved config + provenance to stderr, exit 0. |
| `--help`, `-h` | flag | — | — | Print usage, exit 0. |
| `--version`, `-V` | flag | — | — | Print version (from package.json), exit 0. |

#### Orchestration in `index.ts`

```text
1. parseArgs(argv) → CliArgs
2. resolveDefaults(cliArgs) → ResolvedConfig (U2)
3. Determine input mode (FR-CC-3):
     a. if !process.stdin.isTTY → stdin mode (warn if --transcript also set)
     b. else if cliArgs.transcript → file mode
     c. else → autodetect mode (U5)
4. Open input:
     - stdin mode: drive U5 (stdin reader + /dev/tty or debounce); each
       trigger calls runOnce(...).
     - file/auto modes: read once, call runOnce(...).
5. runOnce(segments, sourcePath, window):
     a. Apply window (U4)
     b. Build prompt (U8)
     c. Estimate tokens; truncate per --on-overflow (U9)
     d. Open sidecar with placeholder front-matter (U7)
     e. Stream LLM (U7)
     f. Finalise sidecar Metrics block (U7)
6. Exit 0.
```

#### Acceptance criteria satisfied

- AC-CC-1 (`--help` works after install + link).
- AC-CC-3 (unknown provider exits 64).
- AC-CC-5 (CLI overrides env).
- AC-CC-8 (stdin precedence over `--transcript`).
- AC-CC-11 (creates `~/.tool-agents/convo-coach/` at mode `0700` on first invocation).
- FR-CC-2, FR-CC-3, FR-CC-8, FR-CC-14.

---

### U4 — Transcript reader (file + parsers + window slicer)

**Phase:** P3. **Parallel** with U6, U8, U9.

#### Files

- `tools/convo-coach/src/transcript/reader.ts` (NEW) — top-level
  `readFromFile(path)` and `readFromStdin(stream)` returning `AsyncIterable<NormalisedRecord>`.
- `tools/convo-coach/src/transcript/jsonl.ts` (NEW) — `parseLine`, `parseStream`
  (mirror merger `parser.ts`). Handles single + dual channel; preserves unknown
  keys in `extras`; skips `_tombstone:true` lines.
- `tools/convo-coach/src/transcript/txt.ts` (NEW) — `[HH:MM:SS.mmm] [LANG?] text`
  regex parser. Cumulative skip-with-summary on bad lines (FR-CC-4 last
  paragraph: ONE warning summarising count, not one per line).
- `tools/convo-coach/src/transcript/srt.ts` (NEW) — SRT cue parser; maps
  `EN: ` / `EL: ` cue prefix to channel labels.
- `tools/convo-coach/src/transcript/vtt.ts` (NEW) — VTT cue parser; extracts
  channel from `<v EN>...</v>` voice tags.
- `tools/convo-coach/src/transcript/duration.ts` (NEW) — `parseDuration`
  (regex `^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$` with at-least-one-group rule).
- `tools/convo-coach/src/transcript/window.ts` (NEW) — `applyWindow(records, window)`,
  `parseSinceTimestamp(input)`, "later boundary wins" combinator.
- `tools/convo-coach/src/transcript/types.ts` (NEW) — shared types.

#### `NormalisedRecord` shape

```typescript
export interface NormalisedRecord {
  startMs: number;            // epoch ms or relative ms; absolute when JSONL has a timestamp
  endMs: number;              // startMs + durationSec * 1000 (or startMs for partials)
  text: string;
  source?: 'system' | 'mic' | 'mixed';
  channel?: 'A' | 'B';        // present only in dual-channel JSONL
  language?: string;          // BCP-47
  model?: string;
  extras: Record<string, unknown>;
}
```

#### Window semantics (FR-CC-5, AC-CC-6)

- `--last <D>` window: `[now - D, now]`.
- `--since <T>` window: `[T, now]`. `T` may be wall-clock (`HH:MM:SS[.mmm]`,
  local TZ), ISO-8601, or relative (`+MM:SS` / `+HH:MM:SS`).
- Both flags: window start = `max(now - D, T)`. Both absent: full transcript.
- `now` for finite files = max `endMs` in the file. For stdin = wall-clock at
  trigger time.

#### Streaming line reader (NFR-CC-2)

`readFromFile` uses `node:fs.createReadStream` + `node:readline` to yield
records one at a time. Memory footprint ≤ a few KB per record regardless of
file size.

#### Acceptance criteria satisfied

- AC-CC-6 (window slicing).
- AC-CC-9 (dual-channel JSONL parsing).
- FR-CC-4, FR-CC-5, NFR-CC-2.

---

### U5 — Auto-detect + stdin modes

**Phase:** P4. **Sequential, depends on U2 (config) + U4 (parsers).**

#### Files

- `tools/convo-coach/src/transcript/autodetect.ts` (NEW)
- `tools/convo-coach/src/transcript/stdin.ts` (NEW)

#### `autodetect.ts`

```typescript
async function findNewestSidecar(recordingsDir: string): Promise<string> {
  // 1. readdir recordingsDir
  // 2. filter to *.transcript.{jsonl,txt,srt,vtt}
  // 3. group by basename (stripping .transcript.<ext>)
  // 4. for each basename: prefer JSONL over others (OD-8)
  // 5. across basenames: pick the one with the newest mtime
  // 6. throw NO_INPUT if none found
}
```

If `MACREC_RECORDINGS_DIR` is not set anywhere in the four-tier chain, raise
`MissingMacrecRecordingsDirError` with `code: 'MISSING_CONFIG'` and exit 78
hint message: "Pass `--transcript <path>` explicitly, or set
`MACREC_RECORDINGS_DIR` in `~/.tool-agents/convo-coach/.env`."
**Wait**: per D7 the default is `~/Recordings`. So this error triggers only
when the resolved path does not exist or is not a directory.

#### `stdin.ts`

Implements the pattern from `docs/reference/investigation-convo-coach.md` §Q5:

1. Open `node:readline` over `process.stdin` line-by-line; push each parsed
   `NormalisedRecord` into an in-memory ring buffer that respects the active
   `--last` / `--since` window.
2. Try to open `/dev/tty` via `fs.openSync('/dev/tty', 'r')`. On success,
   wrap in `readline` and listen for `line` events → each `line` event
   triggers a `runOnce(...)` call.
3. On failure (ENXIO, ENOENT), fall back to debounce: reset a timer on
   every stdin `line` event; fire after `--debounce <D>` of silence.
   `--debounce 0` disables the timer (only EOF triggers a request).
4. Re-entrant guard: ignore triggers while a previous request is still
   streaming; log `info: previous request still streaming, ignoring trigger`.
5. Empty-buffer guard: ignore triggers when the ring buffer is empty after
   window slicing; log `warning: no segments accumulated, skipping trigger`.
6. EOF: emit one final request unless the last trigger was within ~1s.

#### Acceptance criteria satisfied

- AC-CC-7 (auto-detect picks newest sidecar).
- AC-CC-8 (stdin precedence).
- AC-CC-14 (stdin trigger semantics).
- FR-CC-3, FR-CC-6.

---

### U6 — LLM provider factory

**Phase:** P3. **Parallel** with U4, U8, U9.

> **Splitting decision:** the eight provider files are very small (~20-30
> lines each, mostly identical structure). Splitting into eight parallel
> coder units would create coordination overhead with no speed benefit.
> **Recommended:** ONE coder agent owns all of U6 (the factory + eight
> provider files + default-models + tests), since the per-file diff is
> trivial and the factory's switch statement must be coherent.

#### Files

- `tools/convo-coach/src/llm/factory.ts` (NEW) — `createProviderModel(provider, modelId, cfg)`.
  Reuse the factory shape from `docs/research/vercel-ai-sdk-v5-multiprovider.md` §7.
- `tools/convo-coach/src/llm/providers/openai.ts` (NEW)
- `tools/convo-coach/src/llm/providers/anthropic.ts` (NEW)
- `tools/convo-coach/src/llm/providers/google.ts` (NEW)
- `tools/convo-coach/src/llm/providers/azure-openai.ts` (NEW) — includes
  `deriveResourceName(endpoint)` helper.
- `tools/convo-coach/src/llm/providers/azure-ai-inference.ts` (NEW)
- `tools/convo-coach/src/llm/providers/ollama.ts` (NEW)
- `tools/convo-coach/src/llm/providers/litellm.ts` (NEW)
- `tools/convo-coach/src/llm/providers/mlx.ts` (NEW)
- `tools/convo-coach/src/llm/default-models.ts` (NEW) — per-provider
  `DEFAULT_MODEL_IDS` table per D4.

#### Each provider file exports

```typescript
export interface ProviderCreateInput {
  cfg: ResolvedConfig;
  modelId: string;
}
export function create(input: ProviderCreateInput): LanguageModel { … }
```

The factory dispatches on `provider`, calls `create({ cfg, modelId })`,
returning a `LanguageModel` ready for `streamText`. Missing required env
vars throw `ConvoCoachError('MISSING_CONFIG', ...)` with the env-var name
and the four resolution tiers inspected.

#### Per-provider key contracts

| Provider | Required cfg keys | Default model (when --model absent) |
|---|---|---|
| `openai` | `OPENAI_API_KEY` | `gpt-4o-mini` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| `gemini` | `GOOGLE_API_KEY` (or `GEMINI_API_KEY` alias) | `gemini-2.5-flash` |
| `azure-openai` | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` | `${AZURE_OPENAI_DEPLOYMENT}` |
| `azure-ai-inference` | `AZURE_AI_INFERENCE_KEY`, `AZURE_AI_INFERENCE_ENDPOINT` | `claude-haiku-4-5` |
| `ollama` | `OLLAMA_HOST` | `llama3.1:8b` |
| `litellm` | `LITELLM_PROXY_URL`, `LITELLM_MASTER_KEY` | **none — `--model` required** |
| `mlx` | `OPENAI_BASE_URL` | **none — `--model` required** |

#### Acceptance criteria satisfied

- AC-CC-3 (all eight providers wired; unknown → exit 64).
- AC-CC-4 (missing required key → exit 78 + named var + tier list).
- AC-CC-5 (CLI `--provider` / `--model` override env).
- FR-CC-7, FR-CC-8, NFR-CC-5.

---

### U7 — Streaming + sidecar writer

**Phase:** P5. **Sequential, depends on U2, U6, U8, U9.**

#### Files

- `tools/convo-coach/src/output/stream.ts` (NEW) — runs the `streamText`
  loop, writes each delta to both `process.stdout` and the sidecar
  `WriteStream` in lock-step, awaits `result.usage`.
- `tools/convo-coach/src/output/sidecar.ts` (NEW) — `uniqueSidecarPath`,
  `openSidecar`, `writeFrontMatter`, `finaliseMetrics`, `writeErrorFooter`.

#### Sidecar naming (FR-CC-11, NFR-CC-3)

```typescript
function sidecarPathFor(transcriptPath: string, ts: Date): string {
  const dir = path.dirname(transcriptPath);
  let basename = path.basename(transcriptPath);
  basename = basename.replace(/\.transcript\.(jsonl|txt|srt|vtt)$/, '');
  basename = basename.replace(/\.(jsonl|txt|srt|vtt|md)$/, '');
  return uniqueSidecarPath(dir, basename, formatTs(ts));   // -<n> on collision
}
```

For stdin mode without `--advice-out` / `--advice-basename`, basename
defaults to `./convo-coach-stdin`.

#### YAML front matter (per OI-C / OD-7)

```yaml
---
provider:           openai
model:              gpt-4o-mini
transcriptSource:   /Users/me/Recordings/talk.transcript.jsonl
window:
  last:             5m
  since:            null
  resolvedStart:    2026-05-02T13:30:15.000Z
  resolvedEnd:      2026-05-02T13:35:15.000Z
segments:           42
droppedSegments:    3
channelLabels:
  A: Speaker-A (on-device, primary)
  B: Speaker-B (cloud)
startedAt:          2026-05-02T13:35:15.123Z
ttftMs:             null   # filled at first token
elapsedMs:          null   # filled at end
inputTokens:        null   # filled at end
outputTokens:       null   # filled at end
totalTokens:        null   # filled at end
---
# Conversational coaching — 2026-05-02 13:35:15

## Source window
- File: /Users/me/Recordings/talk.transcript.jsonl
- Range: 13:30:15 → 13:35:15
- Segments: 42 (dropped: 3)

## Advice
```

The `## Advice` heading is followed immediately by streamed content. On
stream end, `finaliseMetrics()` re-opens the sidecar (or seeks to a
preserved offset) and rewrites the placeholder metrics in the YAML
front-matter, then appends a `## Metrics` block with the final values.

> **Implementation note:** writing front-matter with placeholders, then
> seeking back to update them, requires either (a) opening the file in
> `r+` mode and `fs.write(fd, …, position)` calls, or (b) buffering the
> front-matter in memory and writing it once at end. Option (b) is
> simpler and safer (no risk of partial overwrite on crash). The Advice
> body streams to a temp `<sidecar>.partial`; on stream-end the final
> `<sidecar>` is assembled (front-matter + body + Metrics block) and the
> partial is renamed atomically. On stream-error the partial is renamed
> to the final path with an `# ERROR` footer instead.

#### Stream loop (per `docs/research/vercel-ai-sdk-v5-multiprovider.md` §1.7)

```typescript
const result = streamText({
  model,
  system: systemPrompt,
  prompt: userMessage,
  maxOutputTokens: 2048,                // per FR-CC-13 reservation
  abortSignal: controller.signal,
});

const started = Date.now();
let firstTokenMs: number | undefined;

try {
  for await (const delta of result.textStream) {
    if (firstTokenMs === undefined) firstTokenMs = Date.now() - started;
    process.stdout.write(delta);                          // unbuffered (R7)
    sidecarPartialStream.write(delta);                    // lock-step (AC-CC-15)
  }
  process.stdout.write('\n');
} catch (err) {
  await writeErrorFooter(sidecarPath, err);
  throw new ConvoCoachError('PROVIDER_FAILURE', String(err));
}

const usage = await result.usage;
await finaliseMetrics(sidecarPath, {
  ttftMs: firstTokenMs,
  elapsedMs: Date.now() - started,
  inputTokens:  usage.inputTokens  ?? null,
  outputTokens: usage.outputTokens ?? null,
  totalTokens:  usage.totalTokens  ?? null,
});
```

#### Acceptance criteria satisfied

- AC-CC-2 (stream + sidecar produced).
- AC-CC-15 (lock-step streaming).
- AC-CC-16 (sidecar contains no API keys — verified by writer code path).
- FR-CC-11, NFR-CC-1, NFR-CC-3.

---

### U8 — Prompt builder

**Phase:** P3. **Parallel** with U4, U6, U9.

#### Files

- `tools/convo-coach/src/prompt/build.ts` (NEW) — exports
  `buildSystemPrompt(opts)` and `buildUserMessage(records, opts)`.

#### Default system prompt (per OD-1)

A single string constant inside `build.ts` (per OI-B). Indicative wording:

> _You are a real-time conversational coach. The user is in a live
> conversation; below is the most recent portion of the dialogue. Suggest
> 3–5 concrete, actionable things the user could say, ask, suggest, request,
> or answer right now to move the conversation productively forward. Be
> specific to what was just discussed. Use bullet points. If the conversation
> is in a non-English language, respond in that language. Do not summarise
> the conversation; do not explain what was said; respond only with the
> suggestions._

If `--system-prompt <path>` is set, the file is read with
`fs.readFile(path, 'utf8')` and the contents replace the default verbatim.

#### User message format

```
The following labels appear in the transcript:
- [system] = audio captured from the user's speakers (the other side of the call)
- [mic]    = audio captured from the user's microphone (the user themself)
- [Speaker-A (on-device, primary)]  = primary on-device transcription channel
- [Speaker-B (cloud)]                = secondary cloud transcription channel

Recent conversation:

[13:30:15.123] [system] Hi, how are you doing today?
[13:30:17.890] [mic]    I'm doing well, thanks. About the proposal...
[13:30:22.001] [Speaker-A (on-device, primary)] We sent it Friday morning.
…
```

For single-channel input the `[Speaker-A]` / `[Speaker-B]` labels do not
appear in the legend, only `[system]` / `[mic]`. For dual-channel input,
the inverse — only the speaker labels appear in the legend (since the
JSONL `source` field alone may be redundant with `channel`).

#### `--language <bcp-47>` hint

Appended to the user message as: `Please respond in <language>.`
(only when set).

#### Acceptance criteria satisfied

- AC-CC-9 (channel→speaker mapping).
- FR-CC-12.

---

### U9 — Token-budget guard

**Phase:** P3. **Parallel** with U4, U6, U8.

#### Files

- `tools/convo-coach/src/llm/budget.ts` (NEW) — `estimateTokens(text, modelId)`,
  `applyBudget(records, system, scaffolding, modelId, strategy)`.
- `tools/convo-coach/src/llm/model-context-windows.ts` (NEW) — static map.

#### `model-context-windows.ts` (per `investigation-convo-coach.md` §Q6)

```typescript
export const MODEL_CONTEXT_WINDOWS: Record<string, number> = {
  'gpt-4o-mini':                  128_000,
  'gpt-4o':                       128_000,
  'gpt-4.1':                    1_047_576,
  'gpt-4.1-mini':               1_047_576,
  'gpt-4.1-nano':               1_047_576,
  'o1-mini':                      128_000,
  'claude-haiku-4-5-20251001':    200_000,
  'claude-haiku-4-5':             200_000,
  'claude-sonnet-4-6':            200_000,
  'claude-opus-4-6':              200_000,
  'claude-opus-4-7':              200_000,
  'gemini-2.5-flash':           1_048_576,
  'gemini-2.5-flash-lite':      1_048_576,
  'gemini-2.5-pro':             2_097_152,
  'llama3.1:8b':                  131_072,
  'llama3.1:70b':                 131_072,
  'llama3.3:70b':                 131_072,
  'qwen2.5:7b':                   131_072,
  'qwen2.5:14b':                  131_072,
  'gemma2:9b':                      8_192,
  'mistral':                       32_768,
};

export const FALLBACK_CONTEXT_WINDOW = 8_192;
```

Unknown models fall back to `8_192` with a single `warning` log line. (This
is **model metadata**, not configuration — explicitly allowed by FR-CC-10.)

#### `estimateTokens`

- **OpenAI-family models** (model id matches `/^gpt-/`, `/^o\d/`, or the
  Azure OpenAI / LiteLLM-routed-OpenAI / MLX-via-OpenAI-compatible cases):
  lazy-`import('js-tiktoken')` and use `o200k_base` for `gpt-4o*` /
  `gpt-4.1*`, `cl100k_base` otherwise.
- **Everything else**: `Math.ceil(text.length / 4)` heuristic.

Lazy-loading per R8 ensures non-OpenAI providers never pay the cold-start
cost.

#### `applyBudget` strategy

```text
1. Compute systemTokens + scaffoldingTokens (legend, formatting overhead).
2. reserved = min(2048, contextWindow / 4).
3. budget = contextWindow - systemTokens - scaffoldingTokens - reserved.
4. Walk records:
     - truncate-start (default): from newest backwards; stop when adding
       the next record would exceed budget; reverse to chronological order.
     - truncate-end: from oldest forward; stop similarly.
     - error: if total token count > budget, throw
       ConvoCoachError('BAD_USAGE', ...) → exit 64.
5. Return { kept: NormalisedRecord[], dropped: number }.
```

The `dropped` count is recorded in the sidecar front-matter as
`droppedSegments`.

#### Acceptance criteria satisfied

- AC-CC-13 (truncate-start drops oldest; error mode exits 64;
  `droppedSegments: <n>` in front matter).
- FR-CC-13.

---

### U10 — Documentation & registration

**Phase:** P7 (after implementation is complete; the doc body needs
verified flag tables and example output). The `/tool-conventions scaffold`
slash command was already invoked in P0 and produced the initial skeleton.

#### Files (modified, NOT hand-rolled creation)

- `docs/tools/convo-coach.md` — finalise the `<convoCoach>` XML block
  body produced by the scaffold subagent (CLI flag table, env-var table
  with verified default model IDs per D4, examples for each provider,
  stdin mode example, troubleshooting section, install instructions).
- `~/.tool-agents/convo-coach/.env` — already seeded by scaffold; no
  changes by U10.

#### Files (modified — project-wide registrations)

- `CLAUDE.md` (project) — add a new `### convo-coach` entry to the `## Tools`
  section, exactly per the recommended wording in FR-CC-15:

  ```
  ### convo-coach

  LLM-powered conversational coach: reads a macrec transcript (single- or
  dual-channel), slices a recent window with `--last` / `--since`, asks any
  of the eight standard LLM providers for in-the-moment advice on what to
  ask / suggest / answer next, and streams the response token-by-token to
  stdout while persisting it to a `.advice-<timestamp>.md` sidecar next to
  the source transcript.

  Documentation: [docs/tools/convo-coach.md](docs/tools/convo-coach.md)

  #### Install as a direct command

  ```sh
  cd tools/convo-coach
  npm install
  npm link        # convo-coach now on PATH globally
  convo-coach --help
  ```
  ```

- `docs/design/project-design.md` — add a `## convo-coach (plan-011)`
  subsection under the existing tools narrative summarising the
  architecture (transcript reader → window → prompt → factory → stream →
  sidecar), the new runtime dependencies (`ai@^6` + five `@ai-sdk/*`
  packages + `js-tiktoken`), and the four-tier config chain inheritance.

- `docs/design/project-functions.md` — add new section §X
  "Convo-Coach Functional Requirements (plan-011)" registering FR-CC-1
  through FR-CC-15 verbatim from the refined request, each with status
  `PLANNED`. (See §6 below for the exact entries to insert.)

- `Issues - Pending Items.md` — append any defects surfaced during
  implementation.

#### Acceptance criteria satisfied

- AC-CC-10 (`docs/tools/convo-coach.md` exists in `<convoCoach>` XML format
  + project `CLAUDE.md` entry).
- FR-CC-15.

---

### U11 — Tests

**Phase:** P8. **Parallel by file** (the `node --test` runner runs each
file in its own worker process).

#### Test files (under `tools/convo-coach/test/`)

| File | Covers | ACs |
|---|---|---|
| `config.test.ts` | Four-tier resolution, alias `GEMINI_API_KEY`→`GOOGLE_API_KEY`, missing-key errors, provenance map, trailing-slash stripping. | AC-CC-4, AC-CC-5, AC-CC-12 |
| `duration.test.ts` | `parseDuration` strict grammar; rejects `5x`, `''`, decimals. | (FR-CC-5 unit) |
| `window.test.ts` | `--last`, `--since` (wall-clock + ISO + relative), later-boundary, full-transcript default. | AC-CC-6 |
| `jsonl.test.ts` | Single-channel + dual-channel parsing; `_tombstone:true` skip; unknown `extras` preservation; `isFinal` ignored gracefully (R9). | AC-CC-9 |
| `txt.test.ts` | TXT regex parser; bad-line summary count. | (FR-CC-4) |
| `srt.test.ts` | SRT cue parser; `EN: ` channel prefix extraction. | (FR-CC-4) |
| `vtt.test.ts` | VTT cue parser; `<v EN>...</v>` voice-tag extraction. | (FR-CC-4) |
| `autodetect.test.ts` | Newest mtime selection; JSONL preferred over TXT; missing-dir hint. | AC-CC-7 |
| `stdin.test.ts` | Stdin precedence over `--transcript`; `/dev/tty` mocked Enter trigger; debounce fallback; empty-buffer skip; re-entrant guard. | AC-CC-8, AC-CC-14 |
| `budget.test.ts` | Truncate-start drops oldest; `droppedSegments` count; `--on-overflow error` exits 64; unknown model uses 8 192 fallback with warning. | AC-CC-13 |
| `factory.test.ts` | All eight providers wire correctly; unknown provider throws `BAD_USAGE`; missing required key throws `MISSING_CONFIG` with env-var name + tier list. Uses a mocked `LanguageModel` per provider via stub functions; does NOT hit the network. | AC-CC-3, AC-CC-4 |
| `prompt.test.ts` | Channel→speaker mapping; `--system-prompt <path>` override. | AC-CC-9 |
| `sidecar.test.ts` | Path naming (`.transcript.jsonl` → `.advice-<ts>.md`); collision `-<n>` suffix; YAML front matter shape; error footer; basename for stdin mode. | AC-CC-2, AC-CC-15 |
| `stream.test.ts` | `streamText` mock yields three chunks; assert `process.stdout.write` and sidecar both received the same byte sequence in lock-step (max divergence ≤ 1s). | AC-CC-15 |
| `logging.test.ts` | At every log level (`quiet`, `info`, `debug`), no fixture API key substring appears in captured stderr or sidecar. | AC-CC-16 |
| `e2e.test.ts` | One end-to-end flow per acceptance criterion using a mocked `streamText` (no network). Asserts exit code, stdout content, sidecar content, sidecar mode `0644`, `~/.tool-agents/convo-coach/` mode `0700`. | AC-CC-1..AC-CC-16 |

`fixtures/` contains:

- `single-channel.transcript.jsonl` — 10 lines, three sources, ISO timestamps.
- `dual-channel.transcript.jsonl` — 10 lines with `channel:"A"|"B"` and
  `language:"en-US"|"el-GR"`, including one `_tombstone:true` line.
- `plain.transcript.txt`, `.srt`, `.vtt` — manually crafted.
- `system-prompts/coach.md` — for the `--system-prompt` test.

#### Mocking the AI SDK

`stream.test.ts` and `e2e.test.ts` use a hand-rolled fake `LanguageModel`
that satisfies the type expected by `streamText`. The fake's `doStream`
yields a fixed sequence of `text-delta` events with controllable inter-token
delays, plus a `finish` event with deterministic `usage`. No network calls.

#### Coverage target (NFR-CC-7)

≥80% line coverage on `src/` excluding the eight provider files (which are
exercised by `factory.test.ts` only at the wiring layer; their HTTP
behaviour is the SDK's responsibility, not convo-coach's). Coverage is
measured locally via `node --test --experimental-test-coverage` (Node ≥20.11)
when needed; not a CI gate in v1.

---

## 6. `docs/design/project-functions.md` updates

Append a new top-level section after §1.x existing FR groups:

```markdown
## §X — Convo-Coach Functional Requirements (plan-011)

> Source: `docs/design/refined-request-convo-coach.md` (FR-CC-1..FR-CC-15);
> implemented under `tools/convo-coach/`. Status: PLANNED unless otherwise
> noted.

### FR-CC-1 — Project location & language
**Status:** PLANNED. **Phase:** U1.
TypeScript-only tool under `tools/convo-coach/` mirroring the structural
conventions of `tools/dual-transcript-merger/` (ESM, Node ≥20, `bin`
mapping, `prepare`/`postbuild` scripts emitting and chmod'ing `dist/cli.js`).
Package + binary name: `convo-coach`.

### FR-CC-2 — Installation
**Status:** PLANNED. **Phase:** U1.
Installable via `cd tools/convo-coach && npm install && npm link`. The
`prepare` script runs `tsc` and `chmod +x dist/cli.js`.

### FR-CC-3 — Transcript input modes
**Status:** PLANNED. **Phases:** U3, U5.
Precedence highest → lowest: stdin (when `process.stdin.isTTY === false`)
> `--transcript <path>` > auto-detect newest `*.transcript.{jsonl,txt,srt,vtt}`
in `MACREC_RECORDINGS_DIR` (default `~/Recordings`).

### FR-CC-4 — Sidecar format support
**Status:** PLANNED. **Phase:** U4.
Parse single-channel JSONL, dual-channel JSONL (`channel:"A"|"B"`), plain
TXT (`[HH:MM:SS.mmm] text` or dual-tagged), SRT, VTT. Skip-with-summary on
malformed lines.

### FR-CC-5 — Conversation-window filtering
**Status:** PLANNED. **Phase:** U4.
`--last <duration>` (`30s | 5m | 1h | 1h30m | 90s`) and `--since <ts>`
(wall-clock, ISO-8601, or relative `+MM:SS`). Combined → later boundary
wins. Absent → full transcript.

### FR-CC-6 — Stdin streaming semantics
**Status:** PLANNED. **Phase:** U5.
Per-Enter trigger via `/dev/tty` when available; `--debounce <duration>`
fallback otherwise (default `15s`). Each trigger produces one separate
timestamped sidecar.

### FR-CC-7 — LLM providers
**Status:** PLANNED. **Phase:** U6.
Eight standard providers: `openai | anthropic | gemini | azure-openai |
azure-ai-inference | ollama | litellm | mlx`.

### FR-CC-8 — Provider/model selection
**Status:** PLANNED. **Phase:** U3, U6.
`--provider` and `--model` (resolved via `CONVO_COACH_PROVIDER` /
`CONVO_COACH_MODEL`). Per-provider defaults per D4.

### FR-CC-9 — Configuration resolution chain
**Status:** PLANNED. **Phase:** U2.
Four-tier chain: `process.env` → `~/.tool-agents/convo-coach/.env` →
`<cwd>/.env` → CLI flags. Folder mode `0700` enforced on first invocation.

### FR-CC-10 — No-fallback rule
**Status:** PLANNED. **Phase:** U2, U6.
Missing required config raises typed `ConvoCoachError('MISSING_CONFIG', …)`
with the env-var name and the four tiers inspected. Default model IDs and
the `MACREC_RECORDINGS_DIR` default `~/Recordings` are documented model
metadata / directory locations, NOT credential fallbacks.

### FR-CC-11 — Output behaviour
**Status:** PLANNED. **Phase:** U7.
Token-by-token stream to `stdout` AND simultaneous append to
`<basename>.advice-<YYYYMMDD-HHMMSS>.md` next to the source transcript,
with YAML front-matter and a Metrics block. Collision suffix `-<n>`.

### FR-CC-12 — Prompt construction
**Status:** PLANNED. **Phase:** U8.
Built-in default system prompt frames the LLM as a real-time coach;
`--system-prompt <path>` override accepted. User message contains
windowed transcript with `[HH:MM:SS.mmm] [<channel-or-source>] text`
format. Channel labels (`A`/`B`) mapped to human-readable speaker hints.

### FR-CC-13 — Token-budget handling
**Status:** PLANNED. **Phase:** U9.
Default: truncate-start (drop oldest segments). `--on-overflow
{truncate-start | truncate-end | error}`. Static model context-window
table; unknown models default to 8 192 with a warning.

### FR-CC-14 — Logging & exit codes
**Status:** PLANNED. **Phases:** U2, U3.
Levels `quiet | info | debug` to stderr. Exit codes: `0`, `1`, `64`, `66`,
`70`, `78`.

### FR-CC-15 — CLAUDE.md "Tools" section entry
**Status:** PLANNED. **Phase:** U10.
Concise reference entry added to project `CLAUDE.md` after the tool is
built and `docs/tools/convo-coach.md` is in place (scaffolded by
`/tool-conventions scaffold convo-coach`).
```

---

## 7. Verification criteria (Claude-executable)

These commands must all pass at the end of P8.

```sh
# 1. Skeleton + dependencies
cd tools/convo-coach
npm install                            # exits 0; creates node_modules + package-lock.json
npm run build                          # exits 0; produces dist/cli.js
test -x dist/cli.js                    # executable bit set

# 2. CLI install + invocation
npm link                               # symlinks convo-coach onto $PATH
which convo-coach                      # resolves to a path
convo-coach --help                     # exits 0; prints non-empty usage
convo-coach --version                  # exits 0; prints package version

# 3. Tests
npm test                               # exits 0; all test files pass

# 4. Lint-equivalent: TypeScript strict compile
npx tsc -p tsconfig.json --noEmit      # exits 0; no type errors

# 5. Bootstrap behaviour (AC-CC-11)
rm -rf ~/.tool-agents/convo-coach      # ONLY after backing up any real .env
convo-coach --help >/dev/null
stat -f '%OLp' ~/.tool-agents/convo-coach     # prints 700

# 6. AC-CC-4: missing config
unset OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY GEMINI_API_KEY \
      AZURE_OPENAI_API_KEY AZURE_AI_INFERENCE_KEY OLLAMA_HOST LITELLM_PROXY_URL
convo-coach --provider openai --transcript test/fixtures/single-channel.transcript.jsonl
echo $?                                # prints 78
# stderr should mention OPENAI_API_KEY and the four resolution tiers.

# 7. AC-CC-3: unknown provider
convo-coach --provider made-up-provider --transcript test/fixtures/single-channel.transcript.jsonl
echo $?                                # prints 64

# 8. AC-CC-7: auto-detect (with a real or fixture recordings dir)
export MACREC_RECORDINGS_DIR=$(mktemp -d)
cp test/fixtures/single-channel.transcript.jsonl "$MACREC_RECORDINGS_DIR/old.transcript.jsonl"
sleep 1
cp test/fixtures/dual-channel.transcript.jsonl "$MACREC_RECORDINGS_DIR/new.transcript.jsonl"
# (with a stub provider that prints the chosen path) — verified by the e2e test, not shell.

# 9. Project doc registration (AC-CC-10, FR-CC-15)
grep -F "### convo-coach" CLAUDE.md   # prints the heading
grep -F "convo-coach" docs/design/project-design.md
grep -F "FR-CC-1" docs/design/project-functions.md

# 10. /tool-conventions audit
# Run /tool-conventions audit convo-coach inside Claude Code; expect status:completed.
```

---

## 8. Acceptance Criteria mapping

| AC | Phase(s) | Unit(s) | Verification |
|---|---|---|---|
| AC-CC-1 | P1, P6 | U1, U3 | `npm install && npm link && convo-coach --help` exits 0. |
| AC-CC-2 | P5, P6 | U7, U3 | `e2e.test.ts` with mocked OpenAI streaming endpoint. |
| AC-CC-3 | P3 | U6 | `factory.test.ts` for all 8 providers + invalid name. |
| AC-CC-4 | P2, P3 | U2, U6 | `config.test.ts` + integration with cleared env. |
| AC-CC-5 | P2, P6 | U2, U3 | Unit + integration assertion of provider in sidecar front-matter. |
| AC-CC-6 | P3 | U4 | `window.test.ts` with synthetic 1-hour transcript. |
| AC-CC-7 | P4 | U5 | `autodetect.test.ts` with two fixture sidecars at distinct mtimes. |
| AC-CC-8 | P4 | U5 | `stdin.test.ts` piping fixture and asserting same advice as `--transcript`. |
| AC-CC-9 | P3 | U4, U8 | `jsonl.test.ts` + `prompt.test.ts`. |
| AC-CC-10 | P0, P7 | scaffold + U10 | `/tool-conventions audit convo-coach` returns `completed`. |
| AC-CC-11 | P6 | U3 | `stat` check in shell and in `e2e.test.ts`. |
| AC-CC-12 | P2 | U2 | `config.test.ts` pairwise overrides. |
| AC-CC-13 | P3 | U9 | `budget.test.ts` with synthetic oversize transcript. |
| AC-CC-14 | P4 | U5 | `stdin.test.ts` driving stdin with synthetic stream. |
| AC-CC-15 | P5 | U7 | `stream.test.ts` reads sidecar concurrently with stdout capture. |
| AC-CC-16 | P2, P5 | U2, U7 | `logging.test.ts` scans stderr + sidecar for known fixture key substrings. |

All sixteen ACs are covered.

---

## 9. Execution order summary

```
P0:  /tool-conventions scaffold convo-coach          ← MANUAL (one slash command call)
P1:  U1 (skeleton)                                   ← 1 agent
P2:  U2 (config)                                     ← 1 agent
P3:  U4 || U6 || U8 || U9                            ← 4 agents IN PARALLEL
P4:  U5                                              ← 1 agent
P5:  U7                                              ← 1 agent
P6:  U3                                              ← 1 agent
P7:  U10                                             ← 1 agent
P8:  U11                                             ← test runner (parallel by file)
```

Total maximum-parallelism cost = ~7 sequential coder turns (P1, P2, P3 batch,
P4, P5, P6, P7) + 1 test-runner turn (P8). The four parallel coder agents in
P3 operate on disjoint file trees (`transcript/`, `llm/`, `prompt/`,
`llm/budget+context-windows`) — no merge conflicts expected.

---

## 10. Out of scope (explicit, per refined-request)

- Daemon / inotify watcher mode beyond stdin streaming.
- Real-time audio capture (consumes existing transcripts only).
- Multi-turn dialogue with memory between invocations.
- Caching, prompt-template management, fine-tuning workflows.
- Any modifications to `macrec`, `macrec-ui`, or `dual-transcript-merger`.
- Wrapping `convo-coach` inside `macrec-ui`.
- A 9th LLM provider (`tool-doc-config-architect` mandates exactly eight).
- Per-provider transcription APIs (Soniox, ElevenLabs) — they don't expose
  chat/completion APIs suitable for coaching.
- Windows support (NFR-CC-4: macOS primary, Linux best-effort, Windows out).

---

## 11. Definition of done

The plan is complete when **all of the following** are true:

1. All eleven units (U1..U11) are implemented and committed.
2. All sixteen acceptance criteria (AC-CC-1..AC-CC-16) pass.
3. `cd tools/convo-coach && npm install && npm run build && npm test && npm link && convo-coach --help` succeeds end-to-end in a clean environment.
4. `/tool-conventions audit convo-coach` returns `status: completed` with no critical findings.
5. Project `CLAUDE.md` "Tools" section contains the `### convo-coach` entry per FR-CC-15.
6. `docs/design/project-functions.md` contains FR-CC-1..FR-CC-15 entries.
7. `docs/design/project-design.md` contains a `## convo-coach (plan-011)` subsection.
8. `Issues - Pending Items.md` contains entries for any defects surfaced
   during implementation, all marked completed before plan close-out.
9. The user has accepted (or vetoed with directives) the three open items
   in §0.5 (OI-A, OI-B, OI-C).
