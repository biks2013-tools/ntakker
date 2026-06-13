---
language: mixed
language_detail: "Swift (project primary); TypeScript (convo-coach scope and dual-transcript-merger)"
framework: "Swift: ScreenCaptureKit + AVFoundation + SwiftUI; TypeScript: Node.js ESM, zero runtime deps"
package_manager: "Swift: go-modules (SwiftPM / Package.swift); TypeScript tools: npm"
build_command: "Swift: swift build -c release --product macrec; TypeScript: cd tools/<tool> && npm run build"
test_command: "Swift: swift test; TypeScript: node --test --import tsx test/*.test.ts"
lint_command: null
entry_points:
  - Sources/macrec/main.swift
  - Sources/macrec-ui/main.swift
  - tools/dual-transcript-merger/dist/cli.js
last_scanned_commit: cb14c7cd11c2d3a2c89740637d81e32171e5af22
scanned_for_request: refined-request-convo-coach.md
scanned_at: "2026-05-02T09:15:00Z"
---

# Codebase Scan — recording-tool (convo-coach narrowing)

## 1. Project Overview

`recording-tool` is a macOS-only Swift project that captures system audio
(via `ScreenCaptureKit`) and the microphone (via `AVFoundation`) into `m4a`,
`wav`, or `caf` files, optionally streaming the audio to live speech-to-text
providers and writing JSONL/TXT/SRT/VTT transcript sidecars alongside the
audio file. The primary Swift executables are `macrec` (CLI) and `macrec-ui`
(menu-bar app), backed by the `MacrecCore` library. A sibling TypeScript
toolchain lives under `tools/` — currently a single tool (`dual-transcript-merger`)
that post-processes the dual-channel JSONL sidecars; `convo-coach` will be
the second TypeScript tool in that directory. Deployment target is macOS 26
(bumped from macOS 14 to support `SpeechAnalyzer`, per Exception 002 in
CLAUDE.md).

---

## 2. Module Map

### Swift source root (`Sources/`)

| Path | Purpose | Representative symbols |
|---|---|---|
| `Sources/macrec/` | CLI executable — subcommands `start`, `stop`, `list-devices`, `check-permissions`; thin shell over `MacrecCore` | `StartCommand`, `StopCommand`, `MacrecCommand` |
| `Sources/MacrecCore/` | Library: recording pipeline, transcription providers, sidecar writers, bootstrap | `RecordingSession`, `TranscriptionManager`, `JSONLTranscriptWriter` |
| `Sources/MacrecCore/Bootstrap/` | Creates `~/.tool-agents/macrec/` (mode 0700) and seeds `.env` (mode 0600) on startup | `ToolAgentsBootstrap`, `EnvFileStore` |
| `Sources/MacrecCore/Transcription/` | Provider protocol + concrete implementations (apple, apple-cloud, gemini, soniox, azure, elevenlabs, whisperkit, dual) | `TranscriptionProvider`, `TranscriptionManager`, `DualTranscriptionManager` |
| `Sources/MacrecCore/Transcription/Persistence/` | Sidecar writers (JSONL, TXT, SRT, VTT) | `JSONLTranscriptWriter`, `TXTTranscriptWriter`, `SRTTranscriptWriter`, `VTTTranscriptWriter` |
| `Sources/MacrecCore/Transcription/Dual/` | Dual-mode orchestration (Channel A on-device + Channel B cloud, one merged sidecar) | `DualTranscriptionManager`, `DualSidecarLabel` |
| `Sources/MacrecCore/Errors/` | Typed error enum → exit-code mapping | `MacrecError` |
| `Sources/macrec-ui/` | SwiftUI menu-bar executable; in-process `MacrecCore` | `AppDelegate`, `PopoverController`, `ControlBar` |
| `Sources/MacrecUIKit/` | Shared SwiftUI components for the menu-bar app | `LevelMeter`, `TranscriptPanel`, `DualTranscriptPanel` |

### TypeScript tool root (`tools/`)

| Path | Purpose | Representative symbols |
|---|---|---|
| `tools/dual-transcript-merger/` | TypeScript CLI — merges dual-channel JSONL, applies hallucination filter, writes JSONL/TXT | `parseLine`, `parseStream`, `merge`, `resolveDefaults` |
| `tools/dual-transcript-merger/src/` | Seven source files: `cli.ts`, `config.ts`, `emitter.ts`, `index.ts`, `merger.ts`, `parser.ts`, `types.ts` | `SidecarRecord`, `IndexedRecord`, `MergeOptions` |
| `tools/dual-transcript-merger/test/` | Node built-in test runner (`.test.ts`); one file: `merger.test.ts` | — |

