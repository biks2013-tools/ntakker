# Refined Request: Additional STT Engines (Azure OpenAI gpt-4o-mini-transcribe + ElevenLabs)

## Category

Research + Design (no implementation). Produces a single combined plan
(`plan-007-additional-stt-engines.md`) plus the supporting research,
codebase-scan, and design artifacts under `docs/research/`,
`docs/reference/`, and `docs/design/`.

## Objective

Study the public API surfaces of two additional speech-to-text engines —
**Azure OpenAI `gpt-4o-mini-transcribe`** and **ElevenLabs Speech-to-Text** —
and produce a research-backed plan and design that adds them as additional
`TranscriptionProvider` implementations alongside the existing providers
(`NoOpTranscriptionProvider`, `FakeTranscriptionProvider`,
`GeminiRESTTranscriptionProvider` from plan-004, and
`AppleSpeechTranscriptionProvider` from plan-005). The resulting design
must slot into the existing pipeline-mode-aware `TranscriptionManager`
without breaking either the batch (Gemini REST) or streaming
(Apple SpeechAnalyzer) paths, and must surface the new providers
through the `macrec` CLI and the `macrec-ui` menu-bar app's provider
picker. Apple SpeechAnalyzer remains the existing baseline comparator
and is **not** to be re-implemented.

## Scope

### In scope

- **Engine #1 — Azure OpenAI `gpt-4o-mini-transcribe`**
  - Research the Azure OpenAI Audio API surface: deployment-based
    routing (`{endpoint}/openai/deployments/{deployment-name}/audio/...`),
    `api-version` query parameter conventions, the `/audio/transcriptions`
    REST endpoint (multipart/form-data), and any realtime/streaming
    variant exposed for the `gpt-4o-transcribe` family
    (e.g. WebSocket / `/realtime` endpoint).
  - Cover the four canonical authentication modes for Azure OpenAI:
    `api-key` header, Azure AD bearer token, managed identity, and
    Entra ID. The plan must commit to one for v1 with a documented
    rationale; the others may be deferred.
  - Document supported audio formats, max payload size, supported
    sample rates, supported response formats (`json`, `text`,
    `verbose_json`, `srt`, `vtt`), language hint behaviour, and
    word-/segment-level timestamp availability.
  - Map the engine onto the existing `TranscriptionProvider` contract
    (batch via `transcribe(...)`) and, if a streaming endpoint exists
    for the `gpt-4o-transcribe` family, also onto
    `StreamingTranscriptionSession` (plan-005 §4.2).
- **Engine #2 — ElevenLabs Speech-to-Text**
  - Research the ElevenLabs STT REST endpoint(s) — request/response
    schema, authentication (`xi-api-key` header), supported audio
    formats and limits, language detection vs hint, diarization
    flags, output format, and timestamp granularity.
  - **Verify** during the research phase whether ElevenLabs offers
    a public real-time STT WebSocket as of the work date. As of the
    refinement date (2026-04-29) the user's working assumption is
    that STT is batch-only; the research phase MUST confirm or refute
    this and capture the verification timestamp + source URL in
    `docs/research/elevenlabs-stt-wire-schema.md`.
  - Map the engine onto `TranscriptionProvider.transcribe(...)` for
    batch mode. If real-time STT WebSocket is confirmed available,
    also map onto `StreamingTranscriptionSession`; otherwise document
    the absence as an explicit gap.
- **Combined plan deliverable**
  - A single plan file at
    `docs/design/plan-007-additional-stt-engines.md` with one phase
    per engine (Phase A — Azure, Phase B — ElevenLabs) plus shared
    cross-cutting phases (configuration, factory wiring, UI picker,
    documentation, test scripts). Each per-engine phase must include:
    research summary, file-by-file scope deltas, contract mapping,
    error-handling matrix, configuration variables (env-vars, CLI
    flags, expiration companions per CLAUDE.md), test plan, and
    risk register.
  - Supporting design notes integrated into
    `docs/design/project-design.md` (new §LT-N subsections) and
    `docs/design/project-functions.md` (new FR rows for each
    provider) and `docs/design/configuration-guide.md` (new §2.x
    rows for each new env-var).
