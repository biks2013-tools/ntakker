# ntakker — CLI / Infrastructure Review

Date: 2026-06-12
Reviewer: automated code review (performance / functionality / robustness)
Repo: `/Users/giorgosmarinos/aiwork/coding-platform/recording-tool` @ `e4cd174` (master, clean)

Scope — Swift CLI + infrastructure: `Sources/ntakker-cli/main.swift`, `Sources/NtakkerCore/{Config,Daemon,Bootstrap,Logging,Permissions,Errors,Asking}/`
Severity legend: **HIGH** = correctness/availability risk or material cost on the default path; **MEDIUM** = real but bounded impact or degraded UX; **LOW** = polish, latent risk, or maintenance burden.

---

## Swift CLI and infrastructure

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

- **Why it's a problem:** Setting `NTAKKER_TRANSCRIBE=` (empty) in `./.env` does **not** clear a value from `~/.tool-agents/.env` or the shell — the empty entry is invisible and the lower tier leaks through. A user who writes an empty value to switch a setting off will be surprised.
- **Suggested fix:** Treat an empty value as an explicit unset, or document the behaviour prominently in the tool docs.
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

## Strengths (brief)

- Exemplary error surface: locked one-line description + actionable remediation per case, sysexits-aligned exit codes, `printToStderr` single format (`NtakkerError.swift`).
- Daemonizer follows the Stevens recipe faithfully — pre-fork log-fd open for synchronous error surfacing, `_exit` vs `exit` reasoning documented, fd hygiene correct (`Daemonizer.swift`). (The flaw is *when* it's called — A1 — not *what* it does.)
- Config resolver: strict no-fallback enforcement with precise `invalidConfigValue` messages, fail-fast credential checks before any audio capture, pre-validated Apple locales for deterministic failures.
- Permission gate ordering (screen first so one relaunch fixes both) is thoughtful; test-injectable `PermissionGating` protocol.
- Logging: cached timestamp formatter, runtime-mutable level via `LogLevelBox` without re-bootstrap, 0600/0700 permission discipline everywhere.
- `SSELineParser` handles CRLF + cancellation propagation cleanly; `AskPromptBuilder` reports exactly what window/truncation was sent for auditability.

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
| A10 | Empty-string tier fall-through semantics | LOW |
| A11 | Per-invocation chmods, per-resolve formatter allocations | LOW |
| A12 | `NTAKKER_ASK_CONTEXT_MINUTES` silent default/clamp on invalid input | LOW |
| A13 | O(n²) prompt truncation; no Ask timeout/retry tuning | LOW |
| A14 | Exit-code nits (`pidFileWriteFailed`→66, `staleRecording`→75) | LOW |