### Other top-level directories

| Path | Purpose |
|---|---|
| `docs/design/` | Plans, project-design, project-functions, configuration-guide, refined requests |
| `docs/reference/` | Codebase scans, investigation reports, test-build reports |
| `docs/tools/` | Canonical tool documentation (`macrec.md`, `macrec-ui.md`, `dual-transcript-merger.md`) |
| `test_scripts/` | Shell E2E scripts (Swift builds) + one TS test subfolder (`test_scripts/dual-transcript-merger/`) |
| `scripts/` | Packaging helper (`package-macrec-ui-app.sh`) |
| `Resources/` | `Info.plist` embedded into the `macrec` binary for TCC |

---

## 3. Conventions

- **ESM, zero runtime dependencies** (`tools/dual-transcript-merger/package.json:6`): `"type":"module"`; devDependencies only (`typescript ^5.6`, `tsx ^4.19`, `@types/node ^22`). No runtime npm packages — `fetch`, `node:fs`, `node:readline`, `node:os`, `node:path` from Node built-ins only.

- **Shebang + chmod pattern** (`tools/dual-transcript-merger/package.json:17-24`): the `prepare` script runs `tsc -p tsconfig.json && chmod +x dist/cli.js`; `postbuild` repeats `chmod +x dist/cli.js`. The file opens with `#!/usr/bin/env node` (`tools/dual-transcript-merger/src/cli.ts:1`). `npm link` wires `bin.dual-transcript-merger → ./dist/cli.js`.

- **Four-tier config resolution** (`tools/dual-transcript-merger/src/config.ts:1-153`): shell `process.env` (tier 1) → `~/.tool-agents/<tool>/.env` (tier 2) → `<cwd>/.env` (tier 3) → CLI flags (tier 4, applied in `cli.ts`). Hand-rolled `.env` parser — no `dotenv` dependency. `KEY=value`, `#` comment lines, blank lines tolerated; quoting not supported.

- **No-fallback strictly enforced** (`tools/dual-transcript-merger/src/config.ts:34-38,76-96`): validated values use a whitelist Set; an unrecognised value at any tier throws `MergerError("BAD_CONFIG", ...)` immediately. Typed `HARDCODED_DEFAULTS` exist only for non-credential, non-endpoint knobs (filter mode and output format) and are classified as documented defaults, not fallbacks. Credentials must not be defaulted.

- **Streaming line reader for large files** (`tools/dual-transcript-merger/src/parser.ts:173-182`): `parseStream` is an `async function*` over `AsyncIterable<string>`, yielding one `IndexedRecord` at a time — JSONL files are never loaded fully into RAM.

- **TypeScript strict mode + extra checks** (`tools/dual-transcript-merger/tsconfig.json:8-17`): `"strict":true`, `"noUncheckedIndexedAccess":true`, `"noImplicitOverride":true`, `"noFallthroughCasesInSwitch":true`, target `ES2022`, moduleResolution `Bundler`, `resolveJsonModule:true`, `declaration:true`.

---

## 4. Integration Points

### In-Scope Modules

#### `tools/dual-transcript-merger/` — canonical TypeScript precedent

**`tools/dual-transcript-merger/package.json`** — the exact shape `convo-coach`'s `package.json` must replicate:

```json
{
  "type": "module",
  "bin": { "dual-transcript-merger": "./dist/cli.js" },
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
  "devDependencies": {
    "@types/node": "^22.0.0",
    "tsx": "^4.19.0",
    "typescript": "^5.6.0"
  }
}
```

`convo-coach` must change `name`, `bin` key, and `description` but keep
`type:"module"`, Node engine `>=20`, the same devDependency versions, and
the identical `prepare`/`postbuild`/`test` script pattern.

**`tools/dual-transcript-merger/tsconfig.json`** — compiler options to reuse verbatim:
`ES2022` target + module, `Bundler` moduleResolution, `strict:true`,
`noUncheckedIndexedAccess:true`, `noImplicitOverride:true`,
`noFallthroughCasesInSwitch:true`, `esModuleInterop:true`,
`forceConsistentCasingInFileNames:true`, `skipLibCheck:true`,
`declaration:true`, `sourceMap:true`, `resolveJsonModule:true`.

#### `tools/dual-transcript-merger/src/parser.ts` — dual-channel JSONL parser to replicate

The parser is the definitive reference implementation `convo-coach` must
mirror or import from. Key design points:

- **Required fields** (lines 23-32): `id`, `timestamp`, `source`, `channel`,
  `language`, `model`, `text`, `durationSec` — all must be present, all
  validated by type. Missing or wrong-typed field throws `MergerError`.
