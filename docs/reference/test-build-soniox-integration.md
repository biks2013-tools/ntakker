---
status: completed
mode: write-and-run
scope_slug: soniox-integration
language: swift
framework: XCTest
test_command_full: swift test
test_command_scope: swift test --filter SonioxIntegrationTests
test_dir: Tests/MacrecCoreTests/Transcription/Soniox
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
test_files_owned:
  - Tests/MacrecCoreTests/Transcription/Soniox/SonioxIntegrationTests.swift
tests_added: 4
tests_updated: 0
tests_run: 4
tests_passed: 4
tests_failed: 0
implementation_gaps: 0
built_at: "2026-04-29T08:28:07Z"
last_built_commit: c56425e54dd1286d36e255e6c8bcf6959129c1d1
---

# Test Build — Soniox Provider End-to-End Integration

## 1. Summary

Status: **completed**. Framework: XCTest (matching the pattern established by `SonioxStreamingSessionTests` in the same directory). Four new integration tests were written in a single new file (`SonioxIntegrationTests.swift`) and all four pass with no implementation gaps. The tests exercise the full pipeline stack — `SonioxStreamingTranscriptionProvider` → `SonioxStreamingSession` → `SonioxTokenAggregator` → `StreamingTranscriptionPipeline` → `JSONLTranscriptWriter` — using a `MockWebSocketTransport` pre-loaded with realistic token batches. No real Soniox API key is required.

Two test-fixture bugs were caught during the first run (fixture payloads emitted more segments than intended because the token aggregator flushes on every `is_final: true` token, not only on marker tokens). Both were fixed before the final run. The corrected fixtures accurately reflect the aggregator's documented contract.

---

## 2. Scope Resolved

**Source files under test:**
- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingTranscriptionProvider.swift`
  — `SonioxStreamingTranscriptionProvider.openStreamingSession(source:options:)`
- `Sources/MacrecCore/Transcription/StreamingTranscriptionPipeline.swift`
  — `StreamingTranscriptionPipeline.start()`, `ingest(_:from:)`, `stop()`
- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingSession.swift`
  — `SonioxStreamingSession.start()`, `ingest(_:)`, `finish()`, receive loop
- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift`
  — `SonioxTokenAggregator.ingest(_:)`, `drain()`
- `Sources/MacrecCore/Transcription/Persistence/JSONLTranscriptWriter.swift`
  — `JSONLTranscriptWriter.appendSegment(_:)`
- `Sources/MacrecCore/Transcription/Persistence/TranscriptSidecarWriter.swift`
  — `TranscriptSidecarWriter.write(_:)` (streaming policy)

**In-scope symbols exercised:**
- `SonioxStreamingTranscriptionProvider` — provider identity, `openStreamingSession`
- `StreamingTranscriptionPipeline` — `start()`, `ingest(_:from:)`, `stop()`, `attach(session:for:)`, `handle(_:from:)`
- `SonioxStreamingSession` — `start()`, `ingest(_:)`, `finish()`, receive/drain loop
- `SonioxTokenAggregator` — `ingest(_:)`, `drain()`, language resolution
- `TranscriptSidecarWriter` — `.streaming` policy dispatch, `write(_:)`, `close()`
- `JSONLTranscriptWriter` — `appendSegment(_:)`, JSONL encoding

---

## 3. Existing Coverage

| Symbol / Behavior | Existing test file(s) |
|---|---|
| `SonioxStreamingSession` happy path / 401 / drain / receive-error | `SonioxStreamingSessionTests.swift` |
| `SonioxStreamingTranscriptionProvider` identity / transcribe-throws / openStreamingSession | `SonioxStreamingTranscriptionProviderTests.swift` |
| `SonioxTokenAggregator` partial/final/drain/language | `SonioxTokenAggregatorTests.swift` |
| Soniox wire-schema Codable types | `SonioxWireSchemaTests.swift` |
| `StreamingTranscriptionPipeline` (via Apple Speech) | `StreamingTranscriptionPipelineTests.swift` |
| `JSONLTranscriptWriter`, `TranscriptSidecarWriter` | `Tests/MacrecCoreTests/Transcription/Persistence/` |

**Gap addressed by this build:** No test previously exercised `SonioxStreamingTranscriptionProvider` and `StreamingTranscriptionPipeline` wired together end-to-end with sidecar output. The existing session tests stop at the `SonioxStreamingSession` level; the existing pipeline tests use `AppleSpeechTranscriptionProvider` only.

---

## 4. Plan

| # | target_symbol | category | test_file | test_name | intent |
|---|---|---|---|---|---|
| 1 | `StreamingTranscriptionPipeline` + `SonioxStreamingTranscriptionProvider` | integration | `SonioxIntegrationTests.swift` | `testPipelineIntegrationThreeUtteranceGreekTranscript` | Verify that the full pipeline wired to a Soniox provider (mock transport, 3-utterance Greek+English transcript) emits exactly 3 `.segmentFinalized` events and writes a matching JSONL sidecar with `model:"soniox"` on every line. |
| 2 | `SonioxTokenAggregator.ingest` language field through pipeline | integration | `SonioxIntegrationTests.swift` | `testBilingualLanguageIdentificationOnFinalEvents` | Verify that two consecutive token batches carrying different `language` fields (`"el"` then `"en"`) produce `.segmentFinalized` events whose `segment.language` attributes match the per-utterance language from the wire. |
| 3 | `SonioxStreamingSession.finish()` drain via pipeline | integration | `SonioxIntegrationTests.swift` | `testDrainOnSessionFinishThroughPipeline` | Verify that a non-final buffered token without a marker or `finished` envelope produces at least one `.segmentFinalized` event when `pipeline.stop()` triggers the drain path, and that the drained segment text matches the buffered token. |
| 4 | `SonioxStreamingSession` transport error isolation through pipeline | error_path | `SonioxIntegrationTests.swift` | `testTransportReceiveErrorIsNonFatalThroughPipeline` | Verify that a transport-level receive error mid-stream surfaces as `.error(detail:)` in the pipeline's public event stream, never throws to the caller, and does not produce any `.segmentFinalized` events (NFR-SX-1 recording-integrity isolation). |

---

## 5. Files Owned

| File | Reason |
|---|---|
| `Tests/MacrecCoreTests/Transcription/Soniox/SonioxIntegrationTests.swift` | new — 4 integration tests written from scratch |

No existing test files were modified. No shared test infrastructure (`conftest.py` equivalent: `MockWebSocketTransport.swift`) was touched.

---

## 6. Test Run Results

Command: `swift test --filter SonioxIntegrationTests`

```
Test Suite 'SonioxIntegrationTests' passed at 2026-04-29 11:28:07.205.
     Executed 4 tests, with 0 failures (0 unexpected) in 4.866 (4.867) seconds
