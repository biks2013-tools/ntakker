# Plan 006 — Soniox Real-Time Streaming Transcription Provider

> **Status**: Implementation plan — ready for Phase 5 (Designer) review,
> then Phase 6 (Implementer).
>
> **Date**: 2026-04-29
>
> **Builds on**:
> - `docs/design/plan-005-apple-speech-streaming.md` — extended
>   `TranscriptionProvider` protocol with `supportedModes` + the
>   `openStreamingSession(...)` surface and the `StreamingTranscriptionPipeline`.
>   Plan-006 reuses every one of those abstractions.
> - `docs/design/plan-004-rest-batch-transcription.md` — `TranscriptionManager`
>   actor, sidecar writers (`.streaming` policy), source-tag routing.
>   Unchanged by plan-006.
>
> **Source documents**:
> - `docs/design/refined-request-soniox-streaming.md` — FR-SX-1..FR-SX-18,
>   NFR-SX-1..NFR-SX-7, AC-SX-1..AC-SX-18, A-SX-1..A-SX-10, OQ-SX-1..OQ-SX-12.
> - `docs/reference/investigation-soniox-streaming.md` — recommended approach
>   (Option 1: hand-rolled `URLSessionWebSocketTask`); resolved 5 of 12
>   open questions.
> - `docs/research/soniox-wire-schema.md` — verbatim wire schemas, error
>   catalog, marker token semantics, regional endpoints, Pipecat reference.
> - `docs/reference/codebase-scan-soniox-streaming.md` — 14 new artefacts,
>   10 existing touch points, project layout, build/test commands.
>
> **User intent**: User asked "Add Soniox real-time speech-to-text as a third
> transcription provider alongside Gemini Live and Apple SpeechAnalyzer; it
> must support Greek (el / el-GR) and English (en / en-US / en-GB) in that
> priority order." Plan-006 is the executable implementation plan.

---

## 0. Decisions Needed From User Before Phase 6 Begins

Plan-006 does NOT block on these — defaults are documented inline so
implementation can proceed — but the user is asked to confirm or override
each one before Phase 6 (Implementer) begins. Each decision is reflected
verbatim in the corresponding §Phase task.

| # | Question | Default disposition (this plan) | Status | Where it lands |
|---|---|---|---|---|
| **OQ-SX-1** | Is the existing `TranscriptionProvider` / `StreamingTranscriptionSession` protocol expressive enough for Soniox streaming, or does it need extension? | **KEEP existing protocol unchanged.** Soniox internally owns its `URLSessionWebSocketTask`; bridges Soniox tokens → `StreamingTranscriptionEvent` (`.partial`, `.final`, `.metrics`, `.error`) inside `SonioxStreamingSession`. Same pattern as `AppleSpeechSession`. | **RESOLVED in plan** | Phase A (no protocol change) |
| **OQ-SX-2** | Vendor-canonical API key env var name? | `SONIOX_API_KEY` — confirmed by Soniox docs §"Get API key". | **RESOLVED by investigation** | Phase B |
| **OQ-SX-3** | Should v1 expose Soniox's diarization / language-identification advanced features by default? | **Language identification ON by default** (`enable_language_identification: true`) — required by FR-SX-10 (per-segment language tagging). **Endpoint detection ON by default** (`enable_endpoint_detection: true`, `max_endpoint_delay_ms: 2000`) — gives clean `final` event semantics that mirror Apple Speech. **Diarization OFF** (out of scope per refined request, OQ-SX-3 default). No CLI knob exposed in v1. | **RECOMMENDED, NEEDS USER CONFIRMATION** | Phase D, §config |
| **OQ-SX-4** | Default Soniox model id? | **`stt-rt-v4`** — confirmed by investigation as best multilingual real-time model with native Greek/English support, ~7.4% Greek WER. | **RESOLVED by investigation** | Phase D |
| **OQ-SX-5** | Cost / billing for e2e validation? | $0.12/hr streaming. **User must confirm trial credit availability** at console.soniox.com before AC-SX-1..AC-SX-4 e2e runs are funded. | **RESOLVED in pricing; user must sign up** | Phase I, e2e budget |
| **OQ-SX-6** | Latency targets? Plan proposes ≤ 1.5 s P95 utterance-end → final on disk; ≤ 500 ms P95 first-partial. | **PROPOSED targets**: 1.5 s end-to-end / 500 ms first-partial — observability only (warn-on-exceed, never block recording). | **RECOMMENDED, NEEDS USER CONFIRMATION** | NFR-SX-2; verified at AC-SX-18 |
| **OQ-SX-7** | `--transcribe-language` comma-list semantics for Soniox? | **Honour the comma-separated list**, parity with `apple` provider. Soniox's `language_hints` is a native array. Strip BCP-47 region tags (`el-GR` → `el`, `en-US` → `en`, `en-GB` → `en`), deduplicate, send as `language_hints`. | **RESOLVED by investigation (OQ-SX-7)** | Phase D, §language strategy |
| **OQ-SX-8** | UI picker order? | **Append after Gemini** — final order: `None` / `Apple` / `Gemini` / `WhisperKit` / `Soniox`. Preserves the existing UI ordering of Apple-first (default), Gemini second, WhisperKit third (existing entry); Soniox is appended at the end. | **RECOMMENDED, NEEDS USER CONFIRMATION** | Phase H, AC-SX-8 |
| **OQ-SX-9** | Default `--transcribe-source` for Soniox? | **`mixed` (project default)** — no provider-specific override. User can pass `--transcribe-source both` for per-source streams (each opens its own WebSocket). | **RECOMMENDED, NEEDS USER CONFIRMATION** | Phase D |
| **OQ-SX-10** | Data-retention disclosure? | Soniox does **NOT publish** a per-request data-retention toggle in the WebSocket config schema. Default: **document the org-level retention setting** in `configuration-guide.md` and the `PrivacyDisclosureSheet` body for Soniox; **expose no per-recording opt-out in v1**. Set `client_reference_id = macrec-<recordingId>-<source>` (no PII) for vendor-side debugging only. | **RECOMMENDED, NEEDS USER CONFIRMATION** | Phase 0.6 (configuration-guide), Phase H (disclosure text) |
| **OQ-SX-11** | Hand-rolled WS vs Soniox SDK? | **Hand-rolled.** No Swift SDK exists at github.com/soniox; protocol is small enough that wrapping the Python/JS SDKs via sidecar is unjustified (NFR-SX-7). | **RESOLVED by investigation** | All phases |
| **OQ-SX-12** | Per-provider expiry env var split? | **Recommend going forward with separate expiry per provider.** Add `MACREC_SONIOX_KEY_EXPIRES_AT` as a Soniox-scoped optional override. Keep the shared `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` as the fallback for backward-compat with the Gemini-only configuration today. Resolution order: provider-scoped > shared. | **RECOMMENDED, NEEDS USER CONFIRMATION** | Phase B, FR-SX-5, AC-SX-16 |

If any default above is rejected by the user, the affected Phase task
must be revised before Phase 6 begins. The OQ-SX-3 (advanced features),
OQ-SX-6 (latency target), OQ-SX-8 (picker order), OQ-SX-9 (source default),
OQ-SX-10 (retention), and OQ-SX-12 (expiry split) decisions are
genuinely policy/UX decisions where the user's preference may differ
from the default; the others are vendor-research-resolved.

---

## 1. Goal

Add a third concrete `TranscriptionProvider` —
`SonioxStreamingTranscriptionProvider` — that opens a WebSocket session
per source against `wss://stt-rt.soniox.com/transcribe-websocket`,
streams 16 kHz mono PCM16-LE audio frames with a `language_hints: ["el",
"en"]` configuration, and bridges Soniox's per-token JSON responses
into the existing `StreamingTranscriptionEvent` enum (`.partial`,
`.final`, `.metrics`, `.error`) consumed by the
`StreamingTranscriptionPipeline` defined by plan-005.

The Apple Speech default (`--transcribe apple`) is preserved.
Gemini REST and WhisperKit are preserved. Soniox is the **fifth
transcription option** (`none` / `apple` / `gemini` / `whisperkit` /
`soniox`) and is **opt-in only** — no flip of the default.

The recording integrity isolation contract from project-design §LT
("audio is the primary artefact; nothing in transcription can stop a
recording") is preserved verbatim — only a new provider conformer is
added.

---

## 2. Why this addition

### 2.1 What plan-005 covers and where Soniox fits

Plan-005 added a true streaming pipeline (`StreamingTranscriptionPipeline`)
that bridges any `[.streaming]`-mode provider's `AsyncStream<StreamingTranscriptionEvent>`
into the `TranscriptionManager`'s event bus. Apple SpeechAnalyzer is the
first conformer. Soniox is the second.

Reasons the user wants Soniox alongside Apple:

| Dimension | Apple SpeechAnalyzer | Soniox |
|---|---|---|
| Privacy | 100% on-device | Cloud (US/EU/JP regions) |
| Greek WER (acoustic only) | ~10–14% (varies by macOS install) | **~7.4%** (best in 2025 benchmark) |
| Cost | Free | $0.12/hr streaming |
| First-partial latency | 80–250 ms | 250–500 ms (proposed target) |
| Mid-sentence language switching | No (parallel-locale workaround) | **Yes (native multilingual model)** |
| Per-token language ID | Inferred from per-locale winner | **Native (`enable_language_identification`)** |
| Setup cost | TCC grant only | API key signup |
| Network failure mode | N/A | Recording continues; sidecar gap (NFR-SX-1) |

For a user who works primarily in Greek + English, Soniox offers
materially better acoustic accuracy and mid-sentence language switching
(a real-world need: `"Κάνε screenshot την οθόνη"`) at the cost of cloud
egress. Apple stays as the privacy-preserving default; Soniox is the
power-user upgrade for content where ASR accuracy matters more than
keeping audio local.

### 2.2 Why hand-rolled over an SDK

There is no official Soniox Swift SDK at github.com/soniox. The Python
and JS SDKs are not consumable from a Swift macOS process without a
sidecar, which would add a runtime dependency for negligible gain. The
Soniox WebSocket protocol is small (one config JSON, binary PCM frames,
two text control messages, JSON token responses, empty-frame close) —
exactly the shape `URLSessionWebSocketTask` was designed for. This
mirrors the project's existing precedent (`URLSessionWebSocketTask` was
also the pick for Gemini Live in plan-003 OQ-LT-4 before that was
rewritten as REST in plan-004).

### 2.3 Why no deployment target bump

Plan-005 already lifted the deployment target to macOS 26 for
SpeechAnalyzer. `URLSessionWebSocketTask` is available since macOS 10.15
— Soniox imposes no further OS bump.

---

## 3. Scope deltas (file by file)

The codebase scan (`docs/reference/codebase-scan-soniox-streaming.md`
§4.3) lists 14 new artefacts and 10 existing touch points. Plan-006
groups them into three buckets.

### 3.1 To be added (14 files, 12 of them code/test, 2 e2e + 1 disclosure copy)

