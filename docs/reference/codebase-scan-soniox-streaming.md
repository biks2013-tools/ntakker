---
language: swift
framework: none
package_manager: swift-package-manager
build_command: "swift build --product macrec && swift build --product macrec-ui"
test_command: "swift test"
lint_command: null
entry_points:
  - Sources/macrec/main.swift
  - Sources/macrec-ui/MacrecUIApp.swift
last_scanned_commit: f1adb58a2b7e388a36a600b2dcf7cbc9eeaef8bc
scanned_for_request: refined-request-soniox-streaming.md
scanned_at: "2026-04-29T00:00:00Z"
---

# Codebase Scan — macrec / macrec-ui (Soniox Streaming)

## 1. Project Overview

Swift-only, macOS 26.0+ SwiftPM workspace (`swift-tools-version: 6.2`, running in Swift 5 language mode) that captures system audio and microphone via ScreenCaptureKit and AVFoundation, encodes to M4A/WAV/CAF, and live-transcribes via pluggable `TranscriptionProvider` backends. The workspace produces three products: the `macrec` CLI executable, the `MacrecCore` library (shared domain logic), and the `macrec-ui` menu-bar SwiftUI app. A fourth library, `MacrecUIKit`, separates UI domain logic (controllers, coordinators) from the app shell so tests can import it without AppKit. Third-party SPM dependencies are `swift-argument-parser`, `swift-log`, and `argmax-oss-swift` (WhisperKit). The `bin/` wrapper wraps the UI executable into a proper `.app` bundle for TCC registration; `swift build` / `swift test` are the canonical commands.

---

## 2. Module Map

| Path | Purpose | Representative symbols |
|---|---|---|
| `Sources/MacrecCore/` | Shared domain library — recording, transcription, config, encoding | `RecordingSession`, `ConfigResolver`, `TranscriptionManager` |
| `Sources/MacrecCore/Config/` | Four-tier env-var resolution; recording options value type | `ConfigResolver`, `RecordingOptions`, `TranscriptionProviderId` |
| `Sources/MacrecCore/Transcription/` | Transcription pipeline orchestration, session surface, downsampling | `TranscriptionManager`, `StreamingTranscriptionSession`, `AudioDownsampler` |
| `Sources/MacrecCore/Transcription/Providers/` | Concrete provider conformers + factory | `TranscriptionProviderFactory`, `GeminiRESTTranscriptionProvider`, `AppleSpeechTranscriptionProvider`, `WhisperKitTranscriptionProvider` |
| `Sources/MacrecCore/Transcription/Persistence/` | Sidecar format writers (JSONL, TXT, SRT, VTT) + path builder | `TranscriptSidecarWriter`, `JSONLTranscriptWriter`, `SidecarPathBuilder` |
| `Sources/MacrecCore/Capture/` | ScreenCaptureKit + AVFoundation capture graph | (capture sources, tap, mixer) |
| `Sources/MacrecCore/Encoding/` | M4A/WAV/CAF encoders | (recorder types) |
| `Sources/MacrecCore/Daemon/` | Double-fork daemonizer for `--detach` mode | `Daemonizer` |
| `Sources/MacrecCore/Bootstrap/` | `~/.tool-agents/<tool>/` directory setup | `ToolAgentsBootstrap` |
| `Sources/MacrecCore/Errors/` | Typed error enum with exit-code mapping | `MacrecError` |
| `Sources/macrec/Commands/` | CLI subcommands (start, stop, list-devices, check-permissions) | `StartCommand`, `StopCommand`, `RootCommand` |
| `Sources/MacrecUIKit/` | UI domain logic — controller, coordinator, filename gen | `RecordingController`, `SessionCoordinator` |
| `Sources/macrec-ui/` | SwiftUI menu-bar app shell + views | `MacrecUIApp`, `PopoverController`, `TranscriptionPicker` |
| `Sources/macrec-ui/Views/Transcription/` | Transcription-specific UI views | `TranscriptionPicker`, `PrivacyDisclosureSheet`, `GeminiKeyField` |
| `Tests/MacrecCoreTests/Transcription/` | Unit tests for pipeline, providers, sidecar writers | provider test suites, stub protocol |
| `Tests/MacrecCoreTests/Config/` | ConfigResolver resolution tests | `ConfigResolverTranscriptionTests` |
| `test_scripts/` | Bash e2e scripts + Swift probe scripts | `e2e-transcription-*.sh`, `e2e-transcription-key-missing.sh` |

