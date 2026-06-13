# Plan 004 — REST-Batch Transcription Pivot (notch-style pipeline)

> **Status**: Design (Phase Brainstorming) — awaiting user review of this
> spec, then `writing-plans` produces the executable implementation plan.
>
> **Date**: 2026-04-28
>
> **Supersedes**: The Gemini Live WebSocket transcription path described
> in `plan-003-live-transcription.md` is replaced. Plan-003 stays on
> disk as historical record; this plan is the new authoritative source
> for transcription architecture.
>
> **Author intent**: User reported "the transcription doesn't work yet"
> and asked the team to study the transcription approach in
> `/Users/giorgosmarinos/aiwork/coding-platform/macbook-desktop/notch`
> and follow a similar path while keeping Gemini as the speech-to-text
> model.

---

## 1. Goal

Replace the streaming Gemini Live WebSocket transcription pipeline with
a REST-batch pipeline modelled on `boringNotch/Transcribe/TranscriptionManager`.
Audio capture stays exactly as today (48 kHz Float32 from `ScreenCaptureKit`
system audio + `AVFoundation` mic, aligned by `AudioAligner`). What changes
is everything downstream of the audio tap:

- **Provider** — replaced with `GeminiRESTTranscriptionProvider`, a
  one-shot `URLSession` call to `generateContent` per buffered chunk.
- **Buffering** — per-source `[Float]` ring buffers, flushed every
  ~2.5 s, mirroring notch.
- **Coalescing** — same-source segments within 12 s and not ending on
  `.!?…` are extended in place, mirroring notch.
- **Sanitisation** — silence gate at peak < 0.01 plus a known-hallucination
  word-list filter, mirroring notch.
- **Networking** — entire `Sources/MacrecCore/Transcription/Networking/`
  folder deleted. No WebSocket session lifecycle, no reconnect state
  machine, no session-resumption tokens.

The recording integrity isolation contract from project-design §LT
("audio is the primary artefact; nothing in transcription can stop the
recording") is preserved verbatim — only the implementation changes.

---

## 2. Why this pivot

### 2.1 What the current code does that does not work

`Sources/MacrecCore/Transcription/Providers/GeminiLiveTranscriptionProvider.swift`
(32 KB) speaks the **Gemini Live API** wire protocol over a WebSocket
opened by `Sources/MacrecCore/Transcription/Networking/WebSocketSession.swift`
(23 KB). Plan-003 §0.1 OQ-LT-1 pinned the model at
`gemini-3.1-flash-live-preview` with `responseModalities: ["AUDIO"]`
plus `inputAudioTranscription: {}` — a configuration that the research
deliverable explicitly flagged as unverified (ESC-LT-1) and that
`Issues - Pending Items.md::LT-PEND-1` records as never having passed
the manual smoke-test gate. The user's report is the empirical
confirmation: no transcripts arrive.

### 2.2 Why notch's approach maps cleanly

The notch project (`boringNotch/Transcribe/`) solves the same shape of
problem — capture audio, get text out, render in a UI panel, persist
to disk — with a dramatically simpler pipeline. The only thing that
makes notch's specific code inapplicable as-is is its choice of provider:
notch uses on-device WhisperKit and Parakeet (FluidAudio), which would
require new SwiftPM dependencies that plan-003 §preamble ruled out and
that the user has not approved. Everything else in notch — the
`TranscriptionManager` actor, the per-source `[Float]` buffers, the
2.5 s flush cadence, the energy gate, the hallucination filter, the
sentence-end coalescer, the JSONL persistence — is provider-agnostic
and adapts directly to a Gemini REST provider.

### 2.3 Why REST instead of Live for Gemini

Both REST and Live are first-party Gemini surfaces. The REST surface
fits notch's chunked-batch model 1:1 (buffer N seconds → POST → text);
the Live surface needs a parallel streaming model that adds significant
machinery without buying anything for our 2.5 s flush cadence. The
Live API also still depends on the same `inputAudioTranscription`
feature whose reliability put us here in the first place. REST
`generateContent` with `inlineData` audio is the documented, GA path
for "send audio bytes, get text back" — see
<https://ai.google.dev/gemini-api/docs/audio>.

---

## 3. Scope deltas (file by file)

### 3.1 To be deleted

| Path | Approx. KB |
|---|---|
| `Sources/MacrecCore/Transcription/Networking/WebSocketSession.swift` | 23 |
| `Sources/MacrecCore/Transcription/Networking/URLSessionWebSocketTransport.swift` | 5 |
| `Sources/MacrecCore/Transcription/Networking/FakeWebSocketTransport.swift` | 9 |
| `Sources/MacrecCore/Transcription/Networking/WebSocketTransport.swift` | 3 |
| `Sources/MacrecCore/Transcription/Networking/WebSocketMessage.swift` | 2 |
| `Sources/MacrecCore/Transcription/Networking/WebSocketCloseCode.swift` | 2 |
| `Sources/MacrecCore/Transcription/Networking/ServerEvent.swift` | 3 |
| `Sources/MacrecCore/Transcription/Networking/NetworkPathObserver.swift` | 3 |
| `Sources/MacrecCore/Transcription/Providers/GeminiLiveTranscriptionProvider.swift` | 32 |
| `Sources/MacrecCore/Transcription/Providers/GeminiWireSchema.swift` | 18 |
| `Sources/MacrecCore/Transcription/TranscriptionDriver.swift` | 17 |
| `Sources/MacrecCore/Transcription/TranscriptionPCMChunk.swift` | 2.5 |
| **Total deleted** | **~119 KB** |

The `Networking/` folder is removed entirely. If a future provider
needs WebSocket transport (OpenAI Realtime, Deepgram), it brings its
own — no need to keep a half-used networking layer alive.

### 3.2 To be added

| Path | Approx. KB | Purpose |
|---|---|---|
| `Sources/MacrecCore/Transcription/TranscriptionManager.swift` | ~6 | Orchestrator actor (see §4.3) |
| `Sources/MacrecCore/Transcription/SourceBuffer.swift` | ~3 | Per-source `[Float]` ring buffer with bounded overflow (§4.2) |
| `Sources/MacrecCore/Transcription/SegmentCoalescer.swift` | ~3 | Sentence-end + 12 s window merging (§4.5) |
| `Sources/MacrecCore/Transcription/TranscriptSanitizer.swift` | ~2 | `peak()` and `clean()` pure functions (§4.4) |
| `Sources/MacrecCore/Transcription/AudioWAVEncoder.swift` | ~2 | Float[] → 16 kHz PCM16 WAV bytes for inline payload (§4.7) |
| `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift` | ~6 | The new provider (§4.6) |
| **Total added** | **~22 KB** | |

### 3.3 To be edited

| Path | Change |
|---|---|
| `Sources/MacrecCore/Transcription/TranscriptionProvider.swift` | Replace streaming `run(audio:options:) -> AsyncStream<TranscriptEvent>` with batch `transcribe(samples:source:options:) async throws -> String` |
| `Sources/MacrecCore/Transcription/TranscriptEvent.swift` | Drop the `.partial` case; add `.segmentAppended(idx, segment)` and `.segmentUpdated(idx, segment)` to express coalescer output |
| `Sources/MacrecCore/Transcription/FakeTranscriptionProvider.swift` | Re-conform to the new protocol; default impl returns canned strings keyed by source |
| `Sources/MacrecCore/Transcription/NoOpTranscriptionProvider.swift` | Re-conform — `transcribe` returns `""` |
| `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift` | Drop the Live wiring; build `GeminiRESTTranscriptionProvider` for `gemini` (with `gemini-live` accepted as a deprecation alias for one release) |
| `Sources/MacrecCore/Transcription/AudioDownsampler.swift` | Drop the 30 ms wire-chunking helper; keep the 48k → 16k Float32 conversion |
| `Sources/MacrecCore/Transcription/TranscriptionOptions.swift` | Drop session-resumption / sliding-window fields; add `tagSpeakers: Bool` (default `true` for `both`, `false` otherwise) |
| `Sources/MacrecCore/Transcription/Persistence/SidecarPathBuilder.swift` | Insert `"transcript"` infix → fixes R-LT-1 |
| `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift` | Implement id-keyed line-rewrite-in-place (§5.2) |
| `Sources/MacrecCore/Transcription/Persistence/TXTTranscriptWriter.swift` | Same id-keyed in-place rewrite for the most-recent-line case |
| `Sources/MacrecCore/Transcription/Persistence/SRTTranscriptWriter.swift` | Same id-keyed rewrite |
| `Sources/MacrecCore/Transcription/Persistence/VTTTranscriptWriter.swift` | Same id-keyed rewrite |
| `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift` | Add `rotateSidecar(toAudioURL:)` actor surface — fixes R-LT-5 |
| `Sources/MacrecCore/RecordingSession.swift` | `setUpTranscriptionPipelineIfNeeded` constructs a `TranscriptionManager` instead of a `TranscriptionDriver`; the audio tap calls `manager.ingest(_:from:)` directly; `split(nextOutput:)` calls `manager.rotateSidecar(toAudioURL:)` |
| `Sources/MacrecCore/Config/RecordingOptions.swift` | Drop the unused detach cross-check comment; document the `gemini-live` → `gemini` value alias |
| `Sources/MacrecCore/Config/ConfigResolver.swift` | Remove the (planned-but-unimplemented per R-LT-2) detach cross-check; honour the `gemini-live` deprecation alias with one log line |
| `Sources/MacrecCore/Errors/MacrecError.swift` | Remove `transcriptionDetachUnsupported` (closes R-LT-2 by deletion); keep `transcriptionApiKeyMissing`; keep `transcriptionInvalidConfigValue`; rename `transcriptionWebSocketFailed` → `transcriptionProviderFailed(detail:)` |
| `Sources/MacrecUIKit/SessionCoordinator.swift` | Drop session-resumption metric publishing; emit chunks-sent / RTT / error count instead |
| `Sources/MacrecUIKit/RecordingController.swift` | Drop the partial/final UI distinction; the inline panel updates the most-recent line in place when a `.segmentUpdated` event arrives |
| `Sources/macrec-ui/Views/Transcription/*` | Adjust to the new event shape; the privacy disclosure ("Audio is being sent to Google") tooltip stays |
| `Sources/macrec-ui/Views/ControlBar.swift` | No structural change (the Phase G fix from LT-PEND-5 stays); the picker label "Gemini Live" → "Gemini" |
| `docs/design/project-design.md` §LT-* | Rewrite the Live-API sections; add an §LT-superseded callout pointing here |
| `docs/design/project-functions.md` | Rewrite FR-45..FR-58 / NFR-17..NFR-21 / AC-LT-1..AC-LT-25 (§7 of this plan enumerates the new wording) |
| `docs/design/configuration-guide.md` | Refresh §LT for the new env-var defaults and the `gemini-live` alias |
| `docs/tools/macrec.md` | Refresh `--transcribe` documentation; remove the detach restriction text |
| `docs/tools/macrec-ui.md` | Refresh the picker / privacy / cost-line sections |
| `Issues - Pending Items.md` | Close LT-PEND-1, LT-PEND-2, R-LT-1, R-LT-2, R-LT-4, R-LT-5 (each with a "Resolved by plan-004" line); add a new pending item for the model-id risk (§9.1) |
| `test_scripts/e2e-transcription-noop.sh` | Updated to the new sidecar naming and provider id |
| `test_scripts/e2e-transcription-gemini.sh` | New — happy-path E2E with a real `GOOGLE_API_KEY` (replaces LT-PEND-1's manual procedure) |

### 3.4 Untouched

- `Sources/MacrecCore/Capture/*` — capture pipeline unchanged.
- `Sources/MacrecCore/Aligning/*` — aligner unchanged.
- `Sources/MacrecCore/Encoding/*` — recorders unchanged. Audio integrity
  is fully isolated.
- `Sources/MacrecCore/Permissions/*` — TCC unchanged.
- The `~/.tool-agents/macrec/.env` and `~/.tool-agents/macrec-ui/.env`
  conventions — unchanged. `GOOGLE_API_KEY` resolution chain is
  identical to today.

---

## 4. Component contracts

### 4.1 `TranscriptionProvider` (protocol)

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String
}
```

**Inputs.** `samples` is 16 kHz mono Float32 in the conventional
`[-1.0, 1.0]` range. `source` is the routing label so the provider
can include it in a system prompt if it wants speaker tagging.
`options` carries the model id, language hint, and any future
provider-specific tuning.

**Output.** A best-effort transcription of the audio, or `""` if the
provider judged the audio non-speech. **Never throws on empty audio
or non-speech**; throws only on transport / auth / decode errors.

**Concurrency.** Implementations must be `Sendable` and safe for
concurrent calls (the manager makes up to two parallel calls per
source under load — §4.3).

**v1 conformers.** `NoOpTranscriptionProvider`, `FakeTranscriptionProvider`,
`GeminiRESTTranscriptionProvider`.

### 4.2 `SourceBuffer` (actor)

```swift
public actor SourceBuffer {
    public init(source: SourceTag, chunkSeconds: Double = 2.5,
                sampleRate: Int = 16_000, minSamples: Int = 6_400)
    public func append(_ samples: [Float])
    public func drain(final: Bool) -> [Float]?   // nil if < minSamples
    public var bufferOverflowCount: Int { get }
}
```

`append` is bounded: if `accumulator.count > 2 * chunkSamples` the
oldest half is dropped and `bufferOverflowCount` increments. This
matches today's `bufferingNewest(64)` lossy-under-backpressure
contract but at the actor boundary, where `[Float]` is the natural
unit. `drain(final:)` returns the entire accumulator as a `[Float]`
and clears it; if `final == false` and the accumulator is below
`minSamples` (400 ms — Gemini consistently returns empty text below
this), it returns `nil` and leaves the buffer alone for the next tick.

### 4.3 `TranscriptionManager` (actor)

```swift
public actor TranscriptionManager {
    public init(
        provider: any TranscriptionProvider,
        source: TranscriptionSource,
        options: TranscriptionOptions,
        sidecarWriter: TranscriptSidecarWriter?,
        logger: Logger
    )

    public func start() -> AsyncStream<TranscriptionEvent>
    public func ingest(_ frame: AlignedFrame, from: SourceTag)
    public func rotateSidecar(toAudioURL: URL) async throws
    public func stop() async
    public func metrics() -> TranscriptionMetrics
}
```

**Lifecycle.** `init` is passive (no I/O, no Task). `start` constructs
the per-source `SourceBuffer`s based on `source` (`mic` → 1 buffer,
`system` → 1, `mixed` → 1, `both` → 2), opens the events stream, and
spawns a single `processLoop` Task that wakes every 2.0 s
(80 % of `chunkSeconds`). `ingest` downsamples the frame via the
shared `AudioDownsampler` and appends to the matching buffer (or
both, in `mixed` mode where the aligner has already mixed the frame).
`rotateSidecar` closes the current sidecar writer, opens fresh ones
at the new path derived from `toAudioURL`, and resets the coalescer.
`stop` finishes all buffers with `final: true`, awaits in-flight
provider tasks (≤ 5 s drain), finishes the events stream, returns.

**In-flight cap.** The manager keeps at most **two concurrent provider
calls per source** in a small `[SourceTag: [Task<Void, Never>]]`
dictionary. If a third would-be flush lands while two are still in
flight, the oldest in-flight call is awaited (not cancelled — Gemini
is mid-billing) and the new one is enqueued. This prevents unbounded
fan-out under transient network slowness.

**`processLoop`.**

```swift
while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(chunkSeconds * 0.8))
    for (source, buf) in buffers {
        guard let samples = await buf.drain(final: false) else { continue }
        guard TranscriptSanitizer.peak(samples) >= silenceThreshold else { continue }
        spawnProviderTask(samples: samples, source: source)   // honours in-flight cap
    }
}
```

### 4.4 `TranscriptSanitizer`

```swift
public enum TranscriptSanitizer {
    public static let silenceThreshold: Float = 0.01   // ≈ −40 dBFS
    public static func peak(_ samples: [Float]) -> Float
    public static func clean(_ raw: String) -> String
}
```

`peak` returns max-abs. `clean` trims whitespace, strips leading
punctuation, requires at least one letter or digit, lowercases the
remaining text and matches against a known-hallucination set
(verbatim from notch):

```
"thank you", "thanks", "thanks for watching",
"thank you for watching", "thanks so much for watching",
"bye", "bye bye", "bye-bye", "goodbye",
"you", "yeah", "hmm", "uh", "um", "okay", "ok",
"subtitles by the amara.org community"
```

Returns `""` for any match, otherwise the cleaned input.

### 4.5 `SegmentCoalescer`

```swift
public struct SegmentCoalescer: Sendable {
    public static let coalesceWindowSeconds: TimeInterval = 12

