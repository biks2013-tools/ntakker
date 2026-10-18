<structure-and-conventions>
## Structure & Conventions

<request-refinement>
- **Every non-trivial request must begin with a Request Refinement step** before any planning, design, investigation, implementation, review, or testing work. The refinement converts the raw request into a self-contained, verifiable specification that ALL downstream steps consume.

- **When refinement IS required** (refine before doing anything else):
  - The request is broad, vague, or implicitly multi-step (e.g., "add authentication", "build a dashboard", "set up a CI/CD pipeline").
  - The request will trigger downstream activities such as planning, design, implementation, or testing — whether you execute them directly or via a skill/workflow.
  - The request spans multiple files, modules, or systems.
  - The acceptance criteria are not explicitly stated in the user's message.
  - The request mixes WHAT and HOW, or leaves either of the two underspecified.
  - The request is for a deliverable that will be consumed by others (documentation, research, design, infrastructure plan, etc.).

- **When refinement is NOT required** (skip and proceed directly):
  - Simple read-only or exploratory questions ("what does function X do?", "where is Y defined?", "show me file Z").
  - Trivial single-step actions ("rename variable A to B", "fix this typo", "run `pnpm install`").
  - Requests that are already a fully-specified instruction (the user has explicitly provided objective, scope, and acceptance criteria).
  - Continuations of an already-refined request — a refined-request file from the current conversation already covers the new ask.
  - Requests that invoke a workflow slash command (`/team-workflow`, `/change-workflow`, `/doc-workflow`, etc.) — those workflows run the refinement as their own Phase 1 internally; do NOT duplicate it at the orchestrator level. In that case, pass the raw request to the workflow and let it produce the refined-request file.

- **How to perform refinement**: Dispatch the `request-refiner` subagent (`~/.claude/agents/request-refiner.md`) via the Agent tool. Do NOT attempt to write the refined specification by hand — the subagent owns the full template (Category, Objective, Scope, Requirements, Constraints, Acceptance Criteria, Assumptions, Open Questions, Original Request) and the file-naming convention.

- **Where the refined-request file must be saved**: The subagent saves it as `docs/reference/refined-request-<descriptive-name>.md` inside the active project root. The `<descriptive-name>` slug is a short, lowercase, hyphenated description derived from the request objective (e.g., `refined-request-oauth2-auth.md`). If the `docs/reference/` folder does not exist, the subagent creates it. The refined-request file is the authoritative specification for the request — never edit it during execution. If the scope changes mid-flight, re-run the refiner and produce a new (or updated) refined-request file rather than mutating an existing one silently.

- **How the refined-request file must be passed to next steps**:
  - Capture the absolute path returned by the request-refiner subagent and treat it as `REFINED_REQUEST_FILE` for the duration of the conversation.
  - When invoking ANY downstream subagent (planner, designer, investigator, technical-researcher, codebase-scanner, coder, reviewer, dependency-validator, test-builder, integration-verifier, etc.), include the absolute path in the agent's instructions with a line such as: *"Read the refined request specification at `<REFINED_REQUEST_FILE>` to understand the full scope, requirements, and acceptance criteria."*
  - When invoking a workflow slash command (`/team-workflow`, `/change-workflow`, `/doc-workflow`, etc.), do NOT pre-run the refiner — the workflow's Phase 1 produces its own refined-request file and tracks it as `REFINED_REQUEST_FILE` throughout the workflow's phases. Pass the raw request to the workflow.
  - When invoking a skill (e.g. `taches-cc-resources:create-plans`, `huashu-design`, `presentation-maker:create-presentation`) that needs scope context, pass the `REFINED_REQUEST_FILE` path in the skill's context block so the skill consumes the refined specification rather than the raw request.
  - When you create the project plan (`docs/design/plan-NNN-<description>.md`), reference the `REFINED_REQUEST_FILE` path at the top of the plan so the linkage between specification and plan is permanent.

- **Explicit-skip rule**: If you decide a given request does NOT need refinement, state the reason briefly in your first response (e.g., "Skipping refinement — single-step read-only action.") so the user can override if they disagree.
</request-refinement>

