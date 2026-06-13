# Refined Request: Soniox Real-Time Speech-to-Text Provider Integration

## Category
Development (additional cloud streaming transcription provider for an existing
multi-provider transcription pipeline in a Swift macOS CLI + menu-bar app).

## Objective
Add **Soniox** as a third real-time speech-to-text provider in the
`recording-tool` project (`macrec` CLI + `macrec-ui` menu-bar app),
slotting into the existing `TranscriptionProvider` abstraction (FR-46)
alongside the current providers (Google Gemini and Apple
SpeechAnalyzer). The provider MUST support live, low-latency streaming
transcription of the captured audio (system + microphone) with primary
language coverage for **Greek (`el` / `el-GR`)** and **English (`en` /
`en-US` / `en-GB`)**, while honouring the project's existing
configuration, security, sidecar-output, UI, detach-mode, and
recording-integrity-isolation contracts.

This is a NEW provider option — none of the existing provider
implementations or call sites in `MacrecCore` are to be replaced;
Soniox is added as a peer.

---

## Scope

### In scope
- A new `TranscriptionProvider` conformer that talks to Soniox's
  real-time speech-to-text service.
- Wiring of a new provider id (`soniox`) into the existing
  `--transcribe` CLI flag, the `MACREC_TRANSCRIBE` env var, the
  `ConfigResolver` validation set, and the `macrec-ui` "Live
  transcription" picker.
- Soniox-specific configuration: API key (vendor-canonical env var
  name to be confirmed during investigation; see Open Questions),
  optional model id override, optional region/endpoint override, and
  the standard `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` companion (per the
  configuration-guide convention for expiring credentials).
- Audio-format adaptation from the project's internal Float32 / 48 kHz
  / stereo planar PCM to whatever encoding (sample rate / channels /
  encoding) Soniox's streaming endpoint accepts. The existing
  `AudioDownsampler` and `AudioWAVEncoder` helpers must be reused
  where possible; any Soniox-specific formatting must be encapsulated
  inside the provider conformer (no leakage into `MacrecCore`
  orchestration).
- Greek + English language strategy: configuration that biases the
  recognizer towards `el-GR` and `en-US` / `en-GB` while leaving the
  door open to Soniox's multilingual auto-detect mode.
- Sidecar output parity with existing providers: `jsonl` (default),
  `txt`, `srt`, `vtt`, with the mandatory `*.transcript.<ext>` infix
  and `model:"soniox"` plus a BCP-47 `language` field on each segment
  line.
- Documentation updates: `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`,
  `docs/design/configuration-guide.md`, `docs/design/project-functions.md`,
  `docs/design/project-design.md`, and a new
  `docs/design/plan-006-soniox-streaming.md` plan file.
- An end-to-end test script under `test_scripts/` that exercises
  Soniox with a real API key against a known-text Greek clip and a
  known-text English clip, asserting non-empty sidecar output and
  expected keyword hits.
- An offline / no-key regression script that exits cleanly when
  `--transcribe soniox` is selected without a key (parity with
  `e2e-transcription-key-missing.sh`).
- Unit tests for the new provider's request shaping, response parsing,
  language-hint logic, and error mapping (using a `URLProtocol`-stub
  or `WebSocket`-fake the same way the Gemini provider tests do).

### Out of scope
- Replacing or deprecating the Gemini or Apple providers. Soniox is
  additive.
- Translation features (Soniox supports speech translation; not
  requested for v1 of this integration).
- Speaker diarization beyond the existing `system` / `mic` source
  tagging — see Open Question OQ-SX-3.
- Custom vocabulary / keyword boosting beyond what is needed to make
  Greek and English work well out of the box. Surface the API as
  optional but do not require it.
- Offline / on-device fallback for Soniox (Soniox is a cloud service;
  if the user wants on-device they should use the `apple` provider).
- Batch / file-upload transcription via Soniox's REST API. This
  request is for the streaming path only (parity with the project's
  primary live-transcription value proposition).
- Server-side audio recording or storage on Soniox's side beyond what
  is strictly required for the live recognition request — opt out of
  data retention if Soniox exposes that toggle.
- Modifications to the existing `TranscriptionManager`, `SourceBuffer`,
  `SegmentCoalescer`, `TranscriptSanitizer`, sidecar writers, UI
  panel, or any other transcription-pipeline component beyond the
  minimum needed to register and dispatch the new provider id.

---

## Requirements

### Functional requirements

1. **FR-SX-1 — Provider id `soniox` accepted by `--transcribe`.**
   The `--transcribe` CLI flag and `MACREC_TRANSCRIBE` env var MUST
   accept the literal value `soniox` in addition to the existing
   `none | apple | gemini` set. Invalid values continue to fail with
   exit 64 (`EX_USAGE`) per AC-LT-17.

