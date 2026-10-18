# ntakker Live-Transcription Subsystem — Performance / Functionality / Robustness Review

**Scope:** `Sources/NtakkerCore/Transcription/` (all files: 9 STT providers, dispatcher, source-split manager, sidecar writers) plus the wiring points in `Sources/NtakkerCore/RecordingSession.swift` (lines 1150–1600) needed to evaluate fan-out and teardown.
**Date:** 2026-06-12
**Method:** full read of all 69 files in the directory tree (~10,200 LoC) plus the RecordingSession integration sites.

---

## Strengths (brief)

- **Clean seam architecture.** `TranscriptionDispatcher` / `TranscriptionProvider` / `StreamingTranscriptionSession` / `WebSocketTransport` / `SpeechAnalyzerAdapter` protocols give every provider a testable boundary; mock conformers exist for the hard-to-test surfaces (WebSocket, SpeechAnalyzer).
- **Recording-integrity isolation is consistently enforced**: provider/transport failures become `.error(detail:)` events, never throws into the recording path (NFR-17). The downsampler logs-and-drops instead of throwing.
- **Actor isolation everywhere it matters** (`TranscriptionManager`, `SonioxStreamingSession`, `AzureOpenAIRealtimeSession`, `SourceBuffer`, `TranscriptSidecarWriter`); the few `@unchecked Sendable` classes (`URLSessionWebSocketTaskTransport`, `AppleSpeechSession`) have explicit, narrow lock disciplines.
- **Azure realtime is the most robust networking implementation**: reconnect-with-replay ring buffer, 58-min pre-emptive reconnect before the 60-min cap, handshake-failure detection (close=1000 + "Socket is not connected" repro), actionable error text.
- **Azure batch and ElevenLabs have real retry policies** (Retry-After honoring, jitter, transient-URLError sets, no-retry on `concurrent_limit_exceeded`).
- **Silence gating + hallucination filtering** (`TranscriptSanitizer`) avoids billing for silence and suppresses the classic Whisper-family "thanks for watching" artifacts.
- **`RecordingSession` bounds teardown** with `withTranscriptionTeardownTimeout` (5 s race-with-timer, correctly NOT using `withTaskGroup` which would wait).
- **Sidecar id-keyed in-place rewrite** keeps human-readable formats (SRT/VTT/TXT) consistent for live viewers without a full-file rewrite per update.

---

## 1. Streaming performance

### F1. Audio chunks can be delivered out of order — two layers of unordered fire-and-forget Tasks — HIGH

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/RecordingSession.swift:1294–1323` (live tap)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:181–192` (`ingest`)

```swift
// RecordingSession.swift:1298
case .system:
    Task { await dispatcher.ingestFrame(frame, from: .system) }
...
// TranscriptionManager.swift:184 (streaming branch)
Task { [streamingPipeline] in
    await streamingPipeline?.ingest(samples, from: tag)
}
...
// TranscriptionManager.swift:191 (batch branch)
Task { await buf.append(samples) }
```

- **Why it's a problem:** Unstructured `Task {}` provides **no FIFO ordering guarantee**. Each ~100 ms aligner frame spawns a fresh task at the tap, and `TranscriptionManager.ingest` spawns *another* per chunk. Under scheduler contention two adjacent chunks can reach `SourceBuffer.append` — or worse, a live WebSocket (`SonioxStreamingSession.ingest` sends straight to the wire) — swapped. For streaming providers, swapped PCM chunks produce garbled audio at the recognizer and wrong transcripts; for batch, swapped samples within one accumulated chunk corrupt that chunk. This is a latent correctness bug whose frequency rises with system load.
- **Fix:** Replace the fire-and-forget hops with a single ordered channel: the tap yields frames into an `AsyncStream<AlignedFrame>` (one per source), and one consumer task per source drains it serially (downsample → ingest). This also removes the per-frame Task-allocation overhead (~10–20 tasks/sec/source today).
- **Severity:** High

### F2. Out-of-order transcript merging in the batch pipeline (2 concurrent in-flight calls, completion-order coalescing) — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:317–336` (`spawnProviderCall`, `maxInFlightPerSource = 2`) and `:355` (`coalescer.merge(text: cleaned, source: source, at: Date())`)

```swift
public static let maxInFlightPerSource: Int = 2
...
let result = coalescer.merge(text: cleaned, source: source, at: Date())
```

- **Why it's a problem:** Two provider calls per source run concurrently, but `SegmentCoalescer.merge` appends in **completion order**, not dispatch order. If chunk N has a slow RTT and chunk N+1 returns first (entirely realistic — chunk cadence is 2.0–2.5 s and cloud RTT variance routinely exceeds that), the transcript text within the coalesced segment reads N+1 then N. There is no sequence number anywhere in the path.
- **Fix:** Stamp each dispatched chunk with a monotonically increasing sequence per source; in `runProviderCall`'s success path, hold results in a small reorder buffer and merge strictly in sequence (release on next-expected or after a timeout).
- **Severity:** Medium

### F3. `AudioResampler16to24` builds a new `AVAudioConverter` per chunk — boundary artifacts + per-chunk allocation — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AudioResampler16to24.swift:62–71`

```swift
/// Stateless 16 kHz Float → 24 kHz Int16 LE resampler. Each
/// `resample(_:)` call configures a fresh `AVAudioConverter` ...
func resample(_ samples: [Float]) -> Data? {
    guard let converter = AVAudioConverter(from: Self.inputFormat, to: Self.outputFormat) ...
    converter.sampleRateConverterQuality = .max
    converter.primeMethod = .normal
```

