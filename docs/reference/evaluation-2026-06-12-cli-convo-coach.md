# ntakker — CLI / Infrastructure / convo-coach Review

Date: 2026-06-12
Reviewer: automated code review (performance / functionality / robustness)
Repo: `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool` @ `e4cd174` (master, clean)

Scope A — Swift CLI + infrastructure: `Sources/ntakker-cli/main.swift`, `Sources/NtakkerCore/{Config,Daemon,Bootstrap,Logging,Permissions,Errors,Asking}/`
Scope B — TypeScript tool: `tools/convo-coach/src/`

Severity legend: **HIGH** = correctness/availability risk or material cost on the default path; **MEDIUM** = real but bounded impact or degraded UX; **LOW** = polish, latent risk, or maintenance burden.

---

## Scope A — Swift CLI and infrastructure

### A1. `fork()` is called after the Swift Concurrency runtime has started — violates the Daemonizer's own precondition (HIGH)

- **Files:**
  - `Sources/ntakker-cli/main.swift:20-25`
  - `Sources/ntakker-cli/Commands/StartCommand.swift:172-192`
  - `Sources/NtakkerCore/Daemon/Daemonizer.swift:12-19, 119`

```swift
// main.swift
await asyncMainEntry()            // ← top-level await: concurrency executor threads exist NOW

// StartCommand.swift (run() is `async` — executes on the cooperative pool)
if options.runMode == .detached {
    try Daemonizer.detach( ... )  // line 174 — fork() happens here
}
```

```swift
// Daemonizer.swift header:
// CRITICAL: This function MUST be called BEFORE any thread is created
// in the process. `fork()` after thread creation is unsafe on macOS ...
```

- **Why it's a problem:** The entrypoint is an async `main` (`await RootCommand.main(nil)`), and `StartCommand.run()` is an `async` method. By the time `Daemonizer.detach` executes, the Swift Concurrency cooperative thread pool (and typically a libdispatch worker or two) already exists — `run()` is very likely *executing on* one of those pool threads, not the initial thread. `fork()` then clones only the calling thread; in the grandchild, the rest of the executor pool is gone but its locks/state were cloned mid-flight. The grandchild immediately resumes `try await session.run()` on a half-cloned concurrency runtime. This is exactly the hazard the file header warns about; it can manifest as rare post-fork hangs (malloc/dispatch lock held by a dead thread), not deterministic failures — the worst kind of bug for a long-running recorder. The comment in `StartCommand.swift:18-20` ("we daemonize BEFORE constructing RecordingSession so no framework thread has been spun up yet") is factually wrong for an async command: the concurrency runtime *is* a framework with threads.
- **Suggested fix (pick one):**
  1. **Re-exec instead of double-fork** (most robust on macOS): the parent `posix_spawn`s its own binary with the same args plus an internal `--_daemon-child` flag (and the already-resolved config serialized via env or a temp file), then exits. The child calls `setsid()` + fd redirection in a fresh single-threaded process before ArgumentParser/async ever runs. Apple explicitly recommends spawn-over-fork for daemons.
  2. Alternatively, hoist detach detection into `main.swift` *before* `await`: scan `CommandLine.arguments` for `--detach`/`NTAKKER_DETACH` synchronously, daemonize there (still pre-thread, since nothing async has run), then fall through into the async parser.
- **Severity:** HIGH

### A2. `stop` will SIGTERM whatever process currently owns the recorded PID — no identity check (PID-reuse hazard) (HIGH→MEDIUM)

- **Files:**
  - `Sources/ntakker-cli/Commands/StopCommand.swift:156` (`kill(pid, SIGTERM)`)
  - `Sources/NtakkerCore/Daemon/PidFile.swift:163-192` (`isAlive` = bare `kill(pid, 0)`)

```swift
let killRC = kill(pid, SIGTERM)
```

- **Why it's a problem:** If the daemon crashed (SIGKILL, panic, power loss) the PID file survives. PIDs on macOS recycle; after enough process churn (or a reboot where the file persisted in `~/.tool-agents/...`), the stored PID can belong to an unrelated process. `isAlive` answers "is *some* process with this PID alive" — including EPERM-owned root processes — so `stop` happily SIGTERMs an innocent victim. The poll loop then waits 35 s and reports `stopTimeout` if the victim ignores SIGTERM.
- **Suggested fix:** Verify identity before signalling: store the process **start time** (or executable path) alongside the PID at write-time, and at stop-time compare against `proc_pidpath(pid, ...)` / `sysctl KERN_PROC_PID → kp_proc.p_starttime`. If the identity doesn't match, treat as stale (remove file, exit 75) instead of killing.
- **Severity:** HIGH for the kill-the-wrong-process path (rare but destructive); at minimum MEDIUM.

### A3. `ntakker-cli stop` runs the FULL config resolution — unrelated config errors make a recording unstoppable (MEDIUM)

- **Files:**
  - `Sources/ntakker-cli/Commands/StopCommand.swift:71-93`
  - `Sources/NtakkerCore/Config/ConfigResolver.swift:396-439` (hard-fail API-key checks), `255-261` (default provider `.apple`)

```swift
// StopCommand: "We reuse ConfigResolver ... we then discard everything
// except pidFile and stopTimeout."
resolved = try ConfigResolver(toolName: "ntakker-cli").resolve(cliOverrides: overrides)
```

