<requirements-branch>
## ⚠️ You are on the `requirements` branch

This worktree (`recording-tool-requirements/`) is checked out on the **`requirements` branch** — a long-lived parallel branch dedicated to **continuous requirements development** for the `macrec` macOS audio-recording tool and its sibling tools. It is NOT the implementation branch. Any code, architecture, or infrastructure work belongs on `master` — not here.

### Why this branch exists
Business requirements development is treated as a **first-class, continuous workstream** that runs in parallel to implementation. This branch is the sandbox where requirements are iterated, refined, explored, and challenged — without polluting `master` with half-formed thinking. When a version of the requirements is ready to be adopted, the user explicitly requests a merge to `master`.

### Folder layout (specific to this branch)

```
recording-tool-requirements/
├── inputs/      ← raw input material: emails, transcripts, investigations,
│                  brainstorm dumps, stakeholder feedback. Append-only.
├── current/     ← the single consolidated requirements document.
│                  One file: requirements.md (+ requirements.html mirror).
│                  Rewritten on each consolidation, not appended.
│                  Also hosts product-definition.md — the high-level
│                  "what the product is" reference.
└── items/       ← one file per atomic requirement: REQ-NNN-<topic>-<slug>.md
                   Numbered sequentially, classified by topic, never deleted
                   once a number is assigned.
```

Each folder has its own `README.md` describing its detailed rules — **read those before working in the folder.**

### Workflow
1. **New input arrives** (email, meeting, research result, field observation) → captured as a file in `inputs/`.
2. **Distinct requirements are identified** from inputs → each becomes a new `REQ-NNN-<topic>-<slug>.md` in `items/` at status `draft`.
3. **Items mature** through status transitions: `draft → proposed → accepted` (or `deferred`/`rejected`/`superseded`).
4. **Periodically** the accepted items are consolidated into `current/requirements.md` (and its HTML mirror).
5. **Adoption to `master`** happens only when the user explicitly requests it — usually via a merge commit that records the adopted version.

### Naming convention for individual requirements
`REQ-NNN-<topic>-<short-slug>.md` — see `items/README.md` for the topic taxonomy and full conventions. The number is **sequential, never reused**.

### What does NOT belong on this branch
- Source code (`Sources/`, `Tests/`), build artifacts (`.build/`, `dist/`), package manifests (`Package.swift`, `package.json`, etc.).
- Architecture decisions records (ADRs) and design documents — those live on `master` under `docs/design/`.
- Implementation plans (`plan-xxx-*.md`) — also on `master` under `docs/design/`.
- The functional requirements registry (`docs/design/project-functions.md`) — that is the *adopted* mirror on `master`; the *evolving* requirements live here.
- The `Issues - Pending Items.md` — on `master`.
- Tool documentation (`docs/tools/*.md`) — on `master`.

If a session is about to write code or implementation-flavored docs, it is on the wrong branch. Switch to the `master` worktree at `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/`.

### Sync with `master`
- The `<project-purpose>` and `<structure-and-conventions>` blocks below are kept in sync with `master` so the project's identity travels with both branches.
- This `<requirements-branch>` block is **specific to this branch** and should not be merged into `master` — drop it during a requirements-to-master merge, or treat it as a known conflict to resolve in favor of `master`.

</requirements-branch>

<project-purpose>
## Project Purpose — Ambition & Intention

> This section captures the founding intent of the **recording-tool** project so that any future session can stay aligned with the original vision. Do not modify it without explicit confirmation from the user.

### What this project is
**recording-tool** is a macOS-native ecosystem centred on `macrec` — a dual-source audio recorder that captures **system audio** (anything playing through the Mac: Music, Spotify, browsers, Zoom, Teams, conference platforms) **and the microphone** **simultaneously**, with optional **live speech-to-text transcription** and **post-recording conversational coaching**. It ships as a small family of cooperating local-first tools, not a single monolith.

### Why it exists
macOS does not provide a first-class way to record what's coming **out of** the speakers together with what's going **into** the microphone. The legacy workarounds (BlackHole / Loopback / Soundflower virtual devices) require kernel extensions, system reconfiguration, and produce fragile recording chains. Since macOS 13, `ScreenCaptureKit` exposes a sanctioned system-audio path; `recording-tool` exists to package that capability — together with the microphone path, transcription, and downstream coaching — into a tool a single user can run on their own machine without installing kernel drivers or sending audio to a server they don't trust.

### Audience
A **single-user, local-first** product, aimed at:
- **Knowledge workers** in meetings (Zoom / Teams / Google Meet) who want a high-fidelity recording of both sides of the conversation, with a transcript on their disk and live coaching prompts during the call.
- **Researchers and learners** capturing podcasts, interviews, lectures, or training material that mixes recorded media with their own commentary.
- **Power-users** who want CLI-driven, scriptable recording (`macrec start --detach`, `macrec stop`) integrated into their own automations.
- **Developers and analysts** consuming the JSONL transcript sidecars as structured input for downstream tooling (search, summarisation, agent pipelines).