<investigation-and-research>
- **Immediately AFTER request refinement**, evaluate whether the request needs an Investigation phase, a Technical Research phase, or both, before proceeding to planning, design, or implementation. The goal is to surface the landscape of available options (investigation) and/or fill in deep technical knowledge gaps (research) BEFORE committing to a plan.

- **Two distinct agents** — pick by purpose, not by domain:
  - `investigator` (`~/.claude/agents/investigator.md`) — answers **"WHICH approach should we take?"** It surveys the landscape of available options/tools/libraries/patterns, compares them with a trade-off matrix, and produces a justified recommendation. Works for any domain (development, documentation, infrastructure, design, training, etc.). Tools: WebSearch, WebFetch, Context7, project file reading.
  - `technical-researcher` (`~/.claude/agents/technical-researcher.md`) — answers **"HOW does X actually work?"** It produces deep technical documentation on a specific library, framework, API, SDK, or pattern that has already been chosen. Tools: WebSearch, WebFetch, Context7, mcp__fetch.
  - The two agents are complementary: investigator decides WHICH to use, then technical-researcher digs deep on the chosen one when needed.

- **When INVESTIGATION is required** (dispatch `investigator`):
  - The refined request has more than one plausible approach, technology, library, tool, or pattern to satisfy it.
  - A decision among external options materially affects scope, cost, complexity, or risk (e.g., "WebSockets vs SSE vs polling", "Auth0 vs Entra ID vs Keycloak", "Markdown vs Docusaurus vs MkDocs").
  - The project has no established convention for this kind of work yet.
  - The request explicitly asks to "investigate", "evaluate options", "compare", "recommend", or "research approaches".

- **When TECHNICAL RESEARCH is required** (dispatch `technical-researcher` — one per topic, parallelizable):
  - The investigation's "Technical Research Guidance" section flagged `Research needed: Yes` and lists one or more topics.
  - The chosen technology is new to the project and the team needs implementation-level depth (APIs, configuration, error handling, edge cases, best practices) beyond what the investigation gathered.
  - The request directly names a specific library/API/SDK and asks for usage guidance, integration patterns, or a "deep dive" — in this case, skip investigation and go straight to technical research.
  - The investigation found conflicting or insufficient information about a critical implementation aspect.

- **When BOTH are skipped** (proceed directly to planning):
  - The refined request can be satisfied with a single, obvious approach already used in the project.
  - The project's `CLAUDE.md`, `docs/design/project-design.md`, or an existing tool documentation already prescribes the approach.
  - The work is a localized change (rename, bug fix, formatting, minor refactor) where the implementation strategy is self-evident.
  - The request is a continuation of a previous workflow whose investigation/research artifacts are still valid and referenced in the current refined-request file.
  - The request was dispatched via a workflow slash command (`/team-workflow`, `/change-workflow`, `/doc-workflow`, etc.) — those workflows run Phase 3a (Investigator) and conditional Phase 3b (Technical Researcher) internally; do NOT duplicate at the orchestrator level.

- **How to perform investigation**: Dispatch the `investigator` subagent via the Agent tool. Pass it `REFINED_REQUEST_FILE` and, if available, the `CODEBASE_SCAN_FILE`. Do NOT attempt to write the investigation document by hand — the subagent owns the full template (Executive Summary, Context, Options Identified, Comparison Matrix, Recommendation, Technical Research Guidance, Implementation Considerations, References, Original Request) and the file-naming convention.

- **How to perform technical research**: Dispatch one `technical-researcher` subagent **per topic** flagged in the investigation's "Technical Research Guidance" section (or per topic identified directly from the refined request when skipping investigation). If multiple topics are independent, launch them in parallel using `run_in_background: true`. Pass each agent the topic name, focus areas, depth level, and the `INVESTIGATION_FILE` path (when applicable) for context.

- **Where the investigation file must be saved**: The `investigator` subagent saves it as `docs/reference/investigation-<descriptive-name>.md` inside the active project root. The `<descriptive-name>` slug is a short, lowercase, hyphenated description derived from the investigation topic (e.g., `investigation-real-time-notifications.md`). If `docs/reference/` does not exist, the subagent creates it. The file is the authoritative options-and-recommendation document — never edit it during execution; if new options surface later, re-run the investigator with an updated scope.