- **Why it's a problem:** `resolve()` validates the *entire* option surface, including transcription credentials. If the user's `~/.tool-agents/ntakker-cli/.env` says `NTAKKER_TRANSCRIBE=soniox` and the `SONIOX_API_KEY` has since been removed (or `ELEVENLABS_NUM_SPEAKERS=40`, or any other unrelated typo), `stop` exits 78/64 **without ever reading the PID file** — the running daemon cannot be stopped through the documented interface. It also wastes startup time on `stop` (two `.env` parses + ~50 validations + possible `SFSpeechRecognizer.supportedLocales()` framework load when Apple hints are configured, lines 355-370).
- **Suggested fix:** Add a narrow `ConfigResolver.resolveStopOptions(cliOverrides:)` that merges the four tiers but parses only `NTAKKER_PID_FILE`, `NTAKKER_STOP_TIMEOUT`, `NTAKKER_LOG_LEVEL`. Same precedence semantics, no transcription validation. (The `/dev/null` OUTPUT_PATH placeholder hack at lines 79-83 disappears too.)
- **Severity:** MEDIUM (functional availability of `stop`)

### A4. PID-file creation is not exclusive — TOCTOU race between the already-recording guard and the write (MEDIUM)

- **File:** `Sources/NtakkerCore/Daemon/PidFile.swift:85-133`

```swift
// Use atomic write via Data.write ...
try data.write(to: url, options: [.atomic])
```

- **Why it's a problem:** `write` unconditionally replaces any existing file. The already-recording guard (read → `isAlive` → write, performed by `RecordingSession`) is check-then-act: two `start --detach` invocations racing through the gap both pass the check and the second silently clobbers the first daemon's PID file. The first recorder is then orphaned — `stop` can only ever see the second. The file header (lines 16-18) declares multi-writer races "not a documented scenario", but double-invocation from a hotkey/script is exactly how this happens in practice.
- **Suggested fix:** Use `open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)` for the initial claim and map `EEXIST` into the read/isAlive/stale-takeover flow (unlink + retry once). Alternatively take a `flock` on the PID file for the daemon's lifetime — stale detection then becomes "can I get the lock?" which is immune to PID reuse (also helps A2).
- **Severity:** MEDIUM

### A5. Screen-recording permission can never report `.notDetermined` — fresh installs get "denied" (exit 77) and the prompt-path in the gate is dead code (MEDIUM)

- **Files:**
  - `Sources/NtakkerCore/Permissions/ScreenRecordingPermission.swift:41-43`
  - `Sources/NtakkerCore/Permissions/PermissionGate.swift:105-118`

```swift
public static func current() -> State {
    CGPreflightScreenCaptureAccess() ? .authorized : .denied   // never .notDetermined
}
```

```swift
switch ScreenRecordingPermission.current() {
case .notDetermined:                      // unreachable
    ScreenRecordingPermission.request()
    throw NtakkerError.screenRecordingPermissionNotDetermined  // exit 75
case .denied:
    throw NtakkerError.screenRecordingPermissionDenied         // exit 77 ← what users actually get
```

- **Why it's a problem:** `CGPreflightScreenCaptureAccess` cannot distinguish never-asked from explicitly-denied (the file's own doc comment says so), and `current()` maps both to `.denied`. Consequently `requireBothOrThrow()` on a first run throws `screenRecordingPermissionDenied` (exit 77, EX_NOPERM) with remediation telling the user to flip a System Settings toggle that **does not exist yet** (the binary was never added to the list), and never triggers the OS prompt. The carefully designed exit-75 "prompt triggered, relaunch" flow is unreachable for screen recording.
- **Suggested fix:** When preflight returns `false`, call `CGRequestScreenCaptureAccess()` (or `SCShareableContent.current`) once: if it returns `true` proceed; otherwise distinguish "first prompt just shown" (throw `...NotDetermined`, exit 75) from "previously denied" — e.g. persist a `screen-prompt-shown` marker under `~/.tool-agents/ntakker-cli/` since TCC state itself is unreadable, or use the async `currentAsync()` (already implemented at lines 51-60) as the authoritative read.
- **Severity:** MEDIUM (first-run UX + wrong error/exit code)

### A6. UI file logging is a synchronous write under a global lock on every emit (MEDIUM)

- **File:** `Sources/NtakkerCore/Logging/LoggerFactory.swift:546-564`

```swift
func append(_ line: String) {
    let data = Data(line.utf8)
    lock.lock()
    defer { lock.unlock() }
    ...
    try handle.write(contentsOf: data)   // sync disk I/O on the caller's thread
```

- **Why it's a problem:** Every `Logger` call in the UI process formats a `DateFormatter` timestamp, takes the shared `NSLock`, and performs a blocking `FileHandle.write` on the *calling* thread. Subsystems include capture (`ntakker-cli.capture.system`, `.capture.mic`) — log lines emitted from audio-pipeline paths stall on disk latency and serialize all logging threads through one lock. At `debug` level during transcription this is a measurable hot-path tax; if the disk hiccups (APFS snapshot, low space) the audio thread blocks.
- **Suggested fix:** Make `FileLogSink` enqueue onto a dedicated serial `DispatchQueue` (or an `AsyncStream` consumer) and write in batches with periodic flush; keep the lock only around the buffer swap. Drop-on-overflow beyond a bounded queue keeps it crash-safe ("log loss preferable to log-induced stall" — same philosophy already in the catch block at line 562).
- **Severity:** MEDIUM