- **`parseLine(raw, lineNumber): IndexedRecord | null`** (line 83): returns
  `null` for blank lines; throws `MergerError` for malformed JSON or bad
  fields; computes `startMs` = `Date.parse(timestamp)` and
  `endMs = startMs + durationSec * 1000` as pre-computed epoch-ms values.
- **`parseStream(lines: AsyncIterable<string>)`** (line 173): async generator
  — one `IndexedRecord` yielded per line; never buffers the whole file.
- Extra unknown keys are preserved in `extras: Record<string,unknown>` so
  the parser is forward-compatible with future sidecar additions.

`convo-coach` must implement an equivalent parser (or re-export/import from
the merger package) because it consumes the same JSONL format.

#### `tools/dual-transcript-merger/src/config.ts` — four-tier chain reference implementation

The resolver pattern `convo-coach` must replicate (lines 53-153):

```typescript
// Tier 1 — process.env
const v1 = process.env[ENV_KEY];
// Tier 2 — ~/.tool-agents/<tool>/.env
const tier2 = tryReadDotEnv(join(homedir(), ".tool-agents", "<tool>", ".env"));
// Tier 3 — <cwd>/.env
const tier3 = tryReadDotEnv(resolve(cwd, ".env"));
// Tier 4 — CLI flags applied in cli.ts, not config.ts
```

`parseDotEnv` (line 53): splits on `\n`, skips `#` comments and blank lines,
finds the first `=`, trims key and value. No quoting support — document this
in `convo-coach`'s `.env` template.

---

### macrec JSONL Sidecar Schema

#### Single-channel JSONL (one JSON object per line)

Source of truth: `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift:142-158` and `TranscriptSegment.swift:4-36`.

```jsonc
{
  "id":          "<UUID string>",           // required
  "timestamp":   "2026-05-01T12:00:01.230Z", // ISO-8601 UTC, required
  "source":      "system" | "mic" | "mixed", // required
  "text":        "transcribed text",          // required
  "model":       "apple" | "apple-cloud" | "gemini" | "soniox" | ..., // optional (String?)
  "durationSec": 0.88,                        // optional (Double?); 0 for streaming partials
  "language":    "en-US",                     // optional (String?); BCP-47; absent in some modes
  // NOTE: "channel" field is absent in single-channel mode (no key emitted)
  // NOTE: "isFinal" appears in the dual-mode example in docs/tools/macrec.md
  //       but is NOT in the TranscriptSegment struct — it may be a documentation
  //       artefact. Parse defensively (ignore if present).
}
```

Tombstone lines (`{"_tombstone":true,"id":"<uuid>"}`) appear when a partial
segment is superseded by a final. Parsers must skip lines where `_tombstone`
is `true`.

#### Dual-channel JSONL additions

Source of truth: `docs/tools/macrec.md` §DT-7 (lines 889-897) and
`JSONLTranscriptWriter.swift:133-158`.

The `channel` field is appended as the **last** field of each line when
`mode == .dual`:

```jsonc
{"id":"E1...","timestamp":"2026-05-01T12:00:01.230Z","text":"Hello world",
 "source":"system","model":"apple","language":"en-US",
 "channel":"A","durationSec":0.88,"isFinal":true}

{"id":"7C...","timestamp":"2026-05-01T12:00:01.920Z","text":"Καλημέρα",
 "source":"system","model":"apple-cloud","language":"el-GR",
 "channel":"B","durationSec":1.50,"isFinal":true}
```

- `channel:"A"` → Apple on-device (`model:"apple"`). Map to
  `Speaker-A (on-device, primary)` in the prompt.
- `channel:"B"` → Apple Cloud (`model:"apple-cloud"`). Map to
  `Speaker-B (cloud)` in the prompt.
- Channel label is the uppercased BCP-47 primary subtag (`en-US → EN`,
  `el-GR → EL`), computed by `DualSidecarLabel.channelLabel(for:)`.
- Single-channel JSONL is byte-identical to pre-plan-010 output — the
  `channel` key is NEVER emitted in single mode.

The `dual-transcript-merger` types file (`tools/dual-transcript-merger/src/types.ts`)
documents the wire shape that the merger sees (which may differ slightly from
the raw macrec output — the merger's `REQUIRED_KEYS` include `channel` as
mandatory, while macrec emits it only in dual mode). `convo-coach` must handle
both shapes: `channel` may be absent (single-mode) or `"A"` / `"B"` (dual-mode).

---

### macrec Recordings Folder — CRITICAL FINDING