| Path | Approx. KB | Purpose | Phase |
|---|---|---|---|
| `Sources/MacrecCore/Transcription/Providers/SonioxStreamingTranscriptionProvider.swift` | ~10 | New provider; conforms to extended `TranscriptionProvider` (`supportedModes = [.streaming]`); owns `SonioxStreamingSession` factory | D |
| `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingSession.swift` | ~14 | Per-source streaming session; owns `URLSessionWebSocketTask`; bridges Soniox token responses to `StreamingTranscriptionEvent` | D |
| `Sources/MacrecCore/Transcription/Live/Soniox/SonioxWireMessages.swift` | ~5 | `Codable` types: `SonioxConfigMessage`, `SonioxControlMessage`, `SonioxServerMessage`, `SonioxToken`. All `Sendable`. | C |
| `Sources/MacrecCore/Transcription/Live/Soniox/SonioxLanguageHintMapper.swift` | ~2 | Pure value: BCP-47 → ISO 639-1 stripping (`el-GR` → `el`, `en-US` → `en`, `en-GB` → `en`); deduplicate; preserve order | C |
| `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift` | ~4 | Pure-ish state machine: accumulates non-final tokens (replaces buffer per response), accumulates final tokens, emits `.partial` / `.final` events on `<end>` and `<fin>` markers | C |
| `Sources/MacrecCore/Transcription/Live/Soniox/SonioxErrorMapper.swift` | ~2 | Map Soniox `error_code` (400/401/402/408/429/500/503) to `MacrecError` and event severity | C |
| `Sources/MacrecCore/Transcription/Live/Soniox/SonioxKeepaliveTimer.swift` | ~2 | Background `Task` that sends `{"type":"keepalive"}` every 10 s when no audio has been pushed for ≥ 5 s | D |
| `Sources/MacrecCore/Transcription/Live/Soniox/WebSocketTransport.swift` | ~3 | Tiny protocol abstracting `URLSessionWebSocketTask`'s `send(_:)` / `receive()` / `cancel(...)` for testability (Soniox cannot be intercepted via `URLProtocol`) | D |
| `Tests/MacrecCoreTests/Transcription/Providers/SonioxStreamingTranscriptionProviderTests.swift` | ~6 | Unit tests using `FakeWebSocketTransport` | I |
| `Tests/MacrecCoreTests/Transcription/Providers/FakeWebSocketTransport.swift` | ~3 | Test double for `WebSocketTransport`; replays scripted server messages | I |
| `Tests/MacrecCoreTests/Transcription/Live/Soniox/SonioxWireMessagesTests.swift` | ~3 | Round-trip Codable tests against verbatim fixtures from `docs/research/soniox-wire-schema.md` | C |
| `Tests/MacrecCoreTests/Transcription/Live/Soniox/SonioxLanguageHintMapperTests.swift` | ~1 | Unit tests for BCP-47 stripping | C |
| `Tests/MacrecCoreTests/Transcription/Live/Soniox/SonioxTokenAggregatorTests.swift` | ~3 | Unit tests for `<end>`/`<fin>` segmentation, non-final replacement | C |
| `Tests/MacrecCoreTests/Transcription/Live/Soniox/SonioxErrorMapperTests.swift` | ~1 | Unit tests for error code mapping | C |
| `test_scripts/e2e-transcription-soniox.sh` | ~2 | Real-key e2e: produces `*.transcript.jsonl`; skip-clean if `SONIOX_API_KEY` unset (AC-SX-1) | I |
| `test_scripts/e2e-transcription-soniox-greek.sh` | ~2 | Greek text recognition (AC-SX-2); requires real key | I |
| `test_scripts/e2e-transcription-soniox-english.sh` | ~2 | English text recognition (AC-SX-3); requires real key | I |
| `test_scripts/e2e-transcription-soniox-bilingual.sh` | ~2 | Greek + English bilingual single-session (AC-SX-4); requires real key | I |
| `test_scripts/e2e-transcription-soniox-key-missing.sh` | ~1 | No-key parity test (AC-SX-5) | I |
| `test_scripts/e2e-transcription-soniox-detach.sh` | ~1.5 | Detach-mode parity (AC-SX-10); requires real key | I |
| `test_scripts/e2e-transcription-soniox-split.sh` | ~2 | Pause/resume + manual `split()` rotation (AC-SX-11); requires real key | I |
| `test_scripts/probe-soniox-ws.swift` (OPTIONAL) | ~3 | Standalone probe to capture wire trace and confirm `<end>`/`<fin>` exact emission, empty-frame close-handshake variant, etc. (resolves the "**Inferred — confirm with probe script**" tags in `soniox-wire-schema.md`) | C (optional) |

> **Note on directory layout**: the `Sources/MacrecCore/Transcription/Live/Soniox/`
> subdirectory mirrors plan-005's `Sources/MacrecCore/Transcription/Providers/`
> Apple-Speech grouping (the codebase already places `AppleSpeechSession.swift`
> alongside `AppleSpeechTranscriptionProvider.swift`). Per the user's
> guidance, "mirror Gemini Live's directory layout under
> `Sources/MacrecCore/Transcription/Live/Soniox/`": this groups all
> Soniox-specific wire-protocol code under a single Live/Soniox/ subtree.
> The provider conformer itself stays in `Providers/` for factory
> discoverability; the wire-protocol code (codecs, aggregator, transport,
> keepalive) lives in `Live/Soniox/`.

**Total added**: ~17 source files (8 production, 6 unit-test, 7 e2e
scripts, 1 optional probe).

### 3.2 To be edited

| Path | Change | Phase | Spec ID |
|---|---|---|---|
| `Sources/MacrecCore/Config/RecordingOptions.swift` | Add `.soniox = "soniox"` case to `TranscriptionProviderId`. Add optional `sonioxEndpoint: URL?` field. Add optional `sonioxKeyExpiresAt: Date?` field (for OQ-SX-12 split). Forward both in `withOutput(_:)`. | B | FR-SX-1, FR-SX-7 |
| `Sources/MacrecCore/Config/ConfigResolver.swift` | Add `Keys.sonioxApiKey = "SONIOX_API_KEY"`, `Keys.sonioxEndpoint = "MACREC_SONIOX_ENDPOINT"`, `Keys.sonioxKeyExpiresAt = "MACREC_SONIOX_KEY_EXPIRES_AT"`. Add `case .soniox:` branch in API-key resolution at line 345 mirroring `case .gemini, .geminiLive:`. Add `case .soniox: return "soniox"` at line 241-261. Resolve endpoint default `wss://stt-rt.soniox.com/transcribe-websocket`. Validate optional URL parses. Resolve `sonioxKeyExpiresAt` with **provider-scoped > shared** precedence (per OQ-SX-12). | B | FR-SX-3, FR-SX-4, FR-SX-5, FR-SX-7 |
| `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift` | Add `case "soniox":` branch (lines 46-93). Guard on `apiKey` presence (mirrors `case "gemini":`); wire `endpoint`, `model`, `keyExpiresAt`. Update `default:` error message at line 91 to include `'soniox'`. Add `endpoint: URL?` to `TranscriptionProviderFactoryInput`. | D | FR-SX-2 |
| `Sources/macrec/Commands/StartCommand.swift` | Update `--transcribe` `@Option` help string at line 95 from stale `"none | gemini-live"` to `"none | apple | gemini | whisperkit | soniox"`. Add new `@Option(name: .customLong("soniox-endpoint")) var sonioxEndpoint: String?` and forward it in `buildCLIOverrides()` at line 216 as `Keys.sonioxEndpoint`. **NO `--soniox-api-key` flag** (NFR-SX-3). | H | FR-SX-7, FR-SX-18, AC-SX-14 |
| `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift` | Add `Text("Soniox (cloud, streaming)").tag("soniox")` after the `gemini` tag at line 75. Update `missingKeyTooltip` static so it returns the right env-var name based on `providerRaw` (`SONIOX_API_KEY` when `providerRaw == "soniox"`). | H | FR-SX-17, AC-SX-8 |
| `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift` | Add a `soniox`-keyed disclosure body: "Audio is being sent to Soniox (soniox.com) for transcription. Set the org-level data retention preferences in the Soniox console at console.soniox.com." Add `@AppStorage` flag `com.macrec.ui.sonioxPrivacyAccepted`. | H | FR-SX-16, AC-SX-9 |
| `Tests/MacrecCoreTests/Config/ConfigResolverTranscriptionTests.swift` | Add cases: `MACREC_TRANSCRIBE=soniox` + `SONIOX_API_KEY` resolves; same with `MACREC_SONIOX_ENDPOINT` overrides default; missing-key throws at start; `--transcribe soniox-streaming` (close-but-wrong) exits 64; `MACREC_SONIOX_KEY_EXPIRES_AT` precedence over `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`. | B, I | AC-SX-5, AC-SX-16, AC-SX-17 |
| `Tests/MacrecCoreTests/Transcription/Providers/TranscriptionProviderFactoryTests.swift` | Add cases: `"soniox"` with key returns `SonioxStreamingTranscriptionProvider`; without key throws `transcriptionApiKeyMissing`; endpoint override accepted. | D, I | FR-SX-2, FR-SX-3 |
| `Tests/MacrecCoreTests/Recording/SessionCoordinatorTranscriptionIntegrationTests.swift` (or analogous file `RecordingIntegrityIsolationTests` per the codebase scan §4.1.K) | Add `SonioxAlwaysFailingFake` injection variant. Audio file produced under failing-fake injection MUST be byte-identical to control with `--transcribe none`. | I | NFR-SX-1, AC-SX-6 |
| `docs/tools/macrec.md` | Add Soniox to the `--transcribe` allowed-set table; document `SONIOX_API_KEY`, `MACREC_SONIOX_ENDPOINT`, `MACREC_SONIOX_KEY_EXPIRES_AT`; link to https://soniox.com/docs. | I | FR-SX-18, AC-SX-14 |
| `docs/tools/macrec-ui.md` | Add Soniox to the picker description and the privacy-disclosure copy. | I | FR-SX-18, AC-SX-14 |
| `docs/design/configuration-guide.md` | New section: "Soniox provider" — covers `SONIOX_API_KEY` (no fallback), `MACREC_SONIOX_ENDPOINT` (default `wss://stt-rt.soniox.com/transcribe-websocket`, regional variants `wss://stt-rt.eu.soniox.com/...` and `wss://stt-rt.jp.soniox.com/...`), `MACREC_TRANSCRIBE_MODEL` default `stt-rt-v4`, `MACREC_TRANSCRIBE_LANGUAGE` BCP-47 → ISO 639-1 stripping note, `MACREC_SONIOX_KEY_EXPIRES_AT` (and shared-fallback to `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`), data-retention disclosure (org-level only, configured at console.soniox.com), free-tier policy disclaimer. | 0, I | FR-SX-18, AC-SX-14 |
| `docs/design/project-functions.md` | Append §1.6 "Added 2026-04-29 — Soniox streaming provider (plan-006)" with FR-SX-1..FR-SX-18, NFR-SX-1..NFR-SX-7, AC-SX-1..AC-SX-18. | 0 | FR-SX-18 |
| `docs/design/project-design.md` | Append "## §SX — Soniox Streaming Subsystem (plan-006)" section after the existing "## §AS" section. | 0, I | FR-SX-18 |
| `Issues - Pending Items.md` | Add PEND-SX-1: "wire-schema unverified for `<end>`/`<fin>` exact emission and empty-frame close handshake — run `test_scripts/probe-soniox-ws.swift` once a real `SONIOX_API_KEY` is available, then update `docs/research/soniox-wire-schema.md` to remove the **Inferred — confirm with probe script** tags." | 0 | (risk mitigation) |