    public private(set) var segments: [TranscriptSegment] = []

    public enum MergeResult {
        case appended(index: Int)   // existing segment extended in place
        case created(index: Int)    // new segment added
    }

    public mutating func merge(
        text: String,
        source: SourceTag,
        at: Date
    ) -> MergeResult
}
```

The merge rule: if the last segment exists, has the same `source`,
its text does not end in `.!?…`, and `at - last.lastUpdated <
coalesceWindowSeconds`, append to the last segment in place
(returning `.appended`). Otherwise create a new segment
(returning `.created`).

`TranscriptSegment` carries a stable `UUID` so the sidecar writers
can rewrite the line in place when `.appended` is reported.

### 4.6 `GeminiRESTTranscriptionProvider`

```swift
public struct GeminiRESTTranscriptionProvider: TranscriptionProvider {
    public init(
        apiKey: String,
        modelId: String = Self.defaultModelId,
        urlSession: URLSession = .shared
    )

    public static let defaultModelId = "gemini-3.1-flash-live-preview"
    public static let knownGoodFallback = "gemini-3-flash-preview"

    public let id = "gemini"
    public let displayName = "Gemini"

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String
}
```

**Endpoint.** `POST https://generativelanguage.googleapis.com/v1beta/models/{modelId}:generateContent?key={apiKey}`

**Body.**

```json
{
  "contents": [{
    "parts": [
      { "text": "<system prompt>" },
      { "inlineData": { "mimeType": "audio/wav", "data": "<base64 WAV>" } }
    ]
  }],
  "generationConfig": { "temperature": 0.0, "candidateCount": 1 }
}
```

**System prompt (constant).** `"You are a verbatim audio transcriber.
Output only the spoken text from the audio, with no preamble, no
narration, no labels, no timestamps. If the audio contains no
speech, output an empty string. Preserve the speaker's wording
exactly."` Optionally appended when `options.languageHint != nil`:
`" Audio language: \(options.languageHint!)."`

**Response decode.** Reads `candidates[0].content.parts[0].text`,
trims, returns. If the response contains no `candidates`, returns `""`.

**Error mapping.** Non-2xx → `MacrecError.transcriptionProviderFailed(
detail:)` where `detail` quotes the HTTP status, the Google `error.code`
/ `error.status` if present, and the `MACREC_TRANSCRIBE_MODEL`
override hint mentioning `Self.knownGoodFallback`. Body decode failure
→ same. URLSession throw → same with the underlying error description.

### 4.7 `AudioWAVEncoder`

```swift
public enum AudioWAVEncoder {
    public static func encode(
        samples: [Float],
        sampleRate: Int = 16_000
    ) -> Data
}
```

Builds a 44-byte RIFF/WAVE header followed by little-endian PCM16
(samples clamped to `[-1, 1]`, multiplied by 32 767, rounded). For
2.5 s of 16 kHz mono the output is 80 044 bytes (44 header + 80 000
PCM). This is small enough to inline as base64 in the request body
without any compression.

---

## 5. Data flow

### 5.1 The single-source happy path

```
SCStream/AVAudioEngine
    → AudioAligner                                    (existing)
    → AlignedFrame [48 kHz Float32, 100 ms]
    → tap closure (synchronous)
    → TranscriptionManager.ingest(frame, from: source)
        → Task { await … }                            (lossy hop)
        → AudioDownsampler.downsample → [Float32 @ 16 kHz]
        → SourceBuffer[source].append
   ⋮   buffer accumulates 2.0–2.5 s   ⋮
processLoop wakes every ~2.0 s
    → SourceBuffer[source].drain(final: false) → [Float32, ~40 000 samples]
    → TranscriptSanitizer.peak ≥ 0.01 ? otherwise discard
    → spawnProviderTask
        → provider.transcribe(samples, source, options) → "raw text"
        → TranscriptSanitizer.clean(raw) → "" or "cleaned"
        → SegmentCoalescer.merge(cleaned, source, at: now)
            → .appended(idx) → emit .segmentUpdated(idx, segment)
            → .created(idx)  → emit .segmentAppended(idx, segment)
    → events stream → UI inline panel + SidecarWriter
```

### 5.2 Sidecar in-place rewrite

For `.segmentUpdated` events the sidecar writers must replace the
previously-written line for that segment id (otherwise the file
would grow with N copies of the same evolving segment). The
contract uses a **tombstone-and-append** strategy that is unambiguous
for every supported format:

1. Each writer maintains an in-memory `[UUID: ByteRange]` index
   built as it writes.
2. On `.segmentAppended`, the new line is appended to the file and
   indexed.
3. On `.segmentUpdated`:
   - **Short-grow case** (new line ≤ old range): the new line is
     written into the existing byte range; remaining bytes of the
     old range are filled with spaces, which are valid trailing
     whitespace in all four formats (JSONL/TXT/SRT/VTT each tolerate
     trailing spaces on a line).
   - **Long-grow case** (new line > old range): the old range is
     overwritten with a **tombstone line** of the same byte length
     and the new line is appended at the end of the file. The index
     is updated to point at the new range. Tombstones per format:
     - **JSONL**: `{"_tombstone":true,"id":"<uuid>"}` plus trailing
       spaces to match the old byte length. Still valid JSON, still
       a complete line; consumers that filter on `_tombstone == true`
       skip these. The file remains valid JSONL line-by-line.
     - **TXT**: a single space-only line. Renders as a blank line
       in any text reader.
     - **SRT / VTT**: the cue is replaced with an empty cue
       (sequence number kept, timestamp range kept, body replaced
       with `[updated]` plus trailing spaces). The cue at the end
       of the file is the canonical version with the same sequence
       number — players that read sequentially honour the last
       occurrence; `[updated]` markers are visually obvious to
       human readers and harmless to subtitle decoders.
4. On `close`, no compaction is performed in v1. A consumer that
   wants a clean file can run a one-pass post-processing step
   (`jq 'select(._tombstone != true)' …` for JSONL).

This keeps offline tooling consistent (each segment id has exactly
one canonical record in the file — either in place or appended with
a tombstone marking the prior position). Notch only uses append-only
JSONL without in-place rewrite, so the rewrite logic is the one
recording-tool-specific addition over notch's design — necessary
because recording-tool's inline UI panel and the sidecar are both
fed by the same event stream and the file is the canonical record.

### 5.3 The dual-source `both` path

Two `SourceBuffer`s, two parallel provider tasks per flush tick.
The single `SegmentCoalescer` interleaves results in arrival order
and tags each segment with its source. SRT/VTT writers stamp the
source label as the speaker prefix (`mic: …` / `system: …`) when
`options.tagSpeakers` is true (default `true` for `both`, `false`
otherwise). JSONL always carries the `source` field.

This closes LT-PEND-2.

---

## 6. Configuration

| Variable | CLI flag | Purpose | Default | Notes |
|---|---|---|---|---|
| `MACREC_TRANSCRIBE` | `--transcribe` | Provider id: `none` \| `gemini` | `none` | `gemini-live` accepted as deprecated alias for one release with a `.notice` log line; resolves to `gemini`. |
| `MACREC_TRANSCRIBE_SOURCE` | `--transcribe-source` | `mic` \| `system` \| `mixed` \| `both` | `mixed` | `both` now actually fans out per-source (closes LT-PEND-2). |
| `MACREC_TRANSCRIBE_FORMAT` | `--transcript-format` | `jsonl` \| `txt` \| `srt` \| `vtt` (multi: comma-sep) | `jsonl` | Unchanged. |
| `MACREC_TRANSCRIBE_LANGUAGE` | `--transcribe-language` | BCP-47 hint included in the prompt | unset → auto | Unchanged; v2 still defers a known-list validation (LT-PEND-4 stays open). |
| `MACREC_TRANSCRIBE_MODEL` | `--transcribe-model` | Override the Gemini model id | `gemini-3.1-flash-live-preview` | See §9.1. Validated against the allowed list `[gemini-3.1-flash-live-preview, gemini-3-flash-preview, gemini-2.5-flash, gemini-2.5-pro, gemini-2.0-flash]` — values outside the list log a warning at start and are sent through. |
| `GOOGLE_API_KEY` | — | Gemini API key | — | Mandatory when provider != `none`; missing → `MacrecError.transcriptionApiKeyMissing` exit 78 (`EX_CONFIG`). |

The four-tier resolution chain (shell env → `~/.tool-agents/macrec/.env`
→ local `.env` → CLI flag, lowest-to-highest) is unchanged. No new
SwiftPM dependencies. No new env vars beyond what plan-003 already
introduced (one is repurposed: `MACREC_TRANSCRIBE_MODEL` was the Live
model id, is now the REST model id).

---

## 7. Error model & lifecycle

### 7.1 `MacrecError` cases

| Case | When raised | Exit code | Surface | Posture |
|---|---|---|---|---|
| `transcriptionApiKeyMissing` | Resolver: provider != `none` AND `GOOGLE_API_KEY` empty | 78 | CLI stderr; UI red banner | **Fatal at startup** |
| `transcriptionInvalidConfigValue(field:value:)` | Resolver: bad `--transcribe-source` / `--transcript-format` / `--transcribe-model` outside allowed list | 64 | CLI stderr | **Fatal at startup** |
| `transcriptionProviderFailed(detail:)` | Provider call returns non-2xx, body decode fails, URLSession throws | — | UI amber banner with error count; structured log entry | **Non-fatal at runtime** — recording continues, sidecar continues with a missed-chunk gap line |
| `transcriptionSidecarWriteFailed(url:detail:)` | Sidecar I/O fails (disk full, permission) | — | UI amber banner | **Non-fatal at runtime** |
| `transcriptionDetachUnsupported` | **REMOVED** (was: detach + non-None provider). The new sidecar-only architecture has no terminal-output dependency, so detach + transcribe is now valid. | — | — | Closes R-LT-2 by deletion |
| `transcriptionWebSocketFailed` | **REMOVED** | — | — | No WebSocket exists |

The non-fatal posture for runtime errors enforces the project's hard
rule from project-design §LT: **transcription is a side-channel.
Nothing in the transcription path can stop the recording.**

### 7.2 Lifecycle

1. **`start()`** — Resolver builds `RecordingOptions`. Factory builds
   the provider. `RecordingSession.setUpTranscriptionPipelineIfNeeded`
   constructs the `TranscriptionManager`, attaches the audio tap,
   opens the sidecar writers, emits the one-time privacy disclosure
   event (FR-53 preserved verbatim).
2. **`pause()` / `resume()`** — Manager keeps its buffers; on pause
   it flushes residue with `final: true`, then sleeps until resume.
   Sidecar writers stay open. The R-31 (FR-34) `.part01` rename of
   the first segment continues to apply per existing behaviour.
3. **`split(nextOutput:)`** — Manager calls `rotateSidecar(toAudioURL:)`
   which closes the current sidecar writers, opens fresh ones at the
   new path, resets the coalescer. Closes R-LT-5.
4. **`stop()`** — Manager finalises with up to 5 s drain (matches
   FR-57): flushes residue ≥ `minSamples`, awaits in-flight provider
   tasks (cancelled if 5 s exceeded), finishes the events stream,
   closes sidecar writers. Returns final `TranscriptionMetrics`.
5. **`--max-duration`** — Unchanged: when the recorder stops, the
   manager stops. One-way only.

### 7.3 Detach mode (`--detach --transcribe gemini`)

Now valid. Daemonised process opens a `TranscriptionManager` whose
events stream feeds only the sidecar writers (no UI subscriber). The
privacy disclosure is written once to the detach stderr-redirect file
on first start. `MacrecError.transcriptionDetachUnsupported` is
removed; `ConfigResolver` no longer enforces the cross-check.

---

## 8. Testing strategy

### 8.1 Unit — pure functions

| Component | Tests |
|---|---|
| `TranscriptSanitizer.peak` | Empty array → 0; all-zero array → 0; mixed → max abs |
| `TranscriptSanitizer.clean` | Each hallucination → `""`; punctuation-only → `""`; leading punct stripped; valid text untouched |
| `AudioWAVEncoder.encode` | 44-byte header structure check; 2.5 s @ 16 kHz produces 80 044 bytes; clamping |
| `SegmentCoalescer.merge` | Same source within window appends; different source creates; sentence-end forces create; window expiry creates |

### 8.2 Unit — actors

| Component | Tests |
|---|---|
| `SourceBuffer.append/drain` | `< minSamples` → drain returns nil; `≥ minSamples` → drain returns full; final flush flushes any residue |
| `SourceBuffer` overflow | `> 2 * chunkSamples` triggers overflow counter + drops oldest half |
| `TranscriptionManager` lifecycle | `start → ingest N synthetic frames → stop` produces expected `TranscriptionEvent` count with `FakeTranscriptionProvider` |
| `TranscriptionManager.rotateSidecar` | Old writer closed; new writer at expected path; coalescer reset |

### 8.3 Unit — provider

| Test | Mechanism |
|---|---|
| Happy path: 200 with text → returns text | `URLProtocol` stub returns canned response |
| 200 with empty `candidates` → returns `""` | `URLProtocol` stub |
| 200 with malformed JSON → throws `transcriptionProviderFailed` | `URLProtocol` stub |
| 401 → throws with `apiKeyMissing` hint in detail | `URLProtocol` stub |
| 400 with `"Model does not support generateContent"` → throws with `knownGoodFallback` hint | `URLProtocol` stub — covers the §9.1 failure mode |
| 500 → throws `transcriptionProviderFailed` | `URLProtocol` stub |
| URLSession transport error → throws `transcriptionProviderFailed` | `URLProtocol` stub |
| Request body shape | Capture request via stub, decode, assert `mimeType == "audio/wav"`, `temperature == 0.0`, model in URL |

### 8.4 Unit — sidecar

For each of the four formats: write a sequence
`[appended A, appended B, updated A, appended C, updated A, updated C, appended D, close]`
and assert the resulting bytes parse correctly and contain four
segment records in source order. Cover the short-grow and long-grow
in-place rewrite cases (§5.2).

### 8.5 Integration — pipeline

`RecordingSession.setUpTranscriptionPipelineIfNeeded` happy path with
stubbed `PermissionGating` and `FakeTranscriptionProvider`. Pump
synthetic frames through the existing `FakeAudioSource`; assert that
N frames produce M sidecar lines with the right contents.

### 8.6 E2E — shell scripts

| Script | Requires | Asserts |
|---|---|---|
| `test_scripts/e2e-transcription-noop.sh` | — | No `--transcribe` → no sidecar; exit 0 |
| `test_scripts/e2e-transcription-gemini.sh` | `GOOGLE_API_KEY` env | Audio file non-empty; `*.transcript.jsonl` exists with ≥ 2 segments; ≥ 1 segment fuzzy-matches a known phrase ≥ 60 % token overlap; exit 0 |
| `test_scripts/e2e-transcription-detach.sh` | `GOOGLE_API_KEY` env | New: detach + transcribe runs to completion, sidecar exists, exit 0 |
| `test_scripts/e2e-transcription-key-missing.sh` | unset `GOOGLE_API_KEY` | Exit 78; no audio file; no sidecar |

The two real-key scripts can run on CI with a secret-stored key as
well as locally, replacing LT-PEND-1's manual procedure.

### 8.7 Acceptance-criteria traceability

Each AC-LT item from the refined-request gets a one-line mapping in
`project-functions.md` § AC-LT (rewritten as part of §3.3 of this plan):

- AC-LT-1 (no sidecar without `--transcribe`) → `e2e-transcription-noop.sh`
- AC-LT-2 (sidecar exists with `--transcribe gemini`) → `e2e-transcription-gemini.sh`
- AC-LT-3 (audio integrity) → existing audio assertions in both scripts
- AC-LT-4 (no audio file when key missing) → `e2e-transcription-key-missing.sh`
- AC-LT-5 (sidecar filename infix) → `SidecarPathBuilderTests` + e2e file glob
- AC-LT-7 (per-source labels for `both`) → unit on coalescer + e2e variant
- AC-LT-14 (cost metrics emitted) → unit on `TranscriptionMetrics` + UI test on the post-stop summary
- AC-LT-22 (`--max-duration` stops transcription too) → integration test with mocked clock
- AC-LT-25 (privacy disclosure shown on first start) → UI test
- (remainder enumerated in `project-functions.md` after the §3.3 rewrite)