- **Where the technical research files must be saved**: The `technical-researcher` subagent saves each topic to `docs/research/<topic-name>.md` inside the active project root. The `<topic-name>` slug is a short, lowercase, hyphenated description of the specific technology/library/pattern (e.g., `docs/research/langgraph-streaming.md`, `docs/research/jose-jwt-validation.md`). If `docs/research/` does not exist, the subagent creates it. Each research file stands on its own and includes sources, assumptions, uncertainties, and code examples.

- **How investigation and research results must be passed to next steps**:
  - Capture the investigation file path as `INVESTIGATION_FILE` for the duration of the conversation.
  - Capture the list of technical research file paths as `TECHNICAL_RESEARCH_FILES` (a list — may have zero, one, or many entries).
  - When invoking ANY downstream subagent (planner, designer, codebase-scanner, coder, reviewer, test-builder, integration-verifier, etc.), include the paths in the agent's instructions, e.g.:
    - *"Read the refined request specification at `<REFINED_REQUEST_FILE>` for scope and acceptance criteria."*
    - *"Read the investigation document at `<INVESTIGATION_FILE>` for the recommended approach and rationale."*
    - *"If technical research was conducted, read the research documents at `<TECHNICAL_RESEARCH_FILES>` for deep technical details on the recommended approach."*
  - When invoking a workflow slash command (`/team-workflow`, `/change-workflow`, `/doc-workflow`, etc.), do NOT pre-run investigation/research — the workflow's Phase 3a and Phase 3b produce their own `INVESTIGATION_FILE` and `TECHNICAL_RESEARCH_FILES` and thread them through subsequent phases. Pass the raw request to the workflow.
  - When invoking a skill (e.g. `taches-cc-resources:create-plans`, `huashu-design`, `presentation-maker:create-presentation`) that needs approach context, pass both `INVESTIGATION_FILE` and `TECHNICAL_RESEARCH_FILES` paths in the skill's context block so the skill consumes the chosen approach and its technical depth rather than re-deciding it.
  - When you create the project plan (`docs/design/plan-NNN-<description>.md`), reference `INVESTIGATION_FILE` and any `TECHNICAL_RESEARCH_FILES` at the top of the plan, alongside the `REFINED_REQUEST_FILE`, so the linkage between specification → recommendation → research → plan is permanent and auditable.
  - When you update `docs/design/project-design.md`, the design decisions section must cite the relevant investigation and research files so future readers can trace any architectural choice back to its evidence.

- **Explicit-skip rule**: If you decide a given request does NOT need investigation or research (or skip just one of the two), state the reason briefly in your first response (e.g., "Skipping investigation — single established approach already used in this project. Skipping technical research — no new technology introduced.") so the user can override if they disagree.
</investigation-and-research>

<codebase-scanning>
- **Immediately AFTER investigation/research (or after refinement if both were skipped), and BEFORE planning/design**, evaluate whether the request requires Codebase Scanning. The scan answers two critical questions:
  1. **Is the feature already implemented (fully or partially)?** — to avoid duplicate work and surface reusable code/tools.
  2. **How does the current implementation fit the requested extension?** — to identify integration points, in-scope files, out-of-scope modules, and new landing locations the change must touch.

- **Which agent to dispatch**: The `codebase-scanner` subagent (`~/.claude/agents/codebase-scanner.md`) via the Agent tool. It is read-only on the codebase, produces a structured markdown file with mandatory YAML frontmatter (language, framework, package_manager, build_command, test_command, lint_command, entry_points, last_scanned_commit, scanned_for_request, scanned_at), and — when given a refined-request file — narrows its output to a request-driven "Integration Points" section that classifies each candidate file as In-Scope, Out-of-Scope, or New Integration Point.