### 3.3 To be deleted

None. Plan-006 is purely additive — no plan-004 or plan-005 code is
removed. The `gemini-live` deprecated alias from plan-004 stays.

---

## 4. Component contracts

### 4.1 `TranscriptionProvider` — UNCHANGED from plan-005

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModes: Set<TranscriptionMode> { get }

    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String

    func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
}
```

The Soniox provider declares `supportedModes = [.streaming]`. The
`transcribe(...)` method is implemented as a thin bridge over
`openStreamingSession(...)` (mirrors `AppleSpeechTranscriptionProvider`'s
implementation in `AppleSpeechTranscriptionProvider.swift:167-180`):
open a session, ingest the entire `samples` Float array as one burst,
send empty-frame close, await the `finished` response, concatenate the
final segments' `text`, return.

**OQ-SX-1 RESOLVED**: no protocol change needed.

### 4.2 `SonioxStreamingTranscriptionProvider`

```swift
public struct SonioxStreamingTranscriptionProvider: TranscriptionProvider {
    public let id = "soniox"
    public let displayName = "Soniox (cloud, streaming)"
    public let supportedModes: Set<TranscriptionMode> = [.streaming]

    let apiKey: String
    let modelId: String           // default "stt-rt-v4" if not overridden
    let endpoint: URL             // default wss://stt-rt.soniox.com/transcribe-websocket
    let logger: Logger
    let transportFactory: @Sendable () -> any WebSocketTransport
    let clock: any Clock          // injectable for deterministic latency tests

    public init(
        apiKey: String,
        modelId: String = "stt-rt-v4",
        endpoint: URL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!,
        logger: Logger,
        transportFactory: @escaping @Sendable () -> any WebSocketTransport
            = { URLSessionWebSocketTransport() },
        clock: any Clock = ContinuousClock()
    )

    public func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession
    // returns a SonioxStreamingSession

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String
    // bridges streaming → batch by ingesting all samples + draining
}
```

**Sendable**: yes (a `struct` with `let` properties whose stored types
are themselves `Sendable`). Safe for concurrent calls from
`TranscriptionManager`.

**No fallback for `apiKey`**: `init` requires it; `TranscriptionProviderFactory`
guards against `nil` and throws `MacrecError.transcriptionApiKeyMissing`
before `init` is reached.

### 4.3 `SonioxStreamingSession`

```swift
final class SonioxStreamingSession: StreamingTranscriptionSession,
                                     @unchecked Sendable {
    let source: SourceTag
    let events: AsyncStream<StreamingTranscriptionEvent>

    init(
        source: SourceTag,
        configMessage: SonioxConfigMessage,
        endpoint: URL,
        transport: any WebSocketTransport,
        logger: Logger,
        clock: any Clock
    ) async throws

    /// Push 16 kHz mono Float32 audio. Non-blocking, lossy under
    /// backpressure. Internally converts Float32 → Int16 LE Data
    /// and sends as binary WebSocket frame.
    func ingest(_ samples: [Float]) async

    /// Send finalize control message; wait up to ~2 s for <fin> token
    /// batch; retain WebSocket. Used on Pause.
    func pause() async

    /// Resume sending audio (no special control message needed).
    func resume() async

    /// Send empty TEXT frame ""; wait up to 5 s for `finished`
    /// response; close transport; finish events stream.
    func finish() async
}
```

**Internal moving parts**:

- One `Task` for the WebSocket receive loop (consumes server messages,
  decodes via `JSONDecoder` into `SonioxServerMessage`, routes through
  `SonioxTokenAggregator` → emits events).
- One `Task` for the keepalive timer (`SonioxKeepaliveTimer`).
- An `NSLock` (or `actor`) protecting the metrics counters and the
  "last audio sent at" timestamp the keepalive timer reads.
- The `events` `AsyncStream.makeStream(of:bufferingPolicy:.bufferingNewest(128))`
  matches the buffering policy of `AppleSpeechSession` for parity.

**Concurrency posture**: `@unchecked Sendable` + `NSLock` for mutable
state, parity with `AppleSpeechSession.swift:194`. An `actor` is
viable too; the choice is left to Phase D Designer review.

### 4.4 `SonioxConfigMessage` (the first WS frame)

Verbatim from `docs/research/soniox-wire-schema.md` §2.1:

```swift
struct SonioxConfigMessage: Codable, Sendable {
    let api_key: String
    let model: String                          // "stt-rt-v4" default
    let audio_format: String                   // "pcm_s16le"
    let sample_rate: Int                       // 16000
    let num_channels: Int                      // 1
    let language_hints: [String]?              // ["el", "en"] default
    let language_hints_strict: Bool?           // false default
    let enable_language_identification: Bool?  // true default
    let enable_endpoint_detection: Bool?       // true default
    let max_endpoint_delay_ms: Int?            // 2000 default
    let client_reference_id: String?           // "macrec-<recordingId>-<source>"
    // NOT in v1: enable_speaker_diarization, context, translation
}
```

`enable_speaker_diarization`, `context`, `translation` are explicitly
omitted from v1 (out of scope per refined request and OQ-SX-3 default).

### 4.5 `SonioxControlMessage`

```swift
enum SonioxControlMessage: Codable, Sendable {
    case keepalive   // {"type":"keepalive"}
    case finalize    // {"type":"finalize"}

    private enum CodingKeys: String, CodingKey { case type }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keepalive: try c.encode("keepalive", forKey: .type)
        case .finalize:  try c.encode("finalize",  forKey: .type)
        }
    }
}
```

### 4.6 `SonioxServerMessage` (verbatim wire shape)

The single envelope that covers normal token responses, the `finished`
response, and error responses (per `soniox-wire-schema.md` CRITICAL
FINDINGS #1 and #2):

```swift
struct SonioxServerMessage: Codable, Sendable {
    let tokens: [SonioxToken]
    let final_audio_proc_ms: Int?     // present in normal + finished
    let total_audio_proc_ms: Int?     // present in normal + finished
    let finished: Bool?                // true only in terminal response
    let error_code: Int?               // 4xx/5xx in error responses
    let error_message: String?
}

struct SonioxToken: Codable, Sendable {
    let text: String
    let start_ms: Int?
    let end_ms: Int?
    let confidence: Double
    let is_final: Bool
    let language: String?              // ISO 639-1, when LID enabled
    let speaker: String?               // when diarization enabled (unused v1)
    let translation_status: String?    // unused v1
    let source_language: String?       // unused v1
}
```

Marker tokens detected by `text == "<end>"` or `text == "<fin>"`.

### 4.7 `SonioxTokenAggregator`

A small state machine. State: `pendingFinals: [SonioxToken]`,
`partialBuffer: [SonioxToken]`. Per server message:

1. Replace `partialBuffer` with the message's non-final tokens.
   Emit `.partial(SegmentDraft(text: partialBuffer.text, language:
   partialBuffer.modeLanguage))`.
2. For each final token in the message in order:
   - If `text == "<end>"` or `text == "<fin>"`: aggregate
     `pendingFinals` into one `TranscriptSegment` (text =
     concatenated, startTime = first.start_ms/1000.0, endTime =
     last.end_ms/1000.0, language = mode of `language` fields, model
     = `"soniox"`, confidence = mean), emit
     `.final(StreamingFinal(segment: segment, source: self.source))`,
     clear `pendingFinals`.
   - Else: append to `pendingFinals`.
3. If `message.finished == true`: flush `pendingFinals` if non-empty,
   emit one final `.metrics`, signal end-of-stream.

Pure-ish: state lives in the aggregator; `[StreamingTranscriptionEvent]`
is returned from a single `apply(_ message:) -> [StreamingTranscriptionEvent]`
method that the session's receive loop drains into the events stream.
This makes it straightforward to unit-test with scripted message
sequences.

### 4.8 `WebSocketTransport` (test seam)

```swift
public protocol WebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func cancel(with closeCode: WebSocketCloseCode, reason: Data?)
}

public enum WebSocketMessage: Sendable {
    case data(Data)
    case string(String)
}

public enum WebSocketCloseCode: Sendable {
    case normalClosure
    case goingAway
    // ...
}
```

Production conformer: `URLSessionWebSocketTransport` (wraps
`URLSession.webSocketTask(with:)`).

Test conformer: `FakeWebSocketTransport` — script of (sent message,
expected) pairs and a programmable response queue. Replaces
`URLProtocol`-style stubbing because `URLSessionWebSocketTask` is NOT
intercepted by `URLProtocol` (per the codebase scan §4.1.K's note).

### 4.9 `SonioxKeepaliveTimer`

```swift
actor SonioxKeepaliveTimer {
    init(transport: any WebSocketTransport, clock: any Clock,
         silenceThreshold: Duration = .seconds(5),
         interval: Duration = .seconds(10))

    func recordAudioSent()  // call from session.ingest()
    func start()            // launch background Task
    func stop()
}
```

Background Task wakes every `interval`; if `clock.now - lastAudio >=
silenceThreshold`, sends `{"type":"keepalive"}` text frame. The 10 s
default cadence gives a 2× safety margin over Soniox's 20 s no-audio
ceiling. Per `soniox-wire-schema.md` CRITICAL FINDING #7, the Node
SDK uses 5 s; 10 s is the project's chosen value (still safe).

### 4.10 `SonioxLanguageHintMapper`

```swift
struct SonioxLanguageHintMapper {
    /// Strip BCP-47 region suffixes; deduplicate; preserve order.
    /// "el-GR,en-US,en-GB" → ["el", "en"]
    /// "" or nil → ["el", "en"] (Greek + English default per FR-SX-9)
    static func map(_ bcp47: [String]) -> [String]
}
```

Pure value, easily tested. Default `["el", "en"]` is applied here when
the input is empty (encapsulates FR-SX-9's Greek + English priority).

### 4.11 `SonioxErrorMapper`

```swift
enum SonioxErrorAction: Sendable, Equatable {
    case stopWithApiKeyInvalid
    case warnRecordingContinues(MacrecError)
    case reconnect
}

struct SonioxErrorMapper {
    static func action(forErrorCode code: Int, message: String?)
        -> SonioxErrorAction
}
```

| Code | Action |
|---|---|
| 400 | `.warnRecordingContinues(.transcriptionConfigError)` — config bug; non-fatal |
| 401 | `.stopWithApiKeyInvalid` — bad key; emit `.error`, finish events |
| 402 | `.warnRecordingContinues(.transcriptionQuotaExhausted)` — billing |
| 408 | `.reconnect` — idle timeout |
| 429 | `.warnRecordingContinues(.transcriptionRateLimited)` |
| 500 | `.reconnect` (after short backoff) |
| 503 | `.reconnect` (immediate; per `soniox-wire-schema.md` CRITICAL FINDING #10, this is the mid-session reconnect signal, not a bug) |
| other | `.warnRecordingContinues(.transcriptionUnknownError)` |

`MacrecError.transcriptionApiKeyInvalid` and `transcriptionQuotaExhausted`
and `transcriptionRateLimited` may need to be added to
`MacrecError.swift` if not present. The codebase scan does not show them
explicitly; assume new cases needed in `MacrecError.swift` (Phase B).

---

## 5. Data flow

### 5.1 Streaming happy path (`--transcribe soniox --transcribe-language el-GR,en-US --transcribe-source mixed`)

```
User starts recording
  │
  ▼