---

## 3. Conventions

- **Swift Testing framework** (`@Suite`, `@Test`, `#expect`) is used throughout the unit test suite, not XCTest. The test target requires unsafe linker flags to find the framework under CommandLineTools (`Sources/MacrecCore/Config/RecordingOptions.swift` and `Package.swift` lines 80-98).

- **`URLProtocol` stub pattern for network providers**: `GeminiRESTStubProtocol` (`Tests/MacrecCoreTests/Transcription/Providers/GeminiRESTStubProtocol.swift:1`) subclasses `URLProtocol`, registers via `URLSessionConfiguration.protocolClasses`, and captures the outbound `URLRequest` plus body. The matching test suite (`GeminiRESTTranscriptionProviderTests.swift:15`) constructs the provider with `urlSession: GeminiRESTStubProtocol.makeURLSession()`.

- **`MockSpeechAnalyzer` pattern for streaming providers**: `AppleSpeechTranscriptionProvider` accepts an injected `analyzerFactory` closure; tests supply `MockSpeechAnalyzer()` instead. The session type (`AppleSpeechSession`) uses `@unchecked Sendable` + `NSLock` for mutable state shared across per-locale drain `Task`s (`AppleSpeechTranscriptionProvider.swift:194`).

- **No-fallback configuration rule**: `ConfigResolver.resolve(cliOverrides:)` (`ConfigResolver.swift:83`) merges four tiers via a local `value(_:)` closure (shell env → user `.env` → local `.env` → CLI flags, lowest to highest). Missing required values throw `MacrecError.missingRequiredConfig` or `.transcriptionApiKeyMissing`; there are no defaults for required security values. The `TranscriptionProviderId` enum drives `parseEnum` which throws `MacrecError.invalidConfigValue` (exit 64) on unknown values.

- **`AsyncStream`-based event flow**: streaming sessions expose `var events: AsyncStream<StreamingTranscriptionEvent>` (`StreamingTranscriptionSession.swift:51`). Events are `partial`, `final`, `metrics`, `error`. Sessions are created via `openStreamingSession(source:options:)` on the provider and fed via `ingest(_ samples: [Float]) async`.

- **Sidecar writer dispatch by policy**: `TranscriptSidecarWriter` (`TranscriptSidecarWriter.swift:65`) is an `actor` with a `SidecarPolicy` (`.batch` or `.streaming`). The streaming path persists only `.segmentFinalized` events; the batch path persists `.segmentAppended` + `.segmentUpdated`. All four format writers (`JSONLTranscriptWriter`, `SRTTranscriptWriter`, `VTTTranscriptWriter`, `TXTTranscriptWriter`) conform to `TranscriptFormatWriter`.

---

## 4. Integration Points

### 4.1 In-Scope Touch Points

#### A. TranscriptionProvider Protocol (`Sources/MacrecCore/Transcription/TranscriptionProvider.swift`)
- **Lines 29-44**: The public `TranscriptionProvider` protocol. The Soniox provider MUST conform to this. The protocol requires: `id: String`, `displayName: String`, `supportedModes: Set<TranscriptionMode>`, `transcribe(samples:source:options:) async throws -> String`, and `openStreamingSession(source:options:) async throws -> any StreamingTranscriptionSession`.
- Soniox should declare `supportedModes = [.streaming]` (mirroring Apple) and implement `transcribe(...)` as a thin bridge over `openStreamingSession(...)` (same pattern as `AppleSpeechTranscriptionProvider`, lines 167-180).
- If the streaming protocol proves insufficient for Soniox's wire semantics, `StreamingTranscriptionSession` (`StreamingTranscriptionSession.swift:42`) may be extended with an optional method and a default implementation — no existing providers need to change.