- **When CODEBASE SCANNING is required** (dispatch `codebase-scanner`):
  - The request involves coding, implementation, refactoring, or any modification of source files in an existing project (i.e., not a purely greenfield project).
  - The request might extend, replace, or duplicate existing functionality — the scanner detects overlap before plan/design.
  - The request mentions a feature area, module, or pattern but the user has not pointed you at specific files (the scanner does the localization for you).
  - Multiple downstream subagents will run in parallel and need a shared, consistent view of the project's structure, conventions, build/test commands, and entry points (the YAML frontmatter prevents each agent from re-detecting these and disagreeing).
  - You are about to extend a feature whose current implementation you have not yet read end-to-end — the scan's Integration Points section maps the surface area.

- **When CODEBASE SCANNING is NOT required** (skip and proceed directly):
  - The project is greenfield — no source files exist yet under the project root (excluding `node_modules/`, `.git/`, `docs/`). There is nothing to scan.
  - The request is a pure read-only or exploratory question that has no implementation downstream.
  - The user has already pointed you at the exact files, symbols, or line ranges to modify — the scope is fully localized, no surface-area discovery is needed.
  - A recent codebase scan file already exists at `docs/reference/codebase-scan-<slug>.md`, its `last_scanned_commit` matches the current `HEAD`, AND its `scanned_for_request` matches the current `REFINED_REQUEST_FILE` slug — reuse it instead of re-scanning. Capture its path as `CODEBASE_SCAN_FILE` and continue.
  - The request was dispatched via a workflow slash command (`/team-workflow`, `/change-workflow`, etc.) — those workflows run Phase 2 (Codebase Scanner) internally with the conditional "is it greenfield?" check; do NOT duplicate at the orchestrator level.
  - The request is a documentation-only or design-only task with no source-code touch points.

- **How to perform the scan**: Dispatch the `codebase-scanner` subagent via the Agent tool. Pass it:
  - `request_file`: the `REFINED_REQUEST_FILE` path (so request-driven narrowing kicks in and the Integration Points section is populated).
  - `output_path`: `docs/reference/codebase-scan-<descriptive-name>.md`, where `<descriptive-name>` is the same slug used for the refined-request and investigation files (e.g., `codebase-scan-oauth2-auth.md`). This keeps related artifacts visually grouped under `docs/reference/`.
  Do NOT write the scan file by hand — the subagent owns the frontmatter schema, traversal limits (depth ≤ 4, ≤ 5 samples per large directory), `.gitignore` handling, and the 300–500 line output cap. Hand-written scans break downstream agents that parse the YAML keys.

- **Where the codebase-scan file must be saved**: The scanner writes it to `docs/reference/codebase-scan-<descriptive-name>.md` inside the active project root. If `docs/reference/` does not exist, the subagent creates it. The file is overwritten on each scan (never merged) — the frontmatter's `last_scanned_commit` and `scanned_at` let callers detect staleness. The file is the single source of truth for the project's structural facts (build command, test command, conventions, entry points) during the workflow — downstream subagents must read it rather than re-detect these fields themselves.