ConfigResolver resolves:
  - transcribe = "soniox"
  - SONIOX_API_KEY = "<key>" (from .env or shell env)
  - MACREC_SONIOX_ENDPOINT = nil → default wss://stt-rt.soniox.com/...
  - MACREC_TRANSCRIBE_MODEL = nil → default "stt-rt-v4"
  - MACREC_TRANSCRIBE_LANGUAGE = "el-GR,en-US" → BCP-47 list
  │
  ▼
RecordingSession.start()
  │
  ▼
TranscriptionManager.start(provider: SonioxStreamingTranscriptionProvider)
  │
  ▼
StreamingTranscriptionPipeline.openSession(source: .mixed)
  │  (provider.openStreamingSession returns SonioxStreamingSession)
  │
  ▼
SonioxStreamingSession.init:
  1. transport.connect(to: endpoint)
  2. encode SonioxConfigMessage with:
     - api_key, model: "stt-rt-v4"
     - audio_format: "pcm_s16le", sample_rate: 16000, num_channels: 1
     - language_hints: SonioxLanguageHintMapper.map(["el-GR", "en-US"])
                        = ["el", "en"]
     - language_hints_strict: false
     - enable_language_identification: true
     - enable_endpoint_detection: true, max_endpoint_delay_ms: 2000
     - client_reference_id: "macrec-<recordingId>-mixed"
  3. transport.send(.string(configJSON))
  4. spawn receive-loop Task (drains messages → aggregator → events)
  5. spawn keepalive Task (idle on first audio)
  │
  ▼
Capture pipeline → ingest(samples: [Float]) every ~64 ms
  │  AudioDownsampler (already in pipeline) → Float32 16 kHz mono
  │  SonioxStreamingSession converts to Int16 LE Data
  │  transport.send(.data(pcm16Data))
  │  keepalive timer.recordAudioSent()
  │
  ▼
Server emits SonioxServerMessage frames:
  ── tokens=[{text:"Καλημέρα", lang:"el", is_final:false}, ...]
     SonioxTokenAggregator.apply(...) → [.partial(...)]
  ── tokens=[{text:"Καλημέρα", is_final:true}, ..., {text:"<end>"}]
     SonioxTokenAggregator.apply(...) → [.final(SegmentDraft(...))]
  │
  ▼
events.continuation.yield(.partial(...))
events.continuation.yield(.final(...))
  │
  ▼
StreamingTranscriptionPipeline.bridge → TranscriptionManager.events
  │
  ▼
TranscriptSidecarWriter (.streaming policy) writes only .segmentFinalized
TranscriptionPanel (UI) renders both partial + final
```

### 5.2 Pause / Resume (FR-SX-13)

```
User Pause
  │
  ▼
SonioxStreamingSession.pause():
  1. transport.send(.string({"type":"finalize"}))
  2. await receive of <fin> token batch (timeout 2 s)
  3. emit .final from pending tokens
  4. stop sending audio
  5. keepalive timer is still running (idles through pause)
```

```
User Resume
  │
  ▼
SonioxStreamingSession.resume():
  1. simply resume audio frame ingest from capture pipeline
  2. (no special control message)
```

### 5.3 Split (`split(nextOutput:)`, FR-SX-13)

Soniox does NOT support session resumption. The recommended strategy
(per `soniox-wire-schema.md` §6) is to close the current WebSocket and
open a new one for the next segment:

```
RecordingSession.split(nextOutput:)
  │
  ▼
TranscriptionManager.rotateSidecar(toAudioURL:):
  1. SonioxStreamingSession.finish() — empty-frame close, await
     `finished`, transport.cancel(.normalClosure, nil)
  2. SidecarPathBuilder.sidecarURL(for: nextOutput) → new path
  3. provider.openStreamingSession(source:options:) → new
     SonioxStreamingSession with fresh client_reference_id
     (`macrec-<recordingId>-mixed-part02`)
  4. resume audio ingest into new session
```

### 5.4 Stop drain (FR-SX-14, AC-SX-12)

```
User Stop / SIGINT / SIGTERM
  │
  ▼