- **Why it's a problem:** This directly contradicts the project's own documented rule in `AudioDownsampler.swift:39–44` ("Do NOT create a new instance per audio chunk — the underlying AVAudioConverter maintains resampling filter state across calls... Recreating drops that state and produces an audible click at every chunk boundary"). With `primeMethod = .normal` the fresh converter primes on every chunk: phase discontinuities at every chunk boundary in the 24 kHz stream sent to Azure degrade WER — the exact risk (RT-RISK-2) the `.max` quality setting was chosen to avoid. It also pays converter construction cost ~10×/sec.
- **Fix:** Make the resampler a stateful class owned by `AzureOpenAIRealtimeSession` (the session is an actor, so single-threaded access is already guaranteed; the `Sendable`-struct justification is unnecessary). Create the converter once; use the `.noDataNow` input-block protocol like `AudioDownsampler.convert` does instead of `.endOfStream` (line 107: `outStatus.pointee = .endOfStream` is the live-stream anti-pattern the downsampler file explicitly warns about as "Pitfall 6").
- **Severity:** Medium

### F4. Triple per-sample scalar conversion: Float32 → Int16 → Float32 → Int16 — MEDIUM

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:198–214` (`ingestFrame`: downsample to Int16 `Data`, then `int16BytesToFloat` back to `[Float]`)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingSession.swift:333–351` (`float32ToInt16LEBytes` — back to Int16)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/SpeechAnalyzerAdapter.swift:308–322`, `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/AudioWAVEncoder.swift:32–36` (same conversion again per provider)

```swift
// TranscriptionManager.ingestFrame
guard let int16Data = downsampler.convert(pcmBuffer) else { return }
let floats = Self.int16BytesToFloat(int16Data)   // Int16 → Float, scalar loop
self.ingest(floats, from: tag)                   // → provider converts Float → Int16 again
```

- **Why it's a problem:** Every chunk goes Float32 (capture) → Int16 (downsampler) → Float32 (manager) → Int16 (Soniox/Apple/WAV/Azure-realtime resampler). That is two needless full-array scalar loops per chunk per source, *plus* double quantization (the Int16 round-trip already cost precision; re-quantizing is harmless but the work is wasted). None of the loops use `vDSP`/Accelerate despite this being the hottest per-chunk path in the subsystem.
- **Fix:** Have `AudioDownsampler` produce Float32 16 kHz output (one converter config change) and convert to Int16 **once**, at the wire boundary of providers that need it, using `vDSP.convertElements(of:to:)` / `vDSP_vfix16`. Centralize in one `PCMConversion` utility (see F29).
- **Severity:** Medium

### F5. One slow provider stalls the *other* source's drain (process loop is serial across sources) — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:305–336`

```swift
private func processLoop() async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.processLoopSeconds))
        for (tag, buf) in buffers {
            guard let samples = await buf.drain(final: false) else { continue }
            ...
            await spawnProviderCall(samples: samples, source: tag)   // can block
        }
    }
}
private func spawnProviderCall(...) async {
    ...
    while queue.count >= Self.maxInFlightPerSource {
        let head = queue.removeFirst()
        ...
        await head.value          // ← blocks the whole loop, both sources
```

- **Why it's a problem:** When `source == .both` is handled natively by one manager (legacy path), the in-flight cap for the *system* source being full blocks `spawnProviderCall`, which blocks the `for (tag, buf)` loop, which delays draining the *microphone* buffer. `SourceBuffer` caps at 2×chunk (5 s) and then drops 50% of accumulated audio (`SourceBuffer.swift:25–30`), so a slow provider on one source causes silent audio loss on the other.
- **Fix:** Don't await inside the drain loop. Either skip the source this tick when its in-flight queue is full (the buffer keeps accumulating; raise its cap), or run one independent drain task per source.
- **Severity:** Medium

### F6. Buffer-overflow audio drops are completely silent — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/SourceBuffer.swift:23–31`

```swift
public func append(_ samples: [Float]) {
    accumulator.append(contentsOf: samples)
    let cap = 2 * chunkSamples
    if accumulator.count > cap {
        bufferOverflowCount += 1
        let drop = accumulator.count / 2
        accumulator.removeFirst(drop)
    }
}
```

- **Why it's a problem:** Dropping the oldest 50% (2.5 s of speech) is a legitimate backpressure policy, but `bufferOverflowCount` is never read by anything — no log line, no `TranscriptionEvent`, no metrics field. The user's transcript just has holes with no diagnostic trail. (`TranscriptionMetrics` has no overflow counter; grep confirms no consumer of `bufferOverflowCount` outside tests.)
- **Fix:** Surface overflow into `TranscriptionMetrics` (e.g. `droppedAudioSeconds`) and emit a throttled `.error`/warning event the UI can badge. Also `removeFirst(drop)` on a large array is O(n) memmove — a head index or `Deque` avoids it.
- **Severity:** Medium

