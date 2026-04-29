---
status: completed
mode: write-and-run
scope_slug: soniox-error-paths
language: swift
framework: XCTest
test_command_full: "swift test"
test_command_scope: "swift test --filter 'SonioxErrorMapperEdge|SonioxLanguageHintMapperEdge|SonioxConfigBuilderEdge|SonioxSessionErrorPath'"
test_dir: Tests/MacrecCoreTests/Transcription/Soniox
target_path: /Users/giorgosmarinos/aiwork/coding-platform/recording-tool
test_files_owned:
  - Tests/MacrecCoreTests/Transcription/Soniox/SonioxErrorMapperEdgeTests.swift
  - Tests/MacrecCoreTests/Transcription/Soniox/SonioxLanguageHintMapperEdgeTests.swift
  - Tests/MacrecCoreTests/Transcription/Soniox/SonioxConfigBuilderEdgeTests.swift
  - Tests/MacrecCoreTests/Transcription/Soniox/SonioxSessionErrorPathTests.swift
tests_added: 18
tests_updated: 0
tests_run: 18
tests_passed: 18
tests_failed: 0
implementation_gaps: 0
built_at: "2026-04-29T11:26:52Z"
last_built_commit: c56425e54dd1286d36e255e6c8bcf6959129c1d1
---

# Test Build — Soniox Error-Paths and Edge-Case Coverage

## 1. Summary

Completed. Added 18 new XCTest tests across 4 new files covering the Soniox-specific failure modes documented in `docs/research/soniox-wire-schema.md` (HTTP error codes 400, 408, 429, 500, unknown), WebSocket close-code `.policyViolation`, language-hint normalisation edge cases (ISO-639-1 passthrough, mixed-case BCP-47, triple-region tags, leading/trailing whitespace), config-builder boundaries (empty hints, long `clientReferenceId`, nil `clientReferenceId` omission from JSON), and 5 session-level error-path scenarios via `MockWebSocketTransport`. All 18 tests passed on the first run with no implementation gaps detected.

---

## 2. Scope Resolved

**Source files in scope:**

- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxErrorMapper.swift`
  - `SonioxStreamingError` (enum)
  - `SonioxErrorMapper.map(httpCode:message:)` (static func)
  - `SonioxErrorMapper.map(closeCode:)` (static func)

- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxLanguageHintMapper.swift`
  - `SonioxLanguageHintMapper.defaultHints` (static let)
  - `SonioxLanguageHintMapper.map(_:)` (static func)

- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigBuilder.swift`
  - `SonioxConfigBuilder.defaultModel` (static let)
  - `SonioxConfigBuilder.build(apiKey:model:languageHints:clientReferenceId:)` (static func)

- `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingSession.swift`
  - `SonioxStreamingSession` (actor)
  - `handleTextFrame(_:aggregator:)` (error dispatch path)
  - `startReceiveLoop()` (transport-error containment path)

---

## 3. Existing Coverage

| Symbol | Existing test files |
|---|---|
| `SonioxErrorMapper.map(httpCode:message:)` — 401, 402, 503 | `SonioxErrorMapperTests.swift` |
| `SonioxErrorMapper.map(closeCode:)` — .normal, .internalServerError | `SonioxErrorMapperTests.swift` |
| `SonioxLanguageHintMapper.map(_:)` — el-GR→el, mixed list, empty, whitespace | `SonioxLanguageHintMapperTests.swift` |
| `SonioxLanguageHintMapper.defaultHints` | `SonioxLanguageHintMapperTests.swift` |
| `SonioxConfigBuilder.build(...)` — defaults, custom model, clientReferenceId | `SonioxConfigBuilderTests.swift` |
| `SonioxStreamingSession` — 401 error path, transport receive error containment | `SonioxStreamingSessionTests.swift` |

No existing tests covered: HTTP 400, 408, 429, 500 or unknown codes; `.policyViolation` close code; already-ISO-639-1 inputs; mixed-case BCP-47; triple region tags; whitespace-padded inputs; empty `languageHints` array; very long `clientReferenceId`; nil `clientReferenceId` JSON omission; 402/408/503 server envelope events; empty-token silent batch; JSON-decode failure.

---

## 4. Plan

| # | target_symbol | category | test_file | test_name | intent |
|---|---|---|---|---|---|
| 1 | `SonioxErrorMapper.map(httpCode:message:)` | `error_path` | SonioxErrorMapperEdgeTests.swift | `test400MalformedConfigCarriesMessage` | HTTP 400 → `.malformedConfig` with message payload preserved |
| 2 | `SonioxErrorMapper.map(httpCode:message:)` | `error_path` | SonioxErrorMapperEdgeTests.swift | `test408MapsToIdleTimeout` | HTTP 408 → `.idleTimeout` (not `.serverError`) |
| 3 | `SonioxErrorMapper.map(httpCode:message:)` | `error_path` | SonioxErrorMapperEdgeTests.swift | `test429MapsToRateLimited` | HTTP 429 → `.rateLimited` |
| 4 | `SonioxErrorMapper.map(httpCode:message:)` | `error_path` | SonioxErrorMapperEdgeTests.swift | `test500ServerErrorCarriesMessage` | HTTP 500 → `.serverError` with message payload preserved |
| 5 | `SonioxErrorMapper.map(httpCode:message:)` | `error_path` | SonioxErrorMapperEdgeTests.swift | `testUnknownHttpCodeFallsThrough` | HTTP 418 (unknown) → `.serverError` via default fallthrough |
| 6 | `SonioxErrorMapper.map(closeCode:)` | `error_path` | SonioxErrorMapperEdgeTests.swift | `testPolicyViolationCloseCodeProducesConnectionError1008` | `.policyViolation` close code → `.connectionError(code: 1008, reason: nil)` |
| 7 | `SonioxLanguageHintMapper.map(_:)` | `unit` | SonioxLanguageHintMapperEdgeTests.swift | `testAlreadyIso6391InputsPreserveOrder` | Pure ISO-639-1 inputs pass through unchanged in order |
| 8 | `SonioxLanguageHintMapper.map(_:)` | `unit` | SonioxLanguageHintMapperEdgeTests.swift | `testMixedCaseBcp47NormalisedToLowercase` | Mixed-case BCP-47 tags normalised to lowercase ISO-639-1 |
| 9 | `SonioxLanguageHintMapper.map(_:)` | `unit` | SonioxLanguageHintMapperEdgeTests.swift | `testTripleRegionTagCollapsesToPrimaryLanguageCode` | Script+region subtag (zh-Hant-CN) collapses to "zh" with dedup |
| 10 | `SonioxLanguageHintMapper.map(_:)` | `unit` | SonioxLanguageHintMapperEdgeTests.swift | `testLeadingAndTrailingWhitespaceIsTrimmedBeforeRegionStrip` | Whitespace-padded input trimmed before region strip |
| 11 | `SonioxConfigBuilder.build(...)` | `unit` | SonioxConfigBuilderEdgeTests.swift | `testEmptyLanguageHintsProducesValidConfig` | Empty languageHints slice produces valid, encodable config |
| 12 | `SonioxConfigBuilder.build(...)` | `unit` | SonioxConfigBuilderEdgeTests.swift | `testVeryLongClientReferenceIdPassesThroughUnchanged` | 200-char clientReferenceId stored verbatim without truncation |
| 13 | `SonioxConfigBuilder.build(...)` | `unit` | SonioxConfigBuilderEdgeTests.swift | `testNilClientReferenceIdIsOmittedFromEncodedJSON` | nil clientReferenceId absent from encoded JSON key set |
| 14 | `SonioxStreamingSession.handleTextFrame` | `error_path` | SonioxSessionErrorPathTests.swift | `test402QuotaExceededServerMessageEmitsErrorEvent` | 402 server envelope → `.error(detail:)` referencing "402" or "quota" |
| 15 | `SonioxStreamingSession.handleTextFrame` | `error_path` | SonioxSessionErrorPathTests.swift | `test408IdleTimeoutServerMessageEmitsErrorEvent` | 408 server envelope → `.error(detail:)` referencing "408" or "idle" |
| 16 | `SonioxStreamingSession.handleTextFrame` | `error_path` | SonioxSessionErrorPathTests.swift | `test503TerminatedReconnectServerMessageEmitsErrorEventWithoutAutoReconnect` | 503 server envelope → `.error(detail:)`; no auto-reconnect (connectCallCount == 1) |
| 17 | `SonioxStreamingSession.handleTextFrame` | `unit` | SonioxSessionErrorPathTests.swift | `testEmptyTokensBatchWithNoErrorAndNoFinishedEmitsNoEvents` | `{tokens:[]}` silent batch emits zero partial/final/error events |
| 18 | `SonioxStreamingSession.handleTextFrame` | `error_path` | SonioxSessionErrorPathTests.swift | `testMalformedServerMessageEmitsDecodeFailedError` | Non-JSON frame → `.error(detail:)` containing "decode_failed" |

---

## 5. Files Owned

| File | Reason |
|---|---|
| `Tests/MacrecCoreTests/Transcription/Soniox/SonioxErrorMapperEdgeTests.swift` | new |
| `Tests/MacrecCoreTests/Transcription/Soniox/SonioxLanguageHintMapperEdgeTests.swift` | new |
| `Tests/MacrecCoreTests/Transcription/Soniox/SonioxConfigBuilderEdgeTests.swift` | new |
| `Tests/MacrecCoreTests/Transcription/Soniox/SonioxSessionErrorPathTests.swift` | new |

No existing test files were modified. All new files sit inside the established `Tests/MacrecCoreTests/Transcription/Soniox/` directory, consistent with the project convention.

---

## 6. Test Run Results

Command executed:
```
swift test --filter "SonioxErrorMapperEdge|SonioxLanguageHintMapperEdge|SonioxConfigBuilderEdge|SonioxSessionErrorPath"
```

Exit code: **0**

| Suite | Tests run | Passed | Failed | Skipped |
|---|---|---|---|---|
| SonioxConfigBuilderEdgeTests | 3 | 3 | 0 | 0 |
| SonioxErrorMapperEdgeTests | 6 | 6 | 0 | 0 |
| SonioxLanguageHintMapperEdgeTests | 4 | 4 | 0 | 0 |
| SonioxSessionErrorPathTests | 5 | 5 | 0 | 0 |
| **Total** | **18** | **18** | **0** | **0** |

Per-test details (all passing):

**SonioxErrorMapperEdgeTests:**
- `test400MalformedConfigCarriesMessage` — PASS (0.000 s)
- `test408MapsToIdleTimeout` — PASS (0.000 s)
- `test429MapsToRateLimited` — PASS (0.000 s)
- `test500ServerErrorCarriesMessage` — PASS (0.000 s)
- `testUnknownHttpCodeFallsThrough` — PASS (0.000 s)
- `testPolicyViolationCloseCodeProducesConnectionError1008` — PASS (0.000 s)

**SonioxLanguageHintMapperEdgeTests:**
- `testAlreadyIso6391InputsPreserveOrder` — PASS (0.000 s)
- `testMixedCaseBcp47NormalisedToLowercase` — PASS (0.000 s)
- `testTripleRegionTagCollapsesToPrimaryLanguageCode` — PASS (0.000 s)
- `testLeadingAndTrailingWhitespaceIsTrimmedBeforeRegionStrip` — PASS (0.000 s)

**SonioxConfigBuilderEdgeTests:**
- `testEmptyLanguageHintsProducesValidConfig` — PASS (0.001 s)
- `testVeryLongClientReferenceIdPassesThroughUnchanged` — PASS (0.000 s)
- `testNilClientReferenceIdIsOmittedFromEncodedJSON` — PASS (0.000 s)

**SonioxSessionErrorPathTests:**
- `test402QuotaExceededServerMessageEmitsErrorEvent` — PASS (0.056 s)
- `test408IdleTimeoutServerMessageEmitsErrorEvent` — PASS (0.053 s)
- `test503TerminatedReconnectServerMessageEmitsErrorEventWithoutAutoReconnect` — PASS (0.056 s)
- `testEmptyTokensBatchWithNoErrorAndNoFinishedEmitsNoEvents` — PASS (0.001 s)
- `testMalformedServerMessageEmitsDecodeFailedError` — PASS (0.002 s)

---

## 7. Implementation Gaps

None. All 18 tests passed. The implementation correctly handles:
- HTTP 400, 408, 429, 500 and unknown codes
- `.policyViolation` close code → raw code 1008
- BCP-47 normalisation including mixed case and triple-region tags
- Empty `languageHints` array and nil `clientReferenceId` JSON omission
- 402/408/503 in-band error envelopes mapped to `.error(detail:)` events
- Silent `{tokens:[]}` batches (no spurious events emitted)
- JSON-decode failures surfaced as `decode_failed` error events without propagating the exception out of the session (recording-integrity isolation confirmed)

---

## 8. Manual Review Needed

None. All planned tests could be written using `MockWebSocketTransport` (already established by the existing Phase D suite) and the XCTest framework already in use. No shared test infrastructure (`conftest.py`, `jest.config.*`, etc.) was needed or modified.

**Note on timing in `SonioxSessionErrorPathTests`:** Tests 1–3 each wait up to 1 second for the first event (via `collectEvents(from:upTo:timeout:)`) then call `session.finish()`. The `finishGracePeriod` was reduced to 50 ms in `makeSession(transport:)` so finish completes quickly. Tests pass reliably, but anyone running under extreme resource contention may see the 1-second timeout fire before the event arrives — in that case, increasing the `timeout` parameter in the call to `collectEvents` is the correct fix, not patching the implementation.

---

## 9. Commands Run

| # | Command | Exit code |
|---|---|---|
| 1 | `swift test --filter "SonioxErrorMapperEdge\|SonioxLanguageHintMapperEdge\|SonioxConfigBuilderEdge\|SonioxSessionErrorPath"` | 0 |

Build output confirmed: 4 new Swift source files compiled cleanly, 2 linker warnings about duplicate `-rpath` entries (pre-existing, not introduced by this build), `Build complete!` in 2.90 s.