TranscriptionManager.stop():
  1. flush each SourceBuffer (no-op for streaming providers; the
     provider's session sees no more audio)
  2. SonioxStreamingSession.finish():
     a. transport.send(.string("")) (empty-frame close)
     b. await `finished` (up to 5 s wall-clock)
     c. emit any final segments from pending buffer
     d. transport.cancel(.normalClosure, nil)
     e. emit .metrics with chunksSent / billableSeconds / lastRTT /
        firstPartialP95 / endpointP95 / errorCount
     f. events.continuation.finish()
  3. close sidecar writers
```

The 5 s drain budget is a wall-clock deadline enforced by
`Task.withTimeout` (or equivalent). After 5 s, any still-pending Tasks
are cancelled.

### 5.5 Error path — invalid API key

```
Server sends: {"tokens":[], "error_code":401, "error_message":"Invalid API key."}
  │
  ▼
SonioxErrorMapper.action(401, "Invalid API key.") → .stopWithApiKeyInvalid
  │
  ▼
SonioxStreamingSession:
  1. emit .error(.transcriptionApiKeyInvalid(provider: "soniox"))
  2. transport closes (server-initiated)
  3. events.continuation.finish()
```

Recording continues per NFR-SX-1 (the audio recorder is not even on
the same Task tree). The sidecar may be empty.

---

## 6. Configuration

| Key | Type | Default | Field on `RecordingOptions` | Notes |
|---|---|---|---|---|
| `MACREC_TRANSCRIBE` | enum | `none` | `transcriptionProviderId` | Must accept `soniox` |
| `SONIOX_API_KEY` | string | — (REQUIRED when `transcribe = soniox`) | `transcriptionApiKey` (existing field, reused) | No fallback, no CLI flag |
| `MACREC_TRANSCRIBE_MODEL` | string | `stt-rt-v4` (when provider = soniox) | `transcriptionModel` (existing field, reused) | Unknown values pass through with `info` log |
| `MACREC_SONIOX_ENDPOINT` | URL | `wss://stt-rt.soniox.com/transcribe-websocket` | `sonioxEndpoint` (NEW) | Regional variants documented |
| `MACREC_TRANSCRIBE_LANGUAGE` | comma list | `el,en` (when provider = soniox; default applied in `SonioxLanguageHintMapper`) | `transcriptionLanguageHints` (existing `[String]` field, reused — added in plan-005) | BCP-47 in, ISO 639-1 stripped before send |
| `MACREC_SONIOX_KEY_EXPIRES_AT` | ISO-8601 date | nil | `sonioxKeyExpiresAt` (NEW) | Provider-scoped; takes precedence over the shared `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` (per OQ-SX-12 default) |
| `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` | ISO-8601 date | nil | `transcriptionKeyExpiresAt` (existing) | Shared fallback |

Resolution rules:

- `SONIOX_API_KEY` resolved through the four-tier chain: shell env →
  `~/.tool-agents/macrec/.env` → `./.env` → CLI flag (none for keys).
  Missing → `MacrecError.transcriptionApiKeyMissing(provider: "soniox",
  envVar: "SONIOX_API_KEY", sources: [...])`, exit 78.
- `MACREC_SONIOX_ENDPOINT` parsed as URL; if invalid → exit 64.
- `MACREC_SONIOX_KEY_EXPIRES_AT` parsed as ISO-8601; if invalid → exit
  64. If past → log `.warning`, recording continues (AC-SX-16).
- All other keys flow through the existing resolver code paths.

---

## 7. Errors & lifecycle

### 7.1 New `MacrecError` cases (verify presence in plan-005 first)

| Case | Exit code | Trigger |
|---|---|---|
| `transcriptionApiKeyMissing(provider: String, envVar: String, sources: [String])` | 78 | Required at start; from FR-SX-3 / FR-SX-4 |
| `transcriptionApiKeyInvalid(provider: String)` | non-fatal (logged) | Soniox 401 (NEW; verify against plan-005) |
| `transcriptionConfigError(provider: String, detail: String)` | non-fatal | Soniox 400 (NEW or reused) |
| `transcriptionQuotaExhausted(provider: String)` | non-fatal | Soniox 402 (NEW or reused) |
| `transcriptionRateLimited(provider: String)` | non-fatal | Soniox 429 (NEW or reused) |
| `transcriptionUnknownError(provider: String, code: Int, detail: String)` | non-fatal | Soniox other (NEW or reused) |

The first case (`transcriptionApiKeyMissing`) already exists for
Gemini per plan-004; verify it's parameterized by provider, not
hardcoded to Gemini.

### 7.2 Lifecycle states

`SonioxStreamingSession` does NOT introduce new `SessionState`
values. The existing `RecordingSession.SessionState` is sufficient.

### 7.3 Detach mode (`--detach --transcribe soniox`)

Plan-005 already lifted detach + streaming providers. No additional
work for plan-006 — Soniox inherits the lift. Verified by
`e2e-transcription-soniox-detach.sh`.

---

## 8. Testing strategy

### 8.1 Unit — pure functions

| Test | File | Mechanism |
|---|---|---|
| BCP-47 → ISO 639-1 stripping | `SonioxLanguageHintMapperTests.swift` | Table-driven assertions |
| Non-final → final aggregation | `SonioxTokenAggregatorTests.swift` | Replay scripted server messages |
| `<end>` segmentation | `SonioxTokenAggregatorTests.swift` | Inject `<end>` token; assert one `.final` event |
| `<fin>` segmentation | `SonioxTokenAggregatorTests.swift` | Inject `<fin>` token; assert one `.final` event |
| Error code mapping | `SonioxErrorMapperTests.swift` | Table-driven |
| Wire-message Codable round-trip | `SonioxWireMessagesTests.swift` | Verbatim fixtures from `docs/research/soniox-wire-schema.md` |

### 8.2 Unit — actors / sessions

| Test | File | Mechanism |
|---|---|---|
| Session sends correct config message | `SonioxStreamingTranscriptionProviderTests.swift` | `FakeWebSocketTransport` records sent messages; assert first message decodes to expected `SonioxConfigMessage` |
| Audio frame ingest sends binary frames | same | record + assert N binary frames per ingest call |
| Keepalive timer fires after 10 s of silence | same | inject `MockClock`; advance time; assert keepalive sent |
| Pause sends finalize and waits for `<fin>` | same | scripted server response |
| Stop sends empty-frame close and awaits `finished` | same | scripted server response |
| Stop drains within 5 s | same | `MockClock` + scripted slow server |
| 401 emits `.error(.transcriptionApiKeyInvalid)` and finishes | same | scripted error response |

### 8.3 Unit — provider

| Test | File | Mechanism |
|---|---|---|
| Provider conformance unchanged | `SonioxStreamingTranscriptionProviderTests.swift` | Compile-time assertion via type erasure into `any TranscriptionProvider` |
| `transcribe()` bridges over `openStreamingSession()` | same | inject scripted session; assert single string returned |
| Factory wires provider when API key present | `TranscriptionProviderFactoryTests.swift` | unit test |
| Factory throws when API key missing | same | unit test |
| Factory honours endpoint override | same | unit test |

### 8.4 Unit — config resolver

| Test | File | Mechanism |
|---|---|---|
| `MACREC_TRANSCRIBE=soniox` accepted | `ConfigResolverTranscriptionTests.swift` | already-existing test pattern |
| `MACREC_TRANSCRIBE=soniox-streaming` exits 64 | same | mirrors AC-SX-17 |
| `SONIOX_API_KEY` resolved through 4-tier chain | same | mirrors `GOOGLE_API_KEY` test |
| Missing key + `--transcribe soniox` throws at start | same | exit 78 |
| `MACREC_SONIOX_ENDPOINT` overrides default | same | URL parsed and stored |
| `MACREC_SONIOX_KEY_EXPIRES_AT` precedence over shared | same | mirrors AC-SX-16 |
| Invalid endpoint URL exits 64 | same | parse-time validation |

### 8.5 Unit — recording integrity (NFR-SX-1, AC-SX-6)

| Test | File | Mechanism |
|---|---|---|
| Audio file byte-identical with always-failing Soniox | `RecordingIntegrityIsolationTests.swift` (extend) | Inject `SonioxAlwaysFailingFake` (a `WebSocketTransport` that throws on every send), record 10 s of synthetic audio, compare audio file bytes against control with `--transcribe none` |

### 8.6 E2E — shell scripts (real `SONIOX_API_KEY` required; skip-clean otherwise)

| Script | Asserts | Maps to AC |
|---|---|---|
| `e2e-transcription-soniox.sh` | sidecar exists with ≥ 2 segments, `model:"soniox"` | AC-SX-1 |
| `e2e-transcription-soniox-greek.sh` | sidecar text matches ≥ 5 of Greek keyword set, first matched segment `language` starts with `el` | AC-SX-2 |
| `e2e-transcription-soniox-english.sh` | sidecar text matches ≥ 5 of English keyword set, first matched segment `language` starts with `en` | AC-SX-3 |
| `e2e-transcription-soniox-bilingual.sh` | sidecar contains ≥ 1 `el`-tagged + ≥ 1 `en`-tagged segment | AC-SX-4 |
| `e2e-transcription-soniox-key-missing.sh` | exit 78, no audio file, no sidecar, stderr names `SONIOX_API_KEY` | AC-SX-5 |
| `e2e-transcription-soniox-detach.sh` | detached session produces sidecar with ≥ 1 segment | AC-SX-10 |
| `e2e-transcription-soniox-split.sh` | each `partNN` audio file has matching `partNN.transcript.jsonl` sibling, no segment crosses boundary | AC-SX-11 |

The Greek + English clips required by AC-SX-2 / AC-SX-3 / AC-SX-4 must
be recorded in advance and bundled at `test_scripts/fixtures/soniox/`
(WAV files, ≤ 30 s each). The user records these once during Phase I.

### 8.7 Snapshot / UI tests

| Test | Asserts | Maps to AC |
|---|---|---|
| `TranscriptionPickerSnapshotTests` | picker contains 5 entries in expected order: `None`, `Apple`, `Gemini`, `WhisperKit`, `Soniox` | AC-SX-8 |
| `TranscriptionPickerSelectionTests` | selecting `Soniox` and starting wires `transcriptionProviderId == "soniox"` into `RecordingOptions` | AC-SX-8 |
| `PrivacyDisclosureSheetTests` | first-Soniox-start dialog body contains "Soniox"; "Don't show again" suppresses on subsequent starts | AC-SX-9 |
| `StartCommandHelpTests` | `--help` output lists `soniox` in `--transcribe` allowed set | AC-SX-14 |

### 8.8 Acceptance-criteria coverage matrix

| AC | Verified by |
|---|---|
| AC-SX-1 | `e2e-transcription-soniox.sh` |
| AC-SX-2 | `e2e-transcription-soniox-greek.sh` |
| AC-SX-3 | `e2e-transcription-soniox-english.sh` |
| AC-SX-4 | `e2e-transcription-soniox-bilingual.sh` |
| AC-SX-5 | `e2e-transcription-soniox-key-missing.sh` |
| AC-SX-6 | `RecordingIntegrityIsolationTests` (Soniox failing-fake variant) |
| AC-SX-7 | `swift build --product macrec && swift build --product macrec-ui` clean |
| AC-SX-8 | `TranscriptionPickerSnapshotTests` + `TranscriptionPickerSelectionTests` |
| AC-SX-9 | `PrivacyDisclosureSheetTests` (UI test) |
| AC-SX-10 | `e2e-transcription-soniox-detach.sh` |
| AC-SX-11 | `e2e-transcription-soniox-split.sh` |
| AC-SX-12 | `SonioxStreamingTranscriptionProviderTests` — stop-drain test |
| AC-SX-13 | `SonioxStreamingTranscriptionProviderTests` — metrics emission test |
| AC-SX-14 | `StartCommandHelpTests` + manual review of `docs/tools/macrec.md`, `docs/tools/macrec-ui.md`, `docs/design/configuration-guide.md` |
| AC-SX-15 | `git diff Package.swift` is empty (no new SPM dep) |
| AC-SX-16 | `ConfigResolverTranscriptionTests` — past-expiry test |
| AC-SX-17 | `ConfigResolverTranscriptionTests` — `--transcribe soniox-streaming` exits 64 |
| AC-SX-18 | `SonioxStreamingTranscriptionProviderTests` — latency observability test asserts P95 log line emitted |

---

## 9. Risks

### 9.1 No real Soniox API key during early development

**Mitigation**: Phase B–D of plan-006 are fully testable with
`FakeWebSocketTransport`. Phase I (e2e) is the first phase that
requires a real key. The user can sign up at console.soniox.com
in parallel with Phase B–D work; Phase I is the earliest gate that
needs the key.

If Phase I e2e cannot be funded (no trial credit and user does not
want to fund the validation), plan-006 ships with unit-test green and
e2e marked as "MANUAL — requires real key", with the AC-SX-1..AC-SX-4
verification deferred until the user provides a key. The provider is
still production-quality; only the smoke validation is deferred.

### 9.2 Wire-schema unverified for `<end>`/`<fin>` exact emission and empty-frame close handshake

The `docs/research/soniox-wire-schema.md` document explicitly tags
several behaviours as "**Inferred — confirm with probe script**":

- Empty-frame close handshake — text vs binary (plan defaults to
  `.string("")` per Pipecat reference).
- `<end>` and `<fin>` token emission shape (plan defaults to
  `text == "<end>"` detection per Pipecat reference).
- Connection close code on error — plan defaults to "always parse JSON
  error response first; treat close code as informational".
- Tokenization granularity for punctuation (Greek `;` vs `?`).

**Mitigation**: an OPTIONAL `test_scripts/probe-soniox-ws.swift`
standalone probe is listed in §3.1. It is a Phase C deliverable (after
the Codable types exist) that captures the wire trace once a real key
is available. If probe results contradict the plan's defaults, the
contradicting code is patched and the wire-schema doc is updated to
remove the "Inferred" tags. The probe is OPTIONAL because Pipecat's
Python implementation is the closest thing to a reference and matches
the plan's defaults; the probe is a belt-and-suspenders verification.

PEND-SX-1 in `Issues - Pending Items.md` tracks this.

### 9.3 Soniox protocol may change

Soniox is on `stt-rt-v4` (released 2026-02-05). The vendor may release
a v5 with a different config schema. **Mitigation**: the wire-schema
deep-dive doc is dated; revisit annually. The provider pins
`stt-rt-v4` so user is not auto-routed to a new model. Field-level
breaking changes to the response envelope would surface as Codable
decoding errors → `MacrecError.transcriptionUnknownError` → recording
continues (NFR-SX-1).

### 9.4 Greek-vs-English language ID may flap on short utterances

Per `soniox-wire-schema.md` §8 "Language Identification in Real-time",
a token initially tagged as `"en"` may be re-tagged as `"el"` in a
later message. **Mitigation**: the `SonioxTokenAggregator` only emits
`.final` events on `<end>` / `<fin>` markers, by which point the
server has settled on a final language for the token. Partial events
may show flapping; final segments are stable.

### 9.5 5-hour session ceiling

Soniox caps a single WebSocket session at 300 minutes. **Mitigation**:
`split(nextOutput:)` (FR-SX-13) opens a fresh session per `partNN`
file. A user recording a 7-hour session who never splits would hit
this. Automatic mid-recording reconnect on the 5-hour boundary is
**NOT** in v1 scope; documented as a v2 candidate. Mitigation in v1:
log a `.warning` at 4 h 50 min recommending the user pause/resume
(which now invokes finalize but does NOT close the WS) or split the
recording; at 5 h, the server closes the session and the next ingest
fails non-fatally (NFR-SX-1).

> **Open follow-up**: should v1 handle the 5-hour boundary by automatic
> reconnect? Defaults to NO; if the user records >5h sessions
> regularly, this becomes a Phase D enhancement.

### 9.6 No new SPM dependency (AC-SX-15)

Plan deliberately uses `URLSessionWebSocketTask` only. No new SPM
dependency is added. `Package.swift` diff for plan-006 must be empty.
If during Phase D a third-party WebSocket client is found unavoidable
(unlikely; Foundation suffices for Gemini Live precedent), Designer
review must call this out and re-evaluate against NFR-SX-7 before any
SPM addition.

### 9.7 TCC has no impact (Soniox is network only)

Soniox does NOT require TCC `NSSpeechRecognitionUsageDescription` (that
is Apple Speech only). Microphone + Screen Recording grants are still
required (existing). No new entitlements needed.

---

## 10. Deferred to v2

- **Speaker diarization** — Soniox supports it (`enable_speaker_diarization`);
  out of scope per OQ-SX-3 and refined request.
- **Translation** — Soniox supports `translation: {type, target_language}`;
  out of scope per refined request.
- **Custom vocabulary / context biasing** — Soniox supports `context.terms`,
  `context.text`, `context.general`; out of scope per refined request.
- **Automatic mid-recording reconnect on the 5-hour session boundary**
  (Risk 9.5).
- **Per-recording data-retention opt-out** — Soniox does not currently
  expose this in the WebSocket config; revisit if vendor adds it.
- **Async REST batch path via Soniox `stt-async-v4`** — only streaming
  in v1.
- **Soniox GitHub-published Swift SDK adoption** — when/if vendor ships
  one (currently no Swift SDK exists). Re-evaluate per OQ-SX-11.
- **`com.apple.security.network.client` entitlement** — needed when
  `macrec` is later sandboxed; tracked in plan-003 / plan-005 deferred
  list already.

---

## 11. Phases — execution plan

Plan-006 has **9 phases** (Phase 0 + Phases A–H + Phase I). Phase
parallelism analysis:

```
Phase 0 (docs + spec alignment) ───┐
Phase A (no-op: protocol unchanged)  │
Phase B (config plumbing) ──────────┼─→ Phase D (provider + session) ──┐
Phase C (wire codecs + aggregator + ─┘                                  │
         lang mapper + error mapper)                                    ├─→ Phase I (e2e + docs)
Phase H (UI picker + disclosure +  ───────────────────────────────→─────┘
        StartCommand help)
```

- **Phase 0** must complete first (sets up the plan/spec docs and
  registers FRs/NFRs/ACs).
- **Phases A and C are parallel-safe with each other.** A is a no-op
  verification (protocol unchanged); C is pure-value work (Codable
  types + pure functions) testable without WebSocket transport.
- **Phase B is parallel-safe with C.** B touches `ConfigResolver`,
  `RecordingOptions`, factory; C touches new files only.
- **Phase D depends on B + C.** D wires the provider + session, which
  needs the codecs (C) and the resolved options (B).
- **Phase H is parallel-safe with B / C / D.** H touches UI files
  only; the only dependency is the new picker tag string `"soniox"`,
  which is added by B's enum case.
- **Phase I depends on B + C + D + H.** End-to-end + docs cannot run
  until the implementation is done.

Suggested sequencing for a single-implementer pass:

```
Phase 0 → Phase B → Phase C → Phase D → Phase H → Phase I
```

Suggested sequencing for two parallel implementers:

```
Implementer 1: Phase 0 → B → D → I (own provider + plumbing + e2e)
Implementer 2:           → C → H → I (own codecs + UI; rendezvous at I)
```

### Phase 0 — Spec, doc, and project-config alignment

**Goal**: register the new requirements and prepare the doc surfaces
before code lands.

#### Task 0.1 — Add §1.6 to `docs/design/project-functions.md`

Append §1.6 "Added 2026-04-29 — Soniox streaming provider (plan-006)":
FR-SX-1..FR-SX-18, NFR-SX-1..NFR-SX-7, AC-SX-1..AC-SX-18. Section
follows the §1.5 plan-005 template.

**Verify**: file lints + `grep -c "FR-SX-" docs/design/project-functions.md`
returns 18.

#### Task 0.2 — Add §SX section to `docs/design/project-design.md`

Append "## §SX — Soniox Streaming Subsystem (plan-006)" after the
existing "## §AS" section. Cover: file manifest, data flow diagram,
component contracts (the §4 of this plan abridged), configuration
table, error path, lifecycle.

**Verify**: file lints + `grep -c "## §SX" docs/design/project-design.md`
returns 1.

#### Task 0.3 — Refresh `docs/design/configuration-guide.md`

New section: "Soniox provider". Cover all keys from §6 of this plan:
purpose, how to obtain (`console.soniox.com/signup`), recommended
storage (`~/.tool-agents/macrec/.env` mode `0600`), default values,
expiry-companion convention. Document the OQ-SX-12 split: provider-
scoped > shared resolution order. Document Soniox's regional endpoints
(US/EU/JP). Document the data-retention disclaimer (org-level, not
per-request).

**Verify**: manual review.

#### Task 0.4 — Refresh `docs/tools/macrec.md` and `docs/tools/macrec-ui.md`

Add `soniox` to the `--transcribe` allowed-set table; document the new
env vars + the `--soniox-endpoint` flag.

**Verify**: `grep -c "soniox" docs/tools/macrec.md` ≥ 5; same for
`macrec-ui.md`.

#### Task 0.5 — Add PEND-SX-1 to `Issues - Pending Items.md`

> "Wire-schema unverified for `<end>`/`<fin>` exact emission and
> empty-frame close handshake — run `test_scripts/probe-soniox-ws.swift`
> once a real `SONIOX_API_KEY` is available, then update
> `docs/research/soniox-wire-schema.md` to remove the **Inferred —
> confirm with probe script** tags."

**Verify**: file present.

#### Task 0.6 — Phase 0 verification

```bash
swift build --product macrec
swift build --product macrec-ui
grep -c "FR-SX-" docs/design/project-functions.md   # expect ≥ 18
grep -c "AC-SX-" docs/design/project-functions.md   # expect ≥ 18
grep -c "NFR-SX-" docs/design/project-functions.md  # expect ≥ 7
```

### Phase A — Protocol verification (NO CODE CHANGES)

**Goal**: verify (not change) that the existing extended
`TranscriptionProvider` / `StreamingTranscriptionSession` protocol
suffices for Soniox.

#### Task A.1 — Confirm `StreamingTranscriptionEvent` cases

Read `Sources/MacrecCore/Transcription/StreamingTranscriptionSession.swift`
and confirm `events: AsyncStream<StreamingTranscriptionEvent>` carries
`.partial`, `.final`, `.metrics`, `.error` cases — these are the
ones the Soniox session needs. If any are missing, this Phase becomes
a non-trivial protocol extension (Designer review required).

**Verify**: code reading; document the exact protocol surface in a
brief Phase A confirmation note appended to the plan.

#### Task A.2 — Confirm `TranscriptSegment.language` field exists

Plan-005 added `language: String?` to `TranscriptSegment`. Confirm
present.

#### Task A.3 — Confirm `TranscriptionOptions.languageHints: [String]` exists

Plan-005 renamed `languageHint: String?` → `languageHints: [String]`.
Confirm present.

**Verify**: `swift build --product MacrecCore` succeeds with no
warnings beyond baseline.

### Phase B — Config plumbing

**Goal**: thread `SONIOX_API_KEY`, `MACREC_SONIOX_ENDPOINT`,
`MACREC_SONIOX_KEY_EXPIRES_AT` through the resolver; add `.soniox`
to the `TranscriptionProviderId` enum; update factory error messages.

Map to: FR-SX-1, FR-SX-3, FR-SX-4, FR-SX-5, FR-SX-7, FR-SX-18.

#### Task B.1 — Add `.soniox` case to `TranscriptionProviderId`

Edit `Sources/MacrecCore/Config/RecordingOptions.swift:74-79`:

```swift
public enum TranscriptionProviderId: String, Sendable, Codable, CaseIterable {
    case none
    case apple
    case gemini
    case geminiLive = "gemini-live"  // existing deprecated alias
    case soniox                       // NEW
    // (whisperkit handled as raw string per codebase scan §5)
}
```

#### Task B.2 — Add Soniox config keys

Edit `Sources/MacrecCore/Config/ConfigResolver.swift` `Keys` namespace
(lines 404-436):

```swift
public static let sonioxApiKey         = "SONIOX_API_KEY"
public static let sonioxEndpoint       = "MACREC_SONIOX_ENDPOINT"
public static let sonioxKeyExpiresAt   = "MACREC_SONIOX_KEY_EXPIRES_AT"
```

#### Task B.3 — Add API-key resolution branch

Edit `ConfigResolver.swift:345`:

```swift
case .soniox:
    apiKey = value(Keys.sonioxApiKey)
```

(Same pattern as `case .gemini, .geminiLive:`.)

#### Task B.4 — Add `transcriptionProviderId` mapping

Edit `ConfigResolver.swift:241-261`:

```swift
case .soniox: return "soniox"
```

#### Task B.5 — Resolve endpoint, model, expiry

Add resolver block (after API-key resolution):

```swift
let sonioxEndpoint: URL? = try {
    guard let raw = value(Keys.sonioxEndpoint) else { return nil }
    guard let url = URL(string: raw) else {
        throw MacrecError.invalidConfigValue(
            key: Keys.sonioxEndpoint, value: raw,
            reason: "must be a valid wss:// URL")
    }
    return url
}()

let sonioxKeyExpiresAt: Date? = {
    if let v = value(Keys.sonioxKeyExpiresAt) {
        return ISO8601DateFormatter().date(from: v)
    }
    // shared fallback (OQ-SX-12)
    return transcriptionKeyExpiresAt
}()
```

If invalid endpoint URL → exit 64. If invalid date → exit 64. If past
expiry → log `.warning` at start (AC-SX-16), recording continues.

#### Task B.6 — Add fields to `RecordingOptions`

Edit `RecordingOptions.swift`: add

```swift
public let sonioxEndpoint: URL?
public let sonioxKeyExpiresAt: Date?
```

Forward both in `withOutput(_:)` (line 306-331) — add to copy
constructor.

#### Task B.7 — Add Soniox case to `MacrecError` (if needed)

Edit `Sources/MacrecCore/Errors/MacrecError.swift`. Verify the
existing `transcriptionApiKeyMissing` case is parameterized by
provider name + env var name + sources list; if it's hardcoded to
Gemini, parameterize. Add new cases per §7.1 if not already present.

#### Task B.8 — Update factory error message

Edit `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift:91`
to include `'soniox'` in the allowed-values list of the `default:`
error path.

#### Task B.9 — Phase B unit tests

Add to `Tests/MacrecCoreTests/Config/ConfigResolverTranscriptionTests.swift`:

- `MACREC_TRANSCRIBE=soniox` accepted.
- `MACREC_TRANSCRIBE=soniox-streaming` exits 64 (AC-SX-17).
- `SONIOX_API_KEY` resolved via 4-tier chain.
- `MACREC_SONIOX_ENDPOINT` parsed and stored; invalid URL exits 64.
- `MACREC_SONIOX_KEY_EXPIRES_AT` precedence over shared (AC-SX-16).
- Past expiry logs `.warning` (AC-SX-16).

#### Task B.10 — Phase B verification

```bash
swift build --product macrec
swift build --product macrec-ui
swift test --filter ConfigResolverTranscriptionTests
```

### Phase C — Wire-schema codecs, aggregator, mappers, transport

**Goal**: implement the pure value types and pure-ish state machine
that handle Soniox's wire protocol. No WebSocket integration yet —
all work is offline-testable.

Map to: FR-SX-8 (audio adaptation surface), FR-SX-9 (language
strategy), FR-SX-10 (per-segment language tagging), AC-SX-7.

This phase is **parallel-safe** with Phase B.

#### Task C.1 — Create `SonioxWireMessages.swift`

Path: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxWireMessages.swift`.
Define `SonioxConfigMessage`, `SonioxControlMessage`, `SonioxServerMessage`,
`SonioxToken` per §4.4–4.6 of this plan.

Snake-case JSON keys; use `CodingKeys` to map to camelCase Swift
properties OR keep Swift property names snake-case (the latter is
simpler and matches the wire shape). Decision: **keep snake_case Swift
property names** to minimize Codable noise; the Soniox wire format is
the only place these types are used.

#### Task C.2 — Create `SonioxLanguageHintMapper.swift`

Path: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxLanguageHintMapper.swift`.
Pure function `static func map(_ bcp47: [String]) -> [String]`. Default
on empty: `["el", "en"]`. Strip BCP-47 region suffix at first `-` or
`_`. Deduplicate preserving order. Empty input or all-empty after
strip → default `["el", "en"]`.

#### Task C.3 — Create `SonioxTokenAggregator.swift`

Path: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift`.
State machine per §4.7. Public method
`mutating func apply(_ message: SonioxServerMessage) ->
[StreamingTranscriptionEvent]`. Returns events (zero or more) for the
session's events stream to yield.

Edge cases handled:
- Empty `tokens` array (e.g., `finished` response or pure metrics).
- Mixed final + non-final tokens in one message.
- `<end>` followed by additional tokens in same message (rare; flush
  before continuing).
- `<fin>` after manual finalize.
- `is_final: true` non-marker tokens with no surrounding marker (per
  Pipecat's reference, these accumulate until the next marker).

#### Task C.4 — Create `SonioxErrorMapper.swift`

Path: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxErrorMapper.swift`.
Pure function per §4.11.

#### Task C.5 — Create `WebSocketTransport.swift` protocol

Path: `Sources/MacrecCore/Transcription/Live/Soniox/WebSocketTransport.swift`.
Protocol per §4.8. Production conformer
`URLSessionWebSocketTransport` (in same file or a sibling file).
`@unchecked Sendable` is acceptable; `URLSessionWebSocketTask` is
inherently shared-mutable.

#### Task C.6 — Phase C unit tests

Create `Tests/MacrecCoreTests/Transcription/Live/Soniox/`:

- `SonioxWireMessagesTests.swift` — decode every fixture JSON from
  `docs/research/soniox-wire-schema.md` §3.1–3.5 and assert field
  values; encode `SonioxConfigMessage` and assert wire shape matches
  §2.1.
- `SonioxLanguageHintMapperTests.swift` — table tests:
  `[]` → `["el", "en"]`, `["el-GR"]` → `["el"]`,
  `["el-GR", "en-US", "en-GB"]` → `["el", "en"]`,
  `["fr"]` → `["fr"]`.
- `SonioxTokenAggregatorTests.swift` — replay scripted sequences;
  assert event ordering and segment text/timing/language.
- `SonioxErrorMapperTests.swift` — table tests for codes 400/401/402/408/429/500/503.

#### Task C.7 — OPTIONAL probe script

Path: `test_scripts/probe-soniox-ws.swift`. Standalone Swift script
(not part of SwiftPM target) that reads `SONIOX_API_KEY` from env,
opens a WS, sends config + 5 s of synthesized PCM (sine wave or
silence), captures every message to stdout (JSON-pretty-printed),
sends finalize, captures `<fin>` shape, sends empty `.string("")`,
captures `finished` shape, exits.

This is OPTIONAL — Phase C ships without it. PEND-SX-1 tracks the
follow-up for when a real key is available.

#### Task C.8 — Phase C verification

```bash
swift build --product MacrecCore
swift test --filter SonioxWireMessagesTests
swift test --filter SonioxLanguageHintMapperTests
swift test --filter SonioxTokenAggregatorTests
swift test --filter SonioxErrorMapperTests
```

### Phase D — Provider + session implementation

**Goal**: implement `SonioxStreamingTranscriptionProvider` and
`SonioxStreamingSession` and wire into the factory.

Map to: FR-SX-2, FR-SX-6, FR-SX-8, FR-SX-12, FR-SX-13, FR-SX-14,
FR-SX-15, NFR-SX-1, NFR-SX-2, NFR-SX-5, NFR-SX-6.

Depends on: Phase B (resolver + factory plumbing) + Phase C (codecs +
transport).

#### Task D.1 — `SonioxKeepaliveTimer.swift`

Path: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxKeepaliveTimer.swift`.
Per §4.9.

#### Task D.2 — `SonioxStreamingSession.swift`

Path: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingSession.swift`.
Per §4.3. Implements `StreamingTranscriptionSession` protocol.

Internals:
- `init(...) async throws` opens the WebSocket, sends the config
  message (encoded via `JSONEncoder` from `SonioxConfigMessage`),
  spawns the receive-loop Task and the keepalive Task.
- `ingest(_ samples: [Float])` converts Float32 → Int16 LE Data
  (use `withUnsafeBufferPointer` + clamping to `[-1.0, 1.0]` then
  `* Float(Int16.max)`), sends as `.data(...)` binary frame, calls
  `keepaliveTimer.recordAudioSent()`.
- `pause()` sends finalize, waits for `<fin>` (timeout 2 s), holds.
- `resume()` no-op (just resumes audio frame ingestion from upstream).
- `finish()` sends `.string("")`, waits for `finished` (timeout 5 s),
  cancels transport, finishes events stream.
- Receive loop: `while true { let msg = try await transport.receive();
  decode; aggregator.apply(msg).forEach { eventsContinuation.yield($0) };
  if msg.finished == true { break }; if msg.error_code != nil { handle; break } }`.
- Wraps the receive loop's per-receive try/catch so a transport error
  cleanly emits `.error` and finishes events (NFR-SX-1).

Concurrency: prefer `actor` if all the state can be expressed as
isolated; otherwise `final class @unchecked Sendable` with `NSLock`
(parity with `AppleSpeechSession`). Designer review at start of
Phase D picks one.

#### Task D.3 — `SonioxStreamingTranscriptionProvider.swift`

Path: `Sources/MacrecCore/Transcription/Providers/SonioxStreamingTranscriptionProvider.swift`.
Per §4.2. Builds the `SonioxConfigMessage` from `TranscriptionOptions`
+ `apiKey` + `modelId` + `clientReferenceId`. Constructs
`SonioxStreamingSession` via `init(...)`.

`transcribe(...)` bridges streaming → batch: open session, ingest
samples in 64 ms chunks, send empty-frame close, await finished,
collect `.final` events, concatenate text, return.

#### Task D.4 — Wire into factory

Edit `TranscriptionProviderFactory.swift:46-93`:

```swift
case "soniox":
    guard let apiKey = input.apiKey else {
        throw MacrecError.transcriptionApiKeyMissing(
            provider: "soniox",
            envVar: "SONIOX_API_KEY",
            sources: ConfigResolver.searchedSources)
    }
    let modelId = input.modelOverride ?? "stt-rt-v4"
    let endpoint = input.sonioxEndpoint
        ?? URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    return SonioxStreamingTranscriptionProvider(
        apiKey: apiKey,
        modelId: modelId,
        endpoint: endpoint,
        logger: input.logger)
```

Add `sonioxEndpoint: URL?` to `TranscriptionProviderFactoryInput`.
Update factory call site in `TranscriptionManager` (or wherever it's
constructed) to thread `RecordingOptions.sonioxEndpoint` through.

#### Task D.5 — Metrics emission

`SonioxStreamingSession` tracks per FR-SX-15:

- `chunksSent` — binary frames sent.
- `messagesSent` — chunks + control messages.
- `billableSeconds` — `Σ (end_ms - start_ms) / 1000` over final tokens.
- `errorCount`.
- `lastRTTMs` — sliding observation.
- `firstPartialLatencyMsP95`, `endpointLatencyMsP95`.

Emit one `.metrics(StreamingProviderMetrics(...))` event on `finish()`.

#### Task D.6 — Phase D unit tests

`Tests/MacrecCoreTests/Transcription/Providers/SonioxStreamingTranscriptionProviderTests.swift`
+ `FakeWebSocketTransport.swift`.

Coverage per §8.2 / §8.3 of this plan.

#### Task D.7 — Phase D verification

```bash
swift build --product macrec
swift build --product macrec-ui
swift test --filter SonioxStreamingTranscriptionProviderTests
swift test --filter TranscriptionProviderFactoryTests
```

### Phase H — UI integration

**Goal**: add Soniox to the picker, the privacy disclosure, the help
text. Parallel-safe with B / C / D.

Map to: FR-SX-16, FR-SX-17, FR-SX-18, AC-SX-8, AC-SX-9, AC-SX-14.

#### Task H.1 — Update `TranscriptionPicker.swift`

Edit `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift:75`:
add `Text("Soniox (cloud, streaming)").tag("soniox")` after the
`gemini` row.

Update `missingKeyTooltip` (line 67-68) to be a function of
`providerRaw` returning the right env var name (`SONIOX_API_KEY` for
soniox, `GOOGLE_API_KEY` for gemini, etc.). Suggested: extract a
`requiredKeyEnvVar(for: String) -> String?` helper.

#### Task H.2 — Update `PrivacyDisclosureSheet.swift`

Edit `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift`:
add a `soniox`-keyed disclosure body:

> "Audio is being sent to Soniox (soniox.com) for transcription. Set
> the org-level data retention preferences in the Soniox console at
> console.soniox.com."

Add `@AppStorage("com.macrec.ui.sonioxPrivacyAccepted")` flag for
"Don't show again" (parity with the Gemini disclosure flag).

#### Task H.3 — Update `StartCommand.swift` help text + flag

Edit `Sources/macrec/Commands/StartCommand.swift`:

- Line 95: replace `"none | gemini-live"` with
  `"none | apple | gemini | whisperkit | soniox"`.
- Add new `@Option(name: .customLong("soniox-endpoint"),
  help: "Override Soniox WebSocket endpoint (default: wss://stt-rt.soniox.com/transcribe-websocket)")
  var sonioxEndpoint: String?`.
- In `buildCLIOverrides()` (line 216), forward as
  `Keys.sonioxEndpoint`.
- **Do NOT add a `--soniox-api-key` flag** (NFR-SX-3).

#### Task H.4 — UI snapshot tests

Add or extend tests:

- `TranscriptionPickerSnapshotTests` — picker contains 5 entries in
  expected order: `None`, `Apple`, `Gemini`, `WhisperKit`, `Soniox`
  (per OQ-SX-8 default; revise if user picks different order).
- `TranscriptionPickerSelectionTests` — selecting `Soniox` and
  starting wires `transcriptionProviderId == "soniox"` into
  `RecordingOptions`.
- `PrivacyDisclosureSheetTests` — soniox-keyed body text and
  "Don't show again" suppression flag.
- `StartCommandHelpTests` — `--help` snapshot includes `soniox`.

#### Task H.5 — Phase H verification

```bash
swift build --product macrec
swift build --product macrec-ui
swift test --filter TranscriptionPicker
swift test --filter PrivacyDisclosure
swift test --filter StartCommandHelp
```

### Phase I — End-to-end + Greek/English tests + final docs sweep

**Goal**: real-key e2e validation; finalize all docs; close PEND-SX-1
if probe runs.

Map to: AC-SX-1, AC-SX-2, AC-SX-3, AC-SX-4, AC-SX-5, AC-SX-6,
AC-SX-10, AC-SX-11, AC-SX-12, AC-SX-13, AC-SX-14, AC-SX-15,
AC-SX-18.

Depends on: B + C + D + H.

#### Task I.1 — Record Greek + English fixture clips

Path: `test_scripts/fixtures/soniox/`.

- `greek-30s.wav` — user reads "Καλημέρα, σήμερα είναι μια όμορφη
  μέρα. Δοκιμάζω την υπηρεσία αναγνώρισης ομιλίας Soniox." (~30 s,
  PCM16 44.1 kHz mono OK; macrec resamples).