---

## 9. Risks

### 9.1 Default model id `gemini-3.1-flash-live-preview` on the REST endpoint

**Documented risk.** Per
<https://ai.google.dev/gemini-api/docs/audio> (April 2026), the
official REST audio model id is `gemini-3-flash-preview`. The same
page states *"As of now the Gemini API doesn't support real-time
transcription use cases. For real-time voice and video interactions
refer to the Live API."* Model ids ending in `-live-preview` are
served by the Live (WebSocket) endpoint. Posting `gemini-3.1-flash-live-preview`
to the `:generateContent` REST endpoint is documented to return HTTP
4xx (`Model not found` or `Model does not support the generateContent API`).

**User decision (recorded).** The user explicitly chose
`gemini-3.1-flash-live-preview` as the v1 default in the
brainstorming session on 2026-04-28, after being shown the docs.
The choice is honoured; this section makes the risk traceable.

**Mitigations baked into the design.**

- `MACREC_TRANSCRIBE_MODEL` lets a user override the default at
  start time without rebuilding. The validated allowed list includes
  `gemini-3-flash-preview` as a known-good alternative.
- The `transcriptionProviderFailed(detail:)` error message format
  always names `GeminiRESTTranscriptionProvider.knownGoodFallback`
  (`gemini-3-flash-preview`) in the remediation hint, e.g.:
  > `transcription provider failed (HTTP 404 — Model not found). Try setting MACREC_TRANSCRIBE_MODEL=gemini-3-flash-preview, or run macrec start --transcribe-model gemini-3-flash-preview.`
- The `e2e-transcription-gemini.sh` script fails loudly (not silently)
  if zero segments come back, surfacing the issue immediately the
  first time the script runs against a real key.
- A new pending item is added to `Issues - Pending Items.md`:
  > **PEND-LT-6 — Default Gemini REST model id may 4xx; fallback documented.** If the first `e2e-transcription-gemini.sh` run against a real key fails with HTTP 4xx, swap the default to `gemini-3-flash-preview` per the Gemini docs. Owner: user (decision after first run).

### 9.2 Inline-audio payload size

A 2.5 s @ 16 kHz mono PCM16 WAV is ~80 KB. Base64-encoded in JSON
that is ~107 KB per request. At 24 requests / minute / source × 2
sources × 60 minutes = ~2.9 GB of upstream bandwidth per hour of
`both`-source transcription. Documented in `docs/tools/macrec.md`
"Bandwidth" section. If a user complains, options to revisit:
encode as Opus 16 kbps (~20 KB / chunk), or use the Files API
(upload once, reference by URI — adds round-trips but eliminates
re-upload). v1 stays on inline WAV for simplicity.

### 9.3 In-flight call ordering vs sentence reconstruction

The two-concurrent-calls-per-source policy means a faster-returning
later chunk could land before an in-flight earlier chunk's response.
The `SegmentCoalescer.merge` uses `at: Date` timestamps to determine
window membership, but it appends to `segments[segments.count - 1]`
which is the most recently created segment, not the most recently
timed. Mitigation: each provider task records the chunk's flush
timestamp at spawn time and passes it to `merge`; the coalescer is
extended to insert into the correct slot (linear scan back from the
end while `at < segments[i].timestamp`). Edge case rarity: typical
RTT variance is < 500 ms; the 2.5 s flush cadence makes inversion
rare. Tracked in §9 of the executable plan.

### 9.4 Privacy / network-down behaviour

If the network is unreachable, every flush surfaces a
`transcriptionProviderFailed` and the UI banner stays amber. The
recording continues uninterrupted. Documented in
`docs/tools/macrec-ui.md` "Offline behaviour" and in the privacy
disclosure tooltip.

### 9.5 R-17 test runner

The dev host has Apple CommandLineTools, no Xcode, no working test
runner. All new tests are written with `import Testing` + `@Test`
so they run cleanly on a Xcode-equipped CI image. Local `swift test`
is a build check only. The four `test_scripts/e2e-*.sh` are real
runnable artefacts on the dev host because they exercise the binary.

### 9.6 R-20 strict-concurrency warnings

Out of scope. The new transcription code is fully `Sendable`-clean
(actors + value types + immutable structs). The pre-existing R-20
warnings in `M4ARecorder.swift` and `SCKitSystemAudioSource.swift`
remain as-is.

---

## 10. Deferred to v2

| Item | Why deferred |
|---|---|
| Per-source dual sidecar names for `both` (`*.system.transcript.jsonl` + `*.mic.transcript.jsonl`) | LT-PEND-2's full v2 ask. v1 closes the in-process gap (per-source REST calls + per-source labels in a single sidecar); the dual-file split waits for a real user request. |
| Configurable buffer window via `MACREC_TRANSCRIBE_CHUNK_SECONDS` | YAGNI. 2.5 s matches notch's empirical sweet spot. |
| Opus encoding for the inline payload | §9.2 mitigation. v1 ships WAV; revisit if bandwidth complaints surface. |
| Gemini Files API path (upload once, reference by URI) | §9.2 alternative. v1 ships inline WAV. |
| Additional providers (OpenAI Realtime, Deepgram, AssemblyAI) | Out of scope. The new `TranscriptionProvider` protocol leaves room — they drop in as new conformers without orchestration changes. |
| Validation of `MACREC_TRANSCRIBE_LANGUAGE` against a known list | LT-PEND-4 stays open. |
| Migration of historical Live-era WebSocket SidecarWriter header line | R-LT-4. Dropped — the new architecture's per-line `model` + `durationSec` makes summary aggregation a consumer-side concern. |

---

## 11. Open questions for the user

None blocking. All resolved during the brainstorming session on
2026-04-28:

- **Q1 (disposition of Gemini code)** → "keep gemini as the
  transcribing model, just use the rest of the wirings used into
  the notch to build a successful transcription process"
- **Q2 (REST vs Live)** → REST batch (recommended)
- **Q3 (refactor scope)** → Full rewrite, mirror notch directly
- **Q4 (per-source `both`)** → Yes, separate buffers + parallel calls
- **Q5 (detach restriction)** → Lift it
- **Q6 (chunk window)** → 2.5 s, matches notch
- **Q7 (sidecar formats)** → Keep all four
- **Q8 (FR/NFR/AC churn)** → Update `project-functions.md` in place
- **Q9 (default model id)** → `gemini-3.1-flash-live-preview` per
  user decision; risk recorded in §9.1 with `gemini-3-flash-preview`
  as the documented fallback.

---

## 12. Next step

The executable implementation plan follows below as **Part 2**.

---

# Part 2 — Implementation Plan

> **For executors:** Each phase is a coherent unit ending at a
> recommended commit point (executor decides whether to commit;
> the project rule prohibits unrequested VCS operations). Tasks
> use checkbox (`- [ ]`) syntax and follow TDD discipline:
> red → green → tighten. Tests are written with `import Testing`
> + `@Test`. Local `swift test` is a build check only on Apple
> CommandLineTools (R-17); a Xcode-equipped CI image runs the
> actual suite. Each phase ends with a `swift build` + `swift
> build --build-tests` check that **must** pass before moving on.

**Goal:** Replace the Gemini Live WebSocket transcription pipeline
with a notch-style REST-batch pipeline that actually produces
transcripts, while preserving every recording-integrity guarantee
in project-design §LT.

**Architecture:** Per-source `SourceBuffer` actors flush every
2.5 s into a stateless `GeminiRESTTranscriptionProvider`. A single
`TranscriptionManager` actor orchestrates buffering, sanitisation,
coalescing, and sidecar persistence behind a `TranscriptionEvent`
stream that drives both UI and disk I/O.

**Tech Stack:** Swift 5.9+ / Foundation / AVFoundation /
URLSession / `import Testing`. No new SwiftPM dependencies.

---

## Phase 0 — Spec & doc alignment

**Goal:** Get `project-functions.md`, `project-design.md`,
`configuration-guide.md`, and `Issues - Pending Items.md` in sync
with the new architecture **before** any code lands. This isolates
spec churn from code churn so reviewers can verify each in
isolation.

**Files (edit only — no Swift touched in this phase):**
- `docs/design/project-functions.md`
- `docs/design/project-design.md`
- `docs/design/configuration-guide.md`
- `Issues - Pending Items.md`

### Task 0.1 — Rewrite FR-45..FR-58 in project-functions.md

- [ ] Open `docs/design/project-functions.md`.
- [ ] Locate the FR-45..FR-58 block (live-transcription FRs added by plan-003).
- [ ] Rewrite each FR to reflect REST-batch semantics:
  - **FR-45** "Opt-in transcription side-channel via `--transcribe`" — unchanged in intent; rewrite to drop "WebSocket" and substitute "REST per-chunk request".
  - **FR-46** "Provider abstraction supports multiple backends" — unchanged.
  - **FR-47** "Audio downsampled to 16 kHz mono PCM16 before provider call" — unchanged.
  - **FR-48** "Per-chunk buffering window of 2.5 s before flush" — **new wording**, replaces the streaming-30 ms-chunks FR.
  - **FR-49** "Energy gate suppresses near-silent chunks (peak < 0.01)" — **new**; was implicit in plan-003.
  - **FR-50** "Hallucination filter suppresses known-noise tokens" — **new**.
  - **FR-51** "Same-source segments coalesce within 12 s and not at sentence end" — rewrite (was partial/final coalescing).
  - **FR-52** "Inline transcript panel shows growing-segment updates in place" — rewrite to replace partial/final with appended/updated.
  - **FR-53** "Privacy disclosure tooltip shown on first transcribe start" — unchanged.
  - **FR-54** "Sidecar formats jsonl / txt / srt / vtt with `*.transcript.<ext>` infix" — rewrite to add the `.transcript.` infix (closes R-LT-1 spec-side).
  - **FR-55** "Sidecar rotates on `split(nextOutput:)`" — rewrite (closes R-LT-5 spec-side).
  - **FR-56** "`--transcribe-source both` produces per-source labels in a single sidecar" — rewrite (closes LT-PEND-2 spec-side).
  - **FR-57** "Stop drains in-flight provider calls within 5 s" — unchanged.
  - **FR-58** "Per-session metrics emitted: chunks sent, billable seconds, error count, last RTT" — rewrite (was first-token latency).
- [ ] In each FR, flip status line to `IMPLEMENTED (Phase X — plan-004)` if the FR is satisfied by a phase below; otherwise leave `PLANNED` with the specific phase listed.
- [ ] Save.

### Task 0.2 — Rewrite NFR-17..NFR-21 in project-functions.md

- [ ] In the same file, locate NFR-17..NFR-21.
- [ ] Rewrite:
  - **NFR-17** "Recording integrity isolation — transcription failures cannot stop the recording" — unchanged.
  - **NFR-18** "Transcription pipeline memory bounded — per-source buffer ≤ 320 KB peak (40 000 samples × 4 bytes × 2 sources)" — **new wording**, replaces 8 MB streaming ceiling.
  - **NFR-19** "End-to-end latency from utterance end to transcript line ≤ 5 s P95 (2.5 s buffer + 2 s RTT + 0.5 s overhead)" — **new wording**, replaces first-token NFR.
  - **NFR-20** "API key never logged or written to disk except as configured key file" — unchanged.
  - **NFR-21** "Retry policy: per-chunk failures non-fatal; no automatic retry of failed REST calls in v1 (idempotency unclear, retry costs money)" — **new wording**, replaces session-resumption NFR.
- [ ] Save.

### Task 0.3 — Rewrite AC-LT-1..AC-LT-25 in project-functions.md

- [ ] Locate the AC-LT block.
- [ ] For each AC, rewrite the verification mechanism column to
      reference the new test artefacts (`e2e-transcription-*.sh`
      and the new unit tests) per §8.7 of Part 1.
- [ ] AC-LT items that referenced WebSocket-specific behaviour
      (close codes, session-resumption tokens, sliding-window
      context limits) are dropped — replace with a single line
      referencing this plan: "AC-LT-N — superseded by plan-004."
- [ ] Save.

### Task 0.4 — Update project-design.md §LT-*

- [ ] Open `docs/design/project-design.md`.
- [ ] At the top of §LT add a callout:
  ```
  > **Superseded sections.** §LT-3 (WebSocket session lifecycle), §LT-4
  > (reconnect state machine), §LT-5.5 step 8 (detach cross-check),
  > §LT-6.4 (30 ms wire chunking), and §LT-7.2 / §LT-9.1 (header/footer
  > rewrite) are superseded by plan-004 (REST batch architecture).
  > See `docs/design/plan-004-rest-batch-transcription.md`.
  ```
- [ ] In §LT-7.1 (sidecar layout), update example filenames to
      include the `.transcript.` infix.
- [ ] Save.

### Task 0.5 — Refresh configuration-guide.md §LT

- [ ] Open `docs/design/configuration-guide.md`.
- [ ] In the LT section update the env-var table per §6 of Part 1:
  - `MACREC_TRANSCRIBE` value `gemini` (with `gemini-live` deprecation alias)
  - `MACREC_TRANSCRIBE_MODEL` default `gemini-3.1-flash-live-preview`
  - Add a sentence under `MACREC_TRANSCRIBE_MODEL`: "If you see
    HTTP 4xx errors, set this to `gemini-3-flash-preview` per the
    fallback documented in plan-004 §9.1."
- [ ] Save.

### Task 0.6 — Update Issues - Pending Items.md

- [ ] Open `Issues - Pending Items.md`.
- [ ] Append to **each** of LT-PEND-1, LT-PEND-2, R-LT-1, R-LT-2, R-LT-4, R-LT-5
      a one-line "Resolved by plan-004 (Phase X)" footer (X named
      per-item — e.g. R-LT-1 → Phase F.1, R-LT-5 → Phase G.2,
      R-LT-2 → Phase G.3, etc.). **Do not move them yet** — they
      stay in Pending until the implementing phases ship.
- [ ] Add a new pending item at the top of Pending (most-critical-first):

  ```markdown
  ### PEND-LT-6 — Default Gemini REST model id may 4xx; documented fallback (Medium — runtime risk, plan-004 §9.1, 2026-04-28)
  Per https://ai.google.dev/gemini-api/docs/audio (Apr 2026) the
  documented REST audio model is `gemini-3-flash-preview`. The user
  chose `gemini-3.1-flash-live-preview` as the v1 default
  (brainstorming session 2026-04-28). If the first
  `e2e-transcription-gemini.sh` run against a real key fails with
  HTTP 4xx, set `MACREC_TRANSCRIBE_MODEL=gemini-3-flash-preview`
  (or pass `--transcribe-model gemini-3-flash-preview`) and re-run.
  Tracked here so the swap is one-line if it surfaces. Owner: user
  decision after first real-key run.
  ```
- [ ] Save.

### Task 0.7 — Phase 0 verification

- [ ] Run: `grep -n 'IMPLEMENTED (Phase' docs/design/project-functions.md | wc -l` → expect ≥ 14 (one per FR-45..FR-58).
- [ ] Run: `grep -nE 'plan-004' docs/design/project-functions.md docs/design/project-design.md docs/design/configuration-guide.md "Issues - Pending Items.md" | wc -l` → expect ≥ 8.
- [ ] **Recommended commit point**: "doc(transcription): align spec to REST-batch architecture (plan-004 Phase 0)".

---

## Phase A — Pure value types (parallel-friendly)

**Goal:** Land four self-contained pure-value-type modules that
have zero dependencies on each other. These can be implemented
in any order or in parallel, and their tests run in milliseconds.

**Files:**
- Create: `Sources/MacrecCore/Transcription/TranscriptSanitizer.swift`
- Create: `Sources/MacrecCore/Transcription/AudioWAVEncoder.swift`
- Create: `Sources/MacrecCore/Transcription/SegmentCoalescer.swift`
- Create: `Sources/MacrecCore/Transcription/TranscriptSegment.swift` (the value type both the coalescer and the events use)
- Modify: `Sources/MacrecCore/Transcription/TranscriptEvent.swift`
- Test: `Tests/MacrecCoreTests/Transcription/TranscriptSanitizerTests.swift`
- Test: `Tests/MacrecCoreTests/Transcription/AudioWAVEncoderTests.swift`
- Test: `Tests/MacrecCoreTests/Transcription/SegmentCoalescerTests.swift`
- Test: `Tests/MacrecCoreTests/Transcription/TranscriptEventTests.swift` (rewrite existing)