### F7. Per-sample `Data.append` in `AudioWAVEncoder` — LOW

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/AudioWAVEncoder.swift:32–36`

```swift
for sample in samples {
    let clamped = max(-1.0, min(1.0, sample))
    let value = Int16(clamped * Float(Int16.max))
    out.appendLE(UInt16(bitPattern: value))
}
```

- **Why:** 40k `withUnsafeBytes`+`append` calls per 2.5 s chunk (every batch provider call). Works, but is the kind of loop `vDSP_vfix16` + one bulk `Data(bytes:count:)` does ~50× faster.
- **Fix:** Convert into a `[Int16]` buffer with vDSP, append once.
- **Severity:** Low

### F8. Streaming pipeline drops samples while session-open is in flight — LOW

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/StreamingTranscriptionPipeline.swift:117–121

```swift
func ingest(_ samples: [Float], from tag: SourceTag) async {
    guard !stopped else { return }
    guard let session = sessions[tag] else { return }   // open still in flight → samples dropped
```

- **Why:** `openStreamingSession` for cloud providers includes a WS connect + config round-trip (hundreds of ms; for Apple it can include an **asset download**). Everything ingested before `attach` runs is discarded — the first words of every recording are at risk.
- **Fix:** Buffer pre-attach samples per tag (bounded, e.g. 10 s) and flush them into the session on attach.
- **Severity:** Low (short window in the common case, but combines badly with F16)

---

## 2. Network robustness

### F9. Soniox has **no reconnect** and a dead transport produces an error per chunk forever — HIGH

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingSession.swift:136–146 (ingest), 192–221 (receive loop)

```swift
public func ingest(_ samples: [Float]) async {
    guard isStarted, !isFinished else { return }
    ...
    do {
        try await transport.send(data: int16Bytes)
    } catch {
        recordError("soniox.ingest_failed: \(error.localizedDescription)")   // every chunk, forever
    }
}
...
} catch {
    if self.isFinished { return }
    self.recordError("soniox.receive_failed: ...")   // loop exits; session stays "started"
}
```

- **Why it's a problem:** If the Soniox WebSocket dies mid-session (network blip, server restart — Soniox also hard-caps sessions at 300 min and idle-closes at 20 s without keepalive), the receive loop exits, but `isFinished` stays false, so every subsequent `ingest` (≈10/sec for streaming pacing, or per chunk) throws and emits a fresh `.error` event — error spam into the UI and metrics — while transcription is silently dead for the **remainder of the recording**. Contrast with `AzureOpenAIRealtimeSession`, which has a 5 s replay ring buffer and 3 reconnect attempts. The transport is also single-use by design (`URLSessionWebSocketTaskTransport.connect` throws after `close`), so reconnect requires a fresh transport the session has no factory for.
- **Fix:** (a) On receive-loop failure, call the existing `terminate()` so ingest becomes a no-op and exactly one terminal error surfaces; (b) better, port the Azure pattern: inject the provider's `transportFactory` into the session, keep a small PCM ring buffer, and reconnect-with-replay (re-send config frame, replay buffer, cap attempts with backoff).
- **Severity:** High

### F10. Azure realtime: replayed + live audio is sent before the new session is configured — HIGH

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift:423–440` (replay), `:225–228` (config only after `session.created`)

```swift
try await connectAndConfigure()              // resumes WS; does NOT wait for session.created
// Replay the buffered audio in 100 ms chunks ...
while offset < replay.count {
    ...
    await sendJSON(envelope)                 // input_audio_buffer.append before
}                                            // transcription_session.update was ever sent
```

```swift
case .sessionCreated(let payload):
    didCompleteHandshake = true
    await sendSessionConfig()                // model/VAD/language config sent here
```

- **Why it's a problem:** `connectAndConfigure()` returns immediately after `task.resume()`; the `transcription_session.update` carrying the **required** `input_audio_transcription.model`, VAD tuning, and language hints is only sent when the `session.created` event arrives on the receive loop. The replay loop (and the next live `ingest` calls) therefore race ahead of configuration — Azure receives audio for a session with no transcription model configured, which by the project's own field repro ("Azure transcription REQUIRES input_audio_transcription.model", line 274–279) means those appends can be rejected or transcribed with defaults. The replayed 5 s — the entire point of the ring buffer — is the audio most likely to be lost.
- **Fix:** Gate audio sends behind a "configured" state: buffer in the ring until `session.updated` (or at least `session.created` + config send) is observed, then flush replay + resume live sends.
- **Severity:** High

### F11. Azure realtime: pre-emptive reconnect races the close-triggered reconnect — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift:459–468` and `:345–399`

```swift
private func preemptiveReconnect() async {
    ...
    await closeWS(code: .normalClosure, reason: Data("preemptive".utf8))
    await attemptReconnectWithReplay(reason: "pre-emptive 58-min reconnect")
}
```

- **Why it's a problem:** `closeWS` cancels `receiveLoopTask`, but if the in-flight `task.receive()` has already thrown (the cancel races the close frame), the old receive loop runs `handleClose(...)` with `userInitiatedClose == false`. At age ≥ 58 min the `.normalClosure` branch calls `attemptReconnectWithReplay` **as well** — two concurrent reconnect sequences interleave on the actor (each `await` is a suspension point), can double-drain/replay the ring buffer, double-increment `reconnectAttempts`, and open two WS tasks where the second overwrites `wsTask` and the first leaks until its URLSession times out.
- **Fix:** Add a `isReconnecting` latch checked/set at the top of `attemptReconnectWithReplay`, and set a `suppressHandleClose` flag in `preemptiveReconnect` before `closeWS` (analogous to `userInitiatedClose`).
- **Severity:** Medium

### F12. Azure realtime: backoff schedule doesn't match its own comment (0 s, 4 s, 16 s — not 0/1/4) — LOW

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift:410–412`

```swift
// Exponential backoff (0, 1, 4 s) ± 20% jitter.
let baseDelay: Double = (reconnectAttempts == 1) ? 0.0 : pow(2.0, Double(reconnectAttempts - 1) * 2)
```

- **Why:** `pow(2, (attempt-1)*2)` yields 4 (attempt 2) and 16 (attempt 3). With three attempts the user waits up to ~20 s of dead air rather than the intended ~5 s; the plan's "3 attempts within a 30 s window" decay is also unimplemented (`reconnectAttempts` only resets on success).
- **Fix:** `pow(2.0, Double(attempt - 2))` → 0, 1, 2 s (or table `[0, 1, 4]`); add window-based reset.
- **Severity:** Low

### F13. Gemini provider: no retry, no explicit timeout, API key in URL query — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift:85, 91–104`

```swift
components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
...
var request = URLRequest(url: url)
request.httpMethod = "POST"
...
(data, response) = try await urlSession.data(for: request)   // single attempt, default timeout
```