- `english-30s.wav` — user reads "Good morning, today is a beautiful
  day. I am testing the Soniox speech recognition service."
- `bilingual-60s.wav` — user reads alternating sentences from both
  scripts.

These can be generated by `say` (macOS TTS) for first-pass smoke; for
acceptance the user records human speech.

#### Task I.2 — Write e2e scripts

Per §8.6 — seven `.sh` scripts, all mirror existing
`e2e-transcription-*.sh` patterns. Each begins with:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SONIOX_API_KEY:-}" ]]; then
    echo "SONIOX_API_KEY not set — skipping (this is OK in CI)."
    exit 0
fi
```

Per §8.6 / AC-SX-1..AC-SX-5 / AC-SX-10..AC-SX-11 for assertion logic.

#### Task I.3 — Recording integrity test extension

Add `SonioxAlwaysFailingFake` injection variant to
`RecordingIntegrityIsolationTests` (extend file already created in
plan-005 if present, else create per codebase scan §4.1.K).

#### Task I.4 — Manual review of doc updates

- `docs/tools/macrec.md` — Soniox row in the `--transcribe` table;
  env-var documentation; help-text snippet.
- `docs/tools/macrec-ui.md` — picker entry; disclosure copy.
- `docs/design/configuration-guide.md` — Soniox section.
- `docs/design/project-functions.md` — §1.6 (FR/NFR/AC registered;
  done in Phase 0 — re-check).
- `docs/design/project-design.md` — §SX section (done in Phase 0 —
  re-check).
- `Issues - Pending Items.md` — PEND-SX-1 row (done in Phase 0 —
  re-check). If the optional probe was run and the wire-schema doc
  updated to remove the "Inferred" tags, mark PEND-SX-1 RESOLVED.

#### Task I.5 — Run the optional probe (if user supplies key)

If a real `SONIOX_API_KEY` is available and the user wants to close
PEND-SX-1: run `test_scripts/probe-soniox-ws.swift`, capture output,
update `docs/research/soniox-wire-schema.md` to remove "Inferred"
tags wherever the probe confirms behaviour, mark PEND-SX-1 resolved.

#### Task I.6 — Final verification

```bash
# Clean build
swift build --product macrec
swift build --product macrec-ui