### Primary goals — in priority order
1. **Faithful dual-source capture** — bit-perfect record of both system and microphone, time-aligned within ±20 ms, never lossy on the audio file even when downstream layers (network, STT, coach) misbehave.
2. **Choice of where the audio goes** — `mixed` (one summed stereo file), `split` (two files), or `stereo-split` (one stereo file with mic on one channel and system on the other). All formats addressable: `m4a` (AAC), `wav` (PCM), `caf` (PCM).
3. **Frictionless transcription** — pick an STT provider per session (Apple on-device, Apple Cloud, Google Gemini, Soniox, Azure OpenAI batch + realtime, ElevenLabs, WhisperKit, Parakeet on-device multilingual) and get a sidecar transcript in `jsonl`, `txt`, `srt`, or `vtt` next to the audio.
4. **Conversation coaching as a downstream consumer** — `convo-coach` reads a transcript sidecar and streams live LLM-driven coaching advice while the conversation continues.
5. **First-class privacy posture** — on-device default for transcription where available; explicit per-provider privacy disclosure when audio is about to leave the machine; per-provider opt-in storage so users never accidentally share more than they intend.

Secondary goals: dual-mode transcription (on-device + cloud running in parallel against the same audio for accuracy comparison), per-source split transcription (each side of the conversation transcribed with its own provider/locale), software microphone acoustic echo cancellation (so the system-audio bleed-back doesn't pollute the mic transcript).

### Critical requirements (non-negotiable)
- **macOS-native — Swift / SwiftPM**. `ScreenCaptureKit` + `AVFoundation` are the sanctioned APIs. Project Memory Exception 001 records the explicit deviation from the "everything is TypeScript" project convention for this reason.
- **Universal binary** (`arm64` + `x86_64`); builds on Apple Command-Line Tools (no full Xcode required).
- **No virtual audio devices** required — never ask the user to install BlackHole, Loopback, or any kext.
- **No silent fallback for configuration** — if a required env var or flag is missing, raise a typed error and exit with a documented exit code; never substitute a "reasonable default" for a credential.
- **Recording integrity is sacrosanct** — any failure in transcription, coaching, UI, or downstream tooling MUST be non-fatal to the audio file. The audio file is the ground truth.
- **TCC permissions** are explicit and surfaced: Screen Recording (for `ScreenCaptureKit`), Microphone (for `AVCaptureSession`), Speech Recognition (for the Apple STT paths). The CLI and the UI both refuse to start when grants are missing and link to the System Settings panel that resolves it.
- **Companion tools are TypeScript** by default (`dual-transcript-merger`, `convo-coach`) — they live under `tools/<name>/`, comply with `tool-conventions`, and use the standard four-tier env-var resolution chain.

### What it is explicitly NOT
- Not a server. There is no listening port, no API surface, no shared backend. Every recording stays on the user's disk unless they opt-in to a cloud STT provider, in which case only the audio chunks needed for transcription leave the machine.
- Not a podcast / DAW production app. No mixing console, no effects rack, no multi-track timeline editing. The output is the raw recorded audio (optionally mixed, optionally split).
- Not a phone-system / SIP integration. Recording captures whatever the Mac's audio subsystem is already playing — the source of that audio (browser, video-call app, music player) is outside the tool's scope.
- Not a transcription service. Transcription is plug-in: providers come and go, the tool is the orchestrator and the persistence layer, not the recogniser.
- Not a multi-user app. There is no notion of accounts, sharing, or team workspaces. Every config file is single-user (`~/.tool-agents/<name>/`).

### Current technical direction
- **Two Swift executables sharing one core library** (`MacrecCore`): the `macrec` CLI for headless / scripted use, and the `macrec-ui` menu-bar app for interactive use. Both link `MacrecCore` directly (in-process; the UI is NOT a shell wrapper around the CLI).
- **Two TypeScript companion CLIs**: `dual-transcript-merger` (merges Channel A + Channel B JSONL into a single interleaved transcript with cross-language hallucination filtering) and `convo-coach` (streams LLM coaching advice from a transcript via the Vercel AI SDK against eight provider backends).
- **Configuration**: four-tier env-var resolution chain — shell env → `~/.tool-agents/<tool-name>/.env` → local `./.env` → CLI flags (lowest to highest priority). LLM provider env vars use vendor-canonical names (`OPENAI_API_KEY`, `AZURE_OPENAI_*`, `GOOGLE_API_KEY`, etc.).
- **Deployment target**: macOS 26 (Tahoe). Project Memory Exception 002 records the bump from macOS 14 (driven by `SpeechAnalyzer` adoption in plan-005).

### Source documents to consult first (on `master`)
- `docs/design/project-design.md` — the authoritative technical design (architecture diagrams, module interfaces, threading model, configuration precedence, logging, sequence diagrams, ADRs).
- `docs/design/project-functions.md` — the adopted functional-requirements registry (FR-1..FR-58, FR-AS-*, FR-AZ-*, FR-EL-*, FR-XS-*, NFR-1..NFR-21, AC-*).
- `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, `docs/tools/dual-transcript-merger.md`, `docs/tools/convo-coach.md` — per-tool documentation.
- `docs/design/plan-001-recording-tool.md` … `plan-014-aec-stability.md` — historical implementation plans, in order.

### Alignment check for any future session
Before making any architecture, dependency, or scope decision, verify it against:
1. Does it preserve **dual-source capture** as a first-class capability (system + mic, time-aligned, never one without the other in dual mode)?
2. Does it preserve **recording integrity** as non-blocking to every other concern (STT failure ⇒ audio still fine)?
3. Does it preserve the **single-user, local-first, no-server** posture, with cloud calls strictly opt-in and disclosed?
4. Does it respect the **TCC + permissions model** (Screen Recording, Microphone, Speech Recognition prompts; deep links to System Settings on denial)?
5. Does it respect the **TypeScript-for-tools / Swift-for-macrec** split (Project Memory Exception 001)?

If a proposed change conflicts with any of the above, surface it explicitly to the user before proceeding.

</project-purpose>

<structure-and-conventions>
## Structure & Conventions

- Every time you want to create a test script, you must create it in the test_scripts folder. If the folder doesn't exist, you must make it.

- All the plans must be kept under the docs/design folder inside the project's folder in separate files: Each plan file must be named according to the following pattern: plan-xxx-<indicative description>.md

- The complete project design must be maintained inside a file named docs/design/project-design.md under the project's folder. The file must be updated with each new design or design change.

- All the reference material used for the project must be collected and kept under the docs/reference folder.
- All the functional requirements and all the feature descriptions must be registered in the /docs/design/project-functions.MD document under the project's folder.

<configuration-guide>
- If the user ask you to create a configuration guide, you must create it under the docs/design folder, name it configuration-guide.md and be sure to explain the following:
  - if multiple configuration options exist (like config file, env variables, cli params, etc) you must explain the options and what is the priority of each one.
  - Which is the purpose and the use of each configuration variable
  - How the user can obtain such a configuration variable
  - What is the recomented approach of storing or managing this configuration variable
  - Which options exist for the variable and what each option means for the project
  - If there are any default value for the parameter you must present it.
  - For configuration parameters that expire (e.g., PAT keys, tokens), I want you to propose to the user adding a parameter to capture the parameter's expiration date, so the app or service can proactively warn users to renew.
</configuration-guide>

- Every time you create a prompt working in a project, the prompt must be placed inside a dedicated folder named prompts. If the folder doesn't exists you must create it. The prompt file name must have an sequential number prefix and must be representative to the prompt use and purpose.

- You must maintain a document at the root level of the project, named "Issues - Pending Items.md," where you must register any issue, pending item, inconsistency, or discrepancy you detect. Every time you fix a defect or an issue, you must check this file to see if there is an item to remove.
- The "Issues - Pending Items.md" content must be organized with the pending items on top and the completed items after. From the pending items the most critical and important must be first followed by the rest.

- When I ask you to create tools in the context of a project everything must be in Typescript.

- **Tool creation is MANDATORY via `/tool-conventions scaffold <tool-name>`.** Do NOT scaffold a tool's documentation file or its `~/.tool-agents/<tool-name>/` configuration folder by hand under any circumstances. Always invoke the slash command, which dispatches the `tool-doc-config-architect` subagent (`~/.claude/agents/tool-doc-config-architect.md`). The subagent owns the full specification — the documentation file format (the `<toolName>` XML block under `docs/tools/<tool-name>.md`), the configuration folder structure and modes (`~/.tool-agents/<tool-name>/` at `0700`, `.env` at `0600`), the four-tier env-var resolution chain (shell env → `~/.tool-agents/<name>/.env` → local `.env` → CLI flags, lowest to highest priority), the vendor-canonical LLM provider env-var names (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, `AZURE_OPENAI_*`, `AZURE_AI_INFERENCE_*`, `OLLAMA_HOST`, `LITELLM_*`), and the required set of eight standard LLM providers every LLM-enabled tool must support out of the box. To inspect the full specification, read the subagent prompt directly. For existing tools, run `/tool-conventions audit <tool-name>` to verify conformance against the same specification.

- The project's CLAUDE.md file must NOT contain the full tool documentation. Instead, it must contain a "Tools" section with a concise reference entry for each tool that includes:
  - The tool's name
  - A high-level description of what the tool is capable of (one or two sentences)
  - The relative path to the tool's dedicated documentation file (e.g. `docs/tools/<tool-name>.md`) so that Claude can retrieve the full documentation any time it is needed.

  The slash command produces the recommended entry text after each scaffold for the user to review and apply.

- Every time I ask you to do something that requires the creation of a code script, I want you to examine the tools already implemented in the scope of the project (by consulting the "Tools" section of the project's CLAUDE.md and the corresponding documentation files under `docs/tools/`) to detect if the code you plan to write fits to the scope of an existing tool.
- If so, I want you to implement the code as an extension of the tool, otherwise I want you to build a generic and abstract version of the code as a tool, which will be part of the toolset of the project.
- Our goal is, while the project progressing, to develop the tools needed to test, evaluate, generate data, collect information, etc and reuse them in a consistent manner.
- All these tools must be referenced inside the project's CLAUDE.md (with their dedicated documentation files under `docs/tools/`) to allow their consistent reuse.

- When I ask you to locate code, I need to give me the folder, the file name, the class, and the line number together with the code extract.
- Don't perform any version control operation unless I explicitly request it.

- When you design databases you must align with the following table naming conventions:
  - Table names must be singular e.g. the table that keeps customers' data must be called "Customer"
  - Tables that are used to express references from one entity to another can by plural if the first entity is linked to many other entities.
  - So we have "Customer" and "Transaction" tables, we have CustomerTransactions.

- You must never create fallback solutions for configuration settings. In every case a configuration setting is not provided you must raise the appropriate exception. You must never substitute the missing config value with a default or a fallback value.
- If I ask you to make an exception to the configuration setting rule, you must write this exception in the projects memory file, before you implement it.

- Every time you are asked to solve an issue, you must resolve it AND thoroughly document both the issue and the solution.

<dependency-vetting>
- Before adding ANY new runtime dependency to a project (`package.json`, `pyproject.toml`, `go.mod`, etc.), you MUST verify the version you are about to pin is free of known security advisories. Apply this rule especially to:
  - **Browser/embedded-engine packages:** `electron`, `puppeteer`, `playwright`, `chromium`, `webview2` — they ship with full browser engines and accumulate CVEs fast.
  - **Test/build toolchains:** `vitest`, `vite`, `esbuild`, `webpack`, `rollup`, `parcel` — frequent dev-server-RCE advisories with transitive impact.
  - **Network/proxy libraries:** `node-http-proxy`, `http-proxy-3`, `proxy-chain`, `axios`, `node-fetch`, `request`, `got`, `undici`.
  - **Cryptography / auth libraries:** `jsonwebtoken`, `jose`, `bcrypt`, `node-forge`, `crypto-js`.

- Vetting procedure (run BEFORE writing the dependency into the manifest):
  1. Identify the latest stable major version available on the registry (e.g. `npm view <pkg> versions --json | tail -10` or `pnpm info <pkg> versions --json`).
  2. Check the package's security advisory page (GitHub Advisory Database, npmjs.com vulnerability tab, or `npm audit --package <pkg>@<version> --json`) for the candidate version.
  3. If the candidate version has unfixed advisories at HIGH severity or above, bump to the next non-vulnerable major (or, if no such version exists, surface the trade-off to the user via AskUserQuestion before proceeding).
  4. Pin to a caret range against the verified clean version (e.g. `"electron": "^39.8.5"`, not `"electron": "^38"`).
  5. Record the vetted-on date in a one-line comment in `Issues - Pending Items.md` under a "Dependency vetting log" section so future audits can date the decision.

- For ESPECIALLY fast-moving packages (`electron`, `vite`, `vitest`, `esbuild`), ALWAYS pull the latest stable major even when a reference implementation uses an older one. The reference's version is informational, not authoritative — verify it is still on a supported branch before adopting it verbatim.

- After installing, ALWAYS run the project's audit command (`pnpm audit`, `npm audit`, `pip-audit`, `cargo audit`, `go list -m -u -json all | nancy sleuth`, etc.) and confirm the advisory count is zero before marking the scaffolding step complete. Treat any HIGH-or-above advisory as a blocker; surface it before continuing.

- When a transitive dependency carries an advisory that the direct dependency has not yet fixed (e.g. `vitest@1` pulling `vite@5` with a CVE), use the package manager's override mechanism (`pnpm.overrides`, `npm overrides`, `yarn resolutions`, `cargo [patch]`) to force the fixed transitive version, AND document the override in `Issues - Pending Items.md` with its expiry condition (i.e. "remove this override once direct-dep X reaches version Y").
</dependency-vetting>

</structure-and-conventions>