- **Why it's a problem:** (a) Unlike the Azure batch and ElevenLabs siblings, there is no retry on 429/500/503 or transient `URLError` — a single blip costs the whole 2.5 s chunk; over a long session this measurably degrades transcript completeness. (b) No `timeoutInterval` is set (default 60 s) — one stuck request can pin an in-flight slot for a minute (interacts with F5/F18). (c) The API key rides the query string: it can leak into proxy logs, `URLSession` error descriptions, and the provider's own thrown error strings that embed URLs; Google supports the `x-goog-api-key` header.
- **Fix:** Reuse the shared retry helper (see F28), set `request.timeoutInterval = 30`, move the key to the `x-goog-api-key` header.
- **Severity:** Medium

### F14. Apple Cloud: error path restarts the recognition task in a tight loop with no backoff — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift:392–404`

```swift
currentTask = nil
currentRequest = nil
if isFinished {
    ...
} else if !isInformational, code == 1101 {
    ... // auth revoked — stop
} else {
    startNewRecognitionTask()   // ← immediate restart for ANY other error, incl. network
}
```

- **Why it's a problem:** The comment block (lines 374–377) says NSURLErrorDomain network failures are "fatal for that task; we close the events stream", but the code restarts for every non-1101 error. Offline, each new task fails within ~a second → an unbounded create/fail loop emitting an `.error` event per iteration (UI spam, `errorCount` inflation) and hammering Apple's endpoint against the 1000 req/hr device quota.
- **Fix:** Track consecutive failures; apply exponential backoff (sleep before `startNewRecognitionTask`) and give up (finish stream with a terminal error) after N consecutive non-informational failures.
- **Severity:** Medium

### F15. Batch pipeline has no circuit breaker: a dead provider is re-called every ~2.5 s for hours — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:368–372`

```swift
} catch {
    metrics.errorCount += 1
    eventsContinuation?.yield(.error(detail: error.localizedDescription))
    logger.warning("provider call failed: \(error.localizedDescription)")
}
```

- **Why it's a problem:** Recording-integrity isolation is correct, but there is no escalation: with a revoked API key or sustained outage, a 3-hour recording fires ~4,300 doomed HTTPS requests per source (each with its own internal 3-attempt retry for Azure/ElevenLabs ⇒ up to ~13,000 requests), each producing an `.error` event. There is no distinction between retryable and permanent (401/403 config) errors at the manager level.
- **Fix:** Add a consecutive-failure circuit breaker in `runProviderCall` (e.g. after 5 consecutive failures, pause provider calls for 60 s, emit one "transcription degraded" event; trip permanently on `transcriptionApiKeyMissing`-class errors).
- **Severity:** Medium

### F16. Transport `connect()` never performs the handshake — "pre-stream failure" contract is illusory — LOW

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Live/Soniox/URLSessionWebSocketTaskTransport.swift:109–139`; consumed contract at `SonioxStreamingSession.swift:108–116`

```swift
// connect(...) — "this call does not actually do network I/O"
let wsTask = urlSession.webSocketTask(with: request)
wsTask.resume()
```

- **Why:** `SonioxStreamingSession.start()` documents that connect/config-send failures throw to the caller as hard pre-flight errors. Because the task opens lazily, `connect` cannot fail; the first `send(text:)` of the config *may* surface the failure, but a wrong DNS name typically surfaces on the **receive** side instead — i.e., after `start()` returned success and the factory already committed to the session. Users get an in-stream `.error` instead of the intended exit-78-style config error.
- **Fix:** In `connect`, send a no-op `sendPing` (or await the first `receive` with a short timeout) to force the upgrade and surface 4xx/DNS failures synchronously.
- **Severity:** Low

### F17. Soniox `finish()` always pays the full 2 s grace sleep — LOW

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingSession.swift:174–179`

```swift
// Give the receive loop a brief grace period ...
try? await Task.sleep(for: finishGracePeriod)   // unconditional 2 s
receiveTask?.cancel()
```