2. **FR-SX-2 — `SonioxStreamingTranscriptionProvider` conformer.**
   A new type `SonioxStreamingTranscriptionProvider` MUST be added
   under `Sources/MacrecCore/Transcription/Providers/` conforming to
   the existing provider protocol (FR-46). It MUST be `Sendable` and
   safe for concurrent calls from the `TranscriptionManager`. Whether
   the conformer keeps a single long-lived streaming session per
   `SourceTag` or opens one session per chunk is an implementation
   decision left to the design phase, but the public surface MUST
   remain compatible with the existing protocol (the protocol may be
   extended with an optional streaming hook only if strictly needed
   — see Open Question OQ-SX-1).

3. **FR-SX-3 — Soniox API key resolution via the four-tier chain.**
   The provider MUST read its API key through the existing
   `ConfigResolver` four-tier chain (shell env → `~/.tool-agents/macrec/.env`
   → local `./.env` → CLI flag). The vendor-canonical env-var name
   MUST be used (`SONIOX_API_KEY` is the working assumption — to be
   confirmed against the official Soniox docs during investigation;
   see Open Question OQ-SX-2). NO `--soniox-api-key` CLI flag is
   exposed (parity with `GOOGLE_API_KEY` per NFR-20: keys never
   appear on the command line). If the key is absent at session start
   AND `--transcribe soniox` is selected, the resolver MUST raise
   `MacrecError.transcriptionApiKeyMissing` (exit 78, `EX_CONFIG`),
   no audio file is created (AC-LT-4 parity).

4. **FR-SX-4 — No fallback for the API key.**
   Per CLAUDE.md "no fallback solutions for configuration settings",
   a missing API key MUST raise an exception. The provider MUST NOT
   fall back to any default endpoint, demo key, or anonymous mode.

5. **FR-SX-5 — API-key expiration companion variable.**
   Per the project's configuration-guide convention for expiring
   credentials, a companion variable
   `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` (already defined for the
   Gemini key — to be reused, NOT duplicated per provider) MUST be
   honoured for Soniox keys: if set and in the past, log a `.warning`
   at start; recording is NOT blocked. If Soniox issues keys with
   independent expiry semantics from Gemini, a Soniox-scoped variant
   `MACREC_SONIOX_KEY_EXPIRES_AT` MAY be added — to be decided in the
   plan-006 design phase.

6. **FR-SX-6 — Optional model id override.**
   The existing `--transcribe-model` flag and `MACREC_TRANSCRIBE_MODEL`
   env var MUST be accepted by the Soniox provider. The provider
   MUST ship with a pinned default model id (e.g. Soniox's
   recommended real-time multilingual model — to be locked during
   investigation; see Open Question OQ-SX-4). Unknown model ids MUST
   be allowed through (with an `info` log line) so users can opt into
   newer models without a code change.

7. **FR-SX-7 — Optional region / endpoint override.**
   A new optional config var `MACREC_SONIOX_ENDPOINT` (CLI flag
   `--soniox-endpoint <url>`) MUST be accepted to point the provider
   at a non-default Soniox endpoint (regional, dedicated, or future
   self-hosted). Default: the official Soniox public production
   endpoint. The flag MUST follow the same four-tier resolution
   chain as every other config value.

8. **FR-SX-8 — Audio format adaptation.**
   The provider MUST accept the project's internal Float32 mono
   16 kHz buffers (the same shape every other provider gets via
   `AudioDownsampler`) and convert them to whatever Soniox's
   streaming endpoint requires (sample rate, channels, encoding,
   framing) inside the provider conformer. If Soniox accepts
   16 kHz PCM16 mono natively (very likely based on standard cloud
   STT conventions), the conversion is a thin re-use of
   `AudioWAVEncoder`-style PCM16 packing. If Soniox requires a
   different rate (e.g. 8 kHz, 24 kHz) or codec (e.g. Opus, μ-law),
   the provider MUST host its own converter; the existing
   `AudioDownsampler` MUST NOT be specialized for Soniox.