### Task A.1 — TranscriptSegment value type

- [ ] **Step 1: Create the file.**

```swift
// Sources/MacrecCore/Transcription/TranscriptSegment.swift
import Foundation

public struct TranscriptSegment: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public var lastUpdated: Date
    public var text: String
    public let source: SourceTag
    public let confidence: Float?
    public let model: String?
    public let durationSec: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        lastUpdated: Date? = nil,
        text: String,
        source: SourceTag,
        confidence: Float? = nil,
        model: String? = nil,
        durationSec: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.lastUpdated = lastUpdated ?? timestamp
        self.text = text
        self.source = source
        self.confidence = confidence
        self.model = model
        self.durationSec = durationSec
    }
}
```

- [ ] **Step 2: Build.**
  Run: `swift build`
  Expected: success (no test asserting on this type yet — it's a value type used downstream).

### Task A.2 — TranscriptSanitizer

- [ ] **Step 1: Write the failing test.**

```swift
// Tests/MacrecCoreTests/Transcription/TranscriptSanitizerTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("TranscriptSanitizer")
struct TranscriptSanitizerTests {

    @Test("peak returns 0 for empty samples")
    func peakEmpty() {
        #expect(TranscriptSanitizer.peak([]) == 0)
    }

    @Test("peak returns max abs across samples")
    func peakMaxAbs() {
        #expect(TranscriptSanitizer.peak([0.0, -0.7, 0.3, -0.1]) == 0.7)
    }

    @Test("clean strips leading punctuation and whitespace")
    func cleanStripsLeadingPunct() {
        #expect(TranscriptSanitizer.clean("   ,. hello world") == "hello world")
    }

    @Test("clean returns empty for punctuation-only input")
    func cleanRejectsPunctOnly() {
        #expect(TranscriptSanitizer.clean("...,,,!!!") == "")
    }

    @Test("clean drops known hallucinations regardless of trailing punctuation")
    func cleanDropsHallucinations() {
        for token in ["thank you", "Thanks for watching!", "you", "Subtitles by the Amara.org community"] {
            #expect(TranscriptSanitizer.clean(token) == "", "expected '\(token)' to be filtered")
        }
    }

    @Test("clean preserves real text untouched")
    func cleanPreservesRealText() {
        #expect(TranscriptSanitizer.clean("The quick brown fox.") == "The quick brown fox.")
    }
}
```

- [ ] **Step 2: Run — verify failure.**
  Run: `swift build --build-tests`
  Expected: build error (`TranscriptSanitizer` not defined).

- [ ] **Step 3: Implement.**

```swift
// Sources/MacrecCore/Transcription/TranscriptSanitizer.swift
import Foundation

public enum TranscriptSanitizer {

    /// Energy gate threshold (≈ −40 dBFS). Samples whose peak amplitude
    /// is below this value are skipped without calling the provider —
    /// avoids billing for silence and avoids common Whisper-family
    /// hallucinations on near-silent input.
    public static let silenceThreshold: Float = 0.01

    /// Returns the maximum absolute value across `samples`. Returns 0
    /// for an empty array.
    public static func peak(_ samples: [Float]) -> Float {
        var p: Float = 0
        for v in samples {
            let a = abs(v)
            if a > p { p = a }
        }
        return p
    }

    /// Common Whisper / Parakeet / Gemini hallucinations on silent
    /// or non-speech input. Mirrors notch's list verbatim.
    private static let knownHallucinations: Set<String> = [
        "thank you", "thanks", "thanks for watching",
        "thank you for watching", "thanks so much for watching",
        "bye", "bye bye", "bye-bye", "goodbye",
        "you", "yeah", "hmm", "uh", "um", "okay", "ok",
        "subtitles by the amara.org community"
    ]

    /// Trim whitespace, strip leading punctuation, drop empty / hallucination tokens.
    public static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.unicodeScalars.first,
              CharacterSet.punctuationCharacters.contains(first)
                || CharacterSet.whitespaces.contains(first)
        {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaning = s.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        guard hasMeaning else { return "" }

        var key = s.lowercased()
        while let last = key.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(last)
                || CharacterSet.whitespaces.contains(last)
        {
            key.removeLast()
        }
        if Self.knownHallucinations.contains(key) { return "" }

        return s
    }
}
```

- [ ] **Step 4: Run — verify pass.**
  Run: `swift build --build-tests`
  Expected: success. (Tests do not actually execute on this dev host per R-17, but they compile and would pass on CI.)

### Task A.3 — AudioWAVEncoder

- [ ] **Step 1: Write the failing test.**

```swift
// Tests/MacrecCoreTests/Transcription/AudioWAVEncoderTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("AudioWAVEncoder")
struct AudioWAVEncoderTests {

    @Test("header is 44 bytes, body is 2 × samples (PCM16)")
    func encodeProducesExpectedLayout() {
        let samples: [Float] = Array(repeating: 0.5, count: 16_000) // 1 s @ 16 kHz
        let bytes = AudioWAVEncoder.encode(samples: samples)
        #expect(bytes.count == 44 + 16_000 * 2)
        // RIFF magic
        #expect(bytes[0..<4] == Data("RIFF".utf8))
        // WAVE magic
        #expect(bytes[8..<12] == Data("WAVE".utf8))
        // fmt subchunk
        #expect(bytes[12..<16] == Data("fmt ".utf8))
        // PCM format code (1) at offset 20-21 little-endian
        #expect(bytes[20] == 1 && bytes[21] == 0)
    }

    @Test("clamping handles values outside [-1, 1]")
    func encodeClampsOutOfRange() {
        let samples: [Float] = [2.0, -2.0, 0.0]
        let bytes = AudioWAVEncoder.encode(samples: samples)
        // Last 6 bytes are the three int16-LE samples
        let body = bytes.suffix(6)
        // 2.0 → clamped to 1.0 → 32767 → 0xFF 0x7F
        // -2.0 → clamped to -1.0 → -32767 → 0x01 0x80
        // 0.0  → 0 → 0x00 0x00
        let expected: [UInt8] = [0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00]
        #expect(Array(body) == expected)
    }

    @Test("2.5 s @ 16 kHz produces 80 044 bytes")
    func encodeStandardChunkSize() {
        let samples: [Float] = Array(repeating: 0, count: 40_000)
        #expect(AudioWAVEncoder.encode(samples: samples).count == 80_044)
    }
}
```

- [ ] **Step 2: Run — verify failure.**
  Run: `swift build --build-tests` — expected: `AudioWAVEncoder` undefined.

- [ ] **Step 3: Implement.**

```swift
// Sources/MacrecCore/Transcription/AudioWAVEncoder.swift
import Foundation

public enum AudioWAVEncoder {

    /// Encode 32-bit float samples in `[-1, 1]` as a 16-bit-PCM mono WAV.
    /// The output is exactly `44 + samples.count * 2` bytes.
    public static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)
        let chunkSize = 36 + dataSize

        var out = Data()
        out.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        out.append(contentsOf: "RIFF".utf8)
        out.appendLE(chunkSize)
        out.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        out.append(contentsOf: "fmt ".utf8)
        out.appendLE(UInt32(16))                // PCM fmt chunk size
        out.appendLE(UInt16(1))                 // audio format = PCM
        out.appendLE(channels)
        out.appendLE(UInt32(sampleRate))
        out.appendLE(byteRate)
        out.appendLE(blockAlign)
        out.appendLE(bitsPerSample)

        // data subchunk
        out.append(contentsOf: "data".utf8)
        out.appendLE(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * Float(Int16.max))
            out.appendLE(UInt16(bitPattern: value))
        }

        return out
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
```

- [ ] **Step 4: Run — verify pass.**
  Run: `swift build --build-tests` → success.

### Task A.4 — SegmentCoalescer

- [ ] **Step 1: Write the failing test.**

```swift
// Tests/MacrecCoreTests/Transcription/SegmentCoalescerTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("SegmentCoalescer")
struct SegmentCoalescerTests {

    @Test("first merge always creates a new segment")
    func firstMergeCreates() {
        var c = SegmentCoalescer()
        let result = c.merge(text: "hello", source: .mic, at: Date(timeIntervalSince1970: 0))
        if case .created(let idx) = result {
            #expect(idx == 0)
        } else {
            Issue.record("expected .created, got \(result)")
        }
        #expect(c.segments.count == 1)
        #expect(c.segments[0].text == "hello")
    }

    @Test("same source within window appends in place")
    func sameSourceWithinWindowAppends() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "hello", source: .mic, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "world", source: .mic, at: Date(timeIntervalSince1970: 5))
        if case .appended(let idx) = result {
            #expect(idx == 0)
        } else {
            Issue.record("expected .appended, got \(result)")
        }
        #expect(c.segments.count == 1)
        #expect(c.segments[0].text == "hello world")
    }

    @Test("different source creates a new segment")
    func differentSourceCreates() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "alpha", source: .mic, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "beta", source: .system, at: Date(timeIntervalSince1970: 1))
        if case .created(let idx) = result {
            #expect(idx == 1)
        } else {
            Issue.record("expected .created")
        }
    }

    @Test("sentence-end punctuation forces a new segment")
    func sentenceEndForcesCreate() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "hello.", source: .mic, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "world", source: .mic, at: Date(timeIntervalSince1970: 1))
        if case .created = result {
            // pass
        } else {
            Issue.record("expected .created after sentence-end")
        }
    }

    @Test("window expiry forces a new segment")
    func windowExpiryCreates() {
        var c = SegmentCoalescer()
        _ = c.merge(text: "hello", source: .mic, at: Date(timeIntervalSince1970: 0))
        let result = c.merge(text: "world", source: .mic,
                             at: Date(timeIntervalSince1970: SegmentCoalescer.coalesceWindowSeconds + 1))
        if case .created = result { /* pass */ } else {
            Issue.record("expected .created after window expiry")
        }
    }
}
```

- [ ] **Step 2: Run — verify failure.**
  Run: `swift build --build-tests` → undefined.

- [ ] **Step 3: Implement.**

```swift
// Sources/MacrecCore/Transcription/SegmentCoalescer.swift
import Foundation

public struct SegmentCoalescer: Sendable {

    public static let coalesceWindowSeconds: TimeInterval = 12

    public private(set) var segments: [TranscriptSegment] = []

    public init() {}

    public enum MergeResult: Sendable, Equatable {
        case appended(index: Int)
        case created(index: Int)
    }

    public mutating func merge(
        text: String,
        source: SourceTag,
        at: Date
    ) -> MergeResult {
        let lastEndsSentence: Bool
        if let last = segments.last, let lastChar = last.text.last {
            lastEndsSentence = ".!?…".contains(lastChar)
        } else {
            lastEndsSentence = false
        }

        if let last = segments.last,
           last.source == source,
           !lastEndsSentence,
           at.timeIntervalSince(last.lastUpdated) < Self.coalesceWindowSeconds
        {
            let combined = (last.text + " " + text)
                .replacingOccurrences(of: "  ", with: " ")
            segments[segments.count - 1] = TranscriptSegment(
                id: last.id,
                timestamp: last.timestamp,
                lastUpdated: at,
                text: combined,
                source: last.source,
                confidence: last.confidence,
                model: last.model,
                durationSec: last.durationSec
            )
            return .appended(index: segments.count - 1)
        } else {
            let seg = TranscriptSegment(
                timestamp: at,
                text: text,
                source: source
            )
            segments.append(seg)
            return .created(index: segments.count - 1)
        }
    }

    public mutating func reset() {
        segments.removeAll()
    }
}
```

- [ ] **Step 4: Build.**
  Run: `swift build --build-tests` → success.

### Task A.5 — TranscriptionEvent rewrite

- [ ] **Step 1: Read the existing file.**
  Read `Sources/MacrecCore/Transcription/TranscriptEvent.swift`. The
  existing cases include `.partial(text:)`, `.final(text:)`, etc.
- [ ] **Step 2: Replace the public enum body.**

```swift
// Sources/MacrecCore/Transcription/TranscriptEvent.swift
import Foundation

public enum TranscriptionEvent: Sendable, Codable, Equatable {
    /// A new segment was created and appended at `index` of the
    /// running segment list. UI: append a new line to the panel.
    case segmentAppended(index: Int, segment: TranscriptSegment)

    /// The segment at `index` was updated in place (text grew via
    /// the coalescer). UI: rewrite the most-recent line.
    case segmentUpdated(index: Int, segment: TranscriptSegment)

    /// Privacy disclosure that should fire exactly once per session
    /// the first time a non-`none` provider is about to send audio.
    case privacyDisclosure(providerDisplayName: String)

    /// Per-flush metric snapshot. Emitted on each successful provider
    /// call so the UI can show running cost / chunks / RTT.
    case metricsTick(metrics: TranscriptionMetrics)

    /// Non-fatal provider/sidecar error. UI shows a transient amber
    /// banner; the recording continues.
    case error(detail: String)
}

public struct TranscriptionMetrics: Sendable, Codable, Equatable {
    public var chunksSent: Int = 0
    public var billableSeconds: Double = 0
    public var lastRttMs: Int = 0
    public var errorCount: Int = 0
    public var bufferOverflowCount: Int = 0

    public init() {}
}
```

- [ ] **Step 3: Type-rename `TranscriptEvent` → `TranscriptionEvent`** project-wide via:
  Run: `grep -rln '\bTranscriptEvent\b' Sources/ Tests/`
  Then for each match, replace with `TranscriptionEvent` using `Edit`. Any reference to `TranscriptEvent.partial` / `.final` is now broken — those are deleted callers in Phases C/G/H. Leave them broken for this phase; Phase G/H wires the new shape.
- [ ] **Step 4: Build (will fail in Phase A — expected).**
  Run: `swift build` → expected to surface compile errors at the deleted-case sites. **This is fine** — those sites are deleted in subsequent phases. Capture the error list to a scratchpad for Phase G/H reference.

### Task A.6 — Rewrite TranscriptEventTests

- [ ] **Step 1: Replace `Tests/MacrecCoreTests/Transcription/TranscriptEventTests.swift`** with tests for the new enum cases:

```swift
// Tests/MacrecCoreTests/Transcription/TranscriptEventTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("TranscriptionEvent")
struct TranscriptionEventTests {

    @Test("segmentAppended round-trips through Codable")
    func segmentAppendedCodable() throws {
        let seg = TranscriptSegment(timestamp: Date(timeIntervalSince1970: 0),
                                    text: "hi", source: .mic)
        let event: TranscriptionEvent = .segmentAppended(index: 0, segment: seg)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TranscriptionEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("metricsTick increments fields independently")
    func metricsTickFields() {
        var m = TranscriptionMetrics()
        m.chunksSent = 3
        m.billableSeconds = 7.5
        m.lastRttMs = 412
        m.errorCount = 1
        let event: TranscriptionEvent = .metricsTick(metrics: m)
        if case .metricsTick(let read) = event {
            #expect(read.chunksSent == 3)
            #expect(read.billableSeconds == 7.5)
            #expect(read.lastRttMs == 412)
            #expect(read.errorCount == 1)
        } else {
            Issue.record("expected .metricsTick")
        }
    }
}
```

### Task A.7 — Phase A build check

- [ ] Run: `swift build --target MacrecCore` → expect compile errors **only** at TranscriptionDriver.swift / GeminiLiveTranscriptionProvider.swift / RecordingSession.swift sites referencing the old `.partial` / `.final` cases. Record the list.
- [ ] **Recommended commit point**: "feat(transcription): add pure value types — sanitizer, wav encoder, coalescer, segment, events (plan-004 Phase A)".

---

## Phase B — SourceBuffer actor

**Goal:** A bounded per-source `[Float]` accumulator with a 2 × chunk overflow policy.

**Files:**
- Create: `Sources/MacrecCore/Transcription/SourceBuffer.swift`
- Test: `Tests/MacrecCoreTests/Transcription/SourceBufferTests.swift`

### Task B.1 — Write the failing test

```swift
// Tests/MacrecCoreTests/Transcription/SourceBufferTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("SourceBuffer")
struct SourceBufferTests {

    @Test("drain returns nil when below minSamples")
    func drainBelowMin() async {
        let buf = SourceBuffer(source: .mic)
        await buf.append(Array(repeating: Float(0), count: 1_000))
        let result = await buf.drain(final: false)
        #expect(result == nil)
    }

    @Test("drain returns the accumulator when ≥ minSamples")
    func drainAboveMin() async {
        let buf = SourceBuffer(source: .mic)
        await buf.append(Array(repeating: Float(0.1), count: 7_000))
        let result = await buf.drain(final: false)
        #expect(result?.count == 7_000)
        let after = await buf.drain(final: false)
        #expect(after == nil) // drained
    }

    @Test("drain with final: true flushes any non-empty residue")
    func drainFinalReturnsResidue() async {
        let buf = SourceBuffer(source: .mic)
        await buf.append(Array(repeating: Float(0.1), count: 100))
        let result = await buf.drain(final: true)
        #expect(result?.count == 100)
    }

    @Test("overflow drops oldest half when buffer exceeds 2 × chunkSamples")
    func overflowDropsOldestHalf() async {
        let chunkSamples = Int(2.5 * 16_000) // 40 000
        let buf = SourceBuffer(source: .mic)
        await buf.append(Array(repeating: Float(0.1), count: 2 * chunkSamples + 1))
        let count = await buf.bufferOverflowCount
        #expect(count == 1)
    }
}
```

### Task B.2 — Run — verify failure

Run: `swift build --build-tests` → undefined.

### Task B.3 — Implement

```swift
// Sources/MacrecCore/Transcription/SourceBuffer.swift
import Foundation

public actor SourceBuffer {

    public let source: SourceTag
    public let chunkSamples: Int
    public let minSamples: Int

    private var accumulator: [Float] = []
    public private(set) var bufferOverflowCount: Int = 0

    public init(
        source: SourceTag,
        chunkSeconds: Double = 2.5,
        sampleRate: Int = 16_000,
        minSamples: Int = 6_400
    ) {
        self.source = source
        self.chunkSamples = Int(chunkSeconds * Double(sampleRate))
        self.minSamples = minSamples
    }

    public func append(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        let cap = 2 * chunkSamples
        if accumulator.count > cap {
            bufferOverflowCount += 1
            let drop = accumulator.count / 2
            accumulator.removeFirst(drop)
        }
    }

    public func drain(final: Bool) -> [Float]? {
        if accumulator.isEmpty { return nil }
        if !final && accumulator.count < minSamples { return nil }
        let out = accumulator
        accumulator.removeAll(keepingCapacity: true)
        return out
    }
}
```

### Task B.4 — Build

Run: `swift build --build-tests` → success.

### Task B.5 — Phase B commit point

- [ ] **Recommended commit point**: "feat(transcription): add SourceBuffer actor with overflow policy (plan-004 Phase B)".

---

## Phase C — Updated TranscriptionProvider protocol + canonical conformers

**Goal:** Replace the streaming `run(audio:options:) -> AsyncStream` shape with a batch `transcribe(samples:source:options:) async throws -> String`. Update `NoOpTranscriptionProvider` and `FakeTranscriptionProvider` to conform.

**Files:**
- Modify: `Sources/MacrecCore/Transcription/TranscriptionProvider.swift`
- Modify: `Sources/MacrecCore/Transcription/NoOpTranscriptionProvider.swift`
- Modify: `Sources/MacrecCore/Transcription/FakeTranscriptionProvider.swift`
- Delete: `Sources/MacrecCore/Transcription/TranscriptionPCMChunk.swift`
- Modify: `Tests/MacrecCoreTests/Transcription/NoOpTranscriptionProviderTests.swift`
- Modify: `Tests/MacrecCoreTests/Transcription/FakeTranscriptionProviderTests.swift`

### Task C.1 — Replace TranscriptionProvider protocol

- [ ] **Step 1: Replace the file content:**

```swift
// Sources/MacrecCore/Transcription/TranscriptionProvider.swift
import Foundation

/// A speech-to-text backend that takes a fixed-format audio buffer
/// and returns its verbatim transcription.
///
/// Implementations are stateless per call — any state (HTTP session
/// reuse, model warm-up) belongs to the implementation, not the
/// protocol. Implementations MUST be safe for concurrent calls; the
/// `TranscriptionManager` makes up to two parallel calls per source
/// under load.
///
/// Audio contract: `samples` is 16 kHz mono Float32 in `[-1, 1]`.
/// Returns `""` for non-speech input — does NOT throw.
/// Throws only on transport, auth, or decode failures.
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String
}
```

- [ ] **Step 2: Build — expect cascading errors at the conformers + driver.**

### Task C.2 — Update NoOpTranscriptionProvider

```swift
// Sources/MacrecCore/Transcription/NoOpTranscriptionProvider.swift
import Foundation

/// Default provider for `--transcribe none`. Returns "" for every
/// call and does no I/O. Conformance exists so the orchestrator can
/// always have a non-nil provider when its config plumbing finds
/// `transcribe = none`.
public struct NoOpTranscriptionProvider: TranscriptionProvider {
    public let id = "none"
    public let displayName = "None"

    public init() {}

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        ""
    }
}
```

### Task C.3 — Update FakeTranscriptionProvider

- [ ] Read existing file to preserve any hard-coded fixture data the manager tests rely on. Replace conformance:

```swift
// Sources/MacrecCore/Transcription/FakeTranscriptionProvider.swift
import Foundation

/// In-process fake for tests. Returns canned text per source via a
/// pluggable closure; defaults to a deterministic round-robin pulled
/// from `script` (one item per call).
public actor FakeTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "fake"
    public nonisolated let displayName = "Fake"

    private var script: [String]
    private var cursor: Int = 0
    public private(set) var receivedCallCount: Int = 0
    public private(set) var lastSamples: [Float] = []
    public private(set) var lastSource: SourceTag = .mic

    public init(script: [String] = ["hello world"]) {
        self.script = script
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        receivedCallCount += 1
        lastSamples = samples
        lastSource = source
        guard !script.isEmpty else { return "" }
        let text = script[cursor % script.count]
        cursor += 1
        return text
    }

    public func setScript(_ s: [String]) {
        self.script = s
        self.cursor = 0
    }
}
```

### Task C.4 — Rewrite NoOpTranscriptionProviderTests

```swift
// Tests/MacrecCoreTests/Transcription/NoOpTranscriptionProviderTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("NoOpTranscriptionProvider")
struct NoOpTranscriptionProviderTests {
    @Test("returns empty string regardless of input")
    func returnsEmpty() async throws {
        let p = NoOpTranscriptionProvider()
        let opts = TranscriptionOptions.disabled
        let out = try await p.transcribe(
            samples: Array(repeating: Float(0.5), count: 16_000),
            source: .mic, options: opts)
        #expect(out == "")
    }
}
```

### Task C.5 — Rewrite FakeTranscriptionProviderTests

```swift
// Tests/MacrecCoreTests/Transcription/FakeTranscriptionProviderTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("FakeTranscriptionProvider")
struct FakeTranscriptionProviderTests {
    @Test("returns scripted text in order")
    func returnsScripted() async throws {
        let p = FakeTranscriptionProvider(script: ["one", "two", "three"])
        let opts = TranscriptionOptions.disabled
        let r1 = try await p.transcribe(samples: [0.1], source: .mic, options: opts)
        let r2 = try await p.transcribe(samples: [0.1], source: .mic, options: opts)
        let r3 = try await p.transcribe(samples: [0.1], source: .mic, options: opts)
        #expect(r1 == "one"); #expect(r2 == "two"); #expect(r3 == "three")
    }

    @Test("counts calls and remembers last input")
    func counts() async throws {
        let p = FakeTranscriptionProvider(script: ["a"])
        let opts = TranscriptionOptions.disabled
        _ = try await p.transcribe(samples: [0.7], source: .system, options: opts)
        let count = await p.receivedCallCount
        let src = await p.lastSource
        #expect(count == 1)
        #expect(src == .system)
    }
}
```

### Task C.6 — Delete TranscriptionPCMChunk.swift

- [ ] Run: `rm Sources/MacrecCore/Transcription/TranscriptionPCMChunk.swift`
- [ ] Build expectation: any reference site is in TranscriptionDriver.swift / GeminiLiveTranscriptionProvider.swift, both of which we delete in Phase I.

### Task C.7 — Phase C build check

- [ ] Run: `swift build` → expect remaining errors at TranscriptionDriver, GeminiLiveTranscriptionProvider, RecordingSession transcription factory site. These are addressed in Phases D / E / G.
- [ ] **Recommended commit point**: "feat(transcription): batch TranscriptionProvider protocol + NoOp/Fake conformers (plan-004 Phase C)".

---

## Phase D — GeminiRESTTranscriptionProvider

**Goal:** A working REST provider with URLProtocol-stub-driven tests.

**Files:**
- Create: `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift`
- Create: `Sources/MacrecCore/Transcription/Providers/GeminiRESTSchema.swift`
- Modify: `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`
- Test: `Tests/MacrecCoreTests/Transcription/Providers/GeminiRESTTranscriptionProviderTests.swift`

### Task D.1 — Codable request/response types

```swift
// Sources/MacrecCore/Transcription/Providers/GeminiRESTSchema.swift
import Foundation

enum GeminiREST {

    struct Request: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig

        struct Content: Encodable {
            let parts: [Part]
        }

        enum Part: Encodable {
            case text(String)
            case inlineAudio(mimeType: String, base64Data: String)

            enum CodingKeys: String, CodingKey {
                case text
                case inlineData
            }
            enum InlineKeys: String, CodingKey {
                case mimeType
                case data
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let s):
                    try c.encode(s, forKey: .text)
                case .inlineAudio(let mime, let data):
                    var nested = c.nestedContainer(keyedBy: InlineKeys.self, forKey: .inlineData)
                    try nested.encode(mime, forKey: .mimeType)
                    try nested.encode(data, forKey: .data)
                }
            }
        }

        struct GenerationConfig: Encodable {
            let temperature: Double
            let candidateCount: Int
        }
    }

    struct Response: Decodable {
        let candidates: [Candidate]?
        let error: ErrorDetail?

        struct Candidate: Decodable {
            let content: Content?
        }
        struct Content: Decodable {
            let parts: [Part]?
        }
        struct Part: Decodable {
            let text: String?
        }
        struct ErrorDetail: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }
    }
}
```

### Task D.2 — Provider implementation (skeleton + system prompt)

```swift
// Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift
import Foundation
import Logging

/// REST-batch transcription provider for Google Gemini.
/// One `URLSession` data task per `transcribe` call. Stateless across calls.
public struct GeminiRESTTranscriptionProvider: TranscriptionProvider, Sendable {

    public static let defaultModelId = "gemini-3.1-flash-live-preview"
    public static let knownGoodFallback = "gemini-3-flash-preview"

    /// Allowed list checked at resolver time. Anything outside is logged
    /// as a warning at start but still sent through (so newer GA models
    /// can be opted into without a code change).
    public static let allowedModelIds: Set<String> = [
        "gemini-3.1-flash-live-preview",
        "gemini-3-flash-preview",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash"
    ]

    public let id = "gemini"
    public let displayName = "Gemini"

    private let apiKey: String
    private let modelId: String
    private let urlSession: URLSession
    private let logger: Logger

    public init(
        apiKey: String,
        modelId: String = Self.defaultModelId,
        urlSession: URLSession = .shared,
        logger: Logger = Logger(label: "macrec.transcription.gemini")
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.urlSession = urlSession
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        let wav = AudioWAVEncoder.encode(samples: samples)
        let base64 = wav.base64EncodedString()

        var prompt = "You are a verbatim audio transcriber. Output only the spoken text from the audio, with no preamble, no narration, no labels, no timestamps. If the audio contains no speech, output an empty string. Preserve the speaker's wording exactly."
        if let lang = options.languageHint, !lang.isEmpty {
            prompt += " Audio language: \(lang)."
        }

        let body = GeminiREST.Request(
            contents: [.init(parts: [
                .text(prompt),
                .inlineAudio(mimeType: "audio/wav", base64Data: base64)
            ])],
            generationConfig: .init(temperature: 0.0, candidateCount: 1)
        )

        guard var components = URLComponents(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent")
        else {
            throw MacrecError.transcriptionProviderFailed(detail: "could not build URL for model \(modelId)")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw MacrecError.transcriptionProviderFailed(detail: "could not finalise URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw MacrecError.transcriptionProviderFailed(
                detail: "URLSession error: \(error.localizedDescription). Try setting MACREC_TRANSCRIBE_MODEL=\(Self.knownGoodFallback)."
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw MacrecError.transcriptionProviderFailed(detail: "non-HTTP response")
        }

        if !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "(non-utf8 body)"
            let parsed = try? JSONDecoder().decode(GeminiREST.Response.self, from: data)
            let google = parsed?.error.map { e in
                " (\(e.status ?? "UNKNOWN") \(e.code.map(String.init) ?? "-"): \(e.message ?? "no message"))"
            } ?? ""
            throw MacrecError.transcriptionProviderFailed(
                detail: "HTTP \(http.statusCode)\(google). Body: \(bodyText.prefix(200)). Try setting MACREC_TRANSCRIBE_MODEL=\(Self.knownGoodFallback) (per https://ai.google.dev/gemini-api/docs/audio)."
            )
        }

        let parsed: GeminiREST.Response
        do {
            parsed = try JSONDecoder().decode(GeminiREST.Response.self, from: data)
        } catch {
            throw MacrecError.transcriptionProviderFailed(
                detail: "response decode failed: \(error.localizedDescription)"
            )
        }

        let raw = parsed.candidates?.first?.content?.parts?.first?.text ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

### Task D.3 — URLProtocol stub fixture

```swift
// Tests/MacrecCoreTests/Transcription/Providers/GeminiRESTStubProtocol.swift
import Foundation

/// URLProtocol-based fixture for intercepting URLSession calls in unit tests.
/// Set `Self.handler` to canned `(HTTPURLResponse, Data)` response for the next call.
final class GeminiRESTStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        // URLSession does not pass httpBody through URLProtocol — read from httpBodyStream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            Self.capturedBody = data
        } else {
            Self.capturedBody = request.httpBody
        }
        guard let h = Self.handler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "GeminiRESTStubProtocol", code: -1))
            return
        }
        do {
            let (resp, data) = try h(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiRESTStubProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        handler = nil
        capturedRequest = nil
        capturedBody = nil
    }
}
```

### Task D.4 — Provider unit tests

```swift
// Tests/MacrecCoreTests/Transcription/Providers/GeminiRESTTranscriptionProviderTests.swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("GeminiRESTTranscriptionProvider", .serialized)
struct GeminiRESTTranscriptionProviderTests {

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!,
                        statusCode: status,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil)!
    }

    private func makeProvider(model: String = GeminiRESTTranscriptionProvider.defaultModelId) -> GeminiRESTTranscriptionProvider {
        GeminiRESTStubProtocol.reset()
        return GeminiRESTTranscriptionProvider(
            apiKey: "test-key",
            modelId: model,
            urlSession: GeminiRESTStubProtocol.makeURLSession()
        )
    }

    @Test("happy path returns trimmed text")
    func happyPath() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            let body = #"{"candidates":[{"content":{"parts":[{"text":"  hello world  "}]}}]}"#
            return (self.httpResponse(200), Data(body.utf8))
        }
        let p = makeProvider()
        let out = try await p.transcribe(
            samples: Array(repeating: Float(0.1), count: 16_000),
            source: .mic, options: .disabled)
        #expect(out == "hello world")
    }

    @Test("empty candidates returns empty string")
    func emptyCandidates() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            return (self.httpResponse(200), Data("{}".utf8))
        }
        let p = makeProvider()
        let out = try await p.transcribe(
            samples: [0.1], source: .mic, options: .disabled)
        #expect(out == "")
    }

    @Test("HTTP 400 throws transcriptionProviderFailed mentioning fallback model")
    func http400() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            let body = #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Model does not support generateContent"}}"#
            return (self.httpResponse(400), Data(body.utf8))
        }
        let p = makeProvider()
        do {
            _ = try await p.transcribe(samples: [0.1], source: .mic, options: .disabled)
            Issue.record("expected throw")
        } catch let e as MacrecError {
            let desc = "\(e)"
            #expect(desc.contains("HTTP 400"))
            #expect(desc.contains("gemini-3-flash-preview"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("request body contains audio/wav inline data")
    func requestBodyShape() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            (self.httpResponse(200), Data(#"{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}"#.utf8))
        }
        let p = makeProvider()
        _ = try await p.transcribe(
            samples: Array(repeating: Float(0.1), count: 16_000),
            source: .mic, options: .disabled)
        let body = GeminiRESTStubProtocol.capturedBody ?? Data()
        let s = String(data: body, encoding: .utf8) ?? ""
        #expect(s.contains("\"mimeType\":\"audio/wav\""))
        #expect(s.contains("\"temperature\":0"))
    }

    @Test("URL contains the configured model id and key")
    func requestURL() async throws {
        GeminiRESTStubProtocol.handler = { _ in
            (self.httpResponse(200), Data(#"{"candidates":[]}"#.utf8))
        }
        let p = makeProvider(model: "gemini-3-flash-preview")
        _ = try await p.transcribe(samples: [0.1], source: .mic, options: .disabled)
        let url = GeminiRESTStubProtocol.capturedRequest?.url?.absoluteString ?? ""
        #expect(url.contains("/models/gemini-3-flash-preview:generateContent"))
        #expect(url.contains("key=test-key"))
    }
}
```

### Task D.5 — Update TranscriptionProviderFactory

- [ ] Read existing factory.
- [ ] Replace its body with REST-only build path:

```swift
// Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift
import Foundation
import Logging

public struct TranscriptionProviderFactoryInput: Sendable {
    public let providerId: String
    public let apiKey: String?
    public let modelId: String?
    public let languageHint: String?
    public let logger: Logger
    public let keyExpiresAt: Date?
}

public enum TranscriptionProviderFactory {
    /// Build a concrete `TranscriptionProvider` from resolved options.
    /// Honours the `gemini-live` deprecation alias for one release.
    public static func build(_ input: TranscriptionProviderFactoryInput)
        throws -> any TranscriptionProvider
    {
        let normalized: String = {
            switch input.providerId {
            case "gemini-live":
                input.logger.notice("MACREC_TRANSCRIBE=gemini-live is deprecated; use 'gemini'. Resolving to 'gemini'.")
                return "gemini"
            default:
                return input.providerId
            }
        }()

        switch normalized {
        case "none", "":
            return NoOpTranscriptionProvider()
        case "gemini":
            guard let key = input.apiKey, !key.isEmpty else {
                throw MacrecError.transcriptionApiKeyMissing(provider: "gemini")
            }
            let model = input.modelId ?? GeminiRESTTranscriptionProvider.defaultModelId
            if !GeminiRESTTranscriptionProvider.allowedModelIds.contains(model) {
                input.logger.warning("MACREC_TRANSCRIBE_MODEL='\(model)' is not in the allowed list; sending it through as-is. If you see HTTP 4xx errors, fall back to '\(GeminiRESTTranscriptionProvider.knownGoodFallback)'.")
            }
            return GeminiRESTTranscriptionProvider(
                apiKey: key,
                modelId: model,
                urlSession: .shared,
                logger: input.logger
            )
        default:
            throw MacrecError.transcriptionInvalidConfigValue(field: "transcribe", value: normalized)
        }
    }
}
```

### Task D.6 — Phase D build check

- [ ] Run: `swift build --build-tests` → expect remaining errors only at TranscriptionDriver / GeminiLiveTranscriptionProvider / RecordingSession (Phase E/G/I).
- [ ] **Recommended commit point**: "feat(transcription): GeminiRESTTranscriptionProvider with URLProtocol-stub tests (plan-004 Phase D)".

---

## Phase E — TranscriptionManager actor

**Goal:** The orchestrator that wires per-source buffers + sanitiser + coalescer + provider into a single `TranscriptionEvent` stream.

**Files:**
- Create: `Sources/MacrecCore/Transcription/TranscriptionManager.swift`
- Test: `Tests/MacrecCoreTests/Transcription/TranscriptionManagerTests.swift`

### Task E.1 — Implementation

```swift
// Sources/MacrecCore/Transcription/TranscriptionManager.swift
import Foundation
import AVFoundation
import Logging

/// Per-session orchestrator that buffers per-source audio, batch-flushes
/// to a `TranscriptionProvider`, sanitises results, coalesces segments,
/// and emits `TranscriptionEvent`s consumed by both UI and sidecar writers.
///
/// Lifecycle: `init` is passive. `start()` returns the events stream and
/// spawns the process loop. `ingest` appends to the matching source
/// buffer. `stop()` drains in-flight calls (≤ 5 s) and finishes the stream.
public actor TranscriptionManager {

    // MARK: - Configuration

    public static let chunkSeconds: Double = 2.5
    public static let processLoopSeconds: Double = 2.0   // 80 % of chunk
    public static let stopDrainSeconds: Double = 5.0
    public static let maxInFlightPerSource: Int = 2

    // MARK: - Dependencies

    private let provider: any TranscriptionProvider
    private let source: TranscriptionSource
    private let options: TranscriptionOptions
    private var sidecarWriter: TranscriptSidecarWriter?
    private let downsampler: AudioDownsampler
    private let logger: Logger

    // MARK: - State

    private var buffers: [SourceTag: SourceBuffer] = [:]
    private var coalescer = SegmentCoalescer()
    private var inFlight: [SourceTag: [Task<Void, Never>]] = [:]
    private var processTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var started: Bool = false
    private var stopped: Bool = false
    private var disclosureFired: Bool = false
    private var metrics = TranscriptionMetrics()

    // MARK: - Init

    public init(
        provider: any TranscriptionProvider,
        source: TranscriptionSource,
        options: TranscriptionOptions,
        downsampler: AudioDownsampler,
        sidecarWriter: TranscriptSidecarWriter?,
        logger: Logger
    ) {
        self.provider = provider
        self.source = source
        self.options = options
        self.downsampler = downsampler
        self.sidecarWriter = sidecarWriter
        self.logger = logger
    }

    // MARK: - Public surface

    public func start() -> AsyncStream<TranscriptionEvent> {
        precondition(!started, "TranscriptionManager.start() called twice")
        started = true

        for tag in source.activeSourceTags() {
            buffers[tag] = SourceBuffer(source: tag)
            inFlight[tag] = []
        }

        let (stream, cont) = AsyncStream.makeStream(of: TranscriptionEvent.self,
                                                     bufferingPolicy: .bufferingNewest(64))
        self.eventsContinuation = cont

        if !disclosureFired && provider.id != "none" {
            disclosureFired = true
            cont.yield(.privacyDisclosure(providerDisplayName: provider.displayName))
        }

        processTask = Task { [weak self] in
            await self?.processLoop()
        }

        return stream
    }

    public func ingest(_ samples: [Float], from tag: SourceTag) {
        guard let buf = buffers[tag], !stopped else { return }
        Task { await buf.append(samples) }
    }

    /// Convenience for callers that have an `AlignedFrame` from the existing
    /// HostClockAligner tap closure. Downsamples 48 kHz → 16 kHz first.
    public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) {
        do {
            let downsampled = try downsampler.downsample(frame: frame)
            self.ingest(downsampled, from: tag)
        } catch {
            logger.warning("downsample failed: \(error.localizedDescription)")
        }
    }

    public func rotateSidecar(toAudioURL: URL) async throws {
        try await sidecarWriter?.close()
        let formats = options.sidecarFormats
        sidecarWriter = try TranscriptSidecarWriter(
            audioURL: toAudioURL,
            formats: formats,
            logger: logger
        )
        coalescer.reset()
    }

    public func stop() async {
        guard started, !stopped else { return }
        stopped = true
        processTask?.cancel()
        processTask = nil

        // Final drain of all buffers.
        for (tag, buf) in buffers {
            if let samples = await buf.drain(final: true) {
                if TranscriptSanitizer.peak(samples) >= TranscriptSanitizer.silenceThreshold {
                    await runProviderCall(samples: samples, source: tag, isFinal: true)
                }
            }
        }

        // Wait for outstanding tasks up to stopDrainSeconds.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.stopDrainSeconds))
        for tasks in inFlight.values {
            for t in tasks {
                if ContinuousClock.now < deadline {
                    await t.value
                } else {
                    t.cancel()
                }
            }
        }

        try? await sidecarWriter?.close()
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    public func currentMetrics() -> TranscriptionMetrics {
        metrics
    }

    // MARK: - Private

    private func processLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.processLoopSeconds))
            for (tag, buf) in buffers {
                guard let samples = await buf.drain(final: false) else { continue }
                let p = TranscriptSanitizer.peak(samples)
                guard p >= TranscriptSanitizer.silenceThreshold else { continue }
                await spawnProviderCall(samples: samples, source: tag)
            }
        }
    }

    private func spawnProviderCall(samples: [Float], source: SourceTag) async {
        var queue = inFlight[source] ?? []
        // Drop completed.
        queue = queue.filter { !$0.isCancelled }
        // If at cap, await the oldest before queuing the new one.
        while queue.count >= Self.maxInFlightPerSource {
            await queue.removeFirst().value
        }
        let t = Task { [weak self] in
            await self?.runProviderCall(samples: samples, source: source, isFinal: false)
        }
        queue.append(t)
        inFlight[source] = queue
    }

    private func runProviderCall(samples: [Float], source: SourceTag, isFinal: Bool) async {
        let started = Date()
        let durationSec = Double(samples.count) / 16_000.0
        do {
            let raw = try await provider.transcribe(samples: samples,
                                                    source: source,
                                                    options: options)
            let cleaned = TranscriptSanitizer.clean(raw)
            metrics.chunksSent += 1
            metrics.billableSeconds += durationSec
            metrics.lastRttMs = Int(Date().timeIntervalSince(started) * 1_000)
            eventsContinuation?.yield(.metricsTick(metrics: metrics))

            guard !cleaned.isEmpty else { return }

            let result = coalescer.merge(text: cleaned, source: source, at: Date())
            switch result {
            case .appended(let idx):
                let seg = coalescer.segments[idx]
                eventsContinuation?.yield(.segmentUpdated(index: idx, segment: seg))
                try? await sidecarWriter?.write(.segmentUpdated(index: idx, segment: seg))
            case .created(let idx):
                let seg = coalescer.segments[idx]
                eventsContinuation?.yield(.segmentAppended(index: idx, segment: seg))
                try? await sidecarWriter?.write(.segmentAppended(index: idx, segment: seg))
            }
        } catch {
            metrics.errorCount += 1
            eventsContinuation?.yield(.error(detail: error.localizedDescription))
            logger.warning("provider call failed: \(error.localizedDescription)")
        }
    }
}