- **Cross-cutting design topics**
  - Provider-id strings, default selection (Apple stays default),
    factory wiring in
    `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`.
  - Configuration mapping: per-provider env-vars, the Azure
    deployment-name vs model-name distinction, expiration-companion
    variables for each new credential per CLAUDE.md
    `<configuration-guide>` rule.
  - Error-handling matrix per provider: rate limiting (HTTP 429),
    auth failures (HTTP 401/403), payload-too-large (HTTP 413),
    transient network failures (retry-with-backoff policy), and
    deployment-not-found errors (Azure-specific HTTP 404 on a missing
    deployment id).
  - UI surface: how the new providers appear in the `macrec-ui`
    `ControlBar` provider picker (flat list vs grouped "Cloud"
    submenu — see Open Question Q5).
  - Privacy disclosure: whether the existing one-time disclosure
    dialog (FR-53) needs updated copy for each provider's data
    handling stance (the user-data residency story for Azure
    OpenAI is materially different from ElevenLabs).
  - Sidecar policy: both new providers fall under the existing
    batch policy from plan-005 §4.7 unless a streaming variant
    is in scope.

### Out of scope

- **Implementation**. No code is to be written by this workflow.
  Producing only `.md` artifacts: the plan, the wire-schema research
  notes, the codebase scan, and the investigation document.
- **Any change to `AppleSpeechTranscriptionProvider`** — Apple is the
  baseline comparator only. plan-005's design is treated as immutable
  for the purposes of this work.
- **Removal or modification of `GeminiRESTTranscriptionProvider`** —
  the existing batch provider stays available unchanged.
- **WhisperKit, Deepgram, OpenAI Realtime API (non-Azure), AssemblyAI,
  Soniox, AWS Transcribe**, or any other engine not explicitly listed.
- **TypeScript implementation**. Per Approved Exception 001 in
  `CLAUDE.md`, this project is Swift; the plan must specify Swift
  Package Manager targets and Swift idioms (actors, `AsyncStream`,
  `URLSession`, `URLSessionWebSocketTask`).
- **macOS < 26 compatibility**. Per Approved Exception 002, the
  deployment target is macOS 26; no `#available` shimming required
  for the new providers themselves (though the providers must not
  themselves require any newer API than the existing baseline).
- **CI / test-runner provisioning** for the new providers — covered
  by R-17 / R-22 risks already tracked in `Issues - Pending Items.md`.
- **Multi-tenant Azure / B2B account-management** — single Azure
  OpenAI resource per user is sufficient for v1.

## Requirements

### R-1 — Codebase scan deliverable

Produce `docs/reference/codebase-scan-additional-stt-engines.md` that
locates and quotes (file + class + line) every place a new provider
must integrate with: `TranscriptionProvider` protocol,
`TranscriptionMode` enum, `StreamingTranscriptionSession` protocol,
`TranscriptionProviderFactory`, `ConfigResolver`, `RecordingOptions`,
`TranscriptionManager`, `TranscriptSidecarWriter`, `MacrecError`,
`ControlBar` (UI picker), and the privacy-disclosure surface. The
scan must verify that the contract from plan-005 §4.1 is in effect
in the current codebase and flag any drift.

### R-2 — Per-engine wire-schema research notes

For each engine, produce a document under `docs/research/`:
- `docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md`
- `docs/research/elevenlabs-stt-wire-schema.md`

Each document must capture: endpoint URL templates with all path /
query parameters, authentication header(s), required and optional
request body fields with types and defaults, complete response
schema with field types, error-response shape and HTTP status code
matrix, supported audio MIME types and codecs, max payload size,
supported sample rates, supported languages list (or pointer to
official list), pricing model and unit (per-minute vs per-character
vs per-token), streaming availability (yes/no/protocol), and
verification date + source URL for every claim.

### R-3 — Investigation document