# Full unit test suite
swift test

# Filtered unit tests
swift test --filter Soniox
swift test --filter ConfigResolverTranscription
swift test --filter TranscriptionProviderFactory
swift test --filter RecordingIntegrityIsolation

# E2E (requires SONIOX_API_KEY for non-skip)
bash test_scripts/e2e-transcription-soniox.sh
bash test_scripts/e2e-transcription-soniox-greek.sh
bash test_scripts/e2e-transcription-soniox-english.sh
bash test_scripts/e2e-transcription-soniox-bilingual.sh
bash test_scripts/e2e-transcription-soniox-key-missing.sh        # always runs (no key needed)
bash test_scripts/e2e-transcription-soniox-detach.sh
bash test_scripts/e2e-transcription-soniox-split.sh

# Help text
.build/debug/macrec start --help | grep -E "soniox"  # must appear

# Doc presence
grep -c "FR-SX-" docs/design/project-functions.md   # ≥ 18
grep -c "NFR-SX-" docs/design/project-functions.md  # ≥ 7
grep -c "AC-SX-" docs/design/project-functions.md   # ≥ 18
grep -c "Soniox" docs/tools/macrec.md               # ≥ 5
grep -c "Soniox" docs/tools/macrec-ui.md            # ≥ 3
grep -c "Soniox" docs/design/configuration-guide.md # ≥ 5

