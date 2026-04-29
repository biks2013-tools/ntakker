---
investigation_for: refined-request-live-transcription.md
codebase_scan: codebase-scan-live-transcription.md
investigated_at: "2026-04-26"
language: swift
target_platform: macOS 14+
---

# Investigation: Live Transcription Side-Channel for `macrec` / `macrec-ui`

## Executive Summary

The user's stated preference — "Gemini 3.1 Live" — resolves to the real, currently-published model id **`gemini-3.1-flash-live-preview`**, released by Google on March 26, 2026 and the recommended successor to `gemini-live-2.5-flash-native-audio`. The Live API is a stateful WebSocket protocol over `wss://` that accepts raw 16-bit PCM at 16 kHz mono and emits `BidiGenerateContentServerMessage` JSON frames with `serverContent.inputTranscription.text` fragments. A native Swift client built on `URLSessionWebSocketTask` is feasible, well-documented, and has at least one community Swift package (`paradigms-of-intelligence/swift-gemini-api`) and one production transport (`pipecat-client-ios-gemini-live-websocket`) that prove the pattern. **No SDK is required**; the protocol is documented JSON-over-WebSocket and the project's "no-new-dependency" preference can be honored.

The recommended architecture taps the audio stream at **`HostClockAligner.onAlignedFrame`** (the codebase scan's preferred tap point) for `mixed`/`system`/`mic` source modes, downsamples Float32-48k-stereo to PCM16-16k-mono via a dedicated `AVAudioConverter`, and feeds it through a bounded `AsyncStream<TranscriptionPCMChunk>` with `.bufferingNewest(N)` into a provider conforming to a new `TranscriptionProvider` Swift protocol. The first concrete implementation is `GeminiLiveTranscriptionProvider`; a `NoOpTranscriptionProvider` services the `None` UI choice. The protocol is shaped so OpenAI Realtime, Deepgram Streaming, and AssemblyAI Universal-Streaming can be added later as drop-in providers — they all use WebSocket + PCM16 with only minor format/auth differences.

The transcription path is fully isolated from the recording path (FR-44, NFR-17): a hang or crash in the WebSocket task cannot back-pressure the capture queues, because the tap copies frames into the bounded queue and returns immediately, and the queue's drop-newest policy guarantees zero blocking even when the consumer stalls. Cost is negligible: Gemini 3.1 Flash Live is currently free-of-charge on the AI Studio free tier and ~$0.005/minute on the paid tier.

**Go.** No blockers identified. Proceed to the planner phase with Gemini 3.1 Flash Live as the v1 provider, behind a `TranscriptionProvider` protocol that admits at minimum three future providers without any orchestration-code changes.

## Context

- **What was investigated**: The feasibility, technical shape, and cost of adding a parallel live-transcription side-channel to `macrec`/`macrec-ui` using Google Gemini Live and a provider-agnostic Swift abstraction; alternative providers (OpenAI Realtime, Deepgram Streaming, AssemblyAI Universal-Streaming) for protocol-design validation; on-device alternatives (Apple Speech, WhisperKit) for documenting why they're out of scope.
- **Key constraints**: Swift-only (per CLAUDE.md Exception 001), `AsyncStream` exclusively (no Combine), zero existing networking code, must not affect on-disk recording integrity (NFR-17), default UI choice is `None`, must be provider-agnostic, audio coming out of `HostClockAligner` is Float32 / 48 kHz / mono-or-stereo, target APIs want PCM16 / 16 kHz / mono.
- **Refined request**: [docs/design/refined-request-live-transcription.md](../design/refined-request-live-transcription.md)
- **Codebase scan**: [docs/reference/codebase-scan-live-transcription.md](codebase-scan-live-transcription.md)

## Options Identified

### Option 1: Gemini Live API via direct `URLSessionWebSocketTask` — RECOMMENDED for v1

- **Description**: Open a `wss://` WebSocket to the Gemini Live API endpoint, send a `BidiGenerateContentSetup` message containing model id `gemini-3.1-flash-live-preview` plus `inputAudioTranscription: {}`, then stream base64-encoded PCM16/16kHz/mono blobs as `BidiGenerateContentRealtimeInput` frames at 20–40 ms cadence. Receive `BidiGenerateContentServerMessage` JSON frames whose `serverContent.inputTranscription.text` field carries incremental transcript fragments. Authenticate with a `GOOGLE_API_KEY` (vendor-canonical name) header for v1; ephemeral tokens are recommended for production but are out-of-scope for a single-user macOS desktop tool.
- **Strengths**:
  - Officially documented, currently active, vendor-canonical model.
  - Best-in-class audio model per Google ("highest-quality audio and speech model to date").
  - Cheap: free tier exists for `gemini-3.1-flash-live-preview` as of March 2026; paid is ~$0.005/min input, $3.00 per 1M audio tokens.
  - JSON-over-WebSocket protocol — no gRPC, no proto compiler, no SwiftPM dependency.
  - User's explicitly preferred provider ("My preference is Gemini 3.1 Live").
  - Two reference Swift implementations exist (`paradigms-of-intelligence/swift-gemini-api`, Pipecat iOS) to crib protocol details from without taking a dep.
- **Weaknesses**:
  - **Preview status** (`gemini-3.1-flash-live-preview`). Google explicitly says preview models can change in backwards-incompatible ways. Mitigation: pin the model id in `RecordingOptions`, expose it as a config var, and document the deprecation path in the configuration guide.
  - **Audio-only sessions are capped at 15 minutes**, requiring transparent reconnection for long meetings (FR-56 already requires this).
  - Partial-vs-final semantics are *implicit*: there is no `isFinal` flag on `inputTranscription`. Finality is inferred from sibling `turnComplete` / `generationComplete` events on the same `serverContent` — the provider implementation must reconstruct partial/final boundaries by buffering text fragments and committing on those signals.
  - **Native audio model behavior**: Gemini 3.1 Flash Live is a *conversational* model, not a pure ASR engine. It expects a "conversation" semantic and may infer that the user wants an audio response. The setup must explicitly request `responseModalities: ["TEXT"]` (or omit and rely on `inputTranscription` only) and use a system instruction like "Transcribe verbatim. Do not respond, do not summarize, do not converse." This is a known pattern but the v1 build must validate empirically.
- **Effort/Complexity**: Medium. JSON encoding/decoding via `Codable`, `URLSessionWebSocketTask` send/receive loops, base64 PCM blob framing, partial/final reconstruction logic. ~600–900 LoC for the provider.
- **Risk**: Medium. The preview-status risk and the conversational-vs-ASR semantic mismatch are the two primary risks. Both are manageable.
- **Best suited when**: The user explicitly named Gemini and wants the cheapest viable path with the highest-quality model. This is our base case.

### Option 2: Gemini Live API via Firebase AI Logic Swift SDK (or `swift-gemini-api`)

- **Description**: Add a SwiftPM dependency on either Firebase AI Logic (official, preview) or `paradigms-of-intelligence/swift-gemini-api` (community) and consume their already-implemented Live transport.
- **Strengths**:
  - Less code to write and maintain.
  - SDK handles protocol drift if Google changes the wire format.
  - `swift-gemini-api` exposes a clean `LiveSession` API with audio in/out streams.
- **Weaknesses**:
  - **Adds a dependency**. The project's locked stack today is just `swift-argument-parser` and `swift-log`; adding Firebase pulls in Firebase Core, Firestore stubs, and a substantial transitive graph. `swift-gemini-api` is ~1 dep but is community-maintained ("not an officially supported Google product").
  - **Firebase requires a Firebase project setup**; that's user-hostile for a small CLI tool.
  - SDK has its own auth model (Firebase tokens), which clashes with the project's four-tier env-var resolution.
  - Both SDKs are Live-API-specific and would have to be ripped out when adding OpenAI/Deepgram/AssemblyAI providers — i.e., zero leverage for the provider abstraction.
- **Effort/Complexity**: Low for Gemini-only. High when later providers are added (each one keeps its own SDK, the codebase ends up with 4 transport stacks).
- **Risk**: Medium-high (vendor lock-in via SDK choice; Firebase preview status is not subject to SLA per the docs).
- **Best suited when**: The project is Gemini-exclusive and wants to off-load protocol maintenance. Not our case.

### Option 3: OpenAI Realtime API (`gpt-realtime` / `gpt-4o-realtime-preview`) as the default provider

- **Description**: Same WebSocket pattern, but to `wss://api.openai.com/v1/realtime?model=gpt-realtime` with `Authorization: Bearer $OPENAI_API_KEY` and `OpenAI-Beta: realtime=v1` headers. PCM16 at 24 kHz mono, base64-encoded inside `input_audio_buffer.append` events.
- **Strengths**:
  - **GA, not preview**: `gpt-realtime` went GA with stable pricing.
  - Sample rate is 24 kHz (still requires downsampling from 48k but a different ratio).
  - Strong VAD and turn-taking out of the box.
  - More mature partial/final semantics than Gemini Live (explicit `response.audio_transcript.delta` and `.done` events).
- **Weaknesses**:
  - **20–60× more expensive**: $32 per 1M audio input tokens (~$0.06/min) versus Gemini's $3 per 1M (~$0.005/min). For an 8-hour meeting that's ~$28.80 vs. $2.40.
  - User explicitly preferred Gemini; this is a fallback / additional-provider option, not the v1 default.
  - Same conversational-model issue as Gemini: it's voice-to-voice, not pure ASR; system prompt must constrain to transcription.
- **Effort/Complexity**: Medium (same shape as Option 1, different JSON schema).
- **Risk**: Low (GA, well-documented).
- **Best suited when**: User wants OpenAI specifically, or wants better diarization/VAD than Gemini surfaces. **Recommended as the second provider** added once the protocol abstraction is proven.

### Option 4: Deepgram Streaming (`nova-3`) as a provider

- **Description**: WebSocket at `wss://api.deepgram.com/v1/listen?…` with `Authorization: Token $DEEPGRAM_API_KEY`. Pure ASR (not a chatbot). Accepts a wide range of formats including PCM16 at any sample rate (declared in query params).
- **Strengths**:
  - **Cheapest professional ASR**: $0.0077/min ($0.46/hr) on streaming.
  - **Pure transcription model** — no system-prompt gymnastics needed; it's literally an ASR API.
  - Built-in speaker diarization (a future enhancement).
  - Sub-300 ms latency.
  - Explicit `is_final` and `speech_final` flags on every result — partial/final mapping is trivial.
  - **Billed per second**, not rounded up.
- **Weaknesses**:
  - Adds a third API key the user has to manage.
  - Less "intelligent" than LLM-based transcription (no inferred punctuation cleanup, no semantic correction).
  - User did not request it.
- **Effort/Complexity**: Low (simplest of the four wire protocols).
- **Risk**: Low.
- **Best suited when**: Cost is paramount, or the user wants speaker diarization. **Recommended as the third provider** to add.

### Option 5: AssemblyAI Universal-Streaming as a provider

- **Description**: WebSocket at `wss://streaming.assemblyai.com/v3/ws`. Send 50–1000 ms PCM16 chunks; receive `Begin` / `Turn` events with immutable transcripts (no revision after emission).
- **Strengths**:
  - $0.15/hr ($0.0025/min) — cheapest of all four cloud options.
  - Immutable transcripts simplify UI: every emission is a "final"; no partial-replacement logic.
  - 333 free hours.
  - Session-based billing on connection-open time (so we close cleanly on stop).
- **Weaknesses**:
  - Less feature-rich than Gemini/OpenAI (pure transcription, no LLM cleanup).
  - Session-based billing means *idle* time on an open WebSocket is billed.
  - English-default; multilingual is a separate model parameter.
- **Effort/Complexity**: Low.
- **Risk**: Low.
- **Best suited when**: A second cheap-and-simple provider is wanted.

### Option 6: On-device transcription (Apple `SFSpeechRecognizer` / WhisperKit) — OUT OF SCOPE per refined request

- **Description**: Use Apple's built-in Speech framework or WhisperKit (the macOS port of OpenAI Whisper running locally) to transcribe without network.
- **Strengths**: Zero network, zero per-minute cost, works offline, no privacy disclosure needed.
- **Weaknesses**:
  - Refined request §Out of Scope explicitly excludes: *"On-device / offline transcription… The objective is explicit: 'send the same voice stream to a fast LLM'"*.
  - `SFSpeechRecognizer` historically caps at 1 minute per request and routes to Apple servers for the highest-quality model anyway.
  - WhisperKit requires bundling a multi-GB model.
- **Verdict**: Documented here for completeness only. Not implemented in v1. Documented as a v2 follow-up in `Issues - Pending Items.md`.

## Comparison Matrix

| Criterion | 1. Gemini Live (direct WS) | 2. Gemini Live (SDK) | 3. OpenAI Realtime | 4. Deepgram | 5. AssemblyAI |
|---|---|---|---|---|---|
| User-stated preference | Yes (primary) | Yes (primary) | No | No | No |
| Stable / GA | Preview | Preview | GA | GA | GA |
| Cost / hr (paid tier, audio in only) | ~$0.30 ($0.005/min) | ~$0.30 | ~$3.60 ($0.06/min) | $0.46 ($0.0077/min) | $0.15 ($0.0025/min) |
| Free tier | Yes (free of charge in AI Studio) | Yes (Firebase tier) | No | $200 credit | 333 free hours |
| Audio input format | PCM16 / 16 kHz / mono | PCM16 / 16 kHz / mono | PCM16 / 24 kHz / mono | PCM16 / any rate | PCM16 / 16 kHz / mono |
| Transport | WebSocket (JSON) | WebSocket via SDK | WebSocket (JSON) | WebSocket (JSON) | WebSocket (JSON) |
| Partial/final semantics | Implicit (`turnComplete` boundary) | Wrapped by SDK | Explicit (`delta` + `done` events) | Explicit (`is_final`, `speech_final`) | Immutable finals only |
| Max session length | 15 min (audio-only) | 15 min | unbounded (per-token budget) | unbounded | 3 hr auto-close |
| Adds SwiftPM dependency | No | Yes (heavy: Firebase) | No | No | No |
| Authentication | API key header | Firebase token | API key header | API key header | API key header |
| Native Swift example available | Yes (`swift-gemini-api`) | Yes (Firebase quickstart) | Community | Community | Community |
| Speaker diarization | No (out of scope v1) | No | No (basic VAD only) | Yes (built-in) | Yes (paid tier) |
| Risk for v1 | Medium (preview status) | Medium-high (SDK lock-in) | Low | Low | Low |
| Fits provider-agnostic protocol | Yes | No (SDK constrains shape) | Yes | Yes | Yes |
| Long-term viability | High (Google flagship audio model) | Medium (SDK preview) | High | High | High |

## Recommendation

### Primary recommendation: Option 1 (Gemini Live via direct `URLSessionWebSocketTask`) for v1.

**Concrete decisions to lock in:**

1. **Model id**: `gemini-3.1-flash-live-preview` — pinned in `RecordingOptions.transcriptionModelId`, exposed as `MACREC_TRANSCRIBE_MODEL` env var with a documented default, never silently substituted (per the project's no-fallback rule, missing env var only falls back to the source-code-pinned default at the *type-system* level, not at the resolver level).
2. **Transport**: `URLSessionWebSocketTask` (Foundation, no dependency). The endpoint is `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$GOOGLE_API_KEY` (Gemini Developer API path, AI-Studio key model). Vertex AI path is a documented future enhancement.
3. **Audio format**: PCM16 / 16 kHz / mono / little-endian, MIME type `audio/pcm;rate=16000`. Chunk cadence 30 ms (mid-point of the documented 20–40 ms recommendation), base64-encoded inside `realtimeInput.audio.data`.
4. **Audio source**: Default `mixed` (per refined-request A-LT-1) tapped at `HostClockAligner.onAlignedFrame` — confirmed by the codebase scan as the correct integration point. The aligner produces 100 ms `AlignedFrame` windows already containing both `systemBuffer` and `micBuffer`; the tap sums them via the existing `BufferSummer.sum(_:_:)` (already public in `MacrecCore/Mixing/BufferSummer.swift:108`), then downsamples through a dedicated `AVAudioConverter`. For `--transcribe-source system|mic`, tap the corresponding source-specific buffer instead. For `both`, instantiate two parallel transcription pipelines (one per source) and label outputs in the sidecar.
5. **Setup message**: Send `BidiGenerateContentSetup` with:
   - `model: "models/gemini-3.1-flash-live-preview"`
   - `generationConfig.responseModalities: ["TEXT"]`
   - `inputAudioTranscription: {}` (the empty object enables transcription on the input stream)
   - `systemInstruction.parts[0].text: "You are a transcription engine. Output only the verbatim transcription of the user's speech. Do not respond, do not greet, do not summarize, do not interpret. If silence, output nothing."`
6. **Partial/final reconstruction**: Buffer all `serverContent.inputTranscription.text` fragments since the last commit point. Emit a `TranscriptEvent.partial(...)` after each fragment. On the next sibling `serverContent.turnComplete: true` or `serverContent.generationComplete: true`, concatenate the buffered fragments, emit `TranscriptEvent.final(...)`, and clear the buffer.
7. **Authentication**: API key in URL query parameter `?key=$GOOGLE_API_KEY` (per AI Studio convention). Resolved via the standard four-tier chain (`shellEnv → ~/.tool-agents/macrec/.env → ./.env → CLI flag`). Missing key with non-`None` provider selected throws `MacrecError.transcriptionApiKeyMissing(provider:key:)` mapped to exit 78 (`EX_CONFIG`).
8. **Reconnection**: Bounded exponential backoff with jitter — start 500 ms, ×2 each attempt, cap 30 s, ±10 % jitter, max 12 attempts (~2 min worst-case wall clock). On every successful reconnect, reset the backoff timer. On hitting 3 reconnect failures within 60 s, transition to a `transcriptionPaused` state; log a `TranscriptEvent.error(reason: ..., isFatal: false)`; the recording continues. Use `NWPathMonitor` from the Network framework to immediately retry when network reachability returns, instead of blindly waiting on the backoff timer.
9. **Bounded queue**: `AsyncStream<TranscriptionPCMChunk>.makeStream(of:bufferingPolicy: .bufferingNewest(64))`. At a 30 ms chunk cadence, 64 chunks ≈ 1.9 s of buffered audio. At PCM16 mono 16 kHz that's ~120 KB — three orders of magnitude under NFR-19's 8 MB ceiling. Drops increment a `droppedFrameCount` metric exposed in the sidecar header and the post-stop log line.
10. **Provider abstraction shape** (concrete API):

    ```swift
    public protocol TranscriptionProvider: Sendable {
        var providerId: String { get }                 // "gemini-live", "openai-realtime", "noop", ...
        var displayName: String { get }                // "Gemini Live", "OpenAI Realtime", "None"
        var requiredApiKey: String? { get }            // "GOOGLE_API_KEY", nil for noop
        var requiredAudioFormat: TranscriptionAudioFormat { get }   // sample rate, bit depth, channel count

        // Long-running task: consume audio chunks, emit transcript events.
        // Cancellation of the calling Task triggers a clean WebSocket close.
        func run(
            audio: AsyncStream<TranscriptionPCMChunk>,
            options: TranscriptionOptions
        ) -> AsyncStream<TranscriptEvent>
    }

    public struct TranscriptionPCMChunk: Sendable {
        public let pcmData: Data                       // raw PCM16 LE bytes
        public let sampleRate: Int
        public let channelCount: Int
        public let source: CaptureSourceTag            // .system | .microphone | .mixed
        public let hostTime: UInt64                    // mach_absolute_time at chunk start
    }

    public enum TranscriptEvent: Sendable {
        case partial(text: String, source: CaptureSourceTag, hostTime: UInt64)
        case final(text: String, source: CaptureSourceTag, startedAt: UInt64, endedAt: UInt64)
        case error(reason: String, isFatal: Bool)
        case sessionEnded(reason: SessionEndReason)
    }
    ```

    No methods that take `inout` state; provider is fully functional from the caller's perspective. All concurrency lives inside `run()`. `run()` is responsible for opening/closing the WebSocket and for downsample-buffering its incoming audio.

11. **Where the provider runs**: A new `TranscriptionDriver` actor in `Sources/MacrecCore/Transcription/TranscriptionDriver.swift` owns the `Task` that runs `provider.run()`. It also owns the dedicated `AVAudioConverter` (never shared with the recorder) and the bounded `AsyncStream` continuation. `RecordingSession` holds an optional `transcriptionDriver` and forwards aligned frames into it via a non-blocking `enqueue(_:)` call. `SessionCoordinator` manages segment lifecycle: pause finalizes the current sidecar, resume opens the next. The driver outlives segment rotations (per refined-request §Tap Point B notes).
12. **Sidecar format**: `jsonl` default — one JSON object per `TranscriptEvent`. Header line records `{ "schema": "macrec.transcript.v1", "provider": "gemini-live", "model": "gemini-3.1-flash-live-preview", "audioPath": "...", "startedAt": "...", "secondsStreamed": 0, "partialCount": 0, "finalCount": 0, "droppedFrames": 0 }`. The header is rewritten on flush (truncate-then-write) so the metrics stay consistent. `srt`/`vtt` are derived views written at session-end from the in-memory finals list. `txt` is final-only concatenation.
13. **UI picker**: Mirror the existing `FormatPicker.swift` pattern exactly — `@AppStorage("com.macrec.ui.transcribeProvider")`, `Picker` with `.menu` style (matches `FormatPicker`), disabled while `recordingController.state` is not in `{.idle, .stopped, .failed}`. Three entries in v1: `None`, `Gemini Live`, `[future provider placeholder hidden]`. A separate `TranscriptionSourcePicker.swift` for the source choice. Use the same red-dot affordance for missing-key state that the existing `MicrophonePicker` uses for missing-permission state.
14. **Transcript display**: Inline panel below `LevelMeterView` in the popover, fixed max-height ~120 pt, scrollable, partials in muted style, finals committed in normal style, "Jump to live" affordance per FR-52. **Not a separate window in v1** — keeps the popover self-contained and matches the cramped-but-cohesive existing UX. A "Open transcript window" follow-up is logged in `Issues - Pending Items.md`.

### Why this option won

- **Honors the user's explicit preference** for Gemini.
- **Lowest cost path** of all live-LLM options ($0.005/min vs $0.06/min for OpenAI Realtime).
- **Zero new SwiftPM dependencies** — keeps the locked-stack discipline established by `plan-001` and `plan-002`.
- **Cleanest provider-agnostic abstraction** — JSON-over-WebSocket is the lingua franca of all five candidate providers; an SDK-based path would have foreclosed the provider-agnostic goal.
- **Reference Swift code exists** (`paradigms-of-intelligence/swift-gemini-api`, Pipecat iOS) to validate JSON schemas without taking the dependency.
- **The protocol abstraction is the deliverable's real value**: any future provider (OpenAI Realtime is the obvious next add, given its GA status and explicit final/delta semantics) drops in behind the same interface.

### Conditions under which the recommendation would change

- **If `gemini-3.1-flash-live-preview` is removed before v1 ships**: Fall back to `gemini-live-2.5-flash-native-audio` (the documented stable alternative). The wire protocol is identical; only the model id changes.
- **If the user retracts the Gemini preference**: Switch to OpenAI Realtime (`gpt-realtime`, GA) as the v1 default. The provider abstraction makes this a single-file change.
- **If on-device transcription is later promoted in scope**: Add an `AppleSpeechTranscriptionProvider` using `SFSpeechRecognizer.recognitionTask(with:)` and an `AsyncStream` adapter. The existing protocol absorbs it cleanly because no method in `TranscriptionProvider` assumes a network — `run()` simply runs.

## Technical Research Guidance

**Research needed**: Yes — three topics where the current investigation has enough to *plan* but not enough to *implement* the first lines of code with full confidence.

### Topic 1: Gemini Live `BidiGenerateContent` JSON wire schema (request and response shapes)

- **Why**: The investigation confirmed the high-level shape (`BidiGenerateContentSetup`, `BidiGenerateContentRealtimeInput`, `BidiGenerateContentServerMessage` with `serverContent.inputTranscription.text`) but did not enumerate the exact field types, base64 framing details, the precise location of `inputAudioTranscription: {}` in the setup tree (Live API docs and Vertex AI docs use slightly different paths), or the exact name of the audio-fragment field (`realtimeInput.audio.data` vs `realtimeInput.mediaChunks[].data`). Implementing the WebSocket sender and the JSON `Codable` types requires byte-level certainty.
- **Focus**: Read the canonical reference at `https://ai.google.dev/api/live` and the WebSockets get-started guide; cross-reference with the open-source `paradigms-of-intelligence/swift-gemini-api` source code to confirm the field names actually accepted in production. Document the exact `Codable` request/response types in `docs/research/live-transcription-feasibility.md` (per the refined-request Phase 0 deliverable). Confirm whether `responseModalities: ["TEXT"]` is honored on `gemini-3.1-flash-live-preview` (it's a *native audio* model and may force `["AUDIO"]` regardless).
- **Depth**: Deep dive — the Codable types and the setup-message construction are the foundational ~150 LoC of the provider; getting them wrong wastes the first integration cycle.
- **Relevance**: Directly determines `GeminiLiveTranscriptionProvider.swift` correctness. Without this, the planner cannot finalize the file's structure.

### Topic 2: Float32 / 48 kHz / interleaved-or-not → PCM16 / 16 kHz / mono via `AVAudioConverter`

- **Why**: The codebase's existing converters live inside the recorder pipeline and operate on different format pairs (e.g., Float32 → AAC at 48 kHz). The transcription downsample is a new conversion graph (Float32-48k-stereo-or-mono → Int16-16k-mono) and the constraint forbids reusing existing converters. The investigation confirmed `AVAudioConverter` is the right Apple-recommended primitive (per TN3136) and that vDSP-based hand-rolled resamplers are explicitly discouraged, but did not produce a complete worked example for this exact conversion graph in a non-AVAudioEngine context (we're starting from `CMSampleBuffer` / `AVAudioPCMBuffer`, not from a tap on `AVAudioEngine.inputNode`).
- **Focus**: Build a worked Swift snippet that (a) creates the `AVAudioFormat` for input (Float32, 48000, 1 or 2 channel, non-interleaved as produced by `SCKitSystemAudioSource` / `BufferSummer`) and output (Int16, 16000, 1 channel, interleaved); (b) instantiates the `AVAudioConverter` once; (c) implements the `convert(to:error:withInputFrom:)` block correctly handling `.haveData` / `.noDataNow`; (d) handles the buffer-size accounting (input arrives in 100 ms windows = 4800 frames at 48k, output emits ~1600 frames at 16k); (e) writes the resulting `Int16` samples into a `Data` value with little-endian byte order. Validate against `tad-iizuka/PCMDownSamplingSample` and the FluidAudio guide.
- **Depth**: Intermediate — existing references are close but not directly drop-in. Risk of subtle bugs (channel-count mismatch on stereo input, frame-rounding errors at chunk boundaries).
- **Relevance**: Determines `TranscriptionAudioConverter.swift` correctness. Bad conversion produces garbled audio that Gemini will silently accept and emit garbage transcripts for, with no error signal.

### Topic 3: `URLSessionWebSocketTask` + `AsyncStream` integration pattern with bounded reconnection

- **Why**: The project has zero existing networking code, so there is no prior pattern in the codebase to mirror. The investigation confirmed the high-level recipe (exponential backoff with jitter, NWPathMonitor for connectivity-restored fast-reconnect, application-level heartbeats, one-shot `receive()` that must be re-armed) but did not produce a vetted Swift snippet that ties together the four moving parts: the send loop (`task.send(.data(_:))` per chunk), the receive loop (`while let msg = try await task.receive()`), the bounded reconnection state machine, and the `AsyncStream<TranscriptEvent>` consumer-facing output. The consumer-facing stream's lifetime must outlive a reconnection (transparently to the consumer) which is non-trivial.
- **Focus**: Sketch a `WebSocketSession` actor that exposes a single `events: AsyncStream<ServerEvent>` continuation, owns the `URLSessionWebSocketTask`, runs send/receive on child Tasks, monitors `NWPathMonitor`, and on disconnect rewinds via exponential backoff while keeping the public `events` stream open. Define the contract: a transient disconnect emits no event; an exhausted-retries event emits one `TranscriptEvent.error(isFatal: false)` and the stream stays open in `paused` state; user-initiated cancel closes the stream cleanly. Prototype this in isolation before bolting it into `GeminiLiveTranscriptionProvider`.
- **Depth**: Deep dive. This pattern will be reused by every future provider, so getting it right amortizes across `OpenAIRealtimeProvider`, `DeepgramProvider`, `AssemblyAIProvider`. It is also the most subtle area for race conditions and leaked Tasks.
- **Relevance**: Determines `TranscriptionDriver` and the network-layer base classes. Without this clarity the planner cannot specify whether the WebSocket logic lives on the provider or on a shared transport actor.

(Topics explicitly *not* requested for further research: the `AsyncStream.bufferingNewest` drop policy — already proven in the codebase and well-understood; the `MacrecError` extension — straightforward additive change; the `RecordingOptions` field additions — mechanical edit.)

## Implementation Considerations

- **Decisions still to be made (escalate to designer/planner phase)**:
  - **OQ-LT-2**: Default source for the UI picker — refined-request A-LT-1 picks `mixed`; the user has not confirmed. Recommend a single confirming question before Phase D coding ("Do you want one merged transcript, or one per speaker?"). My recommendation: keep `mixed` as default but expose `both` as a UI option — covers both intents.
  - **OQ-LT-3**: Inline panel vs. separate window for the live transcript. My recommendation: inline with fixed max-height 120 pt for v1, separate window logged as v2 in `Issues - Pending Items.md`.
  - **OQ-LT-6**: The 15-minute audio-only session cap on Gemini Live means a 90-minute meeting will trigger six transparent reconnections. Each reconnect produces a small audible-text gap (FR-56's "log the gap, emit non-fatal error" path). Recommend explicitly documenting this in `docs/tools/macrec.md` and surfacing it in the post-stop disclosure ("Transcription was reconnected 5 times; expect minor gaps").

- **Dependencies / prerequisites**:
  - User must obtain a `GOOGLE_API_KEY` from `aistudio.google.com`. Document this step in the configuration guide. Add `GOOGLE_API_KEY_EXPIRES_AT` as the optional companion key (per CLAUDE.md configuration-guide rule).
  - No new SwiftPM dependency. No new `~/.tool-agents/<tool>/` folder (per the refined-request Process constraint — keys go into the existing `~/.tool-agents/macrec/.env` and `~/.tool-agents/macrec-ui/.env`).
  - No new TCC permission. No `com.apple.security.network.client` entitlement work for v1 because the binary is not sandboxed; flag this for v2 if sandboxing is added.

- **Potential pitfalls to watch for**:
  - **Conversational-vs-ASR mismatch**: Gemini 3.1 Flash Live is a chat model, not an ASR. Without the `systemInstruction` "Transcribe verbatim, do not respond" the model will start chatting back. Validate this empirically in Phase 0 with a real key.
  - **Native-audio response modality**: The model's docs hint that `responseModalities: ["TEXT"]` may not be honored on the native-audio model (it might force `AUDIO`). If so, the workaround is to *enable* `outputAudioTranscription` and *ignore* the audio output, reading only the transcript field. This is a documented Google pattern but adds 24 kHz of useless return-path bandwidth.
  - **Segment rotation loses transcription options**: The codebase scan flagged `RecordingOptions.withOutput(_:)` at `RecordingOptions.swift:185` — adding new transcription stored properties without updating `withOutput` causes silent options-loss on every pause/resume rotation. Make this a code-review checklist item.
  - **`HostClockAligner.onAlignedFrame` runs on `macrec.aligner.serial`**: the new `transcriptionTap` closure must be enqueue-and-return-only. It cannot `await`, cannot call into the `TranscriptionDriver` actor synchronously, cannot allocate large buffers. Recommended: copy the bytes off the buffer (cheap), `await` nothing, post the chunk via a non-blocking `AsyncStream.Continuation.yield(_:)`.
  - **API key leakage to logs**: Never log the full URL with the `?key=` query parameter. The `LoggerFactory` wrapper should be extended with a `redact(_:)` helper that strips the `key` parameter before any URL is logged.
  - **WebSocket close codes**: `URLSessionWebSocketTask.cancel(with:reason:)` defaults to abnormal closure. Use `.normalClosure` (1000) on user-initiated stops to avoid AssemblyAI's "auto-close in 3 hours billable" trap, and to honor Gemini's session-management contract.

- **Suggested first steps for the planner**:
  1. Resolve Topic 1 (wire schema) and Topic 2 (audio conversion) before any code is committed; both fit in a single research deliverable saved at `docs/research/live-transcription-feasibility.md` (per Phase 0 of the refined request).
  2. Sketch the `TranscriptionProvider` protocol file as a stand-alone Swift file with no implementations (it's the contract surface); review against this investigation's recommended shape.
  3. Implement `NoOpTranscriptionProvider` + the `TranscriptionDriver` actor + the bounded `AsyncStream` plumbing first. This proves the integration path end-to-end with zero network.
  4. Implement `FakeTranscriptionProvider` for tests — accepts injected scripts of `TranscriptEvent`s with timing, used by every UI and integration test.
  5. Only then implement `GeminiLiveTranscriptionProvider` against a real key.
  6. Update `MacrecError`, `ConfigResolver.Keys`, `RecordingOptions` (and `withOutput(_:)`!), and the four affected docs in a single dependency-validation commit before the providers go in.

## References

| # | Source | URL | What was learned |
|---|---|---|---|
| 1 | Google: Live API capabilities guide | https://ai.google.dev/gemini-api/docs/live-guide | Audio session limit (15 min audio-only / 2 min audio+video); native-audio response modality behavior; `inputAudioTranscription` config field. |
| 2 | Google: Get started with Gemini Live API using WebSockets | https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket | PCM16/16kHz/mono input format; `audio/pcm;rate=16000` MIME; chunk cadence 20–40 ms; client-to-server vs server-to-server architecture; ephemeral token recommendation. |
| 3 | Google: Live API WebSockets reference | https://ai.google.dev/api/live | `BidiGenerateContentSetup` / `BidiGenerateContentRealtimeInput` / `BidiGenerateContentServerMessage` shapes; `serverContent.inputTranscription` / `outputTranscription` / `turnComplete` / `generationComplete` / `interrupted` semantics. |
| 4 | LaoZhang AI Blog (Mar 2026): Gemini 3.1 Flash Live Quickstart | https://blog.laozhang.ai/en/posts/gemini-3-1-flash-live-api | Confirmed model id `gemini-3.1-flash-live-preview` and its release date (Mar 26, 2026). |
| 5 | MarkTechPost (Mar 2026): Google Releases Gemini 3.1 Flash Live | https://www.marktechpost.com/2026/03/26/google-releases-gemini-3-1-flash-live-a-real-time-multimodal-voice-model-for-low-latency-audio-video-and-tool-use-for-ai-agents/ | Confirmed model is collapsed transcribe-reason-synthesize stack ("native audio"); positioned as Google's flagship audio model. |
| 6 | Google blog: Gemini 2.5 Native Audio upgrade | https://blog.google/products-and-platforms/products/gemini/gemini-audio-model-updates/ | Migration path from `gemini-live-2.5-flash-preview-native-audio-09-2025` (deprecated Mar 19, 2026) to `gemini-live-2.5-flash-native-audio` and onward to 3.1. |
| 7 | TokenCost (Apr 2026): Gemini 3.1 Flash Live API Pricing | https://tokencost.app/models/gemini-3-1-flash-live | $3.00 per 1M audio input tokens; ~$0.005/min input audio; free tier on AI Studio. |
| 8 | OpenAI: Introducing gpt-realtime | https://openai.com/index/introducing-gpt-realtime/ | `gpt-realtime` GA pricing: $32 per 1M audio input tokens (~$0.06/min). 20 % cheaper than `gpt-4o-realtime-preview`. |
| 9 | OpenAI Platform: GPT-4o Realtime Model docs | https://platform.openai.com/docs/models/gpt-4o-realtime-preview | WebSocket endpoint `wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview`, headers, PCM16 / 24 kHz / mono, `input_audio_buffer.append` event shape. |
| 10 | TokenMix Blog: GPT-4o Realtime Audio API 2026 | https://tokenmix.ai/blog/gpt-4o-realtime-audio-api-guide-2026 | Confirmed audio formats (PCM16, G.711 µ-law, G.711 A-law); rate limits; cost-comparison example showing pipeline-vs-realtime trade-off. |
| 11 | Deepgram pricing | https://deepgram.com/pricing | Streaming $0.0077/min ($0.46/hr) on Nova-3; per-second billing; $200 free credit. |
| 12 | Deepgram Live Audio API docs | https://developers.deepgram.com/reference/speech-to-text/listen-streaming | WebSocket connection pattern; explicit `is_final` and `speech_final` flags; query-param-driven audio-format declaration. |
| 13 | AssemblyAI Universal-Streaming docs | https://www.assemblyai.com/docs/streaming/universal-streaming | $0.15/hr session-based billing; immutable transcripts (no revision); `Begin`/`Turn` event shape; `wss://streaming.assemblyai.com/v3/ws` endpoint. |
| 14 | AssemblyAI session-based pricing FAQ | https://www.assemblyai.com/docs/faq/how-does-universal-streaming-session-based-pricing-work | 3-hour auto-close trap; idle-time billing on open sessions; importance of explicit `Terminate` message. |
| 15 | Apple TN3136: AVAudioConverter sample rate conversions | https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions | Apple-recommended primitive for sample-rate conversion; not vDSP/manual decimation. |
| 16 | Apple: AVAudioConverter docs | https://developer.apple.com/documentation/avfaudio/avaudioconverter | `convert(to:error:withInputFrom:)` API; `.haveData` / `.noDataNow` input-block contract. |
| 17 | tad-iizuka/PCMDownSamplingSample (GitHub) | https://github.com/tad-iizuka/PCMDownSamplingSample | Worked Swift example of PCM downsampling via AVAudioEngine + AVAudioConverter. |
| 18 | FluidAudio AudioConversion guide | https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Guides/AudioConversion.md | "Always go through AudioConverter; never roll your own resampler" — confirms architectural decision. |
| 19 | WebSocket.org: Reconnection guide (Mar 2026) | https://websocket.org/guides/reconnection/ | State-sync-after-reconnect is the hard part; transport reconnection is the easy part; recommended backoff parameters (500 ms initial, ×2, 30 s cap, jitter). |
| 20 | OneUptime: WebSocket Reconnection Logic (Jan 2026) | https://oneuptime.com/blog/post/2026-01-27-websocket-reconnection/view | Production-grade checklist: bounded retries, NWPathMonitor for connectivity, application-level heartbeats vs TCP keepalive insufficiency. |
| 21 | Apple Developer Forums: NSURLSession Exponential Backoff | https://developer.apple.com/forums/thread/47346 | Canonical Swift retry pattern: `let delay = retryDelay * pow(2, Double(attempt)); try await Task.sleep(...)`. |
| 22 | paradigms-of-intelligence/swift-gemini-api (GitHub) | https://github.com/paradigms-of-intelligence/swift-gemini-api | Reference Swift implementation of Gemini Live transport (read-only reference; not taken as a dependency). |
| 23 | pipecat-ai/pipecat-client-ios-gemini-live-websocket (GitHub) | https://github.com/pipecat-ai/pipecat-client-ios-gemini-live-websocket | Production-grade iOS Gemini Live WebSocket transport (read-only reference; not taken as a dependency). |
| 24 | Firebase AI Logic: Get started with Gemini Live API | https://firebase.google.com/docs/ai-logic/live-api | Confirmed the official-SDK option exists but is in Preview, requires Firebase project setup, and is rejected as too heavy for this project. |

## Original Request

> Can you investigate if we could allow the user to enable, while recording, sending the same voice stream to a fast LLM trying to get back the transcription of the current conversation?
>
> My preference for this task is the use of Gemini 3.1 Live model.
>
> If it is feasible, it must be an option on the user interface where the user will decide which model he will use to transcribe the conversation.
>
> If he chooses None, that means that the conversation will not be transcribed.

The full refined request is preserved at [docs/design/refined-request-live-transcription.md](../design/refined-request-live-transcription.md) and was used as the binding scope for this investigation.