- **Why:** Even when the server's `{"finished":true}` arrives in 50 ms (which sets `isFinished` and finishes the continuation), `finish()` sleeps the full 2 s. Every stop of a Soniox recording is 2 s slower than necessary; combined with the session-teardown budget of 5 s this eats 40% of it.
- **Fix:** Poll/await a "finished observed" signal (e.g. `withTaskGroup` racing the sleep against a continuation resumed by `handleTextFrame`'s finished branch).
- **Severity:** Low

---

## 3. Concurrency, task lifecycle, cancellation

### F18. `TranscriptionManager.stop()`'s "bounded" drain is not actually bounded — HIGH

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:264–283`

```swift
// Final drain of all buffers.
for (tag, buf) in buffers {
    if let samples = await buf.drain(final: true) {
        ...
        await runProviderCall(samples: samples, source: tag, isFinal: true)  // unbounded await #1
    }
}
// Wait for outstanding tasks up to stopDrainSeconds.
let deadline = ContinuousClock.now.advanced(by: .seconds(Self.stopDrainSeconds))
for tasks in inFlight.values {
    for t in tasks {
        if ContinuousClock.now < deadline {
            await t.value          // unbounded await #2 — deadline checked only BETWEEN tasks
        } else {
            t.cancel()
        }
    }
}
```

- **Why it's a problem:** The doc comment promises "stop() returns in bounded time even if the network is unreachable", but (a) the final-drain `runProviderCall` is awaited serially per source with **no** deadline — a hung HTTPS call (Gemini default 60 s timeout, ElevenLabs 120 s) holds `stop()` for that long; (b) inside the deadline loop, the deadline is only consulted *before* each `await t.value`; the first await can block arbitrarily long past the deadline. The only thing saving the stop sequence is `RecordingSession.withTranscriptionTeardownTimeout` (5 s), which then **abandons** the whole teardown — meaning the sidecar `close()` and `eventsContinuation.finish()` at lines 285–287 may never run on the abandoned task until the network call times out: the events stream stays open and the UI's `for await` can hang past the recording's end.
- **Fix:** Race each await against the remaining deadline (`withTaskGroup` of `t.value` vs `Task.sleep`, or wrap provider calls in a cancellable timeout). Cancel, don't await, once the deadline passes; always run sidecar close + continuation finish before returning.
- **Severity:** High

### F19. `StreamingTranscriptionPipeline`: a session that opens after `stop()` leaks forever — HIGH

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/StreamingTranscriptionPipeline.swift:95–107 (start), 149–161 (stop), 175–184 (attach)

```swift
for tag in source.activeSourceTags() {
    Task { [provider, options, weak self] in
        do {
            let s = try await provider.openStreamingSession(source: tag, options: options)
            await self?.attach(session: s, for: tag)
        } ...
    }
}
...
private func attach(session: any StreamingTranscriptionSession, for tag: SourceTag) {
    sessions[tag] = session              // ← no `stopped` check
    let task = Task { [weak self] in ... }
    drainTasks.append(task)
}
```

- **Why it's a problem:** `openStreamingSession` can take seconds (WS connect; Apple asset download can take **minutes**). If the user stops the recording during that window, `stop()` iterates the (empty) `sessions` map and returns; when the open completes, `attach` happily registers the session — whose `finish()` will now never be called. For Soniox that leaks a live WebSocket + keepalive timer task pinging the server indefinitely (billable session until Soniox's 20 s idle timeout — except the keepalive **prevents** the idle timeout, so it lives until the 300-min cap); for Apple Cloud it leaks an `SFSpeechRecognitionTask` + rotation timer task that rotates forever; the drain task also keeps the pipeline actor alive.
- **Fix:** In `attach`, `guard !stopped else { Task { await session.finish() }; return }`. Also keep the open tasks in a list and cancel them in `stop()`.
- **Severity:** High

### F20. `AppleSpeechSession.finish()` can cut off late finals (forwarding tasks not awaited) — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift:226–233 (forwarders), 241–252 (finish)

```swift
// init
for (locale, adapter) in analyzers {
    Task { [weak self] in
        for await result in adapter.results { self?.handle(result, from: locale) }
    }
}
// finish()
for (_, adapter) in analyzers { await adapter.finalizeAndFinish() }
... reconcile pending ...
eventsContinuation.finish()
```

- **Why it's a problem:** `finalizeAndFinish()` waits for the *analyzer* to drain, but the per-adapter results then sit in the adapter's `AsyncStream` buffer waiting for the unreferenced forwarding `Task` to consume them. `finish()` does not await those tasks, so it can reconcile-and-finish the public stream while the last final result is still in the buffer — the final utterance of the recording is dropped from both UI and sidecar. The forwarding tasks are also unstored/uncancellable.
- **Fix:** Store the forwarding tasks; in `finish()`, await them (they exit when the adapter stream finishes, which `finalizeAndFinish` guarantees) **before** reconciling and finishing the continuation.
- **Severity:** Medium

### F21. Apple Cloud `finish()` hard-finishes after a fixed 1.5 s, racing the in-flight final — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift:300–307, 476–482`

```swift
Task { [weak self] in
    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s
    await self?.forceFinishIfStillOpen()
}
...
private func forceFinishIfStillOpen() {
    guard isFinished else { return }
    eventsContinuation.yield(.metrics(metrics))
    eventsContinuation.finish()    // unconditional — even if the final hasn't landed yet
}
```

- **Why it's a problem:** Apple's cloud path frequently takes >1.5 s to deliver the final after `endAudio()` (network round trip + server-side finalization). `forceFinishIfStillOpen` doesn't check whether a task is still in flight — it finishes the stream unconditionally, so the **last utterance** of a recording is frequently lost on the cloud path. (The result handler does check `isFinished` and would have finished cleanly after yielding the final.)
- **Fix:** Only force-finish if `currentTask == nil`, or extend the window and let the result handler's `isFinished` branch (lines 394–396, 430–432) do the close; treat the timer purely as a no-result safety net.
- **Severity:** Medium

### F22. Merged source-split stream reuses colliding segment indices from both children — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/SourceSplitTranscriptionManager.swift:66–81`

```swift
Task { for await event in systemStream { continuation.yield(event) } ... }
Task { for await event in microphoneStream { continuation.yield(event) } ... }
```

- **Why it's a problem:** Each child `TranscriptionManager`/`StreamingTranscriptionPipeline` numbers segments independently from 0 (`coalescer` index / `nextSegmentIndex`). The merged stream therefore emits `.segmentAppended(index: 0, …)` twice, `.segmentUpdated(index: 1, …)` for two different segments, etc. Any consumer that keys UI rows or update-in-place logic on `index` (the batch pipeline's documented contract) will overwrite the wrong row in `--transcribe-source both` mode. The forwarding tasks are also unstructured — not cancelled if the merged stream's consumer goes away (mitigated by children finishing on `stop()`).
- **Fix:** Re-index in the merge (maintain a per-(child, childIndex) → mergedIndex map in the forwarding tasks), or change the event surface to key on `segment.id` (UUID) and deprecate the integer index.
- **Severity:** Medium