Produce `docs/reference/investigation-additional-stt-engines.md`
that compares the four streaming/batch providers across consistent
axes: latency (first-partial, final), cost per hour of audio,
quality (English + Greek, the user's primary languages), privacy
posture (data residency, opt-out from training), max audio length
per request, supported sample rates / codecs, language list breadth,
diarization availability, word-level timestamps availability, and
SDK / native Swift availability. Include a recommendation per
use-case (default for live captioning, default for offline batch,
fallback for non-English content, etc.).

### R-4 — Combined plan

Produce `docs/design/plan-007-additional-stt-engines.md` containing:
- §1 Goal — one-paragraph statement of what this plan adds.
- §2 Why this addition — for each engine, the value-add over the
  existing providers (e.g. Azure: enterprise data residency, OpenAI
  model quality; ElevenLabs: vendor consolidation if user already
  uses their TTS, multilingual coverage).
- §3 Scope deltas (file by file) — separate "to be added" and
  "to be edited" tables, per CLAUDE.md plan convention; no
  deletions expected.
- §4 Component contracts — show how each new provider conforms
  to `TranscriptionProvider`, what `supportedModes` it declares,
  what `StreamingTranscriptionSession` (if any) it returns, what
  `TranscriptionOptions` fields it consumes.
- §5 Configuration — list every new env-var (e.g.
  `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`,
  `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_VERSION`,
  `ELEVENLABS_API_KEY`, plus `<X>_EXPIRES_AT` companions), each
  with type, default, required-vs-optional, and CLAUDE.md
  configuration-guide section it must be added to.
- §6 Per-engine phase plan — Phase A (Azure) and Phase B
  (ElevenLabs), each broken into the standard sub-phases used by
  plans-003/004/005 (engine, configuration, persistence, networking,
  provider, UI, documentation, test scripts).
- §7 Cross-cutting phase — factory wiring, UI picker integration,
  privacy disclosure copy, documentation rollup.
- §8 Error-handling matrix — table mapping each anticipated
  HTTP/network failure to a `MacrecError` case (existing or new),
  exit code, and remediation message.
- §9 Test plan — per-engine `e2e-transcription-azure.sh` and
  `e2e-transcription-elevenlabs.sh` shell scripts (script bodies
  not required by this workflow, but their inputs / outputs /
  pass-fail criteria must be specified).
- §10 Risk register — at minimum: deployment-name drift between
  Azure portal and config (Azure-specific), provider rate limiting,
  cost overrun, language coverage gaps, ElevenLabs streaming gap
  if confirmed batch-only, vendor lock-in to specific model
  versions (model deprecation cycle), and any TCC / network /
  privacy implications.
- §11 Definition of Done — explicit checklist from this spec's
  Acceptance Criteria.

### R-5 — Provider contract back-compatibility

The plan must show that the existing
`TranscriptionProvider` protocol from plan-005 §4.1 is sufficient
for both new providers without breaking changes. If any extension
is required (e.g. a new `TranscriptionMode` case, a new
`TranscriptionOptions` field), the plan must explicitly call it
out, justify it, and verify that all four existing conformers
(`NoOp`, `Fake`, `GeminiREST`, `AppleSpeech`) continue to compile
with the change.

### R-6 — Configuration extension follows CLAUDE.md rules

- No fallback values for required configuration; missing required
  values throw `MacrecError.missingRequiredConfig` per the
  no-fallback rule.
- Each credential pairs with an `<X>_EXPIRES_AT` ISO-8601 companion
  per CLAUDE.md `<configuration-guide>` rule for expiring
  parameters.
- Azure deployment-name is treated as a first-class config value
  (not derived from any model name) per the typical Azure OpenAI
  pattern (Assumption A-3).
- Provider-specific secrets are documented in `docs/design/configuration-guide.md`
  with the standard four-tier resolution chain.

### R-7 — UI picker integration design

The plan must specify how `Sources/macrec-ui/Views/ControlBar.swift`
exposes the two new providers. See Open Question Q5; default
assumption is a flat list with the new entries appended after
"Apple Speech" and "Gemini REST" (Assumption A-4).

### R-8 — Privacy disclosure copy

For each new provider, the plan must propose the exact disclosure
text that the one-time disclosure dialog (FR-53) shows the user
on first selection, including: the provider's data residency
posture, whether it trains on user audio by default, the URL of
the provider's data-processing addendum or privacy notice, and
how to opt out. The two providers' postures differ materially
and must each be addressed.

## Constraints

- **Language**: Swift only (Approved Exception 001). All design
  artifacts must specify Swift idioms (actors, `AsyncStream`,
  `URLSession`, `URLSessionWebSocketTask`, `Sendable` annotations).
- **Deployment target**: macOS 26 (Approved Exception 002).
- **No new SwiftPM dependencies** unless explicitly justified in
  the plan and approved by the user. Both engines have HTTPS REST
  surfaces; `URLSession` from Foundation is the preferred transport.
  No vendor SDK is required.
- **Existing providers must not be modified** beyond adding the
  new factory cases and any new `TranscriptionMode` / `TranscriptionOptions`
  surface (R-5). The Apple and Gemini paths must continue to pass
  their existing e2e scripts unchanged.
- **No implementation** — only research, planning, and design.
  No `.swift` files are produced; no `swift build` is run.
- **CLAUDE.md document placement rules apply**:
  - Plan goes to `docs/design/plan-007-additional-stt-engines.md`.
  - Research notes go to `docs/research/`.
  - Codebase scan and investigation go to `docs/reference/`.
  - Functional requirements (one FR row per provider) go to
    `docs/design/project-functions.md`.
  - Config variables go to `docs/design/configuration-guide.md`.
- **Working directory**: this is a git worktree at
  `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/.worktrees/explore-stt-models`,
  not the canonical project root. All file paths in the plan
  must be project-relative; the workflow operates within this
  worktree only.

## Acceptance Criteria

### AC-1 — Codebase scan exists and is complete

`docs/reference/codebase-scan-additional-stt-engines.md` exists and
locates (file + class + line + ≤ 10-line code extract) every one
of: `TranscriptionProvider` protocol declaration,
`TranscriptionMode` enum declaration, `StreamingTranscriptionSession`
protocol declaration, `TranscriptionProviderFactory.make(...)`,
`ConfigResolver.parseTranscriptionProvider(...)`,
`RecordingOptions.transcriptionProviderId` (and adjacent fields),
`TranscriptionManager.init` pipeline-mode dispatch,
`MacrecError.transcriptionApiKeyMissing` (and adjacent transcription
errors), `ControlBar` provider picker, and the privacy-disclosure
trigger surface.

### AC-2 — Two wire-schema research files exist with verification metadata

`docs/research/azure-openai-gpt-4o-mini-transcribe-wire-schema.md` and
`docs/research/elevenlabs-stt-wire-schema.md` both exist. Each
contains, at minimum: endpoint URL template, auth headers, request
body schema, response body schema, error code matrix, audio format
support, supported languages pointer, pricing pointer, streaming
availability statement, and a verification footer with date + URL
for every factual claim.

### AC-3 — Investigation document compares all four providers

`docs/reference/investigation-additional-stt-engines.md` exists and
contains a side-by-side comparison table covering at minimum:
GeminiREST (existing batch baseline), AppleSpeechAnalyzer (existing
streaming baseline), Azure OpenAI gpt-4o-mini-transcribe, ElevenLabs.
Comparison axes include latency (first-partial / final), cost per
audio hour, quality (en + el), privacy posture, max audio length,
supported sample rates / codecs, supported language list breadth,
diarization, word-level timestamps, and Swift native availability.

### AC-4 — Combined plan exists with all required sections

`docs/design/plan-007-additional-stt-engines.md` exists and contains
the eleven sections enumerated in R-4 (§1 Goal through §11 Definition
of Done), with §6 split into Phase A (Azure) and Phase B (ElevenLabs).

### AC-5 — Provider contract back-compat verified

The plan §4 demonstrates — by referencing the contract from plan-005
§4.1 — that both new providers conform to the existing
`TranscriptionProvider` protocol, and (if any extension is needed)
that the four existing conformers continue to work. Any extension
is justified and documented as a delta against plan-005.

### AC-6 — Configuration variables enumerated

The plan §5 lists every new env-var with: name (per Azure / vendor
canonical convention), type, default, required-vs-optional flag,
and the configuration-guide §2.x section number where it will live.
Every credential variable has an `<X>_EXPIRES_AT` companion. No
fallback default is proposed for any required value.

### AC-7 — Error-handling matrix covers each provider's failure modes

The plan §8 contains a table per provider covering at minimum:
HTTP 401 (auth), HTTP 403 (forbidden / quota), HTTP 404 (Azure:
deployment not found; ElevenLabs: endpoint typo), HTTP 413 (payload
too large), HTTP 429 (rate limit / retry policy with jitter),
HTTP 5xx (transient → backoff), and offline / DNS failure. Each row
maps to a `MacrecError` case, an exit code, and a user-facing
remediation message.

### AC-8 — UI picker integration designed

The plan §7 specifies the new entries in `ControlBar`'s provider
picker (label, internal id, default-selected? flag, ordering),
and notes whether grouping ("Cloud" submenu) is required (per Q5).

### AC-9 — Privacy disclosure copy proposed

The plan §7 contains the exact one-time disclosure-dialog copy for
each new provider, citing the provider's privacy / DPA URL.

### AC-10 — No code produced

No `.swift` file under `Sources/` or `Tests/` is created or modified
by this workflow. The deliverables are entirely under `docs/`.

### AC-11 — All Acceptance Criteria are testable by file inspection

Every AC above can be verified by inspecting the listed `.md` files
without running any build. A reviewer following this spec must be
able to sign off the workflow purely by reading the produced
documents.

### AC-12 — Existing providers and contracts referenced verbatim

The plan must cite plan-004 and plan-005 by section number where
it depends on or extends them, rather than restating their contents.
Drift from those plans (e.g. if the codebase scan reveals the actual
code has diverged from plan-005 §4.1) must be flagged in the codebase
scan and acknowledged in the plan.

## Assumptions

The following assumptions are made because the user has not provided
explicit guidance and a reasonable default exists. Each may be
challenged before the plan is executed.

- **A-1 — Streaming is desirable but not mandatory for either engine.**
  Both engines may be added as batch-only providers in v1 if their
  realtime surface is unstable, undocumented, or imposes a meaningful
  implementation cost beyond REST. The plan must record latency
  expectations per provider (e.g. Azure realtime first-partial
  ~300 ms; Azure REST end-to-end ~3–5 s same as Gemini REST today;
  ElevenLabs REST end-to-end TBD by research). _Basis_: Apple
  SpeechAnalyzer already covers the true-streaming use case
  on-device for free; the new providers are most valuable for
  multilingual / quality-comparison workloads where Apple has gaps.
- **A-2 — Latency / quality / cost are all "research and report"
  not "hit a specific SLO".** The plan does not commit to a
  numeric latency or cost target; it reports observed values per
  provider and lets the user select per recording. _Basis_: this
  is a research/design workflow, not a service rollout.
- **A-3 — Azure OpenAI uses deployment-name routing, not model-name
  routing.** The plan models Azure config as a tuple of
  (`endpoint`, `deployment-name`, `api-version`, `api-key`), with
  the model name being whatever is bound to the deployment in the
  Azure portal. _Basis_: this is the standard Azure OpenAI URL
  pattern (`{endpoint}/openai/deployments/{deployment}/audio/transcriptions?api-version=…`)
  and the user explicitly said "deployment-based" in the raw request.
- **A-4 — UI picker uses a flat list, not a grouped submenu.** The
  new providers are appended to the existing flat picker
  ("Apple Speech (default) / Gemini REST / Azure OpenAI / ElevenLabs"),
  in declaration order. _Basis_: the current `ControlBar` already
  uses a flat picker and Q5 has no a priori preference. Revisit
  this if the picker grows beyond ~6 entries.
- **A-5 — ElevenLabs STT is batch-only in v1 unless the research
  phase confirms a public realtime WebSocket is GA.** The plan
  documents the verification step explicitly. _Basis_: as of
  refinement date (2026-04-29), ElevenLabs's headline STT product
  is the REST `speech-to-text` endpoint; any realtime variant is
  unverified and must be confirmed during Phase B research.
- **A-6 — `URLSession` is sufficient for both providers; no SDK
  dependency.** No new SwiftPM package is added for either provider.
  _Basis_: both engines expose REST/WebSocket; Foundation suffices.
- **A-7 — Azure auth via `api-key` header in v1.** Other modes
  (Azure AD bearer, managed identity, Entra ID) are listed as
  v2 follow-ups. _Basis_: lowest implementation cost, parity
  with how `GOOGLE_API_KEY` works today.
- **A-8 — Apple SpeechAnalyzer remains the default provider.**
  The plan does not flip the default away from `apple`. _Basis_:
  it is the highest-quality, lowest-latency, lowest-cost, and
  most private option already shipping in the project; the new
  providers are explicit opt-ins.
- **A-9 — Privacy disclosure uses the existing FR-53 surface.**
  No new dialog or settings panel is added; only the per-provider
  copy is new. _Basis_: FR-53 is generic and providerName-driven.
- **A-10 — The plan-007 phasing follows the
  research → plan → design → review pattern of plans-003/004/005.**
  No phase delivers code in this workflow; coding phases are
  defined but not executed. _Basis_: explicit user instruction.

## Open Questions

Pre-resolved by the user (NOT to be re-asked):

- Engine list = Azure OpenAI gpt-4o-mini-transcribe + ElevenLabs.
- Apple SpeechAnalyzer is the existing baseline (no new
  implementation).
- Output = single combined plan with one phase per engine.
- No code is to be written.
- Swift, macOS 26.

The following remain open and the plan must either resolve them
during research or escalate to the user:

- **Q1 — Streaming required for both engines?** Default
  assumption A-1 says "no, batch-only is acceptable for either
  engine if streaming proves costly". Confirm or override during
  the Azure / ElevenLabs research phase based on the actual
  endpoint surfaces discovered.
- **Q2 — Numeric latency / quality / cost targets?** Default
  assumption A-2 says "report only, no SLO". If the user wants
  hard targets (e.g. "Azure must reach < 500 ms first-partial"),
  capture them before §6 of the plan.
- **Q3 — Azure deployment-name vs model-name?** Default assumption
  A-3 says deployment-name (typical Azure OpenAI pattern). The
  plan should not deviate from this without explicit user
  approval.
- **Q4 — Should ElevenLabs ship even if STT is batch-only?**
  Default assumption A-5 says yes — the design value of having
  ElevenLabs as a fourth comparator is worth shipping batch-only
  in v1. Revisit if research reveals ElevenLabs STT has a hard
  blocker (e.g. enterprise-only, > 10 s end-to-end RTT, missing
  language support).
- **Q5 — UI picker: flat list or "Cloud" submenu?** Default
  assumption A-4 says flat list. Revisit if the picker becomes
  visually cramped or if the user wants explicit grouping.

## Original Request

```
Explore the option of integrating two additional speech-to-text engines into the existing `macrec` macOS recorder + `macrec-ui` menu-bar app:

1. **Azure OpenAI gpt-4o-mini-transcribe** (deployment-based; uses an Azure OpenAI resource with a model deployment named e.g. `gpt-4o-mini-transcribe`). Reference: https://learn.microsoft.com/azure/ai-services/openai/concepts/models#audio-models and the OpenAI Audio API surface (`/audio/transcriptions`, plus the new `gpt-4o-transcribe` realtime/streaming variant where applicable).
2. **ElevenLabs Speech-to-Text API**. Reference: https://elevenlabs.io/docs/api-reference/introduction (Speech-to-Text endpoints, both batch and streaming where supported).

A third engine — **Apple SpeechAnalyzer** — is in scope as the existing baseline (already implemented in `docs/design/plan-005-apple-speech-streaming.md`); the user does NOT want a new implementation for it. Reference it as the existing comparator only.

Goal of the work: study the public API documentation of the two new engines (Azure gpt-4o-mini-transcribe and ElevenLabs) and produce a plan + design to add them as additional `TranscriptionProvider` implementations alongside the existing Gemini Live (streaming) and Apple SpeechAnalyzer (on-device) providers, plus the existing batch REST provider documented in plan-004.

The user has decided up front:
- Output of this workflow is a single combined plan (`plan-007-additional-stt-engines.md`) with one phase per engine (Azure, ElevenLabs).
- No code is to be written by this workflow — only research, plan, and design artifacts.
- The implementation language is **Swift** (per Exception 001 in CLAUDE.md), NOT TypeScript. The CLAUDE.md "Tools" section lists `macrec` (CLI) and `macrec-ui` (menu-bar app); both are Swift Package Manager targets.
- The deployment target is macOS 26 (per Exception 002 in CLAUDE.md).
```