9. **FR-SX-9 — Language strategy: Greek + English primary.**
   The provider MUST be configured by default (i.e. when the user
   does NOT pass `--transcribe-language`) to recognize **Greek and
   English** as the primary languages. The implementation strategy
   depends on Soniox's API surface (to be confirmed during
   investigation):
   - If Soniox supports a multi-language hint list, the provider's
     default MUST be `[el, en]` (or `[el-GR, en-US, en-GB]` if
     region tags are accepted), in that priority order.
   - If Soniox supports a single language hint only, the default
     MUST be `el-GR` with documented user override to `en-US` via
     `--transcribe-language`.
   - If Soniox supports auto-detect across an explicit language set,
     the provider MUST configure that set to `{el, en}` only (so
     non-target languages do not pollute results).
   - Whatever the chosen mechanism, `--transcribe-language` MUST
     remain the user override, accepting BCP-47 tags and (per the
     existing `apple` provider's convention) optionally a
     comma-separated list. The provider MUST document explicitly
     whether the comma-list is honoured for parallel recognition or
     whether only the first hint is consumed (parity with existing
     provider documentation, e.g. `gemini` uses only the first hint).

10. **FR-SX-10 — Per-segment language tagging.**
    Each segment emitted by Soniox MUST be tagged with its detected
    BCP-47 language code on the `language` field of the sidecar
    record (parity with the `apple` provider's FR-AS-4 / FR-AS-6).
    For TXT / SRT / VTT writers, when ≥ 2 distinct languages appear
    in a session the cue body MUST be prefixed with `[lang]` (parity
    with FR-AS-6).

11. **FR-SX-11 — Sidecar parity.**
    Soniox sidecar files MUST follow the existing sidecar
    conventions: `*.transcript.<ext>` infix (FR-54), `partNN`
    rotation on `split(nextOutput:)` (FR-55), per-source labelling
    in `--transcribe-source both` (FR-56), and the standard set of
    formats (`jsonl`, `txt`, `srt`, `vtt`). The `model` field on
    each segment line MUST equal `"soniox"`.

12. **FR-SX-12 — Detach mode supported.**
    `macrec start --detach --transcribe soniox` MUST work end-to-end
    (parity with the post-plan-004 lift for Gemini and FR-AS-10 for
    Apple). The TCC microphone grant must be in place before
    launching detached.

13. **FR-SX-13 — Pause / Resume / Split parity.**
    Pause/Resume MUST produce a clean utterance boundary (parity
    with FR-AS-11). `split(nextOutput:)` MUST rotate the Soniox
    sidecar atomically (parity with FR-55 / FR-AS-12); if the
    provider holds a long-lived streaming session it MUST close and
    reopen the session so the new sidecar starts cleanly without
    samples from the prior segment.

14. **FR-SX-14 — Stop drains in-flight provider work within 5 s.**
    Parity with FR-57. On Stop / SIGINT / SIGTERM, the Soniox
    provider's session(s) MUST be closed cleanly (any final-only
    server messages emitted as `final` segments) within the 5 s
    drain deadline, with cancellation of any still-pending work
    after that.

15. **FR-SX-15 — Per-session metrics.**
    The provider MUST report into the existing `TranscriptionMetrics`
    aggregate (FR-58): chunks / messages sent, billable seconds,
    error count, last RTT or last partial-latency observation,
    buffer overflow drops. The exact sub-metric set MAY be reduced
    if Soniox's streaming model does not expose chunk-equivalent
    counters, but the surface MUST remain populated (zero-valued
    fields are acceptable; missing fields are not).

16. **FR-SX-16 — Privacy disclosure on first opt-in.**
    Selecting Soniox in the UI picker for the first time on a given
    launch MUST surface the same one-time confirmation dialog the
    Gemini provider uses, with body text adapted to name Soniox as
    the destination ("Audio is being sent to Soniox"). Parity with
    FR-53 / AC-LT-9 / AC-LT-25 / NFR-20.

17. **FR-SX-17 — UI picker option.**
    The `macrec-ui` popover's live-transcription provider picker MUST
    list `Soniox` as a fourth option after `None`, `Apple`, and
    `Gemini`. Persisted via the existing
    `@AppStorage("com.macrec.ui.transcribeProvider")` key. Disabled
    while recording (parity with AC-LT-19).

18. **FR-SX-18 — `--help` and documentation surfaces updated.**
    `macrec start --help` output MUST list `soniox` in the allowed
    set for `--transcribe`, and the surrounding doc files
    (`docs/tools/macrec.md`, `docs/tools/macrec-ui.md`,
    `docs/design/configuration-guide.md`,
    `docs/design/project-functions.md`,
    `docs/design/project-design.md`, and the new
    `docs/design/plan-006-soniox-streaming.md`) MUST be updated to
    name Soniox, its env vars, model id, endpoint flag, language
    strategy, and sidecar behaviour.

### Non-functional requirements

19. **NFR-SX-1 — Recording integrity isolation.**
    Any failure inside the Soniox provider (network error, invalid
    API key, rate limit, malformed server message, hung session)
    MUST be non-fatal to the recording pipeline. Parity with NFR-17.
    Verified by running an integration test that injects a hanging
    or always-throwing fake provider behind the `soniox` registration
    point and asserting the audio file is byte-identical to a control
    recording with `--transcribe none`.

20. **NFR-SX-2 — End-to-end latency target ≤ 1.5 s P95 (utterance
    end → final segment line on disk).**
    Soniox's real-time API is a streaming WebSocket (or HTTP/2
    streaming) and is expected to outperform Gemini REST's NFR-19
    budget of ≤ 5 s P95. Target: ≤ 1.5 s P95 from end-of-utterance
    to the corresponding `final` segment landing in the sidecar
    JSONL on disk. This is an observability target, not a hard SLO
    — exceeding it logs a `.warning` and never stops the recording.
    First-partial latency target: ≤ 500 ms P95 (parity ambition with
    FR-AS-3 / NFR-AS-1).