### A7. No log rotation or size cap anywhere — daemon and UI logs grow without bound (MEDIUM)

- **Files:**
  - `Sources/NtakkerCore/Daemon/Daemonizer.swift:124-127` (`O_WRONLY | O_CREAT | O_APPEND`, no size policy)
  - `Sources/NtakkerCore/Logging/LoggerFactory.swift:502-544` (`FileLogSink.open` — `seekToEndOfFile`, append forever)

- **Why it's a problem:** `~/.tool-agents/ntakker-cli/ntakker-cli.log` (detached CLI) and the UI log file accumulate across every session forever. A daemon left at `--log-level debug` with live transcription emits per-chunk lines for hours — hundreds of MB are realistic, and nothing ever truncates, rotates, or warns.
- **Suggested fix:** Cheapest robust option: at open time, if the file exceeds a threshold (e.g. 10 MB), rename to `<name>.log.1` (keep one or two generations) before opening fresh. Both sinks already funnel opens through a single place each, so this is a ~20-line change.
- **Severity:** MEDIUM

### A8. Ask HTTP failures are reported as `transcriptionProviderUnavailable` — wrong taxonomy, wrong remediation (MEDIUM)

- **Files:**
  - `Sources/NtakkerCore/Asking/OpenAICompatibleAskClient.swift:50-52`
  - `Sources/NtakkerCore/Errors/NtakkerError.swift:224-225, 326-327`

```swift
continuation.finish(throwing: NtakkerError.transcriptionProviderUnavailable(
    reason: "HTTP \(http.statusCode) from \(config.provider.displayName): \(body)"
))
```

```swift
case .transcriptionProviderUnavailable:
    return "Verify the provider configuration (model id, endpoint) and try again,
            or pass '--transcribe none' to disable live transcription."
```

- **Why it's a problem:** A 401 from the *Ask* (in-recording Q&A) LLM endpoint surfaces with a message that says "transcription provider unavailable" and remediation that tells the user to pass `--transcribe none` — both wrong and actively confusing, since the user's transcription provider may be perfectly healthy. It also pollutes the locked design-§2.1 string contract: regression tests asserting that string now cover two unrelated features.
- **Suggested fix:** Add dedicated cases (`askProviderUnavailable(reason:)`, `askConfigMissing(...)` if desired) mapping to the same exit buckets (70/78), with Ask-specific remediation ("check NTAKKER_ASK_PROVIDER / NTAKKER_ASK_MODEL and the provider key…").
- **Severity:** MEDIUM

### A9. Two divergent `.env` parsers; UI-side parse failures are silently swallowed (LOW→MEDIUM)

- **Files:**
  - `Sources/NtakkerCore/Config/DotEnvParser.swift:49-141` (full parser: quotes, trailing comments, throws on malformed lines)
  - `Sources/NtakkerCore/Bootstrap/EnvFileStore.swift:145-162` (minimal parser: no quote stripping, no comment handling in values), `:66-75`

```swift
// EnvFileStore.loadIntoProcess
guard let parsed = try? parse(at: url) else {
    return [:]              // malformed .env silently contributes nothing
}
```

- **Why it's a problem:** (1) Behavioural divergence: `KEY="value with spaces"` resolves to `value with spaces` in the CLI (DotEnvParser strips quotes) but to `"value with spaces"` — quotes included — in the UI (`EnvFileStore.parse` keeps them, and `loadIntoProcess` `setenv`s the quoted string). A credential saved with quotes works in one surface and 401s in the other. (2) The CLI hard-fails on a malformed `.env` (exit 64, per the no-fallback rule), while the UI's `try?` silently ignores the entire file — the Settings panel then shows stale shell values with no hint why. (3) `EnvFileStore.upsert` writes values unquoted, so a value containing ` # ` would be re-read differently by `DotEnvParser` (trailing-comment stripping).
- **Suggested fix:** Make `EnvFileStore.parse` delegate to `DotEnvParser.parseFile`, and have `loadIntoProcess` surface parse errors (log + user-visible warning) instead of `try?`. Quote values in `upsert` when they contain `#`, quotes, or leading/trailing whitespace.
- **Severity:** MEDIUM for the quote divergence; LOW for the rest.

### A10. Config-chain semantics: empty string at a higher tier silently falls through to a lower tier (LOW)

- **File:** `Sources/NtakkerCore/Config/ConfigResolver.swift:89-95`

```swift
func value(_ key: String) -> String? {
    if let v = cliOverrides[key], !v.isEmpty { return v }
    if let v = localEnv[key], !v.isEmpty { return v }
    if let v = userEnv[key], !v.isEmpty { return v }
    if let v = shellEnv[key], !v.isEmpty { return v }
    return nil
}
```