// Helper on TranscriptionSource (defined in existing file):
extension TranscriptionSource {
    /// Which `SourceTag` buffers this routing should produce.
    fileprivate func activeSourceTags() -> [SourceTag] {
        switch self {
        case .mic: return [.mic]
        case .system: return [.system]
        case .mixed: return [.mixed]
        case .both: return [.mic, .system]
        }
    }
}
```

### Task E.2 — Manager unit tests

```swift
// Tests/MacrecCoreTests/Transcription/TranscriptionManagerTests.swift
import Foundation
import Testing
@testable import MacrecCore
import Logging

@Suite("TranscriptionManager")
struct TranscriptionManagerTests {

    @Test("emits privacy disclosure on first start with non-none provider")
    func emitsDisclosure() async throws {
        let provider = FakeTranscriptionProvider(script: ["hello"])
        let downsampler = AudioDownsampler.passthrough16k() // see helper below
        let manager = TranscriptionManager(
            provider: provider,
            source: .mic,
            options: .disabled.withProvider(id: "fake"),
            downsampler: downsampler,
            sidecarWriter: nil,
            logger: Logger(label: "test")
        )
        let stream = await manager.start()
        var received: [TranscriptionEvent] = []
        let task = Task {
            for await ev in stream {
                received.append(ev)
                if received.count >= 1 { break }
            }
        }
        _ = await task.value
        #expect(received.first.map { if case .privacyDisclosure = $0 { return true } else { return false } } ?? false)
        await manager.stop()
    }