#### B. TranscriptionProviderFactory (`Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`)
- **Lines 46-93**: The `switch normalized { ... }` block is the provider registry. Add a `case "soniox":` branch before the `default:` fallthrough.
  - Guard on `apiKey` being present (same pattern as `case "gemini":`, line 50-52).
  - Build and return `SonioxStreamingTranscriptionProvider(apiKey: key, modelId: ..., logger: ...)`.
- **Line 91**: The error message in `default:` lists allowed values as `'none', 'apple', 'gemini', 'whisperkit'` — add `'soniox'` to this message.
- New file to create: `Sources/MacrecCore/Transcription/Providers/SonioxStreamingTranscriptionProvider.swift`

#### C. ConfigResolver — Provider ID enum and API key resolution (`Sources/MacrecCore/Config/ConfigResolver.swift` and `Sources/MacrecCore/Config/RecordingOptions.swift`)
- **`TranscriptionProviderId` enum** (`RecordingOptions.swift:74-79`): Add `.soniox = "soniox"` case. This drives `parseEnum` at config load time; adding the case automatically makes `MACREC_TRANSCRIBE=soniox` valid and `MACREC_TRANSCRIBE=foobar` continue to exit 64.
- **API key resolution block** (`ConfigResolver.swift:345-354`): Add a `case .soniox:` branch that reads `value(Keys.sonioxApiKey)` where `Keys.sonioxApiKey = "SONIOX_API_KEY"` (vendor-canonical, to be confirmed against Soniox docs). Pattern mirrors the `case .gemini, .geminiLive:` branch.
- **`transcriptionProviderId` switch** (`ConfigResolver.swift:241-261`): Add `case .soniox: return "soniox"`.
- **Apple Speech locale pre-validation block** (`ConfigResolver.swift:315-330`): The guard `if transcribeProviderEnum == .apple` MUST remain exclusive — Soniox does NOT need SFSpeechRecognizer locale validation.
- **Add new key constant** to `ConfigResolver.Keys` (`ConfigResolver.swift:404-436`): `public static let sonioxApiKey = "SONIOX_API_KEY"` and `public static let sonioxEndpoint = "MACREC_SONIOX_ENDPOINT"`.
- **`RecordingOptions.withOutput(_:)`** (`RecordingOptions.swift:306-331`): If a Soniox-specific stored property is added to `RecordingOptions` (e.g. `sonioxEndpoint`), it MUST be forwarded here or `RecordingOptionsTranscriptionTests.testWithOutputPreservesTranscriptionFields` will catch the omission.

#### D. Gemini Provider — streaming session shape to mirror (`Sources/MacrecCore/Transcription/Providers/GeminiRESTTranscriptionProvider.swift`)
- Gemini is REST-batch only; its `openStreamingSession` throws `transcriptionConfigConflict` (line 141-148). Soniox is the inverse — it is streaming-native.
- The WebSocket session pattern to model: `AppleSpeechSession` in `AppleSpeechTranscriptionProvider.swift` (lines 191-344). Key structural elements to replicate:
  - `AsyncStream.makeStream(of: StreamingTranscriptionEvent.self, bufferingPolicy: .bufferingNewest(128))` for `events`.
  - Per-source drain `Task` that yields events from the remote stream into the continuation.
  - `NSLock` for mutable counter state (or `actor`).
  - `finish()` that calls provider close, reconciles any pending finals, then calls `eventsContinuation.finish()`.
- For the WebSocket transport: use `URLSessionWebSocketTask` (Foundation, no new dependency). The `urlSession` should be injectable (like `GeminiRESTTranscriptionProvider.urlSession`) so tests can stub via `URLProtocol`.

#### E. Apple SpeechAnalyzer Provider — locale / language pattern to mirror (`Sources/MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift`)
- **Language hint resolution** (`AppleSpeechTranscriptionProvider.swift:93-96`): Soniox should similarly consume `options.languageHints` from `TranscriptionOptions`. When the list is empty, default to `["el", "en"]` (Greek-first per FR-SX-9).
- **Per-segment language tagging** (`AppleSpeechSession.swift:325-330`): the `final` event carries `language: winner.locale.identifier`. Soniox must populate the `language` field on each `StreamingTranscriptionEvent.final` from the Soniox server message (if available) or from the configured hint (fallback).
- **`SpeechPermission.ensureGranted()`** (`AppleSpeechTranscriptionProvider.swift:121`): NOT needed for Soniox (network call, not mic TCC). Remove this dependency.