21. **NFR-SX-3 — API key never logged or written to disk except as
    the configured key file.** Parity with NFR-20: `SONIOX_API_KEY`
    MUST appear only in the resolver's in-memory
    `RecordingOptions.transcriptionApiKey` field and the
    user-controlled source files. It MUST NOT appear in any log line,
    sidecar header, post-stop UI summary, or error message. No
    `--soniox-api-key` flag.

22. **NFR-SX-4 — No PII metadata in requests.**
    Audio bytes and the source label (`mic` / `system`) are the only
    data sent to Soniox. No filename, mic device name, host name,
    user name, or any other host metadata. Parity with NFR-20.

23. **NFR-SX-5 — Bounded retry posture.**
    Per-chunk / per-message failures MUST be non-fatal (parity with
    NFR-21). Soniox's streaming API may automatically reconnect under
    its own session resumption protocol (to be investigated); if so,
    the provider MAY enable that. v1 MUST NOT add automatic retry of
    a failed chunk on top of provider reconnect.

24. **NFR-SX-6 — Provider footprint.**
    The Soniox provider MUST stay within the same per-process
    transcription memory bound as the existing providers (NFR-18
    spirit: ≤ 320 KB per active source for in-flight PCM; the
    streaming session's own buffers are additional and capped by the
    SDK / `URLSessionWebSocketTask` defaults).

25. **NFR-SX-7 — No new third-party SPM dependencies unless
    justified.**
    Strong preference for `URLSessionWebSocketTask` (Foundation, no
    dep) for the streaming transport, mirroring the original
    plan-003 OQ-LT-4 decision. If Soniox publishes an official Swift
    SDK, evaluate it during investigation and document the
    add-vs-do-without trade-off in plan-006. Default disposition:
    HAND-ROLLED Foundation client unless the SDK provides material
    value (e.g. handles a non-trivial wire protocol). If a SPM
    dependency IS introduced, it MUST be added to `Package.swift`
    and called out in plan-006 §Risks.

---

## Constraints

### Technical constraints
- **Language**: Swift only (Exception 001).
- **Platform**: macOS 26.0+ (Tahoe; Exception 002 — required for
  `SpeechAnalyzer`, transitively pinned for the whole project).
- **Existing protocol surface**: the new provider MUST conform to the
  existing `TranscriptionProvider` protocol (FR-46). Extending the
  protocol is allowed only if streaming semantics fundamentally
  cannot be expressed via the current `transcribe(samples:source:options:)`
  signature; even then, the extension MUST be optional with a
  default implementation so the existing two providers are not
  forced to change.
- **Networking**: prefer `URLSessionWebSocketTask` (Foundation, no
  dep). Any new SPM dependency must be justified (NFR-SX-7).
- **Configuration**: the four-tier env-var resolution chain is
  mandatory (FR-12). No fallback values for missing config (FR-14 /
  CLAUDE.md "no fallback" rule). Vendor-canonical env-var names
  (e.g. `SONIOX_API_KEY`) preferred over project-prefixed names
  (parity with `GOOGLE_API_KEY`, `OPENAI_API_KEY`, etc.).
- **Security**: API keys MUST NOT be acceptable as CLI flags (NFR-20
  parity). Stored in `~/.tool-agents/macrec/.env` (mode `0600`) or
  `~/.tool-agents/macrec-ui/.env` (mode `0600`).
- **Recording integrity**: transcription failures are isolated from
  the audio recorder (NFR-17 / NFR-SX-1).
- **Audio format reuse**: leverage the existing `AudioDownsampler`
  (Float32/48 kHz/stereo → Float32/16 kHz/mono). Soniox-specific
  encoding (PCM16 packing, framing) lives inside the provider only.