    @Test("ingesting enough samples produces a segmentAppended event")
    func ingestProducesSegment() async throws {
        let provider = FakeTranscriptionProvider(script: ["hello world"])
        let manager = TranscriptionManager(
            provider: provider,
            source: .mic,
            options: .disabled.withProvider(id: "fake"),
            downsampler: AudioDownsampler.passthrough16k(),
            sidecarWriter: nil,
            logger: Logger(label: "test")
        )
        let stream = await manager.start()

        // Push 1.5 s of synthetic 16 kHz audio at amplitude 0.2 (above silence gate).
        let samples = Array(repeating: Float(0.2), count: 1_500 * 16)
        await manager.ingest(samples, from: .mic)
        // Trigger a final flush by stopping; final drain processes residue.
        await manager.stop()

        var sawAppended = false
        for await ev in stream {
            if case .segmentAppended(_, let seg) = ev {
                #expect(seg.text == "hello world")
                sawAppended = true
            }
        }
        #expect(sawAppended)
    }
}
```

> **Note:** `AudioDownsampler.passthrough16k()` is a test-only convenience
> that returns the input unchanged. If the existing `AudioDownsampler`
> doesn't have it, add a `#if DEBUG`-gated factory in
> `Sources/MacrecCore/Transcription/AudioDownsampler.swift` for tests:
>
> ```swift
> #if DEBUG
> public static func passthrough16k() -> AudioDownsampler { /* identity */ }
> #endif
> ```

### Task E.3 — Phase E build check

- [ ] Run: `swift build --build-tests` → expect remaining errors only at TranscriptionDriver / GeminiLiveTranscriptionProvider / RecordingSession driver-init site (Phase G/I).
- [ ] **Recommended commit point**: "feat(transcription): TranscriptionManager actor with per-source buffers + coalescer + sidecar (plan-004 Phase E)".

---

## Phase F — Sidecar writers (path fix + tombstone-and-append)