**`MACREC_RECORDINGS_DIR` does NOT exist as a macrec-native env var.**

Verification result from grepping all Swift sources and docs:

- `macrec start` takes `--output <path>` for each individual recording — there
  is no global "recordings folder" concept in the CLI.
- `macrec-ui` stores the user-chosen folder in
  `@AppStorage("com.macrec.ui.outputFolder")` (UserDefaults, not an env var).
- `~/.tool-agents/macrec/.env` (which exists, mode `0600`) currently contains
  only `# macrec environment overrides` with no `MACREC_RECORDINGS_DIR` entry.
- `docs/design/configuration-guide.md` has no mention of `MACREC_RECORDINGS_DIR`.

**Implication for `convo-coach` FR-CC-3 (auto-detect) and AC-CC-7:**
The `MACREC_RECORDINGS_DIR` env var is a `convo-coach`-invented convention, not
an existing macrec config key. This is acceptable — `convo-coach` reads it from
its own four-tier chain (shell env → `~/.tool-agents/convo-coach/.env` → local
`.env` → CLI). The downstream spec (FR-CC-3, A-1) must be updated to clarify
that `MACREC_RECORDINGS_DIR` is a `convo-coach`-specific config variable, not a
macrec one. The auto-detect fallback via `~/.tool-agents/macrec/.env` looking for
`MACREC_RECORDINGS_DIR` is moot — that file currently contains nothing useful for
folder discovery.

**Recommended resolution:** `convo-coach` defines and owns `MACREC_RECORDINGS_DIR`
in its own `~/.tool-agents/convo-coach/.env` template; users set it once. When
absent, the tool raises `MissingMacrecRecordingsDirError` (exit 78) with a hint
to pass `--transcript` explicitly or set the variable in
`~/.tool-agents/convo-coach/.env`.

---

### macrec `.env` Template at `~/.tool-agents/macrec/.env`

Path: `/Users/giorgosmarinos/.tool-agents/macrec/.env` (exists, mode `0600`,
folder mode `0700`). Current content is minimal:

```sh
# macrec environment overrides
# Format: KEY=value
```

This is the bootstrap-seeded skeleton. It demonstrates the convention
`convo-coach` must mirror: create `~/.tool-agents/convo-coach/` (mode `0700`)
and seed `~/.tool-agents/convo-coach/.env` (mode `0600`) with commented
placeholders for all eight standard LLM provider groups plus
`CONVO_COACH_PROVIDER`, `CONVO_COACH_MODEL`, `CONVO_COACH_LOG_LEVEL`,
`CONVO_COACH_DEBOUNCE`, and `MACREC_RECORDINGS_DIR`.

Swift reference implementation for the bootstrap pattern lives in:
`Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift` and
`Sources/MacrecCore/Bootstrap/EnvFileStore.swift`.

---

### `~/.claude/agents/tool-doc-config-architect.md` — Eight Standard LLM Providers

Path: `/Users/giorgosmarinos/.claude/agents/tool-doc-config-architect.md`
(confirmed present; read in full during this scan).

The agent mandates exactly **eight** standard providers for every LLM-enabled
tool (`llm_required: yes`). Vendor-canonical env var names are authoritative —
no tool-name prefix allowed:

| Provider | Required env vars | Optional env vars |
|---|---|---|
| Direct OpenAI | `OPENAI_API_KEY` | `OPENAI_BASE_URL`, `OPENAI_ORG_ID` |
| Direct Anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` |
| Google Gemini | `GOOGLE_API_KEY` (alias: `GEMINI_API_KEY`) | — |
| Azure OpenAI | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` | `AZURE_OPENAI_API_VERSION` |
| Azure AI Inference (Foundry) | `AZURE_AI_INFERENCE_KEY`, `AZURE_AI_INFERENCE_ENDPOINT` | — |
| Ollama (local) | `OLLAMA_HOST` | — |
| LiteLLM proxy | `LITELLM_PROXY_URL`, `LITELLM_MASTER_KEY` | — |
| MLX-LM (local) | reuses `OPENAI_BASE_URL` | — |

The `/tool-conventions scaffold convo-coach` slash command invokes this agent
and will produce `docs/tools/convo-coach.md` and `~/.tool-agents/convo-coach/`
with the correct modes and a fully populated `.env` template.
**Do NOT hand-roll these artifacts** — per CLAUDE.md constraint C-2.

---

### LLM Provider Code — Greenfield

