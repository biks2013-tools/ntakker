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
- **Implication**: anyone running macOS 13–25 cannot build or run `macrec` after this change. If wider compatibility is needed later, the streaming provider could fall back to `SFSpeechRecognizer` via `#available(macOS 26, *)` gating.

## Tools

### macrec

macOS dual-source audio recorder: captures system audio (via `ScreenCaptureKit`) and the microphone (via `AVFoundation`) simultaneously and writes to `m4a` / `wav` / `caf` in `mixed`, `split`, or `stereo-split` layouts. Supports foreground execution (Ctrl-C to stop) or detached background execution paired with a `stop` subcommand. Foreground recordings can optionally stream the captured audio to a real-time speech-to-text provider (Google Gemini Live in v1) via `--transcribe`, producing a JSONL / TXT / SRT / VTT transcript sidecar alongside the audio file.

Documentation: [docs/tools/macrec.md](docs/tools/macrec.md)

### macrec-ui

macOS menu-bar status item app for the `macrec` audio recorder. Provides a popover toolbar to start, pause, resume, stop, and split recordings, with elapsed-time, format/layout/folder/mic selectors, permission status, and per-source level meters; drives `MacrecCore` in-process and ships under a separate bundle id (`com.local.macrec-ui`) so its TCC grants are independent of the CLI's. The popover also exposes opt-in live transcription (None / Gemini Live picker, source picker, sidecar-format picker, inline live-transcript panel, one-time privacy-disclosure dialog, and per-recording cost / latency display).

Documentation: [docs/tools/macrec-ui.md](docs/tools/macrec-ui.md)