# Package.swift unchanged (NFR-SX-7 / AC-SX-15)
git diff --stat Package.swift   # must be empty
```

---

## 12. Self-Review

The plan was reviewed against:

### 12.1 Refined request requirements

All 18 FR-SX-*, all 7 NFR-SX-*, all 18 AC-SX-*, and all 10 A-SX-*
assumptions are addressed:

- **FR-SX-1** (provider id `soniox` accepted): Phase B Task B.1.
- **FR-SX-2** (`SonioxStreamingTranscriptionProvider` conformer): Phase D Task D.3.
- **FR-SX-3** (4-tier API key resolution): Phase B Task B.3.
- **FR-SX-4** (no fallback for API key): enforced in factory at Phase D Task D.4.
- **FR-SX-5** (expiry companion var, with OQ-SX-12 split): Phase B Tasks B.5+B.6.
- **FR-SX-6** (model override accepted): Phase D Task D.4.
- **FR-SX-7** (endpoint override): Phase B Tasks B.5+B.6, Phase D Task D.4, Phase H Task H.3.
- **FR-SX-8** (audio format adaptation): Phase D Task D.2 (Float32 → Int16 LE inside session).
- **FR-SX-9** (Greek + English language strategy): Phase C Task C.2 (`SonioxLanguageHintMapper` defaults to `["el", "en"]`); Phase D Task D.3 (provider applies default).
- **FR-SX-10** (per-segment language tagging): Phase C Task C.3 (`SonioxTokenAggregator` populates `language` from token's `language` field).
- **FR-SX-11** (sidecar parity): existing sidecar pipeline; provider sets `model: "soniox"` on each segment.
- **FR-SX-12** (detach mode): inherited from plan-005's lift; verified by AC-SX-10.
- **FR-SX-13** (pause/resume/split parity): Phase D Task D.2 (`pause()`, `resume()`, full-close-and-reopen on `split()`).
- **FR-SX-14** (5 s drain on stop): Phase D Task D.2 `finish()`.
- **FR-SX-15** (per-session metrics): Phase D Task D.5.
- **FR-SX-16** (privacy disclosure): Phase H Task H.2.
- **FR-SX-17** (UI picker option): Phase H Task H.1.
- **FR-SX-18** (help + doc updates): Phase 0 + Phase H Task H.3 + Phase I Task I.4.
- **NFR-SX-1** (recording integrity isolation): enforced by `StreamingTranscriptionPipeline` (plan-005 already isolates); verified by AC-SX-6 / Phase I Task I.3.
- **NFR-SX-2** (latency targets): observability per Phase D Task D.5; warn-on-exceed.
- **NFR-SX-3** (no key in logs / disk): no `--soniox-api-key` CLI flag (Phase H Task H.3); resolver stores in-memory only.
- **NFR-SX-4** (no PII): `client_reference_id = "macrec-<recordingId>-<source>"`; no host metadata.
- **NFR-SX-5** (bounded retry posture): no automatic per-chunk retry in v1; on 503 reconnect once (per error mapper).
- **NFR-SX-6** (memory footprint): Float32 → Int16 chunked send is allocation-light; receive buffer bounded by `bufferingNewest(128)`.
- **NFR-SX-7** (no new SPM dep): verified at AC-SX-15 / Phase I Task I.6.

All 18 AC-SX-* are mapped to test artefacts in §8.8.

### 12.2 Investigation findings

- **5 RESOLVED OQs** are honoured: OQ-SX-2 (`SONIOX_API_KEY`),
  OQ-SX-4 (`stt-rt-v4`), OQ-SX-7 (multi-language hint list with
  BCP-47 → ISO 639-1 stripping), OQ-SX-11 (hand-rolled WS), OQ-SX-5
  (pricing documented in configuration-guide).
- **7 STILL-OPEN OQs** are surfaced in §0 with default dispositions
  and "needs user confirmation" tags.
- **CRITICAL FINDINGS** from `soniox-wire-schema.md` are honoured:
  - #1 (`finished` envelope) → `SonioxServerMessage` has all fields
    optional except `tokens`.
  - #2 (errors carry `tokens: []`) → same envelope handles errors.
  - #3 (`<end>`/`<fin>` are tokens) → aggregator detects via
    `text == "<end>"` / `text == "<fin>"`.
  - #4 (empty TEXT frame for close) → session sends `.string("")`;
    PEND-SX-1 tracks the optional probe-script confirmation.
  - #5 (300 min session) → noted in Risk 9.5.
  - #6 (regional endpoints) → `MACREC_SONIOX_ENDPOINT` documented
    in configuration-guide with US/EU/JP variants listed.
  - #7 (5 s SDK keepalive default) → 10 s used (2× safety margin
    over 20 s ceiling); documented.
  - #8 (`language_hints` order is bias not priority) → no special
    handling needed (default `["el", "en"]`).
  - #9 (BCP-47 → 400) → `SonioxLanguageHintMapper` strips before
    sending.
  - #10 (503 = reconnect signal) → `SonioxErrorMapper` returns
    `.reconnect` for 503.

### 12.3 Global CLAUDE.md compliance

- "No fallback solutions for configuration settings": enforced by
  Phase B Task B.7 (`MacrecError.transcriptionApiKeyMissing` is
  raised at start when `--transcribe soniox` and no key); FR-SX-4.
- "All test scripts MUST live under `test_scripts/`": yes, all 7
  e2e scripts and the optional probe go there.
- "All plans must be kept under `docs/design/`": this file is
  `docs/design/plan-006-soniox-streaming.md`.
- "All reference material under `docs/reference/`": investigation +
  codebase-scan already there; wire-schema research in `docs/research/`.
- "All FRs / features registered in `docs/design/project-functions.md`":
  Phase 0 Task 0.1.
- "Tools must be in TypeScript": **EXCEPTION 001** for the recording-tool
  project (Swift only). Plan-006 honours.
- "When you locate code, give folder + file + class + line + extract":
  Phase B / D tasks cite exact line numbers from the codebase scan.
- "Don't perform any version control operation unless explicitly
  requested": plan-006 has no `git` commands except read-only
  diff-stat in Phase I verification.

### 12.4 Project architecture parity

- Provider conformer placed in `Sources/MacrecCore/Transcription/Providers/`
  (parity with Gemini, Apple, WhisperKit).
- Wire-protocol code in `Sources/MacrecCore/Transcription/Live/Soniox/`
  (per user's instruction to mirror Gemini Live's directory layout).
- Test seam (`WebSocketTransport` protocol + `FakeWebSocketTransport`)
  parallels the `analyzerFactory` / `MockSpeechAnalyzer` pattern in
  Apple Speech.
- Streaming session bridges `URLSessionWebSocketTask` → `AsyncStream`
  per the established `docs/research/websocket-asyncstream-pattern.md`
  recipe.
- No changes to `TranscriptionManager`, `SourceBuffer`,
  `SegmentCoalescer`, `TranscriptSanitizer`, sidecar writers — Soniox
  is purely a new conformer.

### 12.5 Swift / SwiftPM idioms

- All new types declare `Sendable` (or `@unchecked Sendable` with
  explicit `NSLock` justification per `AppleSpeechSession` precedent).
- Codable for wire types (snake_case property names match wire shape;
  no `CodingKeys` needed).
- `async / await` for I/O; `AsyncStream.makeStream` for events.
- `Task` for the keepalive timer + receive loop; structured
  cancellation on `finish()`.
- `URL` instead of `String` for the endpoint.
- `Duration` + `ContinuousClock` for timing-sensitive logic
  (keepalive, latency observation, drain timeout) — supports
  `MockClock` injection for deterministic tests.
- No new SPM dependency.

---

## 13. Execution Handoff

When Phase 6 (Implementer) takes over, this plan is the executable
prompt. Recommended starting points:

1. **Read** §0 (decisions needed) and resolve with the user the 6
   policy/UX questions (OQ-SX-3, OQ-SX-6, OQ-SX-8, OQ-SX-9, OQ-SX-10,
   OQ-SX-12). If the user accepts all defaults, no plan revision is
   needed.
2. **Sequence** by §11 (Phases). Single-implementer order:
   `0 → B → C → D → H → I`.
3. **Verify** at the end of each Phase using the per-Phase verify
   commands listed in §11.
4. **Track deviations** per the global CLAUDE.md rules: auto-fix
   bugs / missing critical / blockers; ask about architectural; log
   enhancements to `Issues - Pending Items.md`.
5. **At Phase I final verification**, the plan ships when:
   - All `swift build` + `swift test` commands pass (excluding the
     real-key e2e if no key is available).
   - All 18 AC-SX-* are demonstrably verified (modulo the real-key
     e2e gate documented in Risk 9.1).
   - All doc updates land.
   - `Package.swift` diff is empty.

End of plan-006.
