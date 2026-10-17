<structure-and-conventions>
## Structure & Conventions — Documentation Map

<!-- Maintained automatically. The master copy lives at
     ~/.claude/structure-and-conventions.md (claude-workdocs repo) and the SessionStart
     hook ~/.claude/scripts/sync-claude-md.sh keeps this copy of the block up to date —
     edit the master, never this block. The block is committed with the repository on
     purpose: it tells anyone (human or agent) working with this repo where the
     project's documentation lives and how to read and maintain it. -->

### Where the documentation lives

- `docs/plans/` — every plan, one file per plan, named `plan-NNN-<indicative-description>.md`.
- `docs/design/` — all other planning and design documents:
  - `project-design.md` — the complete, always-current project design; update it with every new design or design change.
  - `project-functions.md` — the registry of all functional requirements and feature descriptions.
  - `configuration-guide.md` — the project's configuration guide, when one exists (structure below).
- `docs/reference/` — all reference material collected for the project.
- `docs/refined_requests/` — every refined request specification (create the folder if missing), one file per request named `refined-request-NNN-<slug>.md`. `NNN` is a zero-padded three-digit sequential number: the next number is the highest `NNN` already present in the folder plus one, starting at `001` — and when the category has an archive history branch, the archive's numbering counts too (see "Archiving historical documents" below). `<slug>` is the request slug reused by all downstream artifacts of the same request.
- `docs/prompts/` — every prompt created while working on the project (create the folder if missing), one file per prompt named `NNN-<indicative-description>.md`. `NNN` is a zero-padded three-digit sequential number: the next number is the highest `NNN` already present in the folder plus one, starting at `001` — and when the category has an archive history branch, the archive's numbering counts too (see "Archiving historical documents" below). The description states the prompt's use and purpose.
- `docs/tools/<tool-name>.md` — one dedicated documentation file per project tool.
- `test_scripts/` — every test script goes here; create the folder if it doesn't exist.
- `Issues - Pending Items.md` (project root) — the register of every issue, pending item, inconsistency, or discrepancy detected while working on the project. Pending items come first (most critical and important on top), completed items after. Whenever a defect or issue is fixed, check this file for an item to remove.

### How to use the documentation

- Every time an issue is solved, it must be resolved AND both the issue and the solution must be thoroughly documented.
- This file's "Tools" section (when present) lists each project tool with a one-or-two-sentence description of what it is capable of and the relative path to its dedicated documentation file under `docs/tools/` — retrieve the full documentation from there whenever it is needed. Full tool documentation must never be inlined into this file.
- Before writing any code script, consult the "Tools" section and the documentation under `docs/tools/` to check whether the planned code fits the scope of an existing tool. If so, implement it as an extension of that tool; otherwise build a generic, abstract version of the code as a new tool in the project's toolset, document it under `docs/tools/`, and reference it in the "Tools" section. The goal is to progressively grow the tools needed to test, evaluate, generate data, collect information, etc., and reuse them consistently.

### Archiving historical documents (history branches)