```

| Test | Outcome | Duration |
|---|---|---|
| `testBilingualLanguageIdentificationOnFinalEvents` | PASS | 0.161 s |
| `testDrainOnSessionFinishThroughPipeline` | PASS | 2.280 s |
| `testPipelineIntegrationThreeUtteranceGreekTranscript` | PASS | 0.165 s |
| `testTransportReceiveErrorIsNonFatalThroughPipeline` | PASS | 2.259 s |

**Note on first-run failures (test-bug, now fixed):** Tests 1 and 2 initially failed because the token-batch fixtures used consecutive `is_final: true` tokens within a single utterance. The `SonioxTokenAggregator` correctly flushes on every `is_final: true` non-marker token (producing one segment per such token), so "Good morning" with two `is_final: true` tokens produced two segments instead of one. This was a bug in the test fixture, not in the implementation. Fixed by using `is_final: false` for intermediate tokens and `is_final: true` only on the last token before the `<end>` / `<fin>` marker — which matches the documented Soniox streaming behavior where intermediate tokens in a partial batch are typically `is_final: false` until the endpoint is detected.

---

## 7. Implementation Gaps

None. All four tests passed after fixture corrections. No acceptance criterion from `docs/design/refined-request-soniox-streaming.md` was found unmet by the implementation.

---

## 8. Manual Review Needed

### 8.1 `SonioxStreamingSession.finishGracePeriod` in Test 3

`testDrainOnSessionFinishThroughPipeline` uses the production `finishGracePeriod` default of 2 seconds (because the pipeline constructs the session via `provider.openStreamingSession`, which passes no override). This makes the test take ~2.3 seconds. The session-level tests in `SonioxStreamingSessionTests` avoid this by passing `finishGracePeriod: .milliseconds(50)` directly to `SonioxStreamingSession.init`. The pipeline wrapper (`makePipeline`) cannot currently inject the grace period without a new parameter on `SonioxStreamingTranscriptionProvider.init` or `StreamingTranscriptionPipeline`.

**Recommendation:** Add a `finishGracePeriod: Duration = .seconds(2)` parameter to `SonioxStreamingTranscriptionProvider.init` (forwarded to each `SonioxStreamingSession` it constructs), so integration tests can pass `.milliseconds(50)` without modifying shared infrastructure. This is a production source change and is out of this agent's scope.

### 8.2 `@available(macOS 26.0, *)` annotation on `StreamingTranscriptionPipeline`

`StreamingTranscriptionPipeline` carries `@available(macOS 26.0, *)` in production. The test file omits this annotation because the test target's deployment target is already `.macOS(.v26)` (per `Package.swift`), making the annotation redundant in tests — as confirmed by the existing `StreamingTranscriptionPipelineTests.swift` (same approach). No action needed, but this should be kept in mind if the deployment target is ever lowered.

### 8.3 Async-unhandled-rejection detection

The Swift test runner does not currently expose a project-wide "fail on unhandled Task errors" setting equivalent to Node.js `--unhandled-rejections=throw`. The integration tests explicitly `await pipeline.stop()` and `await collectPipelineEvents(from:)` so no fire-and-forget tasks escape, but if a future test omits the `await`, background Task failures would be silently swallowed. If the project adds a global task-error monitor (e.g. via `Task.currentPriority` introspection or a custom XCTestObserver), these tests should be updated to participate.

---

## 9. Commands Run

| # | Command | Exit code |
|---|---|---|
| 1 | `swift build --target MacrecCoreTests` | 0 |
| 2 | `swift test --filter SonioxIntegrationTests` (first run — 2 test-fixture failures) | 1 |
| 3 | `swift test --filter SonioxIntegrationTests` (second run — after fixture fixes) | 0 |