#### F. AudioDownsampler and AudioWAVEncoder (`Sources/MacrecCore/Transcription/AudioDownsampler.swift`, `AudioWAVEncoder.swift`)
- `AudioDownsampler` (`AudioDownsampler.swift:49`) converts Float32 / 48 kHz / non-interleaved (mono or stereo) → Int16 / 16 kHz / mono / interleaved `Data`. Output is already PCM16-LE at 16 kHz mono — exactly what virtually all cloud STT streaming APIs expect (assumption A-SX-4 is already the output format). The Soniox provider receives `[Float]` samples (already 16 kHz mono via the pipeline) via `ingest(_:)` and needs to convert to `Data` for the WebSocket. Use `AudioWAVEncoder` (`AudioWAVEncoder.swift:5`) for WAV framing if Soniox requires it, or pack raw Int16 LE bytes directly if Soniox accepts raw PCM without a WAV header.
- `AudioDownsampler` is NOT thread-safe — one instance per recording session/source (`AudioDownsampler.swift:14`). The Soniox session MUST NOT recreate it per chunk.
- No changes to `AudioDownsampler` or `AudioWAVEncoder` are required; all Soniox-specific audio formatting belongs inside `SonioxStreamingTranscriptionProvider`.

#### G. Sidecar Writers (`Sources/MacrecCore/Transcription/Persistence/`)
- No new writer types are needed. The four existing writers (`JSONLTranscriptWriter`, `SRTTranscriptWriter`, `VTTTranscriptWriter`, `TXTTranscriptWriter`) are format-agnostic.
- `TranscriptSidecarWriter` (`TranscriptSidecarWriter.swift:65`) must be constructed with `.streaming` policy for Soniox (same as Apple Speech). Only `.segmentFinalized` events write to disk.
- `SidecarPathBuilder.sidecarURL(...)` derives the `*.transcript.<ext>` path — no changes needed.
- The `model` field on each `TranscriptSegment` must be set to `"soniox"` by the provider before emitting the `final` event (parity with FR-SX-11).

#### H. Four-Tier Env-Var Resolution — where SONIOX_API_KEY slots in (`Sources/MacrecCore/Config/ConfigResolver.swift`)
- The resolution chain at lines 84-95 already handles arbitrary keys via the `value(_:)` closure. Adding `SONIOX_API_KEY` requires only: (1) a new constant in `Keys`, (2) a branch in the API key switch to call `value(Keys.sonioxApiKey)`.
- `MACREC_SONIOX_ENDPOINT` follows the same pattern as all other optional `MACREC_*` vars — add a constant and read it in the resolver, storing the result in a new optional field on `RecordingOptions` (or passing it to the factory input).
- `TranscriptionProviderFactoryInput` (`TranscriptionProviderFactory.swift:5-28`) may need an `endpoint: URL?` field added — the factory passes it to the provider init.
- `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` is already resolved at `ConfigResolver.swift:357` and forwarded in `RecordingOptions.transcriptionKeyExpiresAt`. Soniox reuses this field without changes.

#### I. macrec-ui TranscriptionPicker (`Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`)
- **Lines 72-77**: The `Picker` body lists the four tags. Add `Text("Soniox (cloud, streaming)").tag("soniox")` after `Text("Gemini (cloud)").tag("gemini")` and before `Text("None").tag("none")` — producing the `None | Apple | WhisperKit | Gemini | Soniox` order (or `None | Apple | WhisperKit | Gemini | Soniox` — confirm with OQ-SX-8).
- **`missingKeyTooltip` static** (line 67-68): currently hardcoded to `GOOGLE_API_KEY`. When `providerRaw == "soniox"` and a key is missing, the tooltip should name `SONIOX_API_KEY`. Either parameterize the tooltip or add a `sonioxMissingKeyTooltip` constant.
- **`@AppStorage` default** (line 43-44): the persisted default is `"apple"` — no change needed. Soniox is opt-in.
- **Privacy disclosure**: `PrivacyDisclosureSheet.swift` in the same directory — the disclosure text names the cloud destination. Add a `soniox`-keyed disclosure text naming Soniox as the destination (parity with FR-SX-16 / FR-53).
- **`GeminiKeyField.swift`**: inspect whether this is provider-specific or generic; if specific to Gemini, a parallel `SonioxKeyField.swift` (or a generic `APIKeyField`) is needed.