- **Why it's a problem:** Setting `NTAKKER_TRANSCRIBE=` (empty) in `./.env` does **not** clear a value from `~/.tool-agents/.env` or the shell — the empty entry is invisible and the lower tier leaks through. convo-coach implements the opposite, deliberate semantics (`tools/convo-coach/src/config.ts:172-181`: empty value *clears* lower tiers). Two tools in the same project, same documented four-tier chain, opposite behaviour for the same `.env` line. Users moving between the tools will be surprised.
- **Suggested fix:** Align on the convo-coach behaviour (empty = explicit unset) or document the difference prominently in both `docs/tools/*.md` files.
- **Severity:** LOW

### A11. `~/.tool-agents` bootstrap chmods on every invocation; per-resolve formatter allocations (LOW)

- **Files:**
  - `Sources/NtakkerCore/Bootstrap/ToolAgentsBootstrap.swift:94-103, 124-135` — two unconditional `setAttributes` (chmod) calls on every CLI run, even when modes are already correct.
  - `Sources/NtakkerCore/Config/ConfigResolver.swift:1253-1273` — up to three date formatters (`ISO8601DateFormatter` ×2 + `DateFormatter`) constructed per expiry key parsed, per `resolve()` call.
- **Why it's a problem:** Pure startup-latency / syscall noise. Individually trivial (~tens of µs), but `ensure()` runs for every subcommand including `stop` and `check-permissions`, and `resolve()` is also invoked by the UI. Formatter construction is the documented expensive case (the logging code at `LoggerFactory.swift:466-471` already caches one for exactly this reason — the convention just wasn't applied here).
- **Suggested fix:** `stat` first and chmod only when the mode differs; hoist the three formatters to `static let`s (they're only mutated at init; `ISO8601DateFormatter` configured once is safe to reuse).
- **Severity:** LOW

### A12. `AskConfigResolver` silently defaults/clamps `NTAKKER_ASK_CONTEXT_MINUTES` on invalid input (LOW)

- **File:** `Sources/NtakkerCore/Asking/AskConfig.swift:114-119`

```swift
let contextMinutes: Int = {
    guard let raw = nonEmpty(env["NTAKKER_ASK_CONTEXT_MINUTES"]),
          let n = Int(raw)
    else { return 5 }          // "abc" → silently 5
    return min(30, max(1, n))  // 9999 → silently 30
}()
```

- **Why it's a problem:** The project's no-fallback rule (CLAUDE.md) distinguishes *unset* (documented default OK for this operational knob) from *invalid* (must raise). `NTAKKER_ASK_CONTEXT_MINUTES=abc` or `=0` silently becomes 5/1 with no diagnostic — inconsistent with `ConfigResolver`, which throws `invalidConfigValue` for every comparable knob (e.g. `parseOptionalNonNegativeInt`, `ConfigResolver.swift:1222-1232`).
- **Suggested fix:** Throw `NtakkerError.invalidConfigValue(key:value:expected: "integer in 1...30")` when the raw value is present but non-numeric or out of range; keep the default only for the unset case.
- **Severity:** LOW

### A13. `AskPromptBuilder` head-truncation is O(n²); Ask client has no timeout/retry tuning (LOW)

- **Files:**
  - `Sources/NtakkerCore/Asking/AskPromptBuilder.swift:110-116`
  - `Sources/NtakkerCore/Asking/OpenAICompatibleAskClient.swift:26-39`

```swift
var assembled = lines.joined(separator: "\n")
while assembled.utf8.count > maxTranscriptBytes && !lines.isEmpty {
    lines.removeFirst()                       // O(n) shift
    assembled = lines.joined(separator: "\n") // O(total bytes) re-join per dropped line
}
```

- **Why it's a problem:** With a long `.full` window the loop re-joins the whole transcript once per dropped line and `removeFirst()` shifts the array each time — quadratic in segment count. 32 KB cap bounds the damage, but a multi-hour transcript (thousands of segments, several hundred KB) makes this a visible UI stall on the main ask path. Separately, the client uses `URLSession.shared` defaults (60 s request timeout, no retry on transient 429/5xx) — acceptable for v1 but worth a deliberate `URLSessionConfiguration` with a shorter `timeoutIntervalForRequest` so a dead endpoint doesn't freeze the popover's spinner for a minute.
- **Suggested fix:** Precompute per-line UTF-8 byte counts, walk from the tail accumulating until the cap, then slice once. Give the client an injected `URLSessionConfiguration` (e.g. 15 s request timeout) and map `URLError.timedOut` to a clear inline error.
- **Severity:** LOW

### A14. Exit-code taxonomy nits (LOW)

- **File:** `Sources/NtakkerCore/Errors/NtakkerError.swift:82-131`
- Observations:
  - `pidFileWriteFailed` → 66 `EX_NOINPUT` (line 97-100). The PID file is an *output* artifact; `EX_CANTCREAT` (73) or `EX_IOERR` (74) is the conventional bucket. Cosmetic since the table is "locked", but worth fixing at the next design revision.
  - `staleRecording` → 75 `EX_TEMPFAIL`: `stop` against a stale file *removes the file and leaves the system in the desired state*, yet still exits non-zero — scripted callers (`ntakker-cli stop || alert`) get false alarms after any daemon crash. Consider exit 0 with a warning, or document the 75 contract loudly.
  - Strengths worth keeping: locked description/remediation pairs, sysexits-aligned buckets, every error self-describes its fix — this is a model error surface overall.
- **Severity:** LOW

---

## Scope B — convo-coach (TypeScript)

### B1. Stdin mode: unbounded buffer + full re-parse of the entire history on every trigger (HIGH)

- **Files:**
  - `tools/convo-coach/src/transcript/stdin.ts:139-144` (accumulate), `:206-216` (re-parse, "Buffer is intentionally NOT reset")
  - `tools/convo-coach/src/transcript/jsonl.ts:39-136` (`parseJsonl` walks every line)

```ts
stdinRl.on('line', (line: string) => {
    buffer += line + '\n';            // grows forever
    ...
});
...
const records = parseBuffer(buffer, now);  // EVERY trigger re-parses EVERYTHING
yield { records, transcriptEnd: now, reason };
// Buffer is intentionally NOT reset — each yield contains the
// accumulated history
```

- **Why it's a problem:** This is the tool's long-lived "live coaching" mode (`tail -f transcript | convo-coach`). Per trigger it: (1) string-concatenates the whole history (`buffer += line` is O(buffer) amortised but the buffer itself is unbounded — a multi-hour meeting at a few KB/min is fine, an all-day dual-channel session is tens of MB held twice: raw buffer + parsed records); (2) re-splits and re-`JSON.parse`s every line ever seen — O(n) work per trigger → O(n²) over the session; (3) re-emits the *same* `console.warn` for every previously-seen malformed line on every trigger (`jsonl.ts:56-58`), so one bad line warns dozens of times per hour. The windowing layer then throws most of the re-parsed records away (`--last 5m` is the documented usage).
- **Suggested fix:** Parse incrementally: on each `line` event, parse that one line into a `NormalisedRecord` (or skip/warn once) and push to a persistent `records` array; each trigger then snapshots/filters the array. Optionally evict records older than the largest window in play (or cap at N records) to bound memory. The format sniff (`looksLikeJsonl`) only needs the first non-blank line, which is already available on first parse.
- **Severity:** HIGH

### B2. Default provider (azure-openai) almost always hits the 8 000-token "unknown model" fallback → silent aggressive truncation (HIGH)

- **Files:**
  - `tools/convo-coach/src/llm/model-context-windows.ts:53-69`
  - `tools/convo-coach/src/llm/default-models.ts:52-62` (azure model id = deployment name)
  - `tools/convo-coach/src/llm/budget.ts:119-120`

```ts
const UNKNOWN_MODEL_FALLBACK = 8_000;
...
console.warn(`Unknown model '${modelId}' — assuming 8000-token context window. ...`);
return UNKNOWN_MODEL_FALLBACK;
```

- **Why it's a problem:** For `azure-openai` — the tool's **default** provider per Exception 003 — the "model id" used everywhere is the Azure *deployment name* (`resolveModel` returns `AZURE_OPENAI_DEPLOYMENT`). Deployment names ("gpt-5.1", "prod-coach", whatever the user typed in the portal) essentially never match the keys in `MODEL_CONTEXT_WINDOWS`, so every default-path run gets `8000 × 0.85 ≈ 6 800` usable tokens and `truncate-start` silently throws away most of a long transcript — while the actual deployment may have a 128k–1M window. The user sees one stderr warning per invocation (per *trigger* in stdin mode) and degraded advice quality with no obvious cause. The table is also already drifting (no gpt-5.x, no newer claude/gemini ids), which sends ever more traffic to the fallback.
- **Suggested fix:** (1) Add a `COACH_CONTEXT_WINDOW` config key (the project pattern: documented operational default, explicit override) consulted before the table. (2) For azure, try a longest-prefix/substring match of the deployment name against known model families before falling back. (3) Raise the unknown fallback to something defensible for current chat models (e.g. 32k) or make `--on-overflow error` the behaviour for unknown models so truncation is never silent.
- **Severity:** HIGH (quality/cost on the default path)

### B3. One transient provider error kills the entire long-lived stdin session; no retries anywhere (MEDIUM→HIGH)

- **Files:**
  - `tools/convo-coach/src/index.ts:318-335` (throws out of the `for await` loop)
  - `tools/convo-coach/src/output/stream.ts:154-181` (all errors flattened to `ProviderError`)

```ts
} catch (err) {
    try { sidecar.appendFooter(...); sidecar.close(); } catch { }
    throw err;        // ← exits runStdinMode → process exits (code 70)
}
```

- **Why it's a problem:** In live mode the user has a coaching loop attached to an ongoing conversation. A single 429 (rate limit), momentary network blip, or provider 500 terminates the process; the user discovers it minutes later when no advice arrives. There is no retry/backoff at any layer, and `ProviderError(\`stream failed: ${message}\`)` discards the HTTP status / error class, so callers can't even distinguish retryable from fatal. (LangChain's `maxRetries` default may cover some setup errors, but mid-stream failures and the orchestrator level are unprotected.)
- **Suggested fix:** In `runStdinMode`, catch per-iteration errors: write the error footer (already done), log to stderr, and `continue` to the next trigger — only exit on `ConfigError`/`UsageError` or N consecutive failures. Add bounded exponential backoff (e.g. 1s/4s/15s) for 429/5xx/network errors; preserve `status` on `ProviderError` (LangChain errors expose `status`/`error.code`) to drive the retryable classification.
- **Severity:** HIGH for live-mode availability; MEDIUM in file mode.

### B4. `SidecarWriter.write` does `appendFileSync` per streaming delta — open/write/close syscalls per token chunk (MEDIUM)

- **File:** `tools/convo-coach/src/output/sidecar.ts:180-186`

```ts
write(chunk: string): void {
    ...
    fs.appendFileSync(this.tempPath, chunk, 'utf8');  // open+write+close EVERY delta
}
```

- **Why it's a problem:** `appendFileSync(path, ...)` opens the file, writes, and closes it on every call. A streamed completion delivers hundreds of small deltas; that's hundreds of synchronous open/close round-trips blocking the event loop mid-stream (and `runOneAdvice` awaits each sink write before pulling the next chunk — `stream.ts:172-175` — so it directly adds to inter-token latency on stdout too).
- **Suggested fix:** Open the temp file once in the constructor (`fs.openSync(tempPath, 'a')`), use `fs.writeSync(fd, chunk)` in `write()`, and `fs.closeSync(fd)` before the rename in `close()`. Durability is identical; syscall count drops ~3×, no per-call path resolution.
- **Severity:** MEDIUM

### B5. Token budget re-tokenizes the entire record set on every trigger (MEDIUM)

- **File:** `tools/convo-coach/src/llm/budget.ts:89-99, 122-123, 148-154`

```ts
for (const r of records) {
    total += estimateTokens(r.text, provider) + PER_RECORD_OVERHEAD_TOKENS;
}
```

- **Why it's a problem:** In stdin mode every trigger runs `applyBudget` over the full (windowed) history; for OpenAI/Azure that's a real BPE encode of every record's text, every time — compounding B1's O(n²). The system prompt is also re-encoded per trigger though it never changes. js-tiktoken's `encode` is pure JS (no WASM), so this is meaningful CPU on big windows.
- **Suggested fix:** Records are immutable — cache the token count per record (a `WeakMap<NormalisedRecord, number>` or compute at parse time and carry on the record). Hoist the system-prompt count to once per process. Truncation already decrements incrementally (good) — make the initial sum incremental too.
- **Severity:** MEDIUM

### B6. Ctrl-C (SIGINT) exits with code 70 "provider failure" instead of a signal/interrupt code (MEDIUM)

- **Files:**
  - `tools/convo-coach/src/index.ts:397-402` (abort on SIGINT)
  - `tools/convo-coach/src/output/stream.ts:165-181` (abort surfaces as stream error → `ProviderError`)
  - `tools/convo-coach/src/types.ts:242-249` (no interrupt code)

```ts
const onSigint = (): void => { ...; abortController.abort(); };
...
} catch (err) {
    throw new ProviderError(`stream failed: ${message}`);  // AbortError lands here
}
```

- **Why it's a problem:** A user-initiated abort propagates as `AbortError` out of the LangChain stream, gets wrapped in `ProviderError`, and the process exits 70 (`PROVIDER_FAILURE`) with an `# ERROR` footer in the sidecar — misclassifying a deliberate interrupt as a provider fault. Scripts keying on exit codes (and the metrics/footer in the sidecar) get the wrong story.
- **Suggested fix:** In the catch, check `input.abortSignal?.aborted` (or `err.name === 'AbortError'`) and rethrow a distinct `InterruptedError`; map it to exit 130 (128+SIGINT convention) or 0, and write an `# INTERRUPTED` footer instead of `# ERROR`.
- **Severity:** MEDIUM

### B7. No change detection: triggers with zero new content re-send the identical prompt (paid tokens) (MEDIUM)

- **File:** `tools/convo-coach/src/index.ts:287-303`; `tools/convo-coach/src/transcript/stdin.ts:155-157` (tty Enter fires unconditionally)

- **Why it's a problem:** In stdin mode, hitting Enter twice (or a debounce firing after the consumer was busy) re-runs the full pipeline on an unchanged buffer: same window, same prompt, a full LLM round-trip billed at full input-token cost, plus a new sidecar file with duplicate advice. There is no "nothing new since last advice" guard.
- **Suggested fix:** Track the record count (or last record timestamp) included in the previous successful advice; if unchanged at trigger time, print `[convo-coach] no new transcript since last advice — skipped` and continue. Offer `--force`/double-Enter to override.
- **Severity:** MEDIUM (direct cost + noise)

### B8. Debounce never fires under a continuous trickle — live advice can stall indefinitely in non-tty mode (MEDIUM→LOW)

- **File:** `tools/convo-coach/src/transcript/stdin.ts:124-131, 139-144`

```ts
const armDebounce = (): void => {
    ...
    if (debounceTimer !== undefined) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => { ...; fireTrigger('debounce'); }, debounceMs);
};
stdinRl.on('line', ... armDebounce());   // every line RESETS the timer
```

- **Why it's a problem:** The debounce is silence-detection only: each incoming line resets the timer. A live transcription feed that emits a line every few seconds (typical for ntakker partial/final cadence) with the default `COACH_DEBOUNCE=15s` never reaches 15 s of silence during active conversation — exactly when the user wants coaching — and only fires when the conversation pauses. In `/dev/tty`-less environments (the documented fallback: containers, nohup) there is no Enter escape hatch, so advice may simply never arrive mid-conversation.
- **Suggested fix:** Add a max-interval companion (`COACH_MAX_INTERVAL`, e.g. 60s): a second timer armed at the first buffered line that fires regardless of ongoing input, then re-arms. Document the pairing in `docs/tools/convo-coach.md`.
- **Severity:** MEDIUM in headless live use; LOW for the typical tty workflow.

### B9. `--help` text contradicts the implementation in three places (LOW)

- **File:** `tools/convo-coach/src/args.ts:142-151`; vs `tools/convo-coach/src/index.ts:405-416`, `tools/convo-coach/src/transcript/reader.ts:17`, `tools/convo-coach/src/transcript/autodetect.ts:24`

```
INPUT MODE (auto-detected, in priority order)
  1. stdin               When something is piped on stdin (no TTY).
  2. --transcript <path> ...
  ...
  --transcript <path>    Path to a ntakker-cli sidecar (.jsonl, .txt, .srt, .vtt).
  3. autodetect          Newest *.transcript.* file in --recordings-dir
```

- **Why it's a problem:** (1) Code gives `--transcript` priority over stdin (`index.ts:409` first branch, per AC-CC-8) — help says the opposite. (2) `.srt`/`.vtt` are advertised but `reader.ts` rejects anything except `.jsonl`/`.txt` (exit 66). (3) Autodetect matches any top-level `*.jsonl`/`*.txt`, not `*.transcript.*`. Help is self-declared "single source of truth for end-user usage" (`args.ts:130-131`) — it's the thing users read when the tool behaves unexpectedly.
- **Suggested fix:** Correct the three statements (or implement srt/vtt if they were intended — types.ts:138 already mentions srt/vtt parsers that don't exist).
- **Severity:** LOW

### B10. cl100k_base used for models that tokenize with o200k_base (LOW)

- **File:** `tools/convo-coach/src/llm/budget.ts:29-36, 62-70`
- **Why it's a problem:** `gpt-4o*` and `gpt-4.1*` (the listed OpenAI models) use `o200k_base`, not `cl100k_base`. Counts are systematically off (commonly ~5–15 % high for English, more for non-Latin scripts — relevant given the project's Greek+English transcripts). The 15 % safety margin mostly hides it, but the "real BPE count" claim is inaccurate and the margin is being silently spent on tokenizer mismatch.
- **Suggested fix:** Select the encoding by model family (`o200k_base` for 4o/4.1/5.x, `cl100k_base` for legacy), or just treat all counts as estimates and say so.
- **Severity:** LOW

### B11. `isFinal` is parsed but never used — interim/partial lines can duplicate content in the prompt (LOW)

- **Files:** `tools/convo-coach/src/transcript/jsonl.ts:104-106`; no consumer of `isFinal` anywhere in `src/` (checked `window.ts`, `build.ts`, `index.ts`)
- **Why it's a problem:** ntakker streaming providers emit partial hypotheses (`final: false`) that are superseded by finals. If those partials land in the sidecar/pipe, the prompt contains near-duplicate consecutive lines ("so I was thi" / "so I was thinking…"), inflating token cost and confusing the model. The field is faithfully extracted and then ignored.
- **Suggested fix:** Filter `isFinal === false` records (or collapse consecutive same-channel partials into the final) in `stageAdvice` before windowing — behind a flag if partials are deemed useful.
- **Severity:** LOW (depends on what ntakker actually writes to the sidecar; tombstone handling suggests finals-only, but the parser tolerates raw streams)

### B12. Minor robustness nits (LOW)

- `tools/convo-coach/src/index.ts:411`: `process.stdin.isTTY === false` → stdin mode is also selected for `convo-coach < /dev/null` (cron/launchd): immediate EOF yields nothing and exits 0 silently — a no-op success where the user probably wanted autodetect. Consider falling through to autodetect on instant-EOF-with-empty-buffer.
- `tools/convo-coach/src/index.ts:59-73`: `readVersion()` silently falls back to a hardcoded `'0.1.0'` — will drift from package.json; harmless but the kind of silent default the project forbids elsewhere.
- `tools/convo-coach/src/config.ts:121-130`: an unreadable (EACCES) `.env` is treated as "tier contributes nothing" with no warning — same silent-config-loss pattern as A9; one stderr line would save a debugging session.
- `tools/convo-coach/src/output/sidecar.ts:64-69`: `fs.existsSync` probe loop for collision is check-then-act; two concurrent instances can pick the same path. Use `fs.openSync(path, 'wx')` to claim atomically. (Unlikely in practice — LOW.)

### B13. Dependency pins — flags only (not a deep audit)

- **File:** `tools/convo-coach/package.json`
- **No lockfile** is present in the tool directory (no `package-lock.json` / `pnpm-lock.yaml`): builds are not reproducible and `npm audit` results are non-deterministic. Given the project's dependency-vetting rules (CLAUDE.md `<dependency-vetting>` requires audited, dated pins), commit a lockfile. **(most important item here)**
- `overrides: { "@anthropic-ai/sdk": "^0.92.0" }` — registry latest is **0.104.x**; a caret on 0.x pins to 0.92.x, so the override freezes a transitive SDK ~12 minors behind. The project convention requires overrides to be documented in `Issues - Pending Items.md` with an expiry condition ("remove once @langchain/anthropic requires ≥X"); verify that entry exists and re-evaluate the pin.
- Direct pins are within current majors as of 2026-06-12: `@langchain/core ^1.1.0` (latest 1.1.48), `@langchain/openai ^1.4.0` (1.4.7), `@langchain/anthropic ^1.3.0` (1.4.0 — minor behind), `@langchain/google-genai ^2.1.0` (2.1.31), `@langchain/ollama ^1.2.0` (1.2.7), `js-tiktoken ^1.0.0` (1.0.21). Nothing looks dangerous, but `^1.0.0` on js-tiktoken is very loose for a package whose rank data affects budgeting behaviour.
- Doc mismatch: project `CLAUDE.md` ("Tools" section) says convo-coach streams "via the Vercel AI SDK" — the implementation migrated to LangChain (`stream.ts:4-6`). Update the tool entry and `docs/tools/convo-coach.md`.

---

## Strengths (brief)

**Scope A**
- Exemplary error surface: locked one-line description + actionable remediation per case, sysexits-aligned exit codes, `printToStderr` single format (`NtakkerError.swift`).
- Daemonizer follows the Stevens recipe faithfully — pre-fork log-fd open for synchronous error surfacing, `_exit` vs `exit` reasoning documented, fd hygiene correct (`Daemonizer.swift`). (The flaw is *when* it's called — A1 — not *what* it does.)
- Config resolver: strict no-fallback enforcement with precise `invalidConfigValue` messages, fail-fast credential checks before any audio capture, pre-validated Apple locales for deterministic failures.
- Permission gate ordering (screen first so one relaunch fixes both) is thoughtful; test-injectable `PermissionGating` protocol.
- Logging: cached timestamp formatter, runtime-mutable level via `LogLevelBox` without re-bootstrap, 0600/0700 permission discipline everywhere.
- `SSELineParser` handles CRLF + cancellation propagation cleanly; `AskPromptBuilder` reports exactly what window/truncation was sent for auditability.

**Scope B**
- Clean typed error hierarchy mirrored to sysexits, shared with the Swift side's conventions.
- Atomic temp-rename sidecar with frontmatter-first writes (crash leaves a parseable file) and collision suffixes.
- Lazy tiktoken load; provenance-tracking four-tier config with documented alias map and deliberate empty-clears-lower-tier semantics.
- stdin generator has careful resource cleanup (`try/finally`, tty fd, timers) and a graceful JSONL→plaintext degradation path.
- Tolerant JSONL parser with a sensible "all lines failed" wholesale-format error vs per-line skip.

---

## Finding index

| # | Title | Severity |
|---|-------|----------|
| A1 | `fork()` after Swift Concurrency runtime startup | HIGH |
| A2 | `stop` SIGTERMs unverified PID (PID-reuse hazard) | HIGH/MEDIUM |
| A3 | `stop` runs full config validation — unstoppable daemon on unrelated config error | MEDIUM |
| A4 | PID file claim is not exclusive (TOCTOU) | MEDIUM |
| A5 | Screen-recording `.notDetermined` unreachable — fresh installs get exit 77, no prompt | MEDIUM |
| A6 | Synchronous file logging under global lock on hot paths | MEDIUM |
| A7 | No log rotation / size cap | MEDIUM |
| A8 | Ask HTTP errors reported as `transcriptionProviderUnavailable` | MEDIUM |
| A9 | Two divergent .env parsers; UI swallows parse errors | MEDIUM/LOW |
| A10 | Empty-string tier fall-through diverges from convo-coach semantics | LOW |
| A11 | Per-invocation chmods, per-resolve formatter allocations | LOW |
| A12 | `NTAKKER_ASK_CONTEXT_MINUTES` silent default/clamp on invalid input | LOW |
| A13 | O(n²) prompt truncation; no Ask timeout/retry tuning | LOW |
| A14 | Exit-code nits (`pidFileWriteFailed`→66, `staleRecording`→75) | LOW |
| B1 | Stdin mode: unbounded buffer + O(n²) full re-parse per trigger | HIGH |
| B2 | Azure default provider falls to 8k-token unknown-model window → silent truncation | HIGH |
| B3 | One provider error kills the live session; no retries, status discarded | HIGH/MEDIUM |
| B4 | `appendFileSync` per streaming delta in sidecar writer | MEDIUM |
| B5 | Full re-tokenization of records on every trigger | MEDIUM |
| B6 | SIGINT exits 70 (PROVIDER_FAILURE) | MEDIUM |
| B7 | No change detection — duplicate prompts billed on no-op triggers | MEDIUM |
| B8 | Silence-only debounce never fires under continuous input | MEDIUM/LOW |
| B9 | Help text contradicts implementation (priority, srt/vtt, autodetect glob) | LOW |
| B10 | cl100k_base used for o200k_base models | LOW |
| B11 | `isFinal` parsed but never used — partials can duplicate prompt content | LOW |
| B12 | Minor robustness nits (stdin-from-/dev/null, version fallback, silent EACCES, sidecar path race) | LOW |
| B13 | Dependencies: missing lockfile; stale `@anthropic-ai/sdk` override; "Vercel AI SDK" doc mismatch | flag |