### F23. `TranscriptionManager` force-unwraps `streamingPipeline!` on the path its own comment calls reachable-by-construction-failure — LOW

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:123–128, 144–148, 224, 256, 297`

```swift
} else {
    // Deployment target is .v26 so this branch is
    // unreachable in practice; defer the hard error to
    // start() rather than crashing construction.
    self.streamingPipeline = nil
}
...
if isStreaming {
    if #available(macOS 26.0, *) {
        return await streamingPipeline!.start()   // ← the "hard error" is a crash
```

- **Why:** The promised "hard error at start()" is actually a force-unwrap crash. Harmless today (target = v26) but a booby trap for the documented future `SFSpeechRecognizer` fallback path (Project Memory Exception 002 explicitly contemplates lowering the gate).
- **Fix:** `guard let pipeline = streamingPipeline else { throw NtakkerError.transcriptionConfigConflict(...) }` (protocol `start()` is already `throws`).
- **Severity:** Low

---

## 4. Sidecar / transcript writing

### F24. `rotateSidecar` in source-split mode points BOTH children at the SAME file — data loss after split — HIGH

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/SourceSplitTranscriptionManager.swift:111–114`
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:230–233`
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/StreamingTranscriptionPipeline.swift:136–141`
  - (correct initial wiring for contrast: `RecordingSession.swift:1420–1425` passes `sourceTag:`)

```swift
// SourceSplitTranscriptionManager
public func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {
    try await systemManager.rotateSidecar(toAudioURL: toAudioURL, format: format)
    try await microphoneManager.rotateSidecar(toAudioURL: toAudioURL, format: format)
}
// TranscriptionManager.rotateSidecar — NO sourceTag parameter:
let nextPath = SidecarPathBuilder.sidecarURL(forRecording: toAudioURL, format: format)
```

- **Why it's a problem:** At initial setup each child gets a distinct sidecar (`….system.transcript.jsonl` / `….microphone.transcript.jsonl`) because `buildSingleModeManager` passes `sidecarSourceTag`. But the children don't *know* their tag for rotation: on `split()` both compute the identical untagged path. `JSONLTranscriptWriter.init` (line 51) runs `FileManager.default.createFile(atPath:contents:nil)`, which **truncates** an existing file — so the second child's writer truncates the first child's freshly-opened sidecar, then two actors interleave id-keyed seek/write cycles into one `FileHandle`-per-writer file, corrupting byte-range indices. Every post-split transcript in `--transcribe-source both` mode is lost or corrupted.
- **Fix:** Add the source tag to the rotate path: store the `sidecarSourceTag` on `TranscriptionManager` (it already knows its `source`) and pass it to `SidecarPathBuilder.sidecarURL(..., sourceTag:)` in both `TranscriptionManager.rotateSidecar` and `StreamingTranscriptionPipeline.rotateSidecar`. Also make `createFile` conditional (don't truncate an existing file, or fail loudly per the no-fallback rule).
- **Severity:** High

### F25. Batch sidecar update-amplification: a tombstone per coalesced update (~1,400/hour) — MEDIUM

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/SegmentCoalescer.swift:28–45` (text grows on every merge)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Persistence/JSONLTranscriptWriter.swift:83–103` (long-grow → tombstone + append)

```swift
// Coalescer: combined text is strictly longer each merge within the 12 s window
let combined = (last.text + " " + text)...
// JSONL long-grow path (taken on essentially every update, since text only grows):
let tombstoneObj = #"{"_tombstone":true,"id":"..."}"#
...
try handle.write(contentsOf: tomb)        // overwrite old slot
try handle.seekToEnd()
try handle.write(contentsOf: newBytes)    // re-append entire segment
```

- **Why it's a problem:** Each batch chunk lands every ~2–2.5 s; within the 12 s coalesce window each update makes the segment text longer, so `newBytes.count <= oldByteLen` is almost never true → the long-grow path fires on nearly **every** update. Consequences over a long session: (a) the file accumulates one `_tombstone` line (or `[updated]` ghost cue in SRT/VTT, blank line in TXT) per update — ≈1,400/hour of garbage lines; (b) each update rewrites the entire segment text again at EOF (O(segment²) bytes written per segment lifetime); (c) JSONL consumers reading the sidecar live must tolerate and filter tombstones and ever-moving duplicates.
- **Fix:** For the batch policy, keep the *open* segment in memory and write it once when it closes (a new segment is created or `stop()` fires) — partials are already delivered to the UI via the events stream, so live persistence of the open segment buys little. Alternatively pre-pad appended lines with ~2× headroom so short-grow absorbs most updates.
- **Severity:** Medium

### F26. No durability flush; crash loses the OS-buffered tail — LOW

- **Files:** all writers, e.g. `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Persistence/JSONLTranscriptWriter.swift:56–63` (`handle.write` only; `synchronize()` never called)
- **Why:** `FileHandle.write` lands in the page cache. On app crash the data survives (kernel owns it), but on kernel panic / power loss minutes of transcript can vanish even though the events were "persisted". For a tool whose sidecar is consumed live by another process, an occasional `synchronize()` (e.g. every N segments or 30 s) is cheap insurance.
- **Fix:** Periodic `try handle.synchronize()` from the sidecar actor.
- **Severity:** Low

### F27. Per-write encoder/decoder churn and minor inefficiencies — LOW

- **Files:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Persistence/JSONLTranscriptWriter.swift:153` (`try JSONEncoder().encode(wire)` — new encoder per segment write); `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/Azure/Realtime/AzureOpenAIRealtimeSession.swift:214, 475` (new `JSONDecoder()`/`JSONEncoder()` per WS message — tens per second under partial storms).
- **Fix:** Hoist to `static let` / stored properties.
- **Severity:** Low

---

## 5. On-device providers (WhisperKit, Parakeet)

### F28. Lazy model load swallows the first ~N seconds of every cold-start recording — HIGH

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/WhisperKitTranscriptionProvider.swift:118–124, 170–198`
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/ParakeetTranscriptionProvider.swift:96–101, 152–186`
  - interaction: `SourceBuffer.swift:23–31` (5 s cap, drops 50%), `TranscriptionManager.swift:317–336` (both in-flight slots blocked)

```swift
let pipe: WhisperKit
do {
    pipe = try await ensureLoaded()    // first call: full model load (and possibly ~620 MB download)
}
```

- **Why it's a problem:** Model load happens inside the **first** `transcribe` call. On a warm cache, WhisperKit large-v3 load is typically 3–15 s (ANE compilation); first-ever run is a 620 MB download. During this time both in-flight slots per source are occupied awaiting `ensureLoaded`, the process loop blocks in `spawnProviderCall` (F5), and `SourceBuffer` silently halves itself every time it crosses 5 s (F6). Net effect: the first 10 s–minutes of speech are mostly **discarded** with no user-visible signal — exactly the part of a meeting ("intro, agenda") users most want. There is also no warm-up hook: `TranscriptionManager.start()` doesn't touch the provider.
- **Fix:** (a) Kick off `ensureLoaded()` eagerly when the pipeline starts (a `prepare()`/`warmUp()` member on `TranscriptionProvider` with a default no-op, called from `startBatchPipeline`); (b) while loading, raise the `SourceBuffer` cap (or buffer to a temp spill) so audio captured during load is transcribed once the model is ready; (c) emit a `.metricsTick`/disclosure-style event ("model loading…") so the UI can explain the silence.
- **Severity:** High

### F29. `--transcribe-source both` loads TWO copies of the on-device model (≈2× RAM, 2× ANE compile) — MEDIUM

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/RecordingSession.swift:1203–1212` (calls `buildSingleModeManager` twice; each calls `resolveTranscriptionProvider()` → fresh provider via the factory)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/SourceSplitTranscriptionManager.swift:10–12` ("Each inner manager owns its own provider instance")

```swift
let (sysMgr, _, sysSummary) = try await buildSingleModeManager(... sourceOverride: .system ...)
let (micMgr, _, micSummary) = try await buildSingleModeManager(... sourceOverride: .mic ...)
```

- **Why it's a problem:** For cloud providers two instances are correct (per-source connections). For `whisperkit`/`parakeet` it means two full `WhisperKit`/`AsrManager` instances: ~2× the model's working set (WhisperKit large-v3 is on the order of 1+ GB resident with ANE buffers; Parakeet ~600 MB class), double ANE/GPU compile time on first chunk, and contention between two simultaneous inferences on the same accelerator. Parakeet explicitly supports per-source decode state through one manager (`AsrManager.transcribe(_, source:)` — the provider already routes `.system`/`.microphone`), so the duplication buys nothing there.
- **Fix:** In the `.sourceSplit` arm, resolve the provider **once** and hand the same actor instance to both child managers when `provider` is on-device (the providers are actors; concurrent `transcribe` calls already serialize/dedup via `ensureLoaded`). Keep per-child instances for streaming cloud providers.
- **Severity:** Medium

### F30. `SpeechAnalyzerAdapter` input buffer drops audio silently during asset download / analyzer slowness — MEDIUM

- **File:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/SpeechAnalyzerAdapter.swift:166–168, 207–235, 263–269`

```swift
let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream(
    bufferingPolicy: .bufferingNewest(64)
)
...
Task {                                  // setup: asset check + downloadAndInstall + analyzer.start
    ... try await req.downloadAndInstall() ...
    try await analyzerRef.start(inputSequence: inputStream)
}
...
public func ingest(_ samples: [Float]) async {
    ... inputContinuation.yield(input)  // dropped beyond 64 buffered inputs
}
```

- **Why it's a problem:** Until `analyzer.start` consumes the input stream, ingests pile into the 64-element `bufferingNewest` buffer. The setup task can legitimately take **minutes** on first run (locale asset download). At ~10 ingests/sec the buffer covers ~6 s; everything older is silently discarded (`bufferingNewest` drops the *oldest*), with no counter or event. Same applies steady-state if the analyzer falls behind. Also the setup `Task` and forwarding `Task` in `init` are unstored — `finalizeAndFinish` cannot cancel a stuck `downloadAndInstall`.
- **Fix:** Surface drops (instrument a counter via `continuation.yield`'s discarded-result), enlarge the buffer or spill, emit a "downloading model" event so the pipeline/UI know why nothing is arriving, and store the setup task for cancellation.
- **Severity:** Medium

---

## 6. Duplication / missing shared abstractions

### F31. HTTP retry engine duplicated (Azure batch, ElevenLabs) and absent where needed (Gemini) — MEDIUM

- **Files:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/Azure/AzureOpenAITranscriptionProvider.swift:207–289` (`postWithRetries`, `delayForRetry`, `parseRetryAfterSeconds`, `jitter`, transient `URLError` set)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/ElevenLabs/ElevenLabsTranscriptionProvider.swift:294–353` (near-identical `postWithRetries` + `delayForAttempt` + the same 5-element transient set)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift:96–104` (no retry at all)
- **Why:** Two hand-rolled copies of the same loop (same max attempts, same jitter band, same transient-error taxonomy) have already drifted (Azure honours `Retry-After`; ElevenLabs has the 429-concurrent special case); Gemini never got the feature. Every future REST provider re-implements it.
- **Fix:** Extract `HTTPRetryPolicy.post(request:body:session:isRetryable:logger:)` in `Transcription/Net/` (next to `MultipartFormDataBuilder`) with injectable per-provider hooks (retryable status set, `Retry-After` parsing, non-retryable short-circuit). Adopt in all three providers.
- **Severity:** Medium

### F32. Float32↔Int16 PCM conversion implemented five times — MEDIUM

- **Locations:**
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/TranscriptionManager.swift:421–433` (`int16BytesToFloat`)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Live/Soniox/SonioxStreamingSession.swift:333–351` (`float32ToInt16LEBytes`, with its own clamping convention)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/SpeechAnalyzerAdapter.swift:308–322` (`makePCMBuffer`, scale 32767)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/AudioWAVEncoder.swift:32–36` (scale `Int16.max`)
  - `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Providers/AppleCloudTranscriptionProvider.swift:268–282` (Float buffer copy variant)
- **Why:** Five scalar loops with **three different scaling/clamping conventions** (asymmetric `Int16.min` vs symmetric 32767 vs `Int16.max`), all un-vectorized, in the hottest per-chunk path. Subtle level differences between providers (≤1 LSB) and a maintenance hazard.
- **Fix:** One `PCMConvert` enum (vDSP-backed `floatToInt16LE(_:) -> Data`, `int16LEToFloat(_:) -> [Float]`, `floatToPCMBuffer(...)`) with a single documented convention; delete the copies.
- **Severity:** Medium

### F33. Tombstone/in-place rewrite machinery duplicated across all four format writers — MEDIUM

- **Files:** `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool/Sources/NtakkerCore/Transcription/Persistence/{JSONL,TXT,SRT,VTT}TranscriptWriter.swift` — e.g. JSONL:56–104, TXT:37–75, SRT:45–91 (VTT mirrors SRT)
- **Why:** The `index: [UUID: Range<UInt64>]`, short-grow padding, long-grow tombstone+append, `createFile`+`FileHandle(forUpdating:)` lifecycle is copy-pasted four times with only the rendering and tombstone payload differing. A fix like F24's truncation guard or F26's fsync must be applied in four places.
- **Fix:** Extract a `ByteRangeRewritingFileWriter` (owns handle + index + the two grow paths, parameterized by `render(segment) -> Data` and `tombstone(oldLen, segment) -> Data`); format writers become ~30-line renderers.
- **Severity:** Medium

### F34. Smaller duplications — LOW

- `stripBCP47Region` duplicated verbatim: `AzureOpenAITranscriptionProvider.swift:149–156` and `ElevenLabsTranscriptionProvider.swift:235–242`.
- Lazy deduplicated model-loader pattern (`pipe/loadTask` dance) duplicated: `WhisperKitTranscriptionProvider.swift:170–198` vs `ParakeetTranscriptionProvider.swift:152–186` — a generic `actor ModelLoader<T>` would serve both (and any future on-device provider).
- Legacy `var continuation: ...Continuation!` capture-from-closure boilerplate in `SonioxStreamingSession.swift:99–101`, `AzureOpenAIRealtimeSession.swift:99–103`, `AppleCloudTranscriptionProvider.swift:249–258` — `AsyncStream.makeStream` (already used elsewhere in the same module) does this in one line.
- Per-session metrics counting / `isFinished` / continuation-finish lifecycle re-implemented in each of the four streaming session types — candidates for a shared `StreamingSessionCore` mixin once F9's reconnect work touches Soniox anyway.
- **Severity:** Low

---

## Summary table

| # | Finding | Area | Severity |
|---|---------|------|----------|
| F1 | Unordered fire-and-forget Task hops can reorder audio chunks | Streaming perf | High |
| F2 | Completion-order coalescing reorders batch transcript text | Streaming perf | Medium |
| F3 | Azure realtime resampler rebuilt per chunk → boundary artifacts | Streaming perf | Medium |
| F4 | Triple Float↔Int16 conversion per chunk, no vDSP | Streaming perf | Medium |
| F5 | Slow provider on one source stalls the other source's drain | Streaming perf | Medium |
| F6 | Buffer-overflow audio drops are invisible (no log/metric/event) | Streaming perf | Medium |
| F7 | Per-sample `Data.append` in WAV encoder | Streaming perf | Low |
| F8 | Samples dropped while streaming session-open is in flight | Streaming perf | Low |
| F9 | Soniox: no reconnect; dead transport → per-chunk error spam, transcription dead | Network | High |
| F10 | Azure realtime: replay/live audio sent before session is configured | Network | High |
| F11 | Azure realtime: pre-emptive reconnect races close-triggered reconnect | Network | Medium |
| F12 | Azure realtime backoff is 0/4/16 s, not the documented 0/1/4 s | Network | Low |
| F13 | Gemini: no retry, no timeout, API key in URL query | Network | Medium |
| F14 | Apple Cloud: tight error-restart loop without backoff | Network | Medium |
| F15 | Batch pipeline lacks a circuit breaker for dead providers | Network | Medium |
| F16 | WS transport connect() never performs handshake; pre-flight contract illusory | Network | Low |
| F17 | Soniox finish() always pays full 2 s grace sleep | Network | Low |
| F18 | TranscriptionManager.stop() drain deadline not actually enforced | Concurrency | High |
| F19 | StreamingTranscriptionPipeline: session attached after stop() leaks (WS/keepalive/SFSpeech task) | Concurrency | High |
| F20 | AppleSpeechSession.finish() can drop late finals (forwarders not awaited) | Concurrency | Medium |
| F21 | Apple Cloud force-finish at 1.5 s cuts off in-flight final utterance | Concurrency | Medium |
| F22 | Source-split merged stream emits colliding segment indices | Concurrency | Medium |
| F23 | `streamingPipeline!` force-unwraps where a typed error was promised | Concurrency | Low |
| F24 | rotateSidecar in source-split mode: both children open the SAME file (truncation/corruption after split) | Sidecar | High |
| F25 | Batch sidecar tombstone-per-update amplification (~1,400/hr) | Sidecar | Medium |
| F26 | No periodic fsync on sidecars | Sidecar | Low |
| F27 | Per-write JSONEncoder/JSONDecoder churn | Sidecar | Low |
| F28 | Lazy on-device model load discards the first seconds/minutes of audio | On-device | High |
| F29 | `--transcribe-source both` double-loads the on-device model | On-device | Medium |
| F30 | SpeechAnalyzer input buffer (64) silently drops audio during asset download | On-device | Medium |
| F31 | HTTP retry engine duplicated (Azure/ElevenLabs) and missing (Gemini) | Duplication | Medium |
| F32 | Float↔Int16 conversion implemented 5× with 3 conventions | Duplication | Medium |
| F33 | Tombstone-rewrite machinery duplicated across 4 format writers | Duplication | Medium |
| F34 | Minor duplications: stripBCP47Region, model-loader pattern, continuation boilerplate, session lifecycle | Duplication | Low |

**Recommended attack order:** F24 (data loss, small fix) → F19 + F18 (leaks/hangs on stop) → F9 + F10 (cloud-streaming session death) → F28 (on-device cold start) → F1 (ordering) → the medium-tier performance/duplication items, ideally landing F31–F33 as enabling refactors first.