**Goal:** Fix R-LT-1 (missing `.transcript.` infix), implement the §5.2 tombstone-and-append in-place rewrite for `.segmentUpdated`, and add `TranscriptSidecarWriter.rotateSidecar(toAudioURL:)` (R-LT-5).

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Persistence/SidecarPathBuilder.swift`
- Modify: `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift`
- Modify: `Sources/MacrecCore/Transcription/Persistence/TXTTranscriptWriter.swift`
- Modify: `Sources/MacrecCore/Transcription/Persistence/SRTTranscriptWriter.swift`
- Modify: `Sources/MacrecCore/Transcription/Persistence/VTTTranscriptWriter.swift`
- Modify: `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift`
- Tests: `Tests/MacrecCoreTests/Transcription/Persistence/*` (modify existing + add new)

### Task F.1 — Fix SidecarPathBuilder

- [ ] Read `Sources/MacrecCore/Transcription/Persistence/SidecarPathBuilder.swift`.
- [ ] Locate the `sidecarURL(forRecording:format:)` function. Insert `"transcript"` into the components right before `format.rawValue`:
  - Current (buggy): `recording-XXX.<ext>`
  - Fixed: `recording-XXX.transcript.<ext>`
- [ ] Update `Tests/MacrecCoreTests/Transcription/Persistence/SidecarPathBuilderTests.swift` expected strings to include `.transcript.`.

### Task F.2 — Update TranscriptFormatWriter protocol

- [ ] Read `Sources/MacrecCore/Transcription/Persistence/TranscriptFormatWriter.swift`.
- [ ] Update the protocol surface to handle the new event shape (one method now needs to handle both create and update with id-keyed rewrite):

```swift
// Sources/MacrecCore/Transcription/Persistence/TranscriptFormatWriter.swift
import Foundation

protocol TranscriptFormatWriter: AnyObject {
    var url: URL { get }
    func appendSegment(_ segment: TranscriptSegment) throws
    func updateSegment(_ segment: TranscriptSegment) throws
    func close() throws
}
```

### Task F.3 — Implement JSONL with tombstone-and-append

- [ ] Replace `JSONLTranscriptWriter.swift` body:

```swift
// Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift
import Foundation

final class JSONLTranscriptWriter: TranscriptFormatWriter {
    let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    func appendSegment(_ segment: TranscriptSegment) throws {
        let line = try Self.encode(segment) + "\n"
        let bytes = Data(line.utf8)
        let start = try handle.offset()
        try handle.write(contentsOf: bytes)
        let end = try handle.offset()
        index[segment.id] = start..<end
    }

    func updateSegment(_ segment: TranscriptSegment) throws {
        guard let range = index[segment.id] else {
            try appendSegment(segment); return
        }
        let oldByteLen = Int(range.upperBound - range.lowerBound)
        let newLine = try Self.encode(segment) + "\n"
        let newBytes = Data(newLine.utf8)

        if newBytes.count <= oldByteLen {
            // Short-grow — pad with spaces (valid trailing whitespace in JSONL).
            var padded = Data(newLine.dropLast().utf8) // remove "\n"
            padded.append(Data(repeating: 0x20, count: oldByteLen - newBytes.count))
            padded.append(0x0A) // "\n"
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Long-grow — tombstone + append.
            let tombstoneObj = #"{"_tombstone":true,"id":"\#(segment.id.uuidString)"}"#
            var tomb = Data(tombstoneObj.utf8)
            if tomb.count + 1 < oldByteLen {
                tomb.append(Data(repeating: 0x20, count: oldByteLen - tomb.count - 1))
            }
            tomb.append(0x0A)
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: tomb)
            try handle.seekToEnd()
            let start = try handle.offset()
            try handle.write(contentsOf: newBytes)
            let end = try handle.offset()
            index[segment.id] = start..<end
        }
    }

    func close() throws {
        try handle.close()
    }

    private static func encode(_ s: TranscriptSegment) throws -> String {
        struct Wire: Encodable {
            let id: String
            let timestamp: String
            let source: String
            let text: String
            let model: String?
            let durationSec: Double?
        }
        let w = Wire(
            id: s.id.uuidString,
            timestamp: isoFormatter.string(from: s.timestamp),
            source: s.source.rawValue,
            text: s.text,
            model: s.model,
            durationSec: s.durationSec
        )
        return String(data: try JSONEncoder().encode(w), encoding: .utf8) ?? "{}"
    }
}
```

### Task F.4 — TXT writer

- [ ] Replace `TXTTranscriptWriter.swift` body using the same in-place rewrite pattern: tombstone is a single space-only line of matching length:

```swift
// Sources/MacrecCore/Transcription/Persistence/TXTTranscriptWriter.swift
import Foundation

final class TXTTranscriptWriter: TranscriptFormatWriter {
    let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    private func render(_ s: TranscriptSegment) -> String {
        "[\(Self.timeFormatter.string(from: s.timestamp))] \(s.source.rawValue): \(s.text)\n"
    }

    func appendSegment(_ segment: TranscriptSegment) throws {
        let bytes = Data(render(segment).utf8)
        let start = try handle.offset()
        try handle.write(contentsOf: bytes)
        let end = try handle.offset()
        index[segment.id] = start..<end
    }

    func updateSegment(_ segment: TranscriptSegment) throws {
        guard let range = index[segment.id] else { try appendSegment(segment); return }
        let oldLen = Int(range.upperBound - range.lowerBound)
        let newBytes = Data(render(segment).utf8)
        if newBytes.count <= oldLen {
            var padded = Data(render(segment).dropLast().utf8)
            padded.append(Data(repeating: 0x20, count: oldLen - newBytes.count))
            padded.append(0x0A)
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Tombstone = blank line of matching length.
            var tomb = Data(repeating: 0x20, count: oldLen - 1)
            tomb.append(0x0A)
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: tomb)
            try handle.seekToEnd()
            let start = try handle.offset()
            try handle.write(contentsOf: newBytes)
            let end = try handle.offset()
            index[segment.id] = start..<end
        }
    }

    func close() throws { try handle.close() }
}
```

### Task F.5 — SRT writer

- [ ] Read existing `SRTTranscriptWriter.swift` for the timestamp formatter.
- [ ] Replace body using the same pattern. SRT cue tombstone is a same-length cue with body `[updated]`:

```swift
// Sources/MacrecCore/Transcription/Persistence/SRTTranscriptWriter.swift
import Foundation

final class SRTTranscriptWriter: TranscriptFormatWriter {
    let url: URL
    private let handle: FileHandle
    private var index: [UUID: Range<UInt64>] = [:]
    private var sequenceCounter: Int = 0
    private var sequenceForId: [UUID: Int] = [:]
    private let sessionStart: Date

    init(url: URL, sessionStart: Date = Date()) throws {
        self.url = url
        self.sessionStart = sessionStart
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    private func render(seq: Int, _ s: TranscriptSegment) -> String {
        let start = s.timestamp.timeIntervalSince(sessionStart)
        let end = s.lastUpdated.timeIntervalSince(sessionStart)
        return "\(seq)\n\(srtTime(start)) --> \(srtTime(end))\n\(s.source.rawValue): \(s.text)\n\n"
    }

    private func srtTime(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let sec = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
    }

    func appendSegment(_ segment: TranscriptSegment) throws {
        sequenceCounter += 1
        sequenceForId[segment.id] = sequenceCounter
        let bytes = Data(render(seq: sequenceCounter, segment).utf8)
        let start = try handle.offset()
        try handle.write(contentsOf: bytes)
        let end = try handle.offset()
        index[segment.id] = start..<end
    }

    func updateSegment(_ segment: TranscriptSegment) throws {
        guard let range = index[segment.id], let seq = sequenceForId[segment.id] else {
            try appendSegment(segment); return
        }
        let oldLen = Int(range.upperBound - range.lowerBound)
        let newRendering = render(seq: seq, segment)
        let newBytes = Data(newRendering.utf8)
        if newBytes.count <= oldLen {
            var padded = Data(newRendering.dropLast(2).utf8) // drop "\n\n"
            padded.append(Data(repeating: 0x20, count: oldLen - newBytes.count))
            padded.append(contentsOf: [0x0A, 0x0A])
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: padded)
            try handle.seekToEnd()
        } else {
            // Tombstone the old cue with body "[updated]" padded to same length.
            let tombHead = "\(seq)\n\(srtTime(0)) --> \(srtTime(0))\n[updated]"
            var tomb = Data(tombHead.utf8)
            if tomb.count + 2 < oldLen {
                tomb.append(Data(repeating: 0x20, count: oldLen - tomb.count - 2))
            }
            tomb.append(contentsOf: [0x0A, 0x0A])
            try handle.seek(toOffset: range.lowerBound)
            try handle.write(contentsOf: tomb)
            try handle.seekToEnd()
            let start = try handle.offset()
            try handle.write(contentsOf: newBytes)
            let end = try handle.offset()
            index[segment.id] = start..<end
        }
    }

    func close() throws { try handle.close() }
}
```

### Task F.6 — VTT writer

- [ ] Mirror the SRT writer pattern; the only differences are the `WEBVTT\n\n` header on first write and the time format `HH:MM:SS.mmm` (period not comma). Replace `VTTTranscriptWriter.swift` body following the SRT pattern with the format adjustments. (Pattern identical to F.5; brevity here — engineer mirrors the same tombstone-and-append logic.)

### Task F.7 — TranscriptSidecarWriter — rotateSidecar surface

- [ ] Read existing `TranscriptSidecarWriter.swift` (an actor wrapping the per-format writers).
- [ ] Add a `write(_ event:)` method that dispatches based on the event case, and ensure `close()` is async-throws:

```swift
// Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift
// (replace public surface; inner per-format wiring kept)
public actor TranscriptSidecarWriter {
    public let audioURL: URL
    public let formats: Set<SidecarFormat>
    private var writers: [TranscriptFormatWriter]
    private let logger: Logger

    public init(audioURL: URL, formats: Set<SidecarFormat>, logger: Logger) throws {
        self.audioURL = audioURL
        self.formats = formats
        self.logger = logger
        self.writers = try formats.map { fmt in
            let url = SidecarPathBuilder.sidecarURL(forRecording: audioURL, format: fmt)
            switch fmt {
            case .jsonl: return try JSONLTranscriptWriter(url: url)
            case .txt:   return try TXTTranscriptWriter(url: url)
            case .srt:   return try SRTTranscriptWriter(url: url)
            case .vtt:   return try VTTTranscriptWriter(url: url)
            }
        }
    }

    public func write(_ event: TranscriptionEvent) async throws {
        switch event {
        case .segmentAppended(_, let seg):
            for w in writers { try w.appendSegment(seg) }
        case .segmentUpdated(_, let seg):
            for w in writers { try w.updateSegment(seg) }
        case .privacyDisclosure, .metricsTick, .error:
            return // these are not persisted
        }
    }

    public func close() async throws {
        for w in writers { try? w.close() }
        writers.removeAll()
    }
}
```

### Task F.8 — Sidecar tests

- [ ] Add `Tests/MacrecCoreTests/Transcription/Persistence/SidecarRewriteTests.swift`:

```swift
import Foundation
import Testing
@testable import MacrecCore

@Suite("Sidecar rewrite")
struct SidecarRewriteTests {

    private func tmpURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrec-sidecar-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test("JSONL: short-grow rewrite keeps file valid line-by-line")
    func jsonlShortGrow() throws {
        let url = tmpURL("test.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let id = UUID()
        let now = Date()
        let s1 = TranscriptSegment(id: id, timestamp: now, text: "this is a longer line", source: .mic)
        let s2 = TranscriptSegment(id: id, timestamp: now, lastUpdated: now, text: "short", source: .mic)
        try w.appendSegment(s1)
        try w.updateSegment(s2)
        try w.close()
        let txt = try String(contentsOf: url)
        let lines = txt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Each non-empty line must be valid JSON.
        for line in lines where !line.isEmpty {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "invalid JSON: \(line)")
        }
    }

    @Test("JSONL: long-grow rewrite emits tombstone + appended new line")
    func jsonlLongGrow() throws {
        let url = tmpURL("test.jsonl")
        let w = try JSONLTranscriptWriter(url: url)
        let id = UUID()
        let now = Date()
        let s1 = TranscriptSegment(id: id, timestamp: now, text: "x", source: .mic)
        let s2 = TranscriptSegment(id: id, timestamp: now, lastUpdated: now,
                                   text: String(repeating: "y", count: 200), source: .mic)
        try w.appendSegment(s1)
        try w.updateSegment(s2)
        try w.close()
        let txt = try String(contentsOf: url)
        #expect(txt.contains("_tombstone"))
        #expect(txt.contains(String(repeating: "y", count: 200)))
        let lines = txt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
    }
}
```

### Task F.9 — Phase F build check

- [ ] Run: `swift build --build-tests` → success on Persistence/Transcription targets.
- [ ] **Recommended commit point**: "feat(transcription): sidecar `.transcript.` infix + tombstone-and-append rewrite (plan-004 Phase F, fixes R-LT-1)".

---

## Phase G — Wiring: RecordingSession, ConfigResolver, MacrecError

**Goal:** Replace the Phase B/C/G plumbing in `RecordingSession`, `ConfigResolver`, and `MacrecError` with the new manager-based shape. Lifts the detach restriction (closes R-LT-2).

**Files:**
- Modify: `Sources/MacrecCore/Errors/MacrecError.swift`
- Modify: `Sources/MacrecCore/Config/ConfigResolver.swift`
- Modify: `Sources/MacrecCore/Config/RecordingOptions.swift`
- Modify: `Sources/MacrecCore/RecordingSession.swift`
- Tests: `Tests/MacrecCoreTests/MacrecErrorTranscriptionTests.swift`, `Tests/MacrecCoreTests/Config/*`

### Task G.1 — Update MacrecError

- [ ] Read existing file. Locate `transcriptionDetachUnsupported`, `transcriptionWebSocketFailed`.
- [ ] **Remove** `transcriptionDetachUnsupported` case.
- [ ] **Rename** `transcriptionWebSocketFailed(detail: String)` → `transcriptionProviderFailed(detail: String)`. Update `errorDescription` and `remediation` accordingly:

```swift
case transcriptionProviderFailed(detail: String)
// ...
case .transcriptionProviderFailed(let detail):
    return "transcription provider failed: \(detail)"
```

- [ ] Update or remove `Tests/MacrecCoreTests/MacrecErrorTranscriptionTests.swift` assertions about `transcriptionDetachUnsupported` (the case is gone) and rename `WebSocketFailed` → `ProviderFailed`.

### Task G.2 — Update ConfigResolver

- [ ] Read existing file. Locate the (R-LT-2) cross-check that was meant to enforce detach + transcribe rejection — confirm it never landed (per R-LT-2). If it exists, remove it. If not, just confirm.
- [ ] Locate the provider value normalisation. Add `gemini-live` deprecation alias:

```swift
let normalizedProvider: String? = {
    guard let raw = rawProviderValue?.lowercased() else { return nil }
    if raw == "gemini-live" {
        logger.notice("MACREC_TRANSCRIBE=gemini-live is deprecated; resolving to 'gemini'.")
        return "gemini"
    }
    return raw
}()
```

- [ ] Validate `normalizedProvider` against `["none", "gemini"]` only; anything else → `MacrecError.transcriptionInvalidConfigValue(field: "transcribe", value: ...)`.

### Task G.3 — Update RecordingOptions

- [ ] Read `Sources/MacrecCore/Config/RecordingOptions.swift`. Locate the transcription block.
- [ ] **Drop** any `sessionResumption` / `slidingWindow` / `partialFinalDistinction` fields (they were planned but never used).
- [ ] **Add** `tagSpeakers: Bool` defaulting to `source == .both`.
- [ ] Update the comment block that documented the (deferred-to-driver-init) `transcriptionApiKeyMissing` deferral (R-LT-3) — the new resolver still defers this; that's intentional. Keep the comment but update its phase reference to plan-004.

### Task G.4 — Update RecordingSession.setUpTranscriptionPipelineIfNeeded

- [ ] Read the existing function (around line 980).
- [ ] Replace its body:

```swift
private func setUpTranscriptionPipelineIfNeeded() async throws {
    let providerId = options.transcriptionProviderId ?? "none"
    guard providerId != "none" else { return }

    let providerLogger = LoggerFactory.make("macrec.transcription.provider")
    let provider: any TranscriptionProvider
    if let factory = transcriptionProviderFactory {
        // test injection
        provider = try factory(...)
    } else {
        provider = try TranscriptionProviderFactory.build(.init(
            providerId: providerId,
            apiKey: options.transcriptionApiKey,
            modelId: options.transcriptionModelId,
            languageHint: options.transcriptionLanguageHint,
            logger: providerLogger,
            keyExpiresAt: options.transcriptionKeyExpiresAt
        ))
    }

    let downsampler = try AudioDownsampler.from(captureFormat: aligner.captureFormat)
    let sidecar = try TranscriptSidecarWriter(
        audioURL: options.outputURL,
        formats: Set(options.transcriptionSidecarFormats),
        logger: LoggerFactory.make("macrec.transcription.sidecar")
    )

    let manager = TranscriptionManager(
        provider: provider,
        source: options.transcriptionSource,
        options: TranscriptionOptions(...),
        downsampler: downsampler,
        sidecarWriter: sidecar,
        logger: LoggerFactory.make("macrec.transcription.manager")
    )
    self._transcriptionManager = manager

    // Forwarder: pump manager events into the public _transcriptEventsContinuation.
    let stream = await manager.start()
    self._transcriptionForwarderTask = Task { [weak self] in
        for await event in stream {
            self?._transcriptEventsContinuation.yield(event)
        }
    }

    // Install the audio tap.
    let tapToken = aligner.installTap { [weak self] frame, tag in
        Task { await self?._transcriptionManager?.ingestFrame(frame, from: tag) }
    }
    self._transcriptionTapToken = tapToken
}
```

- [ ] Replace `_transcriptionDriver` field with `_transcriptionManager: TranscriptionManager?`.
- [ ] In `split(nextOutput:)`, after the recorder rotation, add:
  ```swift
  if let mgr = _transcriptionManager {
      try await mgr.rotateSidecar(toAudioURL: nextOutput)
  }
  ```
  This closes R-LT-5.
- [ ] In the teardown path, replace `await _transcriptionDriver?.stop()` with `await _transcriptionManager?.stop()`.

### Task G.5 — Phase G build check

- [ ] Run: `swift build` → expect remaining errors only at deletion targets in Phase I (`TranscriptionDriver.swift`, `GeminiLiveTranscriptionProvider.swift`, `Networking/`).
- [ ] **Recommended commit point**: "feat(transcription): wire RecordingSession + resolver + errors to TranscriptionManager (plan-004 Phase G, lifts detach R-LT-2)".

---

## Phase H — UI integration

**Goal:** Update `RecordingController`, `SessionCoordinator`, the inline transcript views, and the `ControlBar` picker label to consume the new event shape.

**Files:**
- Modify: `Sources/MacrecUIKit/RecordingController.swift`
- Modify: `Sources/MacrecUIKit/SessionCoordinator.swift`
- Modify: `Sources/MacrecUIKit/SessionCoordinatorEvent.swift`
- Modify: `Sources/macrec-ui/Views/Transcription/*` (all files)
- Modify: `Sources/macrec-ui/Views/ControlBar.swift`

### Task H.1 — RecordingController event mapping

- [ ] Read `Sources/MacrecUIKit/RecordingController.swift`.
- [ ] Find the `for await event in session.transcriptEvents` loop (or equivalent forwarding).
- [ ] Replace the partial/final dispatch with appended/updated:

```swift
for await event in session.transcriptEvents {
    switch event {
    case .segmentAppended(let idx, let seg):
        await MainActor.run { self.transcriptModel.append(idx: idx, segment: seg) }
    case .segmentUpdated(let idx, let seg):
        await MainActor.run { self.transcriptModel.update(idx: idx, segment: seg) }
    case .privacyDisclosure(let providerName):
        await MainActor.run { self.transcriptModel.showPrivacyDisclosure(providerName: providerName) }
    case .metricsTick(let m):
        await MainActor.run { self.transcriptModel.metrics = m }
    case .error(let detail):
        await MainActor.run { self.transcriptModel.lastError = detail }
    }
}
```

### Task H.2 — Update transcript view model

- [ ] In whichever file holds the inline-panel `ObservableObject` (e.g. `Sources/macrec-ui/Views/Transcription/TranscriptModel.swift`), update its API to provide `append(idx:segment:)` and `update(idx:segment:)` methods that maintain a `[TranscriptSegment]` array and trigger SwiftUI redraw.

### Task H.3 — SessionCoordinator metrics surface

- [ ] Read `Sources/MacrecUIKit/SessionCoordinatorEvent.swift`.
- [ ] If `SessionCoordinatorEvent` had `transcriptionFirstTokenLatency` / `transcriptionResumptionCount` events from plan-003, replace with `transcriptionMetrics(metrics: TranscriptionMetrics)`.
- [ ] Update `SessionCoordinator.swift` to forward the manager's `metricsTick` events as `transcriptionMetrics`.

### Task H.4 — ControlBar picker label

- [ ] Read `Sources/macrec-ui/Views/ControlBar.swift`.
- [ ] Locate the transcription provider picker. Change the option label `"Gemini Live"` → `"Gemini"`. The underlying `@AppStorage("com.macrec.ui.transcribeProvider")` value should be `"gemini"`. If a previous user had `"gemini-live"` stored, the resolver's deprecation alias (Task G.2) handles it.

### Task H.5 — Phase H build check

- [ ] Run: `swift build --product macrec-ui` → success.
- [ ] Run: `swift build --product macrec` → success.
- [ ] **Recommended commit point**: "feat(transcription/ui): consume segmentAppended/Updated events; rename picker (plan-004 Phase H)".

---

## Phase I — Old code deletion

**Goal:** Remove the WebSocket-era code that is now unreferenced. After Phase G compiles cleanly the deletion is safe.

**Files (to delete):**
- `Sources/MacrecCore/Transcription/Networking/` (entire folder)
- `Sources/MacrecCore/Transcription/Providers/GeminiLiveTranscriptionProvider.swift`
- `Sources/MacrecCore/Transcription/Providers/GeminiWireSchema.swift`
- `Sources/MacrecCore/Transcription/TranscriptionDriver.swift`
- `Tests/MacrecCoreTests/Transcription/Networking/` (entire folder)
- `Tests/MacrecCoreTests/Transcription/TranscriptionDriverTests.swift`

### Task I.1 — Delete unreferenced source files

- [ ] Run: `rm -rf Sources/MacrecCore/Transcription/Networking/`
- [ ] Run: `rm Sources/MacrecCore/Transcription/Providers/GeminiLiveTranscriptionProvider.swift`
- [ ] Run: `rm Sources/MacrecCore/Transcription/Providers/GeminiWireSchema.swift`
- [ ] Run: `rm Sources/MacrecCore/Transcription/TranscriptionDriver.swift`

### Task I.2 — Delete unreferenced test files

- [ ] Run: `rm -rf Tests/MacrecCoreTests/Transcription/Networking/`
- [ ] Run: `rm Tests/MacrecCoreTests/Transcription/TranscriptionDriverTests.swift`

### Task I.3 — Trim AudioDownsampler micro-chunking helper

- [ ] Read `Sources/MacrecCore/Transcription/AudioDownsampler.swift`.
- [ ] Find any `chunk30ms` / `splitIntoChunks` helper added by plan-003. **Delete it** if present. Keep only the 48 kHz Float32 → 16 kHz Float32 conversion path.
- [ ] If a `from(captureFormat:)` factory exists, keep it. If not, ensure the manager's call site in Task G.4 builds.

### Task I.4 — Trim TranscriptionOptions

- [ ] Read `Sources/MacrecCore/Transcription/TranscriptionOptions.swift`.
- [ ] Drop fields:
  - `sessionResumption`, `slidingWindow`, `inputAudioTranscription`, `responseModalities`, `wireProtocolVersion` — anything Live-API-shaped.
- [ ] Add field: `var sidecarFormats: Set<SidecarFormat>` and `var languageHint: String?` if not already present.
- [ ] Verify the `.disabled` static factory and the `withProvider(id:)` helper exist; add if missing.

### Task I.5 — Build verification

- [ ] Run: `swift build` → MUST succeed.
- [ ] Run: `swift build --build-tests` → MUST succeed.
- [ ] Run: `swift build -c release` → MUST succeed (catches release-only diagnostics).
- [ ] **Recommended commit point**: "chore(transcription): delete WebSocket-era code (plan-004 Phase I)".

---

## Phase J — E2E scripts + documentation

**Goal:** Provide runnable E2E scripts that replace LT-PEND-1's manual procedure, and refresh the user-facing docs.

**Files:**
- Create: `test_scripts/e2e-transcription-noop.sh` (rewrite if exists)
- Create: `test_scripts/e2e-transcription-gemini.sh`
- Create: `test_scripts/e2e-transcription-detach.sh`
- Create: `test_scripts/e2e-transcription-key-missing.sh`
- Create: `test_scripts/fixtures/known-phrase.wav` (generated from `say` or `afplay` source)
- Modify: `docs/tools/macrec.md`
- Modify: `docs/tools/macrec-ui.md`
- Modify: `Issues - Pending Items.md` (move resolved items to Completed)

### Task J.1 — e2e-transcription-noop.sh

- [ ] Write the script:

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-noop.sh
# Regression: --transcribe none produces no sidecar.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/rec.m4a"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

"$ROOT/.build/release/macrec" start \
    --output "$OUT" --format m4a --layout mixed \
    --max-duration 3s --transcribe none

[ -s "$OUT" ] || { echo "FAIL: audio empty"; exit 1; }
shopt -s nullglob
sidecars=("$(dirname "$OUT")"/*.transcript.*)
[ ${#sidecars[@]} -eq 0 ] || { echo "FAIL: unexpected sidecar(s): ${sidecars[*]}"; exit 1; }
echo "PASS: e2e-transcription-noop"
```

- [ ] Run: `chmod +x test_scripts/e2e-transcription-noop.sh`

### Task J.2 — e2e-transcription-gemini.sh

- [ ] Write the script:

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-gemini.sh
# Happy path with a real GOOGLE_API_KEY. Plays a known phrase as system audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${GOOGLE_API_KEY:?GOOGLE_API_KEY must be set}"

PHRASE="The quick brown fox jumps over the lazy dog"
OUT="$(mktemp -d)/rec.m4a"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

# Generate the fixture phrase via macOS `say` if not present.
FIXTURE="$ROOT/test_scripts/fixtures/known-phrase.aiff"
mkdir -p "$(dirname "$FIXTURE")"
[ -f "$FIXTURE" ] || say "$PHRASE" -o "$FIXTURE" --data-format=LEI16@44100

# Play it as system audio for the duration of the recording.
afplay "$FIXTURE" &
AFPLAY_PID=$!

"$ROOT/.build/release/macrec" start \
    --output "$OUT" --format m4a --layout mixed \
    --max-duration 12s \
    --transcribe gemini --transcribe-source mixed --transcript-format jsonl

wait "$AFPLAY_PID" 2>/dev/null || true

[ -s "$OUT" ] || { echo "FAIL: audio empty"; exit 1; }
SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "$SIDECAR" ] || { echo "FAIL: sidecar missing or empty at $SIDECAR"; exit 1; }
N_LINES=$(grep -v '_tombstone' "$SIDECAR" | wc -l | tr -d ' ')
[ "$N_LINES" -ge 1 ] || { echo "FAIL: zero non-tombstone lines in sidecar"; exit 1; }

# Fuzzy match: at least 3 of the phrase's words appear (case-insensitive) in any segment.
TEXT=$(jq -r 'select(._tombstone != true) | .text' "$SIDECAR" 2>/dev/null | tr '[:upper:]' '[:lower:]')
HITS=0
for w in quick brown fox jumps lazy dog; do
    grep -q -F "$w" <<<"$TEXT" && HITS=$((HITS+1))
done
[ "$HITS" -ge 3 ] || { echo "FAIL: fewer than 3 keyword hits in '$TEXT'"; exit 1; }

echo "PASS: e2e-transcription-gemini ($N_LINES segments, $HITS keyword hits)"
```

- [ ] Run: `chmod +x test_scripts/e2e-transcription-gemini.sh`

### Task J.3 — e2e-transcription-detach.sh

- [ ] Write a shorter variant that runs with `--detach` and asserts the sidecar lands. Same audio fixture, asserts exit 0 (proving R-LT-2 lift):

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-detach.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${GOOGLE_API_KEY:?GOOGLE_API_KEY must be set}"
OUT="$(mktemp -d)/rec.m4a"
trap 'rm -rf "$(dirname "$OUT")"; "$ROOT/.build/release/macrec" stop --output "$OUT" 2>/dev/null || true' EXIT

FIXTURE="$ROOT/test_scripts/fixtures/known-phrase.aiff"
[ -f "$FIXTURE" ] || say "Hello world" -o "$FIXTURE" --data-format=LEI16@44100
afplay "$FIXTURE" &

"$ROOT/.build/release/macrec" start \
    --output "$OUT" --format m4a --layout mixed --detach \
    --max-duration 8s --transcribe gemini

# Wait for the recording to complete on its own.
sleep 10

[ -s "$OUT" ] || { echo "FAIL: detach audio empty"; exit 1; }
SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "$SIDECAR" ] || { echo "FAIL: detach sidecar missing"; exit 1; }
echo "PASS: e2e-transcription-detach"
```

### Task J.4 — e2e-transcription-key-missing.sh

```bash
#!/usr/bin/env bash
# test_scripts/e2e-transcription-key-missing.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/rec.m4a"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

unset GOOGLE_API_KEY
set +e
"$ROOT/.build/release/macrec" start \
    --output "$OUT" --format m4a --layout mixed \
    --max-duration 3s --transcribe gemini
RC=$?
set -e

[ "$RC" -eq 78 ] || { echo "FAIL: expected exit 78 (EX_CONFIG), got $RC"; exit 1; }
[ ! -e "$OUT" ] || { echo "FAIL: audio file should not exist"; exit 1; }
echo "PASS: e2e-transcription-key-missing"
```

### Task J.5 — Refresh docs/tools/macrec.md

- [ ] In the `<macrec>` XML block of `docs/tools/macrec.md`:
  - Update `<command>` examples to use `--transcribe gemini` (drop `gemini-live`).
  - Add a "Bandwidth" subsection per §9.2 of Part 1.
  - Remove the "Detach mode incompatible with --transcribe" limitation; note the lift.
  - Add a "Model id" subsection that documents `MACREC_TRANSCRIBE_MODEL` defaults and the `gemini-3-flash-preview` fallback per §9.1.

### Task J.6 — Refresh docs/tools/macrec-ui.md

- [ ] Update the picker option label `"Gemini Live"` → `"Gemini"` in the documented screenshot or ASCII representation.
- [ ] Replace any "session resumption" / "first token latency" mentions with "chunks sent / billable seconds / last RTT" terminology.

### Task J.7 — Move resolved items in Issues - Pending Items.md

- [ ] Move LT-PEND-1, LT-PEND-2, R-LT-1, R-LT-2, R-LT-4, R-LT-5 from Pending to Completed, each with a "(Resolved by plan-004 Phase X, 2026-04-28)" footer per the phase mappings:
  - **LT-PEND-1** — Resolved by Phase J.2 (e2e-transcription-gemini.sh replaces the manual procedure).
  - **LT-PEND-2** — Resolved by Phase E (per-source buffers + parallel REST calls).
  - **R-LT-1** — Resolved by Phase F.1 (`.transcript.` infix added to SidecarPathBuilder).
  - **R-LT-2** — Resolved by Phase G.1 (`transcriptionDetachUnsupported` removed; detach + transcribe valid).
  - **R-LT-4** — Resolved by removal (header/footer not needed in REST architecture; see plan-004 §10).
  - **R-LT-5** — Resolved by Phase G.4 (`split(nextOutput:)` calls `manager.rotateSidecar`).
- [ ] Leave PEND-LT-6 (the model-id risk added in Task 0.6) in Pending until the first real-key e2e run.

### Task J.8 — Final build + smoke

- [ ] Run: `swift build -c release` → success.
- [ ] Run: `bash test_scripts/e2e-transcription-noop.sh` → expect `PASS`.
- [ ] Run: `bash test_scripts/e2e-transcription-key-missing.sh` → expect `PASS`.
- [ ] If `GOOGLE_API_KEY` is set: run `bash test_scripts/e2e-transcription-gemini.sh`. **If this fails with HTTP 4xx**, set `MACREC_TRANSCRIBE_MODEL=gemini-3-flash-preview` and re-run. If it now passes, file PEND-LT-6 closure (move to Completed) AND change the default in `Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift` from `gemini-3.1-flash-live-preview` to `gemini-3-flash-preview` per the user's documented fallback agreement.
- [ ] **Recommended commit point**: "test(transcription): e2e scripts + doc refresh (plan-004 Phase J)".

---

## Self-Review

**1. Spec coverage** — every section of Part 1 maps to a phase:
- §3.1 (deletions) → Phase I
- §3.2 (additions) → Phases A/B/D/E
- §3.3 (edits) → Phases A/C/F/G/H, with docs in Phase 0/J
- §4 (component contracts) → Phases A/B/C/D/E
- §5 (data flow) → Phase E + Phase F (sidecar in-place rewrite §5.2)
- §6 (configuration) → Phase G.2 (resolver) + Phase D.5 (factory)
- §7 (error model + lifecycle) → Phase G.1 (errors) + Phase E (lifecycle)
- §8 (testing) → tests scattered across A/B/C/D/E/F + Phase J for E2E
- §9.1 (model id risk) → Tasks 0.6, D.5, J.8 with explicit fallback path

**2. Placeholder scan** — none. Every task has either complete code or
exact bash. The single `// (replace public surface; inner per-format
wiring kept)` comment in F.7 references a real existing file the
engineer must read first; the code shown IS the new public surface.

**3. Type consistency** — `TranscriptionEvent` (Phase A.5) is used by
`TranscriptionManager` (E.1), `TranscriptSidecarWriter` (F.7),
`RecordingController` (H.1) consistently. `TranscriptSegment` (A.1)
flows through coalescer (A.4) → manager (E.1) → sidecar (F.3-F.6) →
view model (H.2). `TranscriptionMetrics` defined in A.5, populated in
E.1, consumed in H.3.

**4. Scope check** — focused on transcription only; capture/aligning/
encoding/permissions explicitly untouched. Single-implementation-plan
sized.

---

## Execution Handoff

Plan complete and appended to
`docs/design/plan-004-rest-batch-transcription.md`. Two execution
options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per
task, review between tasks, fast iteration. Best when you want to
keep this main session's context window clean for the high-level
review checkpoints.

**2. Inline Execution** — Execute tasks in this session using the
`executing-plans` skill, batch execution with checkpoints for review.
Best when you want to watch each step happen and intervene quickly.

Which approach?