No TypeScript code in this project currently talks to any LLM chat/completion
endpoint. The `dual-transcript-merger` tool has zero LLM dependencies. The
Swift `macrec` tool calls transcription APIs (Gemini REST, Soniox WebSocket,
Azure OpenAI, ElevenLabs) but these are audio-in/text-out STT APIs, not
chat/completion. All eight LLM provider implementations in `convo-coach` will
be written from scratch.

---

### `Sources/MacrecCore/Bootstrap/ToolAgentsBootstrap.swift` — Bootstrap Pattern

Swift reference for what `convo-coach` must replicate in TypeScript:

- Creates `~/.tool-agents/<toolName>/` with mode `0700` (using `mkdirSync` +
  `chmodSync` in Node terms) on first invocation if absent.
- Seeds `~/.tool-agents/<toolName>/.env` with mode `0600` if the file does not
  exist. Content is a minimal `# <toolName> environment overrides\n# Format: KEY=value\n` skeleton.
- Idempotent — safe to call on every startup.

---

### Out of Scope for `convo-coach`

The following modules are NOT implicated by the `convo-coach` implementation:

- `Sources/MacrecCore/Transcription/Providers/` — all transcription provider
  implementations (gemini, soniox, azure, elevenlabs, whisperkit, apple). `convo-coach`
  only reads the sidecar files these providers produce.
- `Sources/macrec-ui/` and `Sources/MacrecUIKit/` — the menu-bar app; no changes.
- `Sources/MacrecCore/Recording/` — audio capture pipeline; no changes.
- `Sources/macrec/` — CLI entry point; no changes.
- `tools/dual-transcript-merger/` — `convo-coach` does NOT depend on, wrap, or
  modify the merger. It consumes raw macrec sidecars directly.
- `scripts/package-macrec-ui-app.sh` — packaging script; irrelevant.
- `test_scripts/` Swift E2E scripts — unaffected. New `convo-coach` shell tests
  are added here per convention, under `test_scripts/convo-coach/` or as
  named `e2e-convo-coach-*.sh` files at the top level.

---

### New Integration Points

The following are new to this project and have no existing code to extend:

1. **LLM chat/completion provider abstraction** — `src/providers/` under
   `tools/convo-coach/`. Eight implementations, each in its own module. Landing
   in `tools/convo-coach/src/providers/{openai,anthropic,gemini,azure-openai,
   azure-ai-inference,ollama,litellm,mlx}.ts`.

2. **SSE streaming parser** — Server-Sent Events parsing for OpenAI/Azure/LiteLLM/
   MLX streaming responses. Node's built-in `fetch` with `response.body` async
   iteration is the recommended approach (no external dependency).

3. **`/dev/tty` keystroke detection** — opening `/dev/tty` directly while stdin
   is piped, for the Enter-to-trigger stdin streaming mode (FR-CC-6). Node's
   `fs.openSync('/dev/tty', 'r')` pattern.

4. **SRT/VTT parser** — `convo-coach` must parse SRT and VTT sidecars in
   addition to JSONL and TXT. No existing TypeScript code for this exists in the
   project; implement in `src/parsers/srt.ts` and `src/parsers/vtt.ts`.

5. **Token-budget lookup table** — `src/providers/model-context-windows.ts` —
   static map of model id → context-window token count. Entirely new.

---

## 5. Notes

- **`MACREC_RECORDINGS_DIR` is `convo-coach`-owned, not macrec-native.** The
  env var name is introduced by the `convo-coach` spec. The downstream planner
  must update FR-CC-3 and AC-CC-7 to clarify this and ensure the `.env`
  template documents it as a `convo-coach` knob, not a macrec knob. The spec's
  "reading macrec's configuration chain" statement is misleading — macrec has
  no such chain entry for a folder.

- **`isFinal` field in dual-mode JSONL example.** The `docs/tools/macrec.md`
  §DT-7 example lines include `"isFinal":true`, but `TranscriptSegment.swift`
  has no `isFinal` property and `JSONLTranscriptWriter`'s `Wire` struct does
  not encode it. The field may appear in real sidecars via `extras`
  round-tripping, or may be a documentation artefact. `convo-coach`'s parser
  should treat it as an optional/unknown field — ignore it if present, do not
  require it.

- **Single test file for `dual-transcript-merger`.** Only `merger.test.ts`
  exists under `tools/dual-transcript-merger/test/`. Parser and config logic
  have no dedicated unit tests. `convo-coach` should not repeat this gap —
  the spec mandates ≥80% line coverage (NFR-CC-7).

- **No existing `tools/convo-coach/` directory.** The entire TypeScript package
  must be created from scratch. The closest structural precedent is
  `tools/dual-transcript-merger/` — replicate its layout exactly before
  running `/tool-conventions scaffold convo-coach`.