### Process constraints
- A new plan file `docs/design/plan-006-soniox-streaming.md` MUST be
  produced by the planner before implementation begins.
- The work MUST update `docs/design/project-design.md` (transcription
  pipeline section) and `docs/design/project-functions.md`
  (FR-SX-1..FR-SX-18 + NFR-SX-1..NFR-SX-7 registered).
- All test scripts MUST live under `test_scripts/`.
- No version-control operations are to be performed unless the user
  explicitly requests them.
- Documentation conventions in CLAUDE.md must be followed (the
  existing tools `macrec` and `macrec-ui` are documented under
  `docs/tools/` and listed in the project `CLAUDE.md` `## Tools`
  section — Soniox does not introduce a new tool; it is an internal
  capability of `macrec` / `macrec-ui`, so no new `docs/tools/<name>.md`
  is required, but the existing two tool docs MUST be updated).

### Resource constraints
- A real Soniox API key is required for the e2e tests. The user must
  obtain one from <https://console.soniox.com/> (URL to be confirmed
  during investigation). Cost: pay-as-you-go; verify free tier or
  trial credit availability and document in the configuration guide
  (see Open Question OQ-SX-5).
- All e2e tests requiring a real key MUST follow the existing
  `e2e-transcription-*.sh` pattern: skip cleanly with an exit-0 +
  message when `SONIOX_API_KEY` is not set, so CI / local runs
  without the key still pass.

---

## Acceptance Criteria

Each criterion below is testable. Plan-006 will map them to specific
test artefacts (unit, e2e script, manual review).

1. **AC-SX-1 — `--transcribe soniox` produces a sidecar.**
   `bash test_scripts/e2e-transcription-soniox.sh` (with a real
   `SONIOX_API_KEY` exported) produces a `*.transcript.jsonl` sidecar
   alongside the audio file containing ≥ 2 segments and at least one
   line whose `model` field equals `"soniox"`. Exit code 0.