- **Pre-implementation duplication check** (mandatory when the scan runs):
  - Before launching planner/designer/coder, read the scan's "Module Map" and "Integration Points" sections.
  - If the requested feature appears to be **already implemented** (a module's purpose matches the request objective), STOP and surface this to the user via `AskUserQuestion`: confirm whether to (a) extend the existing implementation, (b) replace it, or (c) abandon the request as already-done.
  - If the requested feature is **partially implemented**, the planner must scope the work as an extension of the existing module, NOT as a parallel implementation. Reference the existing file/symbol locations from the scan in the plan.
  - If the scan flags a **New Integration Point**, the design must explain where the new module lands, how it interacts with the existing surface, and which conventions it adopts from the scan's "Conventions" section.

- **How the codebase-scan results must be passed to next steps**:
  - Capture the scan file path as `CODEBASE_SCAN_FILE` for the duration of the conversation.
  - When invoking ANY downstream subagent (planner, designer, coder, reviewer, dependency-validator, test-builder, integration-verifier, etc.), include the path in the agent's instructions, e.g.:
    - *"Read the codebase scan at `<CODEBASE_SCAN_FILE>` — use its YAML frontmatter for the project's build/test/lint commands and its Integration Points section for the in-scope/out-of-scope file boundaries. Do NOT re-detect these fields."*
  - The planner must reference each In-Scope file from the scan in the plan's "Files to modify" section and must explicitly leave Out-of-Scope modules untouched.
  - The designer must align new modules with the conventions documented in the scan's "Conventions" section (citing the same file:line evidence).
  - The coder must use `mcp__serena__find_symbol` and `mcp__serena__replace_symbol_body` on the symbols identified in the scan, rather than blindly creating new files that duplicate existing ones.
  - The test-builder must read the scan's frontmatter to detect the test framework instead of guessing.
  - When invoking a workflow slash command (`/team-workflow`, `/change-workflow`, `/doc-workflow`, etc.), do NOT pre-run the codebase-scanner — the workflow's Phase 2 produces its own `CODEBASE_SCAN_FILE` (conditional on the project not being greenfield) and threads it through all subsequent phases. Pass the raw request to the workflow.
  - When invoking a skill that consumes structural project facts (`create-plans`, `huashu-design`, etc.), pass `CODEBASE_SCAN_FILE` in the skill's context block.
  - When you create the project plan (`docs/design/plan-NNN-<description>.md`), reference `CODEBASE_SCAN_FILE` at the top of the plan alongside `REFINED_REQUEST_FILE`, `INVESTIGATION_FILE`, and `TECHNICAL_RESEARCH_FILES` — the complete provenance chain (refined-request → investigation → research → scan → plan → design) must be permanent and auditable.
  - When you update `docs/design/project-design.md`, cite the scan's Integration Points entries for any architectural change so future readers can trace why a specific module was chosen as the landing site.

- **Staleness rule**: A scan is considered stale if `last_scanned_commit` differs from the current `HEAD` AND the diff touches files in the scan's "Module Map" or "Integration Points" sections. In that case, re-run the scanner before continuing — never proceed to planning with a stale scan, because the Integration Points may have shifted.

- **Explicit-skip rule**: If you decide a given request does NOT need a codebase scan, state the reason briefly in your first response (e.g., "Skipping codebase scan — greenfield project, no source files exist yet." or "Skipping codebase scan — user pointed at exact file and line range; no surface-area discovery needed.") so the user can override if they disagree.
</codebase-scanning>

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

## Tools

### ntakker-cli

macOS dual-source audio recorder: captures system audio (`ScreenCaptureKit`) and the microphone (`AVFoundation`) simultaneously and writes to `m4a` / `wav` / `caf` in `mixed`, `split`, or `stereo-split` layouts. Optional opt-in live transcription via nine STT providers (Apple, Apple Cloud, Gemini, Soniox with default-on diarization, Azure batch, Azure Realtime, ElevenLabs, WhisperKit, Parakeet multilingual on-device), opt-in microphone acoustic echo cancellation (plan-014 v5, off by default), and true source-split transcription (`--transcribe-source both`).

Documentation: [docs/tools/ntakker-cli.md](docs/tools/ntakker-cli.md)

### ntakker

macOS menu-bar status item app that drives the same `NtakkerCore` engine as the CLI under a separate bundle id (`com.giorgosmarinos.ntakker`) for independent TCC grants. Popover surface exposes start / stop / pause / resume / split (the status bar shows Pause and Split while recording, Resume while paused — EVAL-2026-10-16 UI-2, fixed in plan-023), format / layout / folder / mic selectors, permission status, per-source level meters, opt-in live transcription with inline panel, and the opt-in mic echo-cancellation toggle (plan-014).

Documentation: [docs/tools/ntakker.md](docs/tools/ntakker.md)

### ntakker-studio

macOS Dock app (`com.giorgosmarinos.ntakker-studio`, plan-024) for exploring finished recordings: library and full-text search across every transcript, playback with the transcript followed line by line and click-to-jump, cutting ranges into a new copy with re-timed transcripts, Ask and meeting minutes over the whole transcript (ntakker's Ask settings), speaker renaming, transcript text edits, re-transcription with ntakker's batch providers, a System/Light/Dark appearance, and mapping recordings to calendar meetings through a configurable command (`NTAKKER_CALENDAR_COMMAND`, e.g. `m365mail calendar export`) — in Info ▸ Meeting and as `ntakker-studio match-meetings` (JSON).

Documentation: [docs/tools/ntakker-studio.md](docs/tools/ntakker-studio.md)