#### J. macrec CLI `--transcribe` flag (`Sources/macrec/Commands/StartCommand.swift`)
- **Line 95**: The `@Option` help string for `--transcribe` currently reads `"none | gemini-live"`. Update to list all accepted values including `soniox`. No structural code change to the command is needed — the flag value flows through `buildCLIOverrides()` (line 216) which already forwards it as `ConfigResolver.Keys.transcribe`.
- No `--soniox-api-key` flag should be added (NFR-20 / NFR-SX-3 parity — API keys are never accepted as CLI flags).
- A new `--soniox-endpoint <url>` flag (optional) maps to `ConfigResolver.Keys.sonioxEndpoint` in `buildCLIOverrides()`.

#### K. Tests — where Soniox tests should live
- **Provider unit tests**: `Tests/MacrecCoreTests/Transcription/Providers/` — create `SonioxStreamingTranscriptionProviderTests.swift` here.
- **Stub mechanism**: mirror `GeminiRESTStubProtocol.swift` — create `SonioxWebSocketStubProtocol.swift` (a `URLProtocol` subclass, or a WebSocket-level fake injected via the same `urlSession` parameter pattern). The provider should accept an injectable `URLSession` in its `init` so tests can intercept `URLSessionWebSocketTask` creation.
- **Config resolver tests**: `Tests/MacrecCoreTests/Config/ConfigResolverTranscriptionTests.swift` — add test cases: `MACREC_TRANSCRIBE=soniox` with `SONIOX_API_KEY` present resolves correctly; missing key does NOT throw at config-load; `MACREC_TRANSCRIBE=soniox-streaming` exits 64.
- **Factory tests**: `Tests/MacrecCoreTests/Transcription/Providers/TranscriptionProviderFactoryTests.swift` — add cases for `"soniox"` with and without API key.
- **Recording integrity isolation**: `Tests/MacrecCoreTests/Recording/SessionCoordinatorTranscriptionIntegrationTests.swift` — extend with a `SonioxAlwaysFailingFake` injection variant (FR-SX-1 / NFR-SX-1).
- **E2e scripts**: place in `test_scripts/` — `e2e-transcription-soniox.sh`, `e2e-transcription-soniox-key-missing.sh`, `e2e-transcription-soniox-detach.sh` (patterned after `e2e-transcription-key-missing.sh` and `e2e-transcription-apple.sh`).

---

### 4.2 Out of Scope

These modules are NOT implicated by the Soniox integration and MUST NOT be modified beyond the minimum listed above:

- `Sources/MacrecCore/Capture/` — audio capture graph; Soniox receives the same `[Float]` buffers as existing providers.
- `Sources/MacrecCore/Mixing/` — mix/split routing; unchanged.
- `Sources/MacrecCore/Encoding/` — M4A/WAV/CAF encoders; the sidecar is orthogonal.
- `Sources/MacrecCore/Daemon/` — daemonizer; detach mode works without provider-specific changes.
- `Sources/MacrecCore/Aligning/` — host-clock aligner; provider-independent.
- `Sources/MacrecCore/Transcription/SegmentCoalescer.swift` — coalescer is provider-agnostic.
- `Sources/MacrecCore/Transcription/TranscriptSanitizer.swift` — sanitizer is provider-agnostic.
- `Sources/MacrecCore/Transcription/TranscriptionManager.swift` — the manager dispatches to the factory; it is NOT provider-specific.
- `Sources/MacrecCore/Transcription/SourceBuffer.swift` — shared buffer; unchanged.
- `Sources/MacrecUIKit/SessionCoordinator.swift` — coordinator invokes `RecordingController`; unchanged.
- `Sources/MacrecUIKit/RecordingController.swift` — controller reads `transcriptionProviderId`; unchanged (string-based dispatch already handles unknown ids via the factory).
- All existing provider files (`AppleSpeechTranscriptionProvider.swift`, `GeminiRESTTranscriptionProvider.swift`, `WhisperKitTranscriptionProvider.swift`) — Soniox is additive.