- A project MAY move accumulated historical, write-once process artifacts — deployment reports, codebase scans, refined requests, plans, session handoffs, and similar — off the default branch to keep its documentation lean. Living, authoritative documents (`project-design.md`, `project-functions.md`, the guides, tool docs, the issue register) are never archived.
- Each archived category gets a dedicated **orphan, docs-only branch** named `<category>-history`, whose tree contains ONLY that category's files at their original repository paths — so retrieval paths never change: `git show <category>-history:<original-path>`, no branch switching required. A pointer note/README stays in the category's folder on the default branch stating the branch name, the retrieval command, and (for numbered categories) the next number. Archive branches are append-only: never rebase, rewrite, delete, or merge them.
- **Numbering across the archive**: for every `NNN`-numbered folder, the next number is `max(highest NNN in the folder, highest NNN on the category's archive branch) + 1`. Before creating the FIRST document of a numbered category, check whether an archive branch exists for it (the folder's README/pointer note, or `git branch --list --all '*-history'`) and continue from the archive's highest number — never restart at `001`, never reuse an archived number. The archive branch is authoritative over the pointer note's recorded "next number" if they disagree.
- **Migration** runs in a temporary linked worktree so the main checkout — and any uncommitted changes in it — is never disturbed: `git worktree add <tmp> <category>-history` (first-time archiving: `git worktree add --detach <tmp> <default-branch>`, then inside it `git switch --orphan <category>-history` and `git checkout <default-branch> -- <category-paths>`); bring the new artifacts over at their original paths and commit ONLY the category's files; then on the default branch `git rm` the migrated files, update the pointer note, and commit referencing the archive commit. Verify with `git ls-tree -r <category>-history --name-only` and a `git show` spot-check.
- The project's concrete category → branch registry (which categories are archived, under which branch names) is project-specific and lives OUTSIDE this synced block — typically a "Document Archiving Strategy" section in the project's CLAUDE.md.

<configuration-guide>
- A configuration guide, when requested, is created at `docs/design/configuration-guide.md` and explains:
  - When multiple configuration options exist (config file, env variables, CLI params, etc.), what the options are and the priority of each one.
  - The purpose and use of each configuration variable.
  - How the user can obtain such a configuration variable.
  - The recommended approach for storing or managing the variable.
  - Which options exist for the variable and what each option means for the project.
  - Any default value the parameter has.
  - For configuration parameters that expire (e.g., PAT keys, tokens), propose adding a parameter that captures the expiration date, so the app or service can proactively warn users to renew.
</configuration-guide>

</structure-and-conventions>

## Project Memory / Approved Exceptions

This section records explicit, user-approved exceptions to the Structure & Conventions above. Every entry must include the rule it overrides, the reason for the exception, the date approved, and the scope.

### Exception 001 — Implementation language: Swift instead of TypeScript

- **Rule overridden**: "When I ask you to create tools in the context of a project everything must be in Typescript."
- **Approved**: 2026-04-26
- **Scope**: This project (`recording-tool`) and the macOS audio recording tool implemented within it. The TypeScript rule continues to apply to any future tools added to this project unless they are similarly approved as exceptions.
- **Reason**: The tool must capture macOS system audio (audio playing through Music, Spotify, browsers, Zoom, Teams, etc.) plus the built-in microphone. The first-class APIs for this on macOS 13+ are `ScreenCaptureKit` (system audio) and `AVFoundation` (microphone). Both are Swift/Objective-C frameworks with no first-class Node/TypeScript bindings. Implementing the tool natively in Swift avoids brittle FFI shims and is the platform-recommended path.
- **Implication**: All conventions that explicitly assume Node/TypeScript (e.g. `process.env` resolution, `~/.tool-agents/[tool-name]/.env` durable defaults, the env-variable precedence chain) still apply in spirit — they will be implemented using Swift equivalents (`ProcessInfo.processInfo.environment`, `FileManager`, etc.) so the user-facing configuration behavior is identical to a TypeScript tool.

### Exception 002 — Deployment target bumped to macOS 26 for SpeechAnalyzer

- **Rule overridden**: implicit project assumption from plan-001 that the deployment target stays at `macOS 14` for broad compatibility.
- **Approved**: 2026-04-28
- **Scope**: Project-wide (Package.swift `platforms: [.macOS(.v26)]`)
- **Reason**: plan-005 adds on-device live transcription via `SpeechAnalyzer`, introduced in macOS 26 (Tahoe). The new API unlocks real-time partials (~80–250 ms first-partial latency), Swift-concurrency-native results streams, and dual-locale parallel recognition. Quality and latency materially exceed the macOS 14-compatible `SFSpeechRecognizer` on-device mode. The project's primary user runs macOS 26.4.1; the bump is acceptable for v1.5.
- **Implication**: anyone running macOS 13–25 cannot build or run `ntakker-cli` after this change. If wider compatibility is needed later, the streaming provider could fall back to `SFSpeechRecognizer` via `#available(macOS 26, *)` gating.

### Exception 003 — `convo-coach` default LLM provider

- **Rule overridden**: "You must never create fallback solutions for configuration settings. In every case a configuration setting is not provided you must raise the appropriate exception."
- **Approved**: 2026-05-02
- **Scope**: The `convo-coach` TypeScript tool (`tools/convo-coach/`) only — strictly limited to its `COACH_PROVIDER` resolution.
- **Reason**: Forcing the user to pass `--provider <name>` on every invocation (or to explicitly set `COACH_PROVIDER` in `~/.tool-agents/convo-coach/.env`) is unergonomic for a tool intended to be invoked many times during a single conversation. The user's primary LLM access in this project is through Azure OpenAI (the `AZURE_OPENAI_*` vars are already in the shell). Defaulting to `azure-openai` lets bare `convo-coach` invocations work out of the box on the user's machine while still raising clear errors if the Azure OpenAI credentials themselves are missing.
- **Implication**: When neither `--provider` nor `COACH_PROVIDER` is set, `convo-coach` selects `azure-openai`. This is *only* the provider selection — every credential the chosen provider requires (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_VERSION`) must still be present in the resolution chain or the tool raises `ConfigError` with exit code 78 (MISSING_CONFIG). Default model IDs (e.g. `gpt-4o-mini` for openai) are NOT covered by this exception — they remain provider-recommended values applied when the user has explicitly chosen a provider but not a model, which the project treats as model-metadata, not a credential fallback.

### Exception 004 — `convo-coach` operational defaults

- **Rule overridden**: "You must never create fallback solutions for configuration settings. In every case a configuration setting is not provided you must raise the appropriate exception."
- **Approved**: 2026-05-29
- **Scope**: The `convo-coach` TypeScript tool (`tools/convo-coach/`) only — strictly limited to the four **operational** parameters listed below. Does NOT cover any credentials.
- **Reason**: These four parameters control runtime *ergonomics* (where to scan for recordings, how often to debounce, how to handle context overflow, where local Ollama listens), not service authentication. Requiring an explicit value on every invocation produces no security or correctness benefit — only friction. They are explicitly documented in `docs/tools/convo-coach.md` with their defaults so users always know what they get.
- **Implication**: When unset, these four parameters fall back to the documented defaults below. Every credential required by the selected provider continues to be governed by the strict no-fallback rule and raises `ConfigError` (exit 78) when absent.

| Variable | Default when unset | Source |
|---|---|---|
| `NTAKKER_RECORDINGS_DIR` | `~/Recordings` | `tools/convo-coach/src/index.ts:88` |
| `COACH_DEBOUNCE` | `15s` | `tools/convo-coach/src/index.ts:282` |
| `COACH_ON_OVERFLOW` | `truncate-start` | `tools/convo-coach/src/index.ts:98` |
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | `tools/convo-coach/src/providers/ollama.ts:34` |

## Tools

### ntakker-cli

macOS dual-source audio recorder: captures system audio (`ScreenCaptureKit`) and the microphone (`AVFoundation`) simultaneously and writes to `m4a` / `wav` / `caf` in `mixed`, `split`, or `stereo-split` layouts. Optional opt-in live transcription via nine STT providers (Apple, Apple Cloud, Gemini, Soniox with default-on diarization, Azure batch, Azure Realtime, ElevenLabs, WhisperKit, Parakeet multilingual on-device), opt-in microphone acoustic echo cancellation (plan-014 v5, off by default), and true source-split transcription (`--transcribe-source both`).

Documentation: [docs/tools/ntakker-cli.md](docs/tools/ntakker-cli.md)

### ntakker

macOS menu-bar status item app that drives the same `NtakkerCore` engine as the CLI under a separate bundle id (`com.giorgosmarinos.ntakker`) for independent TCC grants. Popover surface exposes start / stop / pause / resume / split (the status bar shows Pause and Split while recording, Resume while paused — EVAL-2026-10-16 UI-2, fixed in plan-023), format / layout / folder / mic selectors, permission status, per-source level meters, opt-in live transcription with inline panel, and the opt-in mic echo-cancellation toggle (plan-014).

Documentation: [docs/tools/ntakker.md](docs/tools/ntakker.md)

### ntakker-studio

macOS Dock app (`com.giorgosmarinos.ntakker-studio`, plan-024) for exploring finished recordings: library and full-text search across every transcript, playback with the transcript followed line by line and click-to-jump, cutting ranges into a new copy with re-timed transcripts, Ask and meeting minutes over the whole transcript (ntakker's Ask settings), speaker renaming, transcript text edits, and re-transcription with ntakker's batch providers.

Documentation: [docs/tools/ntakker-studio.md](docs/tools/ntakker-studio.md)

### convo-coach

TypeScript CLI that reads a `ntakker-cli` transcript sidecar and streams live conversational coaching advice from any of the eight standard LLM providers (OpenAI, Anthropic, Google Gemini, Azure OpenAI, Azure AI Inference, Ollama, LiteLLM, MLX-LM) via LangChain (`@langchain/*`), writing every response to a dated `.advice-*.md` sidecar. Defaults to `azure-openai` when neither `--provider` nor `COACH_PROVIDER` is set (Project Memory Exception 003); four operational parameters fall back to documented defaults (Exception 004).

Documentation: [docs/tools/convo-coach.md](docs/tools/convo-coach.md)