2. **AC-SX-2 — Greek end-to-end recognition.**
   The e2e Greek variant (clip with known Greek text — e.g. a 30 s
   recording of the user reading "Καλημέρα, σήμερα είναι μια όμορφη
   μέρα. Δοκιμάζω την υπηρεσία αναγνώρισης ομιλίας Soniox.") produces
   a sidecar where the concatenated `text` fields contain at least 5
   of the following keyword set: `Καλημέρα`, `σήμερα`, `όμορφη`,
   `μέρα`, `δοκιμάζω`, `υπηρεσία`, `αναγνώρισης`, `ομιλίας`, `Soniox`.
   The first matched segment's `language` field starts with `el`.

3. **AC-SX-3 — English end-to-end recognition.**
   The e2e English variant (clip with known English text — e.g. a
   30 s recording reading "Good morning, today is a beautiful day. I
   am testing the Soniox speech recognition service.") produces a
   sidecar where the concatenated `text` fields contain at least 5 of
   the following keyword set: `morning`, `today`, `beautiful`, `day`,
   `testing`, `Soniox`, `speech`, `recognition`, `service`. The first
   matched segment's `language` field starts with `en`.

4. **AC-SX-4 — Greek + English bilingual within a single recording.**
   When the user reads alternating Greek and English sentences in a
   single recording, the resulting sidecar contains at least one
   segment whose `language` starts with `el` AND at least one whose
   `language` starts with `en` (verifies the language strategy of
   FR-SX-9 actually engages multi-language recognition).

5. **AC-SX-5 — Missing API key fails cleanly.**
   `bash test_scripts/e2e-transcription-soniox-key-missing.sh`
   (with no `SONIOX_API_KEY` exported and `--transcribe soniox` set)
   exits 78, no audio file is created, no sidecar is created, and
   stderr contains the missing-key message naming `SONIOX_API_KEY`
   and the four sources checked.

6. **AC-SX-6 — Recording integrity is isolated from Soniox failures.**
   `RecordingIntegrityIsolationTests` is extended with a
   `SonioxAlwaysFailingFake` injection variant. The test passes if
   the audio file produced under the failing-fake injection is
   byte-for-byte identical to the control recording with
   `--transcribe none`.

7. **AC-SX-7 — Provider conforms to existing protocol.**
   `SonioxStreamingTranscriptionProvider` compiles against the
   unchanged `TranscriptionProvider` protocol surface (or against a
   minimally-extended-with-default-implementation version of it).
   `swift build --product macrec` and `swift build --product
   macrec-ui` complete with no warnings beyond the existing baseline.

8. **AC-SX-8 — UI picker lists Soniox.**
   Snapshot test on `TranscriptionPicker` confirms the menu contains
   four entries in the order `None`, `Apple`, `Gemini`, `Soniox`.
   Selecting `Soniox` and starting a recording wires
   `transcriptionProviderId == "soniox"` into the `RecordingOptions`
   passed to `RecordingSession.run` (parity with the LT-PEND-5 fix).

9. **AC-SX-9 — Privacy disclosure shown on first Soniox start.**
   UI test: launch app, select `Soniox` for the first time, press
   Start. A confirmation dialog appears naming Soniox as the
   destination. Dismissing the dialog with "Don't show again"
   suppresses it on subsequent starts within the same launch.

10. **AC-SX-10 — Detach mode supports Soniox.**
    `bash test_scripts/e2e-transcription-soniox-detach.sh` (with a
    real key) starts a `--detach --transcribe soniox` recording,
    waits 30 s, calls `macrec stop`, and asserts the sidecar lands
    with ≥ 1 segment, `model:"soniox"`. Exit code 0.

11. **AC-SX-11 — Pause / resume / split rotates the sidecar.**
    `e2e-transcription-soniox.sh` split variant: drive a
    pause-resume cycle and a manual `split()` while transcription is
    active. Assert that each `partNN` audio file has a matching
    `partNN.transcript.jsonl` sibling and that the line counts
    distribute across them (no segment crosses a part boundary —
    parity with AC-LT-20).

12. **AC-SX-12 — Stop drains within 5 s.**
    Programmatic test: start a Soniox session, ingest 10 s of
    synthetic audio, call `stop()`, assert the `events` stream
    `.finish`es and the sidecar writer closes within 5 s wall-clock
    of the stop call (parity with AC-LT-13 / FR-57).

13. **AC-SX-13 — Per-session metrics emitted.**
    On stop, the `TranscriptionMetrics` value emitted on the events
    stream contains non-nil values for chunks/messages sent, billable
    seconds, error count, and last RTT (parity with AC-LT-14).

14. **AC-SX-14 — Help text and docs updated.**
    `macrec start --help` lists `soniox` in the `--transcribe`
    allowed set; `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`,
    `docs/design/configuration-guide.md`, and
    `docs/design/project-functions.md` all name Soniox, its env vars
    (`SONIOX_API_KEY`, `MACREC_SONIOX_ENDPOINT`, model + language
    flags), and link to the Soniox docs (https://soniox.com/docs).

15. **AC-SX-15 — No new SPM dependency unless documented.**
    `Package.swift` diff is either empty (Foundation-only
    implementation) or adds exactly one Soniox-related dependency
    that is called out and justified in plan-006 §Risks.

16. **AC-SX-16 — `--transcribe-key-expires-at` warns when past.**
    Setting `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` (or the Soniox-scoped
    variant if introduced) to an ISO-8601 date in the past produces
    a `.warning` log line at recording start. Recording is NOT
    blocked. Sidecar still produced.

17. **AC-SX-17 — Invalid `--transcribe` value still rejected.**
    `--transcribe foobar` continues to exit 64 (parity with
    AC-LT-17); `--transcribe soniox-streaming` (close-but-wrong)
    also exits 64 with a remediation message listing the four
    accepted values.

18. **AC-SX-18 — Latency observability.**
    A debug-level log line at session stop reports the observed
    P50 / P95 first-partial-latency and end-of-utterance-to-final
    latency for the Soniox session. Values within the targets stated
    in NFR-SX-2 do not log a warning; values exceeding them log a
    `.warning` (recording continues either way).

---

## Assumptions

The following assumptions were made during refinement; they are
flagged so plan-006 (Phase 4 Planner) can challenge them before
execution begins.

- **A-SX-1 — Soniox offers a real-time streaming STT API.**
  Basis: the user described Soniox as a "real-time speech-to-text"
  provider and named it as a streaming alternative to Gemini Live
  and Apple SpeechAnalyzer. The Soniox docs site
  (https://soniox.com/docs) and GitHub org (https://github.com/soniox)
  are expected to document the streaming surface. To be CONFIRMED
  during investigation; if Soniox is REST-only batch (analogous to
  plan-004), the spec must be revised before implementation.

- **A-SX-2 — Vendor-canonical API key env var is `SONIOX_API_KEY`.**
  Basis: parity with `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
  `GOOGLE_API_KEY`, etc. The actual canonical name to be confirmed
  against the Soniox docs / SDK examples during investigation
  (see Open Question OQ-SX-2).

- **A-SX-3 — Soniox supports multilingual / Greek + English
  recognition out of the box.**
  Basis: the user stated this as a hard requirement for the
  integration. Soniox is widely advertised as a multilingual STT
  vendor. To be confirmed during investigation by checking the
  supported-languages list on https://soniox.com/docs.

- **A-SX-4 — Soniox streaming accepts 16 kHz mono PCM16.**
  Basis: this is the de facto standard for cloud STT vendors
  (Google Speech-to-Text, Deepgram, AssemblyAI, OpenAI Realtime all
  accept it; the existing `AudioDownsampler` already produces
  Float32/16 kHz/mono and `AudioWAVEncoder` packs it into PCM16).
  To be confirmed; if Soniox requires a different rate (e.g. 8 kHz,
  24 kHz) or codec (Opus, μ-law), the provider hosts its own
  converter (FR-SX-8).

- **A-SX-5 — A free trial / starter tier exists for validation.**
  Basis: most cloud STT vendors offer one. If Soniox does not, the
  user must fund the validation work directly. Documented in the
  Open Question OQ-SX-5.

- **A-SX-6 — Soniox's streaming protocol is WebSocket-based.**
  Basis: virtually every modern streaming STT vendor uses WebSocket.
  To be confirmed; if it is gRPC the provider may need a third-party
  dependency (NFR-SX-7).

- **A-SX-7 — No special TCC permission is required for Soniox.**
  Basis: Soniox is a network service; the existing Microphone +
  Screen Recording grants cover what `macrec` needs to capture audio.
  Soniox's TLS connection requires no additional Mac entitlement
  (the project is not yet sandboxed; if it ever is, the
  `com.apple.security.network.client` entitlement is the standard
  fix and is already noted as a v2 prerequisite in the deferred-features
  section of `project-functions.md`).

- **A-SX-8 — Soniox emits per-message language identification on
  multilingual recognition.**
  Basis: reasonable expectation for a multilingual STT vendor. If
  Soniox returns text without language identification, FR-SX-10
  (per-segment language tagging) needs to fall back to either
  the user-provided hint (single language) or a downstream
  language-detection step (out of scope for v1 — would be deferred).

- **A-SX-9 — The existing `TranscriptionProvider` protocol is
  expressive enough for streaming.**
  Basis: the same protocol already serves Gemini (REST batch) and
  Apple SpeechAnalyzer (true streaming via `AsyncStream` internally
  bridged to the protocol's `transcribe(samples:source:options:)`).
  The Soniox provider can do the same — owning a long-lived
  `URLSessionWebSocketTask` internally and bridging chunks to it
  while presenting the simple `async` request/response surface
  externally. If the bridge proves awkward, plan-006 may propose a
  protocol extension with a default implementation, but it must NOT
  break the existing two providers.

- **A-SX-10 — `SONIOX_API_KEY` shares the existing
  `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` companion variable.**
  Basis: the configuration-guide §2.22 already establishes the
  expiry-companion pattern as provider-agnostic. If Soniox's keys
  have materially different expiry semantics (e.g. organization-level
  vs personal tokens), a Soniox-scoped variant
  `MACREC_SONIOX_KEY_EXPIRES_AT` may be added in plan-006.

---

## Open Questions

These questions could not be resolved from the user's request alone
and require either user input, investigation of the Soniox docs, or
deferral to plan-006 design decisions.

- **OQ-SX-1 — Is the existing `TranscriptionProvider` protocol
  sufficient for Soniox streaming, or is a protocol extension
  needed?**
  Decide during plan-006 Phase 5 (Designer) after a concrete
  prototype of the Soniox session lifecycle. Default disposition:
  KEEP the existing protocol; bridge streaming internally.

- **OQ-SX-2 — Is `SONIOX_API_KEY` actually the vendor-canonical env
  var name?**
  Verify against the Soniox docs and SDK examples during
  investigation. If Soniox uses a different canonical name (e.g.
  `SONIOX_KEY`, `SONIOX_TOKEN`), adopt that name. If no convention
  is published, default to `SONIOX_API_KEY` (matches the LLM-provider
  convention).

- **OQ-SX-3 — Should v1 expose Soniox's speaker-diarization /
  endpointing / language-identification features?**
  These are first-class Soniox capabilities (per the user's
  reference link). Default: NO for v1 — expose only what's needed
  to make Greek + English real-time transcription work end-to-end.
  Diarization is already deferred at the project level (v2 backlog).
  Confirm with user before plan-006 closes.

- **OQ-SX-4 — Which Soniox model id should the provider pin as the
  default?**
  Soniox publishes multiple models with different language-coverage
  / latency / cost trade-offs. The default must be the multilingual
  real-time model that covers Greek and English well. To be locked
  during investigation by reading the model catalogue at
  https://soniox.com/docs.

- **OQ-SX-5 — Cost / billing model.**
  Confirm Soniox's pricing for streaming, whether a free trial /
  starter tier exists, and document it in
  `docs/design/configuration-guide.md` so the user can budget the
  e2e validation. If a paid plan is required even for trial
  validation, escalate to the user before kicking off plan-006.

- **OQ-SX-6 — Latency / SLO target.**
  NFR-SX-2 proposes ≤ 1.5 s P95 utterance-end → final segment on
  disk and ≤ 500 ms P95 first-partial. Confirm these are acceptable
  to the user, or relax / tighten as appropriate. (The user did
  not specify explicit latency targets.)

- **OQ-SX-7 — Should `--transcribe-language` accept comma-separated
  multi-language hints for Soniox (parity with `apple`), or only a
  single primary hint (parity with `gemini`)?**
  Depends on Soniox's API surface. If Soniox accepts a hint LIST
  natively, mirror the `apple` semantics (comma-separated is honoured
  for parallel multi-language recognition). Otherwise, mirror the
  `gemini` semantics (only the first hint consumed; others ignored
  with a `.notice` log line).

- **OQ-SX-8 — Should Soniox be added to the picker BEFORE or AFTER
  Gemini?**
  Spec defaults to AFTER (`None`, `Apple`, `Gemini`, `Soniox`) —
  preserves existing UI ordering and adds the newcomer at the end.
  User may prefer alphabetical (`None`, `Apple`, `Gemini`, `Soniox`
  is already alphabetical after `None`, so the two orderings
  coincide here).

- **OQ-SX-9 — Default `--transcribe-source` for Soniox.**
  Inherits the project default (`mixed`). No reason expected to
  override — confirm during plan-006.

- **OQ-SX-10 — Should Soniox's data-retention controls be exposed?**
  If Soniox lets API callers opt out of server-side audio storage
  / model-improvement use, expose that as an opt-in flag (default:
  opt-OUT of retention, i.e. the most privacy-preserving setting).
  Documented in `docs/design/configuration-guide.md`. Confirm with
  user during plan-006.

- **OQ-SX-11 — Should the official Soniox Swift SDK (if any) be
  used, or a hand-rolled `URLSessionWebSocketTask` client?**
  Default: hand-rolled (NFR-SX-7). Re-evaluate after reading the
  Soniox GitHub org (https://github.com/soniox) — if a Swift SDK is
  published with non-trivial protocol handling (e.g. binary message
  framing, session-resumption, automatic reconnect), the cost of
  reimplementing it in v1 may justify the dependency. Document the
  choice in plan-006 §Risks.

- **OQ-SX-12 — Macro-level: should `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`
  be split into per-provider variants
  (`MACREC_GOOGLE_KEY_EXPIRES_AT`,
  `MACREC_SONIOX_KEY_EXPIRES_AT`)?**
  Currently it's a single shared variable. With a third provider on
  the way, ambiguity grows: which key does it refer to when more
  than one is configured? Plan-006 should propose a migration path
  (default: keep the shared variable, add Soniox-scoped override if
  needed; do NOT break the existing Gemini config).

---

## Original Request

```
Add Soniox real-time speech-to-text as a transcription option to the recording-tool project (a macOS Swift CLI + menu-bar app that records system audio + microphone and supports live transcription via streaming providers).

The user wants this to be a NEW provider option alongside the existing transcription providers (Gemini Live, Apple Speech). Primary supported languages: Greek (el / el-GR) and English (en / en-US / en-GB), in that order of priority.

Reference material the user provided:
- https://github.com/soniox (the Soniox GitHub organization — has SDKs and code samples)
- https://soniox.com/docs (the official Soniox documentation site)

The user wants me to study these sources as needed.
```

### Reference material to study during investigation

- Soniox GitHub organization: <https://github.com/soniox> — collect
  SDKs, code samples, and the streaming protocol reference.
  Specifically scan for:
  - Swift / Objective-C SDK presence
  - Reference WebSocket client implementations (any language) with
    enough wire-protocol detail to hand-roll a Swift equivalent
  - Streaming sample apps for multilingual / Greek / English
- Soniox documentation site: <https://soniox.com/docs> — collect:
  - Streaming API endpoint URL(s) and regional variants
  - Authentication scheme (Bearer header? URL param? other?)
  - Audio format requirements (sample rate, channels, encoding,
    framing)
  - Supported languages and the current model catalogue
  - Pricing / free-tier policy
  - Data-retention controls

The collected reference material MUST be saved under `docs/reference/`
(per CLAUDE.md "All the reference material used for the project must
be collected and kept under the docs/reference folder") as e.g.
`docs/reference/investigation-soniox-streaming.md`.