---

### 4.3 New Integration Points (not present in codebase today)

| Artifact | Location | Notes |
|---|---|---|
| `SonioxStreamingTranscriptionProvider` | `Sources/MacrecCore/Transcription/Providers/SonioxStreamingTranscriptionProvider.swift` | New provider conformer; WebSocket session via `URLSessionWebSocketTask` |
| `SonioxWebSocketStubProtocol` | `Tests/MacrecCoreTests/Transcription/Providers/SonioxWebSocketStubProtocol.swift` | URLProtocol-based WebSocket fake for unit tests |
| `ConfigResolver.Keys.sonioxApiKey` | `Sources/MacrecCore/Config/ConfigResolver.swift` | New constant `"SONIOX_API_KEY"` |
| `ConfigResolver.Keys.sonioxEndpoint` | `Sources/MacrecCore/Config/ConfigResolver.swift` | New constant `"MACREC_SONIOX_ENDPOINT"` |
| `TranscriptionProviderId.soniox` | `Sources/MacrecCore/Config/RecordingOptions.swift` | New enum case `"soniox"` |
| `SONIOX_API_KEY` key resolution branch | `Sources/MacrecCore/Config/ConfigResolver.swift:345` | Mirrors Gemini's `GOOGLE_API_KEY` branch |
| `TranscriptionProviderFactoryInput.endpoint` | `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift` | Optional URL for endpoint override (or pass via factory variant) |
| Soniox entry in `TranscriptionPicker` | `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift:75` | New `Text("Soniox (cloud, streaming)").tag("soniox")` row |
| Soniox privacy disclosure text | `Sources/macrec-ui/Views/Transcription/PrivacyDisclosureSheet.swift` | New disclosure body naming Soniox |
| `e2e-transcription-soniox.sh` | `test_scripts/` | Real-key e2e; skip-clean on missing `SONIOX_API_KEY` |
| `e2e-transcription-soniox-key-missing.sh` | `test_scripts/` | No-key variant; mirrors `e2e-transcription-key-missing.sh` exactly |
| `e2e-transcription-soniox-detach.sh` | `test_scripts/` | Detach-mode e2e; mirrors `e2e-transcription-apple-detach.sh` |

---

## 5. Notes

- **`TranscriptionProviderId` enum is closed**: adding `.soniox` is a source-breaking change to the enum's `CaseIterable` conformance — any exhaustive `switch` over the enum elsewhere must be updated. The primary call site is `ConfigResolver.swift`. Search for `switch transcribeProviderEnum` or `switch transcribeProviderId` before cutting the PR.

- **`--transcribe` help text is stale today**: `StartCommand.swift:95` describes the flag as `"none | gemini-live"` which is already out of date (Apple, WhisperKit are already supported). The Soniox addition is a good opportunity to update this to the canonical list. The `default:` error message in `TranscriptionProviderFactory.swift:91` must also be updated to include `'soniox'`.

- **`missingKeyTooltip` is Gemini-hardcoded**: `TranscriptionPicker.swift:67` has a static string mentioning `GOOGLE_API_KEY`. When Soniox is selected and its key is missing, the tooltip will show the wrong key name. This should be fixed as part of the Soniox UI work.

- **WhisperKit is an undeclared fourth provider**: the `TranscriptionPicker.swift` body already lists `whisperkit` as a tag and the factory handles it (`TranscriptionProviderFactory.swift:76-88`), but `TranscriptionProviderId` in `RecordingOptions.swift` does not have a `.whisperkit` case — the resolver passes it through as a raw string. The Soniox design phase (plan-006) should note this inconsistency and decide whether to regularize it or leave it (out of scope for this request, but affects how `MACREC_TRANSCRIBE=soniox` validation is implemented since `parseEnum` is driven by `TranscriptionProviderId.allCases`).
