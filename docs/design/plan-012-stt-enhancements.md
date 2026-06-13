# Plan 012 — STT enhancements (Parakeet, Soniox diarization, source-split display)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Parakeet TDT V3 multilingual on-device STT provider, enable Soniox speaker diarization (default-on, settings-toggleable, with speaker labels propagated through every sidecar), and replace the v1 `--transcribe-source both` collapse with true dual-driver source separation that produces two sidecars and a two-lane live transcript panel.

**Architecture:** Three independent feature slices on top of the existing `TranscriptionProvider` factory and `TranscriptionDispatcher` façade. Phase A (Soniox diarization) is the smallest and ships first. Phase B (Parakeet) is additive and isolated to its own provider files. Phase C (source-split) is the largest — it introduces a `SourceSplitTranscriptionManager` that composes two existing single-source `TranscriptionManager` instances (one per `SourceTag`), each with its own provider instance and own sidecar, and a new `SourceSplitTranscriptPanel` that shows two stacked auto-scrolling lanes.

**Tech Stack:** Swift 5 language mode under SwiftPM 6.2 (`platforms: [.macOS(.v26)]`). Deps already present: `argmax-oss-swift` (WhisperKit), `swift-argument-parser`, `swift-log`. New dep: `FluidInference/FluidAudio` (Swift-native CoreML wrapper around `parakeet-tdt-0.6b-v3`). Tests use Swift Testing (`@Test` macros).

**Spec:** `docs/design/refined-request-stt-enhancements.md` is the source of truth — every task here implements something from §3, §4, or §5 of that spec.

---

## Conventions used by every task

- **TDD:** every code task starts with a failing test, then the minimal implementation, then verifies the test passes, then commits.
- **Commit prefixes:** `feat(soniox):`, `feat(parakeet):`, `feat(source-split):`, `test(...):`, `docs(...):`.
- **Test runner:** `swift test --filter <TestSuiteName>` for individual suites; `swift test` for the full run. The `Tests/MacrecCoreTests` and `Tests/MacrecUITests` folders already exist (see `Package.swift`).
- **No version-control automation:** when a step says `git commit ...`, the engineer runs it manually — per the project rule "Don't perform any version control operation unless I explicitly request it" (CLAUDE.md). Each commit step is still listed so the agent prompts the user before committing.
- **Build verification:** after each task that touches `Package.swift` or adds a new file referenced by another file, run `swift build` and confirm clean exit before committing.

---

# Phase A — Soniox speaker diarization

> Spec §4. Smallest blast radius. Ship first.

## Task A1: add optional `speaker` field to `TranscriptSegment`

**Files:**
- Modify: `Sources/MacrecCore/Transcription/TranscriptSegment.swift`
- Test: `Tests/MacrecCoreTests/TranscriptSegmentSpeakerFieldTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/TranscriptSegmentSpeakerFieldTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("TranscriptSegment.speaker (Phase A1)")
struct TranscriptSegmentSpeakerFieldTests {

    @Test("speaker defaults to nil when not provided")
    func defaultIsNil() {
        let s = TranscriptSegment(
            timestamp: Date(timeIntervalSince1970: 0),
            text: "hello",
            source: .system
        )
        #expect(s.speaker == nil)
    }

    @Test("speaker round-trips through Codable")
    func codableRoundTrip() throws {
        let s = TranscriptSegment(
            timestamp: Date(timeIntervalSince1970: 0),
            text: "hello",
            source: .mic,
            speaker: "spk:1"
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        #expect(decoded.speaker == "spk:1")
    }

    @Test("nil speaker is omitted from JSONL line")
    func omitWhenNil() throws {
        let s = TranscriptSegment(
            timestamp: Date(timeIntervalSince1970: 0),
            text: "hello",
            source: .mixed
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(data: try enc.encode(s), encoding: .utf8)!
        #expect(!json.contains("\"speaker\""))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TranscriptSegmentSpeakerFieldTests`
Expected: FAIL — `TranscriptSegment` has no `speaker` parameter.

- [ ] **Step 3: Add the `speaker` field**

Edit `Sources/MacrecCore/Transcription/TranscriptSegment.swift` so the struct becomes:

```swift
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
    public let language: String?
    /// Speaker label populated by providers that perform diarization
    /// (currently Soniox when `enable_speaker_diarization=true`).
    /// Provider-opaque string (Soniox emits `"spk:1"`, `"spk:2"`, …).
    /// Renderers convert to a stable display label via
    /// `SpeakerSidecarLabel.label(for:)`. `nil` for non-diarized
    /// providers — Codable synthesis omits the key entirely.
    public let speaker: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        lastUpdated: Date? = nil,
        text: String,
        source: SourceTag,
        confidence: Float? = nil,
        model: String? = nil,
        durationSec: Double? = nil,
        language: String? = nil,
        speaker: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.lastUpdated = lastUpdated ?? timestamp
        self.text = text
        self.source = source
        self.confidence = confidence
        self.model = model
        self.durationSec = durationSec
        self.language = language
        self.speaker = speaker
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TranscriptSegmentSpeakerFieldTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: PASS — every existing snapshot test stays green because the new field is optional and Codable omits `nil` Optionals from synthesized JSON output.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacrecCore/Transcription/TranscriptSegment.swift \
        Tests/MacrecCoreTests/TranscriptSegmentSpeakerFieldTests.swift
git commit -m "feat(transcription): add optional speaker field to TranscriptSegment

Additive nullable field. Codable synthesis omits when nil, so all
existing JSONL fixtures and provider sidecars stay byte-equivalent.
Used by Soniox diarization (Phase A) and renderable by every sidecar
writer in subsequent tasks.

Spec: docs/design/refined-request-stt-enhancements.md §4.3."
```

---

## Task A2: flip Soniox diarization default to `true` (with override-to-false)

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigBuilder.swift`
- Test: `Tests/MacrecCoreTests/SonioxConfigBuilderDiarizationTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SonioxConfigBuilderDiarizationTests.swift`:

```swift
import Testing
@testable import MacrecCore

@Suite("SonioxConfigBuilder diarization default (Phase A2)")
struct SonioxConfigBuilderDiarizationTests {

    @Test("default enables speaker diarization")
    func defaultIsTrue() {
        let msg = SonioxConfigBuilder.build(
            apiKey: "k",
            languageHints: ["en"]
        )
        #expect(msg.enableSpeakerDiarization == true)
    }

    @Test("explicit false override is honoured")
    func overrideFalse() {
        let msg = SonioxConfigBuilder.build(
            apiKey: "k",
            languageHints: ["en"],
            diarize: false
        )
        #expect(msg.enableSpeakerDiarization == false)
    }

    @Test("explicit true override is honoured")
    func overrideTrue() {
        let msg = SonioxConfigBuilder.build(
            apiKey: "k",
            languageHints: ["en"],
            diarize: true
        )
        #expect(msg.enableSpeakerDiarization == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SonioxConfigBuilderDiarizationTests`
Expected: FAIL on `defaultIsTrue` (current default is `false`); FAIL on the override tests because `build(...)` has no `diarize:` parameter.

- [ ] **Step 3: Update `SonioxConfigBuilder.build(...)`**

Replace the body of `Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigBuilder.swift` with:

```swift
import Foundation

public enum SonioxConfigBuilder {

    /// Real-time STT model id used by `macrec` v1.
    public static let defaultModel = "stt-rt-v4"

    /// Default value for `enable_speaker_diarization`. Flipped to
    /// `true` by plan-012 Phase A2 — the user asked for diarization
    /// support and the field is now opt-out via
    /// `MACREC_SONIOX_DIARIZE=false` (CLI: `--soniox-diarize false`,
    /// UI: `com.macrec.ui.sonioxDiarize`).
    public static let defaultDiarize: Bool = true

    public static func build(
        apiKey: String,
        model: String = defaultModel,
        languageHints: [String],
        diarize: Bool = SonioxConfigBuilder.defaultDiarize,
        clientReferenceId: String? = nil
    ) -> SonioxConfigMessage {
        return SonioxConfigMessage(
            apiKey: apiKey,
            model: model,
            audioFormat: "pcm_s16le",
            sampleRate: 16_000,
            numChannels: 1,
            languageHints: languageHints,
            languageHintsStrict: false,
            enableLanguageIdentification: true,
            enableEndpointDetection: true,
            maxEndpointDelayMs: 2_000,
            enableSpeakerDiarization: diarize,
            context: nil,
            clientReferenceId: clientReferenceId,
            keepaliveIntervalMs: nil
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SonioxConfigBuilderDiarizationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Build the whole package to confirm nothing else broke**

Run: `swift build`
Expected: clean exit (no callers of `SonioxConfigBuilder.build(...)` rely on the old non-diarize signature — `diarize:` defaults).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacrecCore/Transcription/Live/Soniox/SonioxConfigBuilder.swift \
        Tests/MacrecCoreTests/SonioxConfigBuilderDiarizationTests.swift
git commit -m "feat(soniox): flip enable_speaker_diarization default to true

Adds a 'diarize' parameter to SonioxConfigBuilder.build(...) that
defaults to a new public 'defaultDiarize: true' constant. Existing
callers stay unchanged thanks to the default arg; the next task
plumbs an explicit override through the provider/factory chain so
the user can opt out via MACREC_SONIOX_DIARIZE=false.

Spec: docs/design/refined-request-stt-enhancements.md §4.1."
```

---

## Task A3: thread `diarize:` through `SonioxStreamingTranscriptionProvider`

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingTranscriptionProvider.swift`
- Test: `Tests/MacrecCoreTests/SonioxStreamingProviderDiarizationTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SonioxStreamingProviderDiarizationTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("SonioxStreamingTranscriptionProvider.diarize plumbing (Phase A3)")
struct SonioxStreamingProviderDiarizationTests {

    @Test("provider exposes its diarize value")
    func diarizeReadable() async {
        let provider = SonioxStreamingTranscriptionProvider(
            apiKey: "k",
            diarize: false
        )
        #expect(await provider.currentDiarize() == false)
    }

    @Test("default constructor preserves builder default (true)")
    func defaultMatchesBuilder() async {
        let provider = SonioxStreamingTranscriptionProvider(apiKey: "k")
        #expect(await provider.currentDiarize() == SonioxConfigBuilder.defaultDiarize)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SonioxStreamingProviderDiarizationTests`
Expected: FAIL — `init(apiKey:diarize:)` does not exist; `currentDiarize()` does not exist.

- [ ] **Step 3: Add the `diarize` parameter and accessor**

Edit `Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingTranscriptionProvider.swift`:

1. Add a stored property after `private let model: String`:
   ```swift
   private let diarize: Bool
   ```
2. Update `init(...)` to accept the new parameter (insert between `model:` and `logger:`):
   ```swift
   public init(
       apiKey: String,
       endpoint: URL = SonioxStreamingTranscriptionProvider.defaultEndpoint,
       model: String = SonioxConfigBuilder.defaultModel,
       diarize: Bool = SonioxConfigBuilder.defaultDiarize,
       logger: Logger? = nil,
       transportFactory: (@Sendable () -> any WebSocketTransport)? = nil
   ) {
       self.apiKey = apiKey
       self.endpoint = endpoint
       self.model = model
       self.diarize = diarize
       self.logger = logger
       self.transportFactory = transportFactory ?? {
           URLSessionWebSocketTaskTransport()
       }
   }
   ```
3. Update `openStreamingSession(...)` to pass `diarize` into the builder:
   ```swift
   let configMessage = SonioxConfigBuilder.build(
       apiKey: apiKey,
       model: resolvedModel,
       languageHints: mappedHints,
       diarize: diarize,
       clientReferenceId: "macrec-\(source.rawValue)"
   )
   ```
4. Add a test-only accessor at the end of the actor:
   ```swift
   /// Test-only accessor. Used by Phase A3 plumbing tests.
   internal func currentDiarize() -> Bool { diarize }
   ```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SonioxStreamingProviderDiarizationTests`
Expected: PASS.

- [ ] **Step 5: Run the full Soniox test suite to confirm no regressions**

Run: `swift test --filter Soniox`
Expected: every Soniox test passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacrecCore/Transcription/Live/Soniox/SonioxStreamingTranscriptionProvider.swift \
        Tests/MacrecCoreTests/SonioxStreamingProviderDiarizationTests.swift
git commit -m "feat(soniox): plumb diarize flag through streaming provider

Adds 'diarize' init parameter (default = SonioxConfigBuilder.defaultDiarize)
and forwards it to SonioxConfigBuilder.build at session-open time.
Internal currentDiarize() accessor lets Phase A3 tests verify the
plumbing without spinning up a real WebSocket transport."
```

---

## Task A4: split-on-speaker boundary in `SonioxTokenAggregator`

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift`
- Test: `Tests/MacrecCoreTests/SonioxAggregatorSpeakerBoundaryTests.swift` (create)

> Read `Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift` first — the change is to (a) split the active partial when a token's `speaker` differs from the in-flight active speaker, and (b) carry the active speaker onto the emitted segment via the new `TranscriptSegment.speaker` field.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SonioxAggregatorSpeakerBoundaryTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("SonioxTokenAggregator speaker boundary handling (Phase A4)")
struct SonioxAggregatorSpeakerBoundaryTests {

    @Test("speaker change splits the active partial into two segments")
    func speakerChangeSplits() async {
        let agg = SonioxTokenAggregator(source: .system)

        // First two tokens — speaker spk:1
        await agg.feed(tokens: [
            SonioxToken(text: "hello", isFinal: true, language: "en",
                        speaker: "spk:1", startMs: 0, endMs: 500),
            SonioxToken(text: " world", isFinal: true, language: "en",
                        speaker: "spk:1", startMs: 500, endMs: 1000)
        ])

        // Third token — speaker spk:2 — must finalise the first
        // segment and start a new one tagged spk:2.
        await agg.feed(tokens: [
            SonioxToken(text: "ok", isFinal: true, language: "en",
                        speaker: "spk:2", startMs: 1000, endMs: 1300)
        ])

        let segments = await agg.finishedSegments()
        #expect(segments.count == 2)
        #expect(segments[0].speaker == "spk:1")
        #expect(segments[0].text.contains("hello"))
        #expect(segments[1].speaker == "spk:2")
        #expect(segments[1].text == "ok")
    }

    @Test("missing speaker carries through as nil")
    func nilSpeakerCarryThrough() async {
        let agg = SonioxTokenAggregator(source: .system)
        await agg.feed(tokens: [
            SonioxToken(text: "hello", isFinal: true, language: "en",
                        speaker: nil, startMs: 0, endMs: 500)
        ])
        let segments = await agg.finishedSegments()
        #expect(segments.count == 1)
        #expect(segments[0].speaker == nil)
    }
}
```

> The test depends on a couple of `SonioxTokenAggregator` accessors that may not exist yet: `feed(tokens:)`, `finishedSegments()`. If the production class uses different names (e.g. `aggregate(_:)`, `drain()`), rename the test calls to match — but keep the assertion shape. The agent should read the existing aggregator source first and adapt the test API names accordingly.

- [ ] **Step 2: Read the current aggregator and align test API names**

Run: `cat Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift`
Update the test method calls to match the public surface; do NOT change the assertion logic.

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter SonioxAggregatorSpeakerBoundaryTests`
Expected: FAIL — `speaker` is not preserved across segments and consecutive same-speaker tokens are not split on speaker change.

- [ ] **Step 4: Implement the speaker-aware logic**

Inside `SonioxTokenAggregator`:

1. Add a stored property tracking the active partial's speaker:
   ```swift
   /// Speaker of the in-flight partial. `nil` until the first token
   /// with a non-nil speaker arrives, then sticks until a token with
   /// a different non-nil speaker forces a finalise-and-restart.
   private var activeSpeaker: String?
   ```
2. In the per-token loop (find the place where each `SonioxToken` is folded into the active partial), insert a guard at the top:
   ```swift
   if let incoming = token.speaker,
      let active = activeSpeaker,
      incoming != active {
       finaliseActivePartial()  // emits the current segment with .speaker = active
       activeSpeaker = incoming
   } else if activeSpeaker == nil {
       activeSpeaker = token.speaker
   }
   ```
3. Where the partial is materialised into a `TranscriptSegment` (the existing `makeSegment(...)` / `emit(...)` helper), pass the active speaker:
   ```swift
   let segment = TranscriptSegment(
       timestamp: …,
       text: …,
       source: source,
       confidence: …,
       model: "soniox",
       durationSec: …,
       language: …,
       speaker: activeSpeaker
   )
   ```
4. Reset `activeSpeaker = nil` when an utterance-end (`<end>` marker / final boundary) closes the partial, so the next utterance can adopt whatever speaker the next token carries.

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter SonioxAggregatorSpeakerBoundaryTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the entire Soniox test suite to confirm existing aggregator tests still pass**

Run: `swift test --filter Soniox`
Expected: clean — pre-existing `SonioxTokenAggregatorTests` keep passing because they don't populate `speaker` and the new logic is a no-op when `token.speaker == nil`.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacrecCore/Transcription/Live/Soniox/SonioxTokenAggregator.swift \
        Tests/MacrecCoreTests/SonioxAggregatorSpeakerBoundaryTests.swift
git commit -m "feat(soniox): split partial on speaker boundary, propagate speaker

Aggregator now finalises the in-flight partial whenever an incoming
token carries a different non-nil speaker, and stamps the active
speaker onto every emitted TranscriptSegment.speaker. No-op for
tokens without a speaker tag (legacy, non-diarized Soniox sessions
and every other provider).

Spec: docs/design/refined-request-stt-enhancements.md §4.3."
```

---

## Task A5: add `MACREC_SONIOX_DIARIZE` resolver + `--soniox-diarize` CLI flag + factory wiring

**Files:**
- Modify: `Sources/MacrecCore/Config/ConfigResolver.swift`
- Modify: `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`
- Modify: `Sources/macrec/Commands/StartCommand.swift`
- Test: `Tests/MacrecCoreTests/SonioxDiarizeResolverTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SonioxDiarizeResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("ConfigResolver MACREC_SONIOX_DIARIZE four-tier resolution (Phase A5)")
struct SonioxDiarizeResolverTests {

    @Test("default is true when no source sets it")
    func defaultTrue() throws {
        let env: [String: String] = ["MACREC_TRANSCRIBE": "soniox", "SONIOX_API_KEY": "k"]
        let opts = try ConfigResolver.resolveForTesting(env: env, cliOverrides: [:])
        #expect(opts.sonioxDiarize == true)
    }

    @Test("env false overrides default")
    func envFalse() throws {
        let env: [String: String] = [
            "MACREC_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "k",
            "MACREC_SONIOX_DIARIZE": "false"
        ]
        let opts = try ConfigResolver.resolveForTesting(env: env, cliOverrides: [:])
        #expect(opts.sonioxDiarize == false)
    }

    @Test("CLI flag wins over env")
    func cliWinsOverEnv() throws {
        let env: [String: String] = [
            "MACREC_TRANSCRIBE": "soniox",
            "SONIOX_API_KEY": "k",
            "MACREC_SONIOX_DIARIZE": "false"
        ]
        let opts = try ConfigResolver.resolveForTesting(
            env: env,
            cliOverrides: [ConfigResolver.Keys.sonioxDiarize: "true"]
        )
        #expect(opts.sonioxDiarize == true)
    }
}
```

> If `ConfigResolver.resolveForTesting(env:cliOverrides:)` does not exist, find the existing test helper used by sibling tests (e.g. `ConfigResolverWhisperKitTests`) and use its name. Do NOT invent a new test surface — adapt to whatever the project already exposes.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SonioxDiarizeResolverTests`
Expected: FAIL — `Keys.sonioxDiarize` does not exist; `RecordingOptions.sonioxDiarize` does not exist.

- [ ] **Step 3: Wire `RecordingOptions.sonioxDiarize`**

In `Sources/MacrecCore/Config/RecordingOptions.swift`, add an Optional `Bool?` field:

```swift
/// Soniox `enable_speaker_diarization` toggle. `nil` → use provider
/// default (currently `true` per SonioxConfigBuilder.defaultDiarize).
/// Resolved from MACREC_SONIOX_DIARIZE / --soniox-diarize. Plan-012
/// Phase A5.
public var sonioxDiarize: Bool?
```

Add it to the memberwise initializer with a `nil` default and wherever the struct is copied/encoded.

- [ ] **Step 4: Add the resolver key + parsing**

In `Sources/MacrecCore/Config/ConfigResolver.swift`:

1. Add a key constant in the existing `enum Keys` block (alphabetical near the other `soniox*` keys):
   ```swift
   public static let sonioxDiarize = "MACREC_SONIOX_DIARIZE"
   ```
2. After the existing Soniox endpoint resolution block (search for `let sonioxEndpoint: URL?`), add:
   ```swift
   let sonioxDiarize: Bool? = try parseOptionalBool(
       key: Keys.sonioxDiarize,
       raw: value(Keys.sonioxDiarize)
   )
   ```
3. In the final `RecordingOptions(...)` construction call (search for `sonioxEndpoint: sonioxEndpoint`), add `sonioxDiarize: sonioxDiarize,` next to it.

- [ ] **Step 5: Add the CLI flag in `StartCommand`**

In `Sources/macrec/Commands/StartCommand.swift`, after the existing `--soniox-endpoint` declaration (around line 113):

```swift
@Option(name: .long, help: "Override Soniox speaker diarization (true | false). Default: true. Env: MACREC_SONIOX_DIARIZE.")
public var sonioxDiarize: Bool?
```

In the CLI-overrides block (search for `if let v = sonioxEndpoint`), add:

```swift
if let v = sonioxDiarize        { o[ConfigResolver.Keys.sonioxDiarize] = v ? "true" : "false" }
```

- [ ] **Step 6: Forward to the factory**

In `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`:

1. Add `sonioxDiarize: Bool?` to `TranscriptionProviderFactoryInput` (init param + stored property), default `nil`.
2. In the `case "soniox":` arm, replace the existing `SonioxStreamingTranscriptionProvider(...)` call with:
   ```swift
   return SonioxStreamingTranscriptionProvider(
       apiKey: key,
       model: input.modelId ?? SonioxConfigBuilder.defaultModel,
       diarize: input.sonioxDiarize ?? SonioxConfigBuilder.defaultDiarize,
       logger: input.logger
   )
   ```
3. In `RecordingSession.swift` (or wherever `TranscriptionProviderFactoryInput(...)` is constructed from `RecordingOptions`), thread `sonioxDiarize: options.sonioxDiarize`.

- [ ] **Step 7: Run the test to verify it passes**

Run: `swift test --filter SonioxDiarizeResolverTests`
Expected: PASS (3 tests).

- [ ] **Step 8: Build the whole package + sanity-check the CLI**

Run: `swift build`
Run: `swift run macrec start --help | grep soniox-diarize`
Expected: build succeeds; the help output lists `--soniox-diarize <bool>`.

- [ ] **Step 9: Commit**

```bash
git add Sources/MacrecCore/Config/ConfigResolver.swift \
        Sources/MacrecCore/Config/RecordingOptions.swift \
        Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift \
        Sources/MacrecCore/RecordingSession.swift \
        Sources/macrec/Commands/StartCommand.swift \
        Tests/MacrecCoreTests/SonioxDiarizeResolverTests.swift
git commit -m "feat(soniox): add MACREC_SONIOX_DIARIZE config + --soniox-diarize CLI

Four-tier resolution (env → user .env → local .env → CLI flag) plus
factory plumbing into SonioxStreamingTranscriptionProvider. Default
remains the SonioxConfigBuilder.defaultDiarize value (currently true);
explicit false at any tier opts the user back out.

Spec: docs/design/refined-request-stt-enhancements.md §4.2."
```

---

## Task A6: `SpeakerSidecarLabel` helper

**Files:**
- Create: `Sources/MacrecCore/Transcription/SpeakerSidecarLabel.swift`
- Test: `Tests/MacrecCoreTests/SpeakerSidecarLabelTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SpeakerSidecarLabelTests.swift`:

```swift
import Testing
@testable import MacrecCore

@Suite("SpeakerSidecarLabel (Phase A6)")
struct SpeakerSidecarLabelTests {

    @Test("Soniox spk:N maps to S<N>")
    func sonioxFormat() {
        #expect(SpeakerSidecarLabel.label(for: "spk:1") == "S1")
        #expect(SpeakerSidecarLabel.label(for: "spk:42") == "S42")
    }

    @Test("nil returns nil")
    func nilPassthrough() {
        #expect(SpeakerSidecarLabel.label(for: nil) == nil)
    }

    @Test("opaque string falls back to the raw value uppercased")
    func opaqueFallback() {
        #expect(SpeakerSidecarLabel.label(for: "alice") == "ALICE")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SpeakerSidecarLabelTests`
Expected: FAIL — type does not exist.

- [ ] **Step 3: Create the helper**

Create `Sources/MacrecCore/Transcription/SpeakerSidecarLabel.swift`:

```swift
import Foundation

/// Single source of truth for converting a provider-opaque speaker
/// id (e.g. Soniox's `"spk:1"`) into the short uppercase label that
/// every sidecar format and the live UI chip render. Plan-012 Phase A6.
public enum SpeakerSidecarLabel {

    /// Maps a raw speaker id to a render label.
    /// * `"spk:N"` (Soniox convention) → `"SN"`.
    /// * `nil` → `nil` (caller renders nothing).
    /// * Any other non-empty string → uppercased verbatim.
    public static func label(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("spk:") {
            let suffix = raw.dropFirst("spk:".count)
            if !suffix.isEmpty { return "S" + suffix }
        }
        return raw.uppercased()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SpeakerSidecarLabelTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/Transcription/SpeakerSidecarLabel.swift \
        Tests/MacrecCoreTests/SpeakerSidecarLabelTests.swift
git commit -m "feat(transcription): add SpeakerSidecarLabel helper

Maps a provider-opaque speaker id (Soniox spk:N) to a stable short
uppercase label (SN). Used by all four sidecar writers and by the
live transcript chip in subsequent tasks so the rendering convention
lives in exactly one place.

Spec: docs/design/refined-request-stt-enhancements.md §4.4."
```

---

## Task A7: render speaker in the four sidecar formats (JSONL / TXT / SRT / VTT)

**Files:**
- Modify: every writer under `Sources/MacrecCore/Transcription/Persistence/` (typically four files: `JSONLTranscriptWriter.swift`, `TXTTranscriptWriter.swift`, `SRTTranscriptWriter.swift`, `VTTTranscriptWriter.swift` — confirm exact names by `ls Sources/MacrecCore/Transcription/Persistence/`).
- Test: `Tests/MacrecCoreTests/SpeakerSidecarFormatsTests.swift` (create)

- [ ] **Step 1: Discover the writer file names**

Run: `ls Sources/MacrecCore/Transcription/Persistence/`
Note the exact filenames; use those in subsequent steps.

- [ ] **Step 2: Write failing tests for all four formats**

Create `Tests/MacrecCoreTests/SpeakerSidecarFormatsTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("Speaker label propagation across all four sidecar formats (Phase A7)")
struct SpeakerSidecarFormatsTests {

    private func sample(speaker: String?) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            timestamp: Date(timeIntervalSince1970: 1.23),
            text: "hello world",
            source: .system,
            model: "soniox",
            durationSec: 0.88,
            language: "en-US",
            speaker: speaker
        )
    }

    @Test("JSONL includes 'speaker' field when present")
    func jsonlHasSpeaker() throws {
        let line = JSONLTranscriptWriter.formatLine(sample(speaker: "spk:2"))
        #expect(line.contains("\"speaker\":\"spk:2\""))
    }

    @Test("JSONL omits 'speaker' field when nil (byte-equiv guarantee)")
    func jsonlOmitsSpeakerWhenNil() throws {
        let line = JSONLTranscriptWriter.formatLine(sample(speaker: nil))
        #expect(!line.contains("speaker"))
    }

    @Test("TXT prefixes line with [S<N>] after the timestamp when speaker present")
    func txtPrefixSpeaker() {
        let line = TXTTranscriptWriter.formatLine(sample(speaker: "spk:1"))
        #expect(line.contains("[S1]"))
        #expect(line.contains("hello world"))
    }

    @Test("TXT emits no [S?] prefix when speaker is nil")
    func txtNoPrefixWhenNil() {
        let line = TXTTranscriptWriter.formatLine(sample(speaker: nil))
        #expect(!line.contains("[S"))
    }

    @Test("SRT prefixes cue text with S<N>: when speaker present")
    func srtPrefixSpeaker() {
        let cue = SRTTranscriptWriter.formatCue(index: 1, segment: sample(speaker: "spk:3"))
        #expect(cue.contains("S3: hello world"))
    }

    @Test("VTT wraps cue text in <v S<N>>...</v> when speaker present")
    func vttVoiceTag() {
        let cue = VTTTranscriptWriter.formatCue(sample(speaker: "spk:2"))
        #expect(cue.contains("<v S2>hello world</v>"))
    }
}
```

> If the writer types use different static-method names (e.g. `format(_:)`), rename the test calls. Do NOT invent new public surfaces — read the existing writers first and adapt the test method names accordingly.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter SpeakerSidecarFormatsTests`
Expected: FAIL on every test that references the speaker code path.

- [ ] **Step 4: Update the JSONL writer**

In the JSONL writer's segment-encoding path, append the speaker field after `language`:

```swift
// pseudocode — adapt to the actual writer's style
if let raw = segment.speaker {
    json["speaker"] = raw
}
```

If the writer uses Codable directly off `TranscriptSegment` (already done in Task A1), no change is needed here. Confirm by inspecting the writer.

- [ ] **Step 5: Update the TXT writer**

In the TXT writer's per-line formatter, after the timestamp prefix and before the text, insert the speaker label:

```swift
let speakerPrefix: String = {
    guard let label = SpeakerSidecarLabel.label(for: segment.speaker) else { return "" }
    return "[\(label)] "
}()
return "[\(timestamp)] \(speakerPrefix)\(segment.text)"
```

- [ ] **Step 6: Update the SRT writer**

In the SRT cue formatter, prefix the text:

```swift
let speakerPrefix: String = {
    guard let label = SpeakerSidecarLabel.label(for: segment.speaker) else { return "" }
    return "\(label): "
}()
return "\(index)\n\(timeRange)\n\(speakerPrefix)\(segment.text)\n"
```

- [ ] **Step 7: Update the VTT writer**

In the VTT cue formatter, wrap the text:

```swift
let body: String = {
    guard let label = SpeakerSidecarLabel.label(for: segment.speaker) else {
        return segment.text
    }
    return "<v \(label)>\(segment.text)</v>"
}()
return "\(timeRange)\n\(body)\n"
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter SpeakerSidecarFormatsTests`
Expected: PASS (6 tests).

- [ ] **Step 9: Run the full sidecar / Soniox test suites**

Run: `swift test --filter Sidecar` ; `swift test --filter Soniox`
Expected: clean — pre-existing snapshot tests stay green because all paths are no-ops when `speaker == nil`.

- [ ] **Step 10: Commit**

```bash
git add Sources/MacrecCore/Transcription/Persistence/ \
        Tests/MacrecCoreTests/SpeakerSidecarFormatsTests.swift
git commit -m "feat(transcription): render speaker label in JSONL/TXT/SRT/VTT

JSONL adds optional 'speaker' field after 'language' (omitted when nil).
TXT prefixes the line with [S<N>] after the timestamp.
SRT prefixes the cue text with S<N>:.
VTT wraps the cue text in <v S<N>>...</v>.

All paths are no-ops when speaker is nil, preserving byte-equivalence
for non-diarized providers.

Spec: docs/design/refined-request-stt-enhancements.md §4.4."
```

---

## Task A8: Soniox settings UI section + speaker chip in `LiveTranscriptPanel`

**Files:**
- Create: `Sources/macrec-ui/Settings/Sections/SonioxSettingsView.swift`
- Modify: `Sources/macrec-ui/Settings/SettingsRootView.swift`
- Modify: `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`
- Test: `Tests/MacrecUITests/SonioxSettingsViewTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecUITests/SonioxSettingsViewTests.swift`:

```swift
import Testing
import SwiftUI
@testable import MacrecUIKit

@Suite("Soniox settings UI smoke tests (Phase A8)")
struct SonioxSettingsViewTests {

    @Test("default AppStorage value is true")
    func appStorageDefault() {
        // The constant lives in the UI module; we assert the expected
        // default key + value at the type level.
        #expect(SonioxSettingsAppStorageKeys.diarize == "com.macrec.ui.sonioxDiarize")
        #expect(SonioxSettingsAppStorageKeys.diarizeDefault == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SonioxSettingsViewTests`
Expected: FAIL — `SonioxSettingsAppStorageKeys` does not exist.

- [ ] **Step 3: Add the AppStorage key constants in MacrecUIKit**

Create `Sources/MacrecUIKit/SonioxSettingsAppStorageKeys.swift`:

```swift
import Foundation

/// Centralised AppStorage key + default for the Soniox settings UI.
/// Lives in MacrecUIKit (testable) rather than macrec-ui (executable)
/// so unit tests can pin both. Plan-012 Phase A8.
public enum SonioxSettingsAppStorageKeys {
    public static let diarize = "com.macrec.ui.sonioxDiarize"
    public static let diarizeDefault: Bool = true
}
```

- [ ] **Step 4: Build the new SettingsView**

Create `Sources/macrec-ui/Settings/Sections/SonioxSettingsView.swift`:

```swift
import MacrecCore
import MacrecUIKit
import SwiftUI

/// Settings panel for the Soniox provider. v1.6 surfaces a single
/// toggle (`Diarize speakers`) bound to the AppStorage key
/// `com.macrec.ui.sonioxDiarize`. Plan-012 Phase A8.
struct SonioxSettingsView: View {

    @AppStorage(SonioxSettingsAppStorageKeys.diarize)
    private var diarize: Bool = SonioxSettingsAppStorageKeys.diarizeDefault

    var body: some View {
        Form {
            Section {
                Toggle("Diarize speakers", isOn: $diarize)
                    .help("Tag each transcript segment with the Soniox-detected speaker (S1, S2, …). On by default; turn off for monologue recordings to remove the per-segment label.")
            } header: {
                Text("Soniox")
            } footer: {
                Text("Speaker labels are added to JSONL (speaker field), TXT ([S1] prefix), SRT (S1: prefix), VTT (<v S1>...</v>). Sidecar files for non-Soniox providers are unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 5: Register the new section in `SettingsRootView`**

Find the existing `case .elevenlabs:` arm in `SettingsRootView.swift` and add a sibling `case .soniox:`:

```swift
case .soniox:
    SonioxSettingsView()
```

Add a new case to the `SettingsTab` enum (search for `case elevenlabs`):

```swift
case soniox
```

Add a sidebar entry pointing to the new tab (search for `Label("ElevenLabs", systemImage: ...)`):

```swift
Label("Soniox", systemImage: "waveform")
    .tag(SettingsTab.soniox)
```

- [ ] **Step 6: Add the speaker chip in `LiveTranscriptPanel.segmentView`**

In `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`, the existing `segmentView(_:)` already renders a language chip. Add a sibling speaker chip just after the language chip:

```swift
if let speakerRaw = segment.speaker,
   let label = SpeakerSidecarLabel.label(for: speakerRaw) {
    Text(label)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(palette.chipBackground)
        .cornerRadius(3)
}
```

- [ ] **Step 7: Build the UI executable to confirm it links**

Run: `swift build --product macrec-ui`
Expected: clean build.

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift test --filter SonioxSettingsViewTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/MacrecUIKit/SonioxSettingsAppStorageKeys.swift \
        Sources/macrec-ui/Settings/Sections/SonioxSettingsView.swift \
        Sources/macrec-ui/Settings/SettingsRootView.swift \
        Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift \
        Tests/MacrecUITests/SonioxSettingsViewTests.swift
git commit -m "feat(macrec-ui): Soniox settings + speaker chip in live transcript

Adds a Settings → Soniox tab with a 'Diarize speakers' toggle bound
to com.macrec.ui.sonioxDiarize (default true). LiveTranscriptPanel's
segmentView renders a small monospace chip next to the language chip
when segment.speaker is non-nil, using SpeakerSidecarLabel for the
display string.

Spec: docs/design/refined-request-stt-enhancements.md §4.5."
```

---

## Task A9: documentation updates for Phase A

**Files:**
- Modify: `docs/tools/macrec.md`
- Modify: `docs/design/configuration-guide.md`
- Modify: `docs/design/project-functions.md`
- Modify: `Issues - Pending Items.md`

- [ ] **Step 1: Update `docs/tools/macrec.md` Soniox section**

In the "Defaults" table for Soniox, change the row:

```
| Speaker diarization    | **OFF** in v1 (tracked as v2 follow-up)                   |
```

to:

```
| Speaker diarization    | **ON** by default (overridable via `MACREC_SONIOX_DIARIZE` / `--soniox-diarize`) |
```

After the "Privacy reminder" subsection, add a new subsection:

```markdown
#### Speaker diarization (plan-012)

When `enable_speaker_diarization=true` (the default since v1.7),
Soniox tags each token with a `speaker` field. The
`SonioxTokenAggregator` finalises the active partial whenever the
incoming speaker changes, producing one segment per speaker turn.
The speaker is propagated via the optional `TranscriptSegment.speaker`
field and rendered in every sidecar format:

| Format | Rendering when `speaker == "spk:1"`                |
|--------|----------------------------------------------------|
| JSONL  | optional `"speaker":"spk:1"` field after `language` |
| TXT    | `[00:00:01.230] [S1] hello world`                  |
| SRT    | `S1: hello world` (cue text)                       |
| VTT    | `<v S1>hello world</v>` (cue text)                 |

The `SpeakerSidecarLabel` helper is the single source of truth for
mapping the provider-opaque id to the display label (`spk:N` → `SN`).

**Override:** set `MACREC_SONIOX_DIARIZE=false` (or pass
`--soniox-diarize false`) to revert to non-diarized output. The UI
toggle lives at Settings → Soniox → "Diarize speakers".
```

- [ ] **Step 2: Update `docs/design/configuration-guide.md`**

Add a new variable entry near the other Soniox variables (`MACREC_SONIOX_ENDPOINT`, `MACREC_SONIOX_KEY_EXPIRES_AT`):

```markdown
### `MACREC_SONIOX_DIARIZE`

* **Purpose:** controls Soniox `enable_speaker_diarization`.
* **Allowed values:** `true` | `false`.
* **Default:** `true`.
* **Resolution chain:** shell env → `~/.tool-agents/macrec/.env` →
  `./.env` → `--soniox-diarize` CLI flag (lowest to highest).
* **UI override:** Settings → Soniox → "Diarize speakers"
  (AppStorage `com.macrec.ui.sonioxDiarize`).
* **Recommended storage:** project-wide setting; keep in
  `~/.tool-agents/macrec/.env` if you want consistent behaviour
  across CLI and UI invocations.
```

- [ ] **Step 3: Register the FR in `project-functions.md`**

Find the next available FR-id (search for the highest `FR-` number) and add an entry like:

```markdown
**FR-SX-19** — Soniox transcription supports speaker diarization
(`enable_speaker_diarization=true` by default). Each emitted segment
carries an optional `speaker` field; sidecar formats render a stable
short label (`S1`, `S2`, …). Plan-012 Phase A.
```

- [ ] **Step 4: Update `Issues - Pending Items.md`**

Find any open item referencing "Soniox diarization" or "OQ-SX-3". Move it from Pending to Completed with a one-line note:

```markdown
- **Soniox speaker diarization (OQ-SX-3 closed)** — implemented in
  plan-012 Phase A. Default `true` with `MACREC_SONIOX_DIARIZE` env
  + `--soniox-diarize` CLI + `Settings → Soniox` UI override.
```

- [ ] **Step 5: Commit**

```bash
git add docs/tools/macrec.md \
        docs/design/configuration-guide.md \
        docs/design/project-functions.md \
        "Issues - Pending Items.md"
git commit -m "docs: Soniox speaker diarization (plan-012 Phase A)

Documents the new MACREC_SONIOX_DIARIZE config, --soniox-diarize CLI
flag, default-on behaviour, sidecar rendering for all four formats,
and the UI override. Closes OQ-SX-3 in Issues - Pending Items.md.

Spec: docs/design/refined-request-stt-enhancements.md §4.7."
```

---

# Phase B — Parakeet TDT V3 multilingual provider

> Spec §3. Additive, isolated to its own files. Ship after Phase A.

## Task B1: add `FluidAudio` SPM dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Verify the latest tagged release**

Run: `git ls-remote --tags https://github.com/FluidInference/FluidAudio | tail -5`
Note the highest semver tag (e.g. `0.6.0`). Pin to that exact tag.

- [ ] **Step 2: Add the dependency declaration**

Edit `Package.swift`:

1. In the `dependencies:` array, add a new entry after the existing `argmax-oss-swift` block:
   ```swift
   // FluidAudio — Swift-native CoreML wrapper around NVIDIA's
   // Parakeet TDT V3 multilingual ASR (~25 European languages
   // including Greek). Pinned to <TAG_FROM_STEP_1>; see
   // docs/design/refined-request-stt-enhancements.md §3.2.
   .package(
       url: "https://github.com/FluidInference/FluidAudio",
       exact: "<TAG_FROM_STEP_1>"
   ),
   ```
2. In the `MacrecCore` target's `dependencies:` array, add:
   ```swift
   .product(name: "FluidAudio", package: "FluidAudio"),
   ```
   (Adjust the product name if `swift package describe` reveals a different export — see Step 3.)

- [ ] **Step 3: Resolve and inspect the dependency**

Run: `swift package resolve`
Run: `swift package describe --type json | python3 -c "import json,sys; d=json.load(sys.stdin); print([t['name'] for t in d.get('dependencies', [])])"`
Confirm the actual product name FluidAudio exports; if it's not literally `FluidAudio`, update the `.product(name:)` call accordingly.

- [ ] **Step 4: Build to confirm it links**

Run: `swift build`
Expected: clean exit. If linker warnings appear about CoreML / Accelerate frameworks, that's expected for FluidAudio's first build.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build(deps): add FluidAudio for Parakeet TDT V3 provider

Pins FluidInference/FluidAudio @ <TAG_FROM_STEP_1>. Adds the product
to the MacrecCore target so a future ParakeetTranscriptionProvider
can import it. No behaviour change yet — the provider lands in the
next task.

Spec: docs/design/refined-request-stt-enhancements.md §3.2."
```

---

## Task B2: `ParakeetTranscriptionProvider` skeleton with batch-only contract

**Files:**
- Create: `Sources/MacrecCore/Transcription/Providers/ParakeetTranscriptionProvider.swift`
- Test: `Tests/MacrecCoreTests/ParakeetTranscriptionProviderTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/ParakeetTranscriptionProviderTests.swift`:

```swift
import Testing
import Logging
@testable import MacrecCore

@Suite("ParakeetTranscriptionProvider basic surface (Phase B2)")
struct ParakeetTranscriptionProviderTests {

    @Test("id is 'parakeet'")
    func providerId() {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        #expect(p.id == "parakeet")
    }

    @Test("supportedModes is .batch only")
    func batchOnly() {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        #expect(p.supportedModes == [.batch])
    }

    @Test("openStreamingSession throws transcriptionConfigConflict")
    func streamingThrows() async {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        await #expect(throws: MacrecError.self) {
            _ = try await p.openStreamingSession(
                source: .system,
                options: TranscriptionOptions()
            )
        }
    }

    @Test("transcribe returns empty for sub-threshold sample count")
    func belowThreshold() async throws {
        let p = ParakeetTranscriptionProvider(logger: Logger(label: "t"))
        let result = try await p.transcribe(
            samples: [Float](repeating: 0, count: 100),
            source: .system,
            options: TranscriptionOptions()
        )
        #expect(result.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ParakeetTranscriptionProviderTests`
Expected: FAIL — `ParakeetTranscriptionProvider` does not exist.

- [ ] **Step 3: Create the provider skeleton**

Create `Sources/MacrecCore/Transcription/Providers/ParakeetTranscriptionProvider.swift`:

```swift
// MacrecCore/Transcription/Providers/ParakeetTranscriptionProvider.swift
//
// On-device transcription via FluidAudio's port of NVIDIA's
// `parakeet-tdt-0.6b-v3` multilingual ASR (~25 European languages
// incl. Greek, Turkish, Polish, …). Plan-012 Phase B.
//
// Architectural shape mirrors WhisperKitTranscriptionProvider:
//   * `actor` for naturally-deduplicated lazy load.
//   * Batch-only — streaming surface throws transcriptionConfigConflict.
//   * Lazy ~600 MB model download on first call (FluidAudio caches
//     under Application Support).

import Foundation
import Logging
import FluidAudio

public actor ParakeetTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id: String = "parakeet"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.batch]

    /// Default Parakeet model. Multilingual TDT-0.6B v3 — supports
    /// ~25 European languages including Greek.
    public nonisolated static let defaultModelName = "parakeet-tdt-0.6b-v3"

    public nonisolated var displayName: String {
        "Parakeet (\(modelName))"
    }

    private nonisolated let modelName: String
    private nonisolated let configuredLanguage: String?
    private let logger: Logger

    /// Loaded FluidAudio pipeline. nil until the first transcribe call.
    private var pipe: ParakeetPipeline?
    private var loadTask: Task<ParakeetPipeline, Error>?

    public init(
        modelName: String = ParakeetTranscriptionProvider.defaultModelName,
        language: String? = nil,
        logger: Logger = Logger(label: "macrec.transcription.parakeet")
    ) {
        self.modelName = modelName
        self.configuredLanguage = language
        self.logger = logger
    }

    public func transcribe(
        samples: [Float],
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> String {
        // Sub-threshold input is treated as silence per the protocol
        // contract ("Returns "" for non-speech input — does NOT throw").
        // Threshold mirrors WhisperKit's 6_400 (~400ms @ 16kHz).
        guard samples.count >= 6_400 else { return "" }

        let pipe: ParakeetPipeline
        do {
            pipe = try await ensureLoaded()
        } catch {
            throw MacrecError.transcriptionProviderUnavailable(
                reason: "Parakeet failed to load model '\(modelName)': \(error.localizedDescription)"
            )
        }

        do {
            let result = try await pipe.transcribe(
                audio: samples,
                language: resolvedLanguage(from: options)
            )
            logger.debug("Parakeet chunk: in=\(samples.count) outLen=\(result.text.count)")
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Parakeet transcribe failed: \(error.localizedDescription)")
            throw MacrecError.transcriptionProviderUnavailable(
                reason: "Parakeet transcribe error: \(error.localizedDescription)"
            )
        }
    }

    public nonisolated func openStreamingSession(
        source: SourceTag,
        options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        throw MacrecError.transcriptionConfigConflict(
            reason: "Parakeet provider is batch-only; streaming mode is not supported. Use 'apple' or 'soniox' for streaming."
        )
    }

    // MARK: - Internals

    private func ensureLoaded() async throws -> ParakeetPipeline {
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }

        let logger = self.logger
        let modelName = self.modelName
        logger.info("Parakeet loading model '\(modelName)' (first launch may download ~600MB; cached after)")
        let task = Task { () throws -> ParakeetPipeline in
            let started = Date()
            let p = try await ParakeetPipeline(model: modelName)
            let elapsed = Int(Date().timeIntervalSince(started))
            logger.info("Parakeet model '\(modelName)' loaded in \(elapsed)s")
            return p
        }
        loadTask = task
        do {
            let resolved = try await task.value
            pipe = resolved
            loadTask = nil
            return resolved
        } catch {
            loadTask = nil
            throw error
        }
    }

    private nonisolated func resolvedLanguage(from opts: TranscriptionOptions) -> String? {
        if let lang = configuredLanguage, !lang.isEmpty { return lang }
        if let primary = opts.languageHints.first,
           let part = primary.split(separator: "-").first,
           !part.isEmpty {
            return String(part).lowercased()
        }
        return nil
    }
}
```

> The exact FluidAudio API names (`ParakeetPipeline`, `transcribe(audio:language:)`) might differ. Check `swift package describe` and FluidAudio's README; if so, adjust the load + transcribe call sites only — the surrounding actor / error mapping remains the same. The agent should `cat .build/checkouts/FluidAudio/README.md` to verify.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ParakeetTranscriptionProviderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/Transcription/Providers/ParakeetTranscriptionProvider.swift \
        Tests/MacrecCoreTests/ParakeetTranscriptionProviderTests.swift
git commit -m "feat(parakeet): add on-device multilingual provider

Actor-isolated ParakeetTranscriptionProvider wraps FluidAudio's port
of NVIDIA parakeet-tdt-0.6b-v3 (multilingual, ~25 European languages
including Greek). Batch-only — openStreamingSession throws
transcriptionConfigConflict, mirroring WhisperKit's posture. Sub-
threshold samples (<6400) return empty string per the silence
contract. ~600MB lazy download on first transcribe call.

Spec: docs/design/refined-request-stt-enhancements.md §3.1."
```

---

## Task B3: factory + resolver + CLI wiring for `parakeet`

**Files:**
- Modify: `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`
- Modify: `Sources/MacrecCore/Config/ConfigResolver.swift`
- Modify: `Sources/MacrecCore/Config/RecordingOptions.swift`
- Modify: `Sources/macrec/Commands/StartCommand.swift`
- Test: `Tests/MacrecCoreTests/ParakeetFactoryAndResolverTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/ParakeetFactoryAndResolverTests.swift`:

```swift
import Testing
import Logging
@testable import MacrecCore

@Suite("Parakeet factory + resolver wiring (Phase B3)")
struct ParakeetFactoryAndResolverTests {

    @Test("factory returns ParakeetTranscriptionProvider for id 'parakeet'")
    func factoryBuildsParakeet() throws {
        let input = TranscriptionProviderFactoryInput(
            providerId: "parakeet",
            apiKey: nil,
            modelId: nil,
            logger: Logger(label: "t"),
            keyExpiresAt: nil
        )
        let p = try TranscriptionProviderFactory.build(input)
        #expect(p.id == "parakeet")
    }

    @Test("resolver accepts MACREC_TRANSCRIBE=parakeet without API key")
    func resolverNoKeyRequired() throws {
        let env: [String: String] = ["MACREC_TRANSCRIBE": "parakeet"]
        let opts = try ConfigResolver.resolveForTesting(env: env, cliOverrides: [:])
        #expect(opts.transcriptionProviderId == "parakeet")
    }

    @Test("MACREC_PARAKEET_MODEL overrides the default")
    func parakeetModelOverride() throws {
        let env: [String: String] = [
            "MACREC_TRANSCRIBE": "parakeet",
            "MACREC_PARAKEET_MODEL": "parakeet-tdt-1.1b-v3"
        ]
        let opts = try ConfigResolver.resolveForTesting(env: env, cliOverrides: [:])
        #expect(opts.parakeetModel == "parakeet-tdt-1.1b-v3")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ParakeetFactoryAndResolverTests`
Expected: FAIL — factory has no `parakeet` arm; resolver has no `parakeetModel` field.

- [ ] **Step 3: Add the factory arm**

In `Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift`:

1. Add new fields to `TranscriptionProviderFactoryInput` (after the WhisperKit fields):
   ```swift
   // -- Parakeet (on-device, multilingual) fields (plan-012 Phase B) --
   public let parakeetModel: String?
   public let parakeetLanguage: String?
   ```
   Add them to the init parameter list (defaulting to `nil`) and assign them in the body.
2. Add the dispatch arm next to `case "whisperkit":`:
   ```swift
   case "parakeet":
       // plan-012 Phase B — On-device multilingual via FluidAudio's
       // Parakeet TDT V3. No API key. Same model-resolution
       // precedence as WhisperKit:
       //   1. parakeetModel (MACREC_PARAKEET_MODEL)
       //   2. modelId (MACREC_TRANSCRIBE_MODEL)
       //   3. provider default
       let model = input.parakeetModel
           ?? input.modelId
           ?? ParakeetTranscriptionProvider.defaultModelName
       return ParakeetTranscriptionProvider(
           modelName: model,
           language: input.parakeetLanguage,
           logger: input.logger
       )
   ```
3. In the default-arm error, add `'parakeet'` to the allowed-providers list:
   ```swift
   throw MacrecError.transcriptionConfigConflict(reason: "transcribe value '\(normalized)' invalid (allowed: 'none', 'apple', 'apple-cloud', 'gemini', 'whisperkit', 'parakeet', 'soniox', 'azure', 'azure-openai-realtime', 'elevenlabs')")
   ```

- [ ] **Step 4: Add the resolver fields**

In `Sources/MacrecCore/Config/RecordingOptions.swift` add:

```swift
public var parakeetModel: String?
public var parakeetLanguage: String?
```

In `Sources/MacrecCore/Config/ConfigResolver.swift`:

1. Add key constants near the WhisperKit ones:
   ```swift
   public static let parakeetModel    = "MACREC_PARAKEET_MODEL"
   public static let parakeetLanguage = "MACREC_PARAKEET_LANGUAGE"
   ```
2. After the WhisperKit block (search for `let whisperKitModelRaw`), add:
   ```swift
   let parakeetModelRaw = value(Keys.parakeetModel)
   let parakeetModel: String? =
       (parakeetModelRaw?.isEmpty == false) ? parakeetModelRaw : nil

   let parakeetLanguageRaw = value(Keys.parakeetLanguage)
   let parakeetLanguage: String? = {
       guard let raw = parakeetLanguageRaw?.trimmingCharacters(in: .whitespaces),
             !raw.isEmpty else { return nil }
       return raw
   }()
   ```
3. Pass them through to `RecordingOptions(...)` (next to `whisperKitModel: whisperKitModel`).
4. Where `RecordingOptions` is consumed by `RecordingSession` to build the `TranscriptionProviderFactoryInput`, thread `parakeetModel: options.parakeetModel, parakeetLanguage: options.parakeetLanguage`.
5. Add `"parakeet"` to the allowed-provider validation list in the resolver (search for `allowed: ['none', 'apple', ...]` or the equivalent guard).

- [ ] **Step 5: Add the CLI flags in `StartCommand`**

In `Sources/macrec/Commands/StartCommand.swift`, after the WhisperKit flag declarations:

```swift
@Option(name: .long, help: "Parakeet-specific model id (defaults to parakeet-tdt-0.6b-v3). Env: MACREC_PARAKEET_MODEL.")
public var parakeetModel: String?

@Option(name: .long, help: "Parakeet language hint (bare ISO-639-1, e.g. 'el'). Default: auto-detect. Env: MACREC_PARAKEET_LANGUAGE.")
public var parakeetLanguage: String?
```

Update the help text on `--transcribe` to include `parakeet`:

```swift
@Option(name: .long, help: "Live transcription provider (none | apple | apple-cloud | gemini | whisperkit | parakeet | soniox | azure | azure-openai-realtime | elevenlabs | dual). Default: apple ...")
```

In the CLI-overrides block:

```swift
if let v = parakeetModel    { o[ConfigResolver.Keys.parakeetModel] = v }
if let v = parakeetLanguage { o[ConfigResolver.Keys.parakeetLanguage] = v }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter ParakeetFactoryAndResolverTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Sanity-check the CLI**

Run: `swift run macrec start --help | grep -E '(parakeet-model|parakeet-language|--transcribe )'`
Expected: all three flags appear; `--transcribe` help text lists `parakeet`.

- [ ] **Step 8: Commit**

```bash
git add Sources/MacrecCore/Transcription/Providers/TranscriptionProviderFactory.swift \
        Sources/MacrecCore/Config/ConfigResolver.swift \
        Sources/MacrecCore/Config/RecordingOptions.swift \
        Sources/MacrecCore/RecordingSession.swift \
        Sources/macrec/Commands/StartCommand.swift \
        Tests/MacrecCoreTests/ParakeetFactoryAndResolverTests.swift
git commit -m "feat(parakeet): factory dispatch + resolver + CLI flags

Factory arm 'parakeet' returns ParakeetTranscriptionProvider with the
WhisperKit-style model precedence chain (--parakeet-model wins over
--transcribe-model wins over provider default). Resolver admits
'parakeet' to the providers allow-list and parses MACREC_PARAKEET_*
env vars through the four-tier chain.

Spec: docs/design/refined-request-stt-enhancements.md §3.3, §3.4."
```

---

## Task B4: surface `parakeet` in the UI picker + Parakeet settings section

**Files:**
- Modify: `Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift`
- Create: `Sources/macrec-ui/Settings/Sections/ParakeetSettingsView.swift`
- Modify: `Sources/macrec-ui/Settings/SettingsRootView.swift`

- [ ] **Step 1: Add the picker option**

In `TranscriptionPicker.swift`, add a new `Text(...).tag(...)` next to the existing WhisperKit option (after `whisperkit`):

```swift
Text("Parakeet (on-device, multilingual)").tag("parakeet")
```

`requiredKeyEnvVar(for:)` already returns `nil` in its `default:` arm, so no change needed there — but verify by reading the function body. If WhisperKit is explicitly listed there, do nothing; if it's caught by the default, also nothing.

- [ ] **Step 2: Create `ParakeetSettingsView`**

Create `Sources/macrec-ui/Settings/Sections/ParakeetSettingsView.swift`:

```swift
import MacrecCore
import MacrecUIKit
import SwiftUI

/// Settings panel for the Parakeet provider. Plan-012 Phase B4.
struct ParakeetSettingsView: View {

    @AppStorage("com.macrec.ui.parakeetModel")
    private var modelName: String = ParakeetTranscriptionProvider.defaultModelName

    @AppStorage("com.macrec.ui.parakeetLanguage")
    private var languageHint: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Model id", text: $modelName)
                    .textFieldStyle(.roundedBorder)
                    .help("FluidAudio model identifier. Default: parakeet-tdt-0.6b-v3 (multilingual, ~25 European languages).")
                TextField("Language hint", text: $languageHint, prompt: Text("auto-detect"))
                    .textFieldStyle(.roundedBorder)
                    .help("Bare ISO-639-1 code (e.g. 'el' for Greek). Leave empty for auto-detect.")
            } header: {
                Text("Parakeet")
            } footer: {
                Text("On-device. No API key. First launch downloads ~600MB to Application Support; subsequent launches reuse the cached model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 3: Register the section in `SettingsRootView`**

Add a new tab case:

```swift
case parakeet
```

Add a sidebar entry:

```swift
Label("Parakeet", systemImage: "bird")
    .tag(SettingsTab.parakeet)
```

Add the dispatch arm:

```swift
case .parakeet:
    ParakeetSettingsView()
```

- [ ] **Step 4: Build the UI to confirm it links**

Run: `swift build --product macrec-ui`
Expected: clean build.

- [ ] **Step 5: Manual smoke test**

Run: `bash scripts/package-macrec-ui-app.sh && open dist/macrec-ui.app`
In the popover: open the provider dropdown, confirm `Parakeet (on-device, multilingual)` appears; open Settings, confirm a new `Parakeet` tab appears with the model + language fields.

- [ ] **Step 6: Commit**

```bash
git add Sources/macrec-ui/Views/Transcription/TranscriptionPicker.swift \
        Sources/macrec-ui/Settings/Sections/ParakeetSettingsView.swift \
        Sources/macrec-ui/Settings/SettingsRootView.swift
git commit -m "feat(macrec-ui): add Parakeet to the provider picker + settings tab

TranscriptionPicker gains a 'Parakeet (on-device, multilingual)' entry.
A new Settings → Parakeet tab exposes the model id and language hint
(persisted to com.macrec.ui.parakeet{Model,Language}). No API-key
affordance — Parakeet is on-device.

Spec: docs/design/refined-request-stt-enhancements.md §3.3."
```

---

## Task B5: documentation updates for Phase B

**Files:**
- Modify: `docs/tools/macrec.md`
- Modify: `docs/design/configuration-guide.md`
- Modify: `docs/design/project-functions.md`
- Modify: `CLAUDE.md` (project Tools section)

- [ ] **Step 1: Update the Supported providers table in `docs/tools/macrec.md`**

Add a row for `parakeet` immediately after `whisperkit`:

```markdown
| `parakeet`     | **On-device multilingual** via FluidAudio's port of NVIDIA parakeet-tdt-0.6b-v3 (~25 European languages incl. Greek). No API key. Batch architecture (chunk-at-a-time). ~600MB lazy model download on first launch. | _(none)_ |
```

Also add `parakeet` to the allowed-list in the `--transcribe` help block at line 113-114 of macrec.md (rendered help text).

- [ ] **Step 2: Add a Parakeet subsection in `docs/tools/macrec.md`**

After the WhisperKit / Soniox subsections, add:

```markdown
### Parakeet (on-device, multilingual, plan-012)

Parakeet is the third on-device transcription option, alongside
Apple Speech and WhisperKit. Backed by FluidAudio's CoreML port of
NVIDIA's `parakeet-tdt-0.6b-v3` model.

**Why use it over WhisperKit:** Parakeet TDT V3 is ~3x faster than
Whisper large-v3 on Apple Silicon for the same audio at comparable
WER on European languages. Especially strong on Greek, Polish,
Turkish, and other locales where Apple-shipped on-device assets
are unavailable.

**Defaults:**

| Setting          | Default                                                  |
|------------------|----------------------------------------------------------|
| Model            | `parakeet-tdt-0.6b-v3` (overridable via `--parakeet-model` / `MACREC_PARAKEET_MODEL`) |
| Language hint    | _(auto-detect — overridable via `--parakeet-language` / `MACREC_PARAKEET_LANGUAGE`)_ |
| Streaming        | NOT supported (batch-only, like WhisperKit)              |
| API key          | Not required                                              |
| First-launch DL  | ~600MB to Application Support (cached after)              |

**Examples:**

```sh
# Parakeet with default model + Greek language hint.
macrec start --transcribe parakeet --parakeet-language el \
    --output ~/recordings/greek-meeting.m4a

# Override model id (advanced users).
macrec start --transcribe parakeet \
    --parakeet-model parakeet-tdt-1.1b-v3 \
    --output ~/recordings/heavy.m4a
```

**Model resolution precedence:**

1. `--parakeet-model` / `MACREC_PARAKEET_MODEL` (Parakeet-specific).
2. `--transcribe-model` / `MACREC_TRANSCRIBE_MODEL` (shared).
3. Provider default (`parakeet-tdt-0.6b-v3`).
```

- [ ] **Step 3: Add config entries**

In `docs/design/configuration-guide.md`, add entries for `MACREC_PARAKEET_MODEL` and `MACREC_PARAKEET_LANGUAGE` mirroring the WhisperKit entries.

- [ ] **Step 4: Register FRs in `project-functions.md`**

```markdown
**FR-PK-1** — `macrec` supports a Parakeet TDT V3 multilingual
on-device transcription provider (`parakeet`). No API key. Batch-
only. Plan-012 Phase B.
**FR-PK-2** — Parakeet model id is configurable via
`MACREC_PARAKEET_MODEL` / `--parakeet-model` with the standard
WhisperKit-style model resolution precedence.
```

- [ ] **Step 5: Update `CLAUDE.md` Tools section**

In the `### macrec` entry, in the providers list line, add Parakeet between WhisperKit and Soniox so the macrec description in the project Tools section stays current.

- [ ] **Step 6: Commit**

```bash
git add docs/tools/macrec.md \
        docs/design/configuration-guide.md \
        docs/design/project-functions.md \
        CLAUDE.md
git commit -m "docs: Parakeet TDT V3 on-device provider (plan-012 Phase B)

Adds a row in the supported-providers table, a dedicated
'Parakeet (on-device, multilingual)' subsection, configuration-guide
entries for MACREC_PARAKEET_{MODEL,LANGUAGE}, and FR-PK-1/2 in
project-functions. Updates the Tools section reference in CLAUDE.md.

Spec: docs/design/refined-request-stt-enhancements.md §3.5."
```

---

# Phase C — Source-separated transcription

> Spec §5. Largest blast radius — touches dispatcher, sidecar writer, live UI panel. Ship after Phases A and B.

## Task C1: `SourceSplitTranscriptionManager` skeleton

**Files:**
- Create: `Sources/MacrecCore/Transcription/SourceSplitTranscriptionManager.swift`
- Test: `Tests/MacrecCoreTests/SourceSplitTranscriptionManagerTests.swift` (create)

> **Architectural decision:** rather than modify `TranscriptionManager` to handle two sources, we compose two existing instances — one per `SourceTag` — behind the existing `TranscriptionDispatcher` protocol. This keeps the existing single-source code path unchanged (DT-INV-style guarantee for non-`both` modes) and makes the dual-source mode strictly additive.

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SourceSplitTranscriptionManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("SourceSplitTranscriptionManager basic surface (Phase C1)")
struct SourceSplitTranscriptionManagerTests {

    @Test("conforms to TranscriptionDispatcher")
    func conformsToProtocol() {
        let mgr = SourceSplitTranscriptionManager.makeForTesting()
        #expect(mgr is any TranscriptionDispatcher)
    }

    @Test("ingest routes by SourceTag — system goes to system manager")
    func ingestRoutesSystem() async {
        let mgr = SourceSplitTranscriptionManager.makeForTesting()
        await mgr.ingest([1.0, 2.0], from: .system)
        let counts = await mgr.testInternalIngestCounts()
        #expect(counts.system == 1)
        #expect(counts.microphone == 0)
    }

    @Test("ingest routes by SourceTag — microphone goes to microphone manager")
    func ingestRoutesMicrophone() async {
        let mgr = SourceSplitTranscriptionManager.makeForTesting()
        await mgr.ingest([1.0], from: .microphone)
        let counts = await mgr.testInternalIngestCounts()
        #expect(counts.system == 0)
        #expect(counts.microphone == 1)
    }
}

// SourceTag is a typealias for CaptureSourceTag (Sources/MacrecCore/Capture/CaptureBuffer.swift)
// and only has two cases: .system and .microphone. There is no .mic, .mixed,
// or .both at the SourceTag level — those literals belong to TranscriptionSource
// (the user-facing CLI flag enum). The dispatcher routes purely on SourceTag,
// so the implementation has only two arms (no defensive .mixed/.both case).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SourceSplitTranscriptionManagerTests`
Expected: FAIL — type does not exist.

- [ ] **Step 3: Create the manager skeleton**

Create `Sources/MacrecCore/Transcription/SourceSplitTranscriptionManager.swift`:

```swift
// MacrecCore/Transcription/SourceSplitTranscriptionManager.swift
//
// Plan-012 Phase C — true `--transcribe-source both` support. Lifts
// the v1 limitation documented in docs/tools/macrec.md by composing
// two single-source `TranscriptionManager` instances (one per
// SourceTag) behind the existing TranscriptionDispatcher façade.
//
// Why composition (not modify TranscriptionManager): keeps the
// existing single-source code path byte-equivalent for non-`both`
// modes and makes dual-source strictly additive. Each inner
// manager owns its own provider instance, sidecar writer, and
// metrics struct.

import Foundation
import Logging

public actor SourceSplitTranscriptionManager: TranscriptionDispatcher {

    private let systemManager: TranscriptionManager
    private let microphoneManager: TranscriptionManager
    private let logger: Logger

    /// Test-only struct exposing the per-source ingest call counts.
    /// `microphone` matches the SourceTag case name (NOT `mic`).
    public struct IngestCounts: Sendable, Equatable {
        public let system: Int
        public let microphone: Int
    }
    private var systemIngestCount = 0
    private var microphoneIngestCount = 0

    public init(
        systemManager: TranscriptionManager,
        microphoneManager: TranscriptionManager,
        logger: Logger = Logger(label: "macrec.transcription.source-split")
    ) {
        self.systemManager = systemManager
        self.microphoneManager = microphoneManager
        self.logger = logger
    }

    /// Convenience constructor for unit tests. Production code uses
    /// the explicit `init(systemManager:microphoneManager:)` and supplies
    /// real managers from the RecordingSession factory.
    public static func makeForTesting() -> SourceSplitTranscriptionManager {
        let sys = TranscriptionManager.fakeForTesting(source: .system)
        let mic = TranscriptionManager.fakeForTesting(source: .microphone)
        return SourceSplitTranscriptionManager(systemManager: sys, microphoneManager: mic)
    }

    // MARK: - TranscriptionDispatcher

    public func start() async throws -> AsyncStream<TranscriptionEvent> {
        // Merge two child streams into one. Concrete merge implementation
        // lives in Task C2 (event merge); for now this returns a passthrough
        // stream from the system manager so the surface compiles.
        let s = try await systemManager.start()
        _ = try await microphoneManager.start()
        return s
    }

    public func ingest(_ samples: [Float], from tag: SourceTag) async {
        switch tag {
        case .system:
            systemIngestCount += 1
            await systemManager.ingest(samples, from: .system)
        case .microphone:
            microphoneIngestCount += 1
            await microphoneManager.ingest(samples, from: .microphone)
        }
    }

    public func ingestFrame(_ frame: AlignedFrame, from tag: SourceTag) async {
        switch tag {
        case .system:
            systemIngestCount += 1
            await systemManager.ingestFrame(frame, from: .system)
        case .microphone:
            microphoneIngestCount += 1
            await microphoneManager.ingestFrame(frame, from: .microphone)
        }
    }

    public func stop() async {
        await systemManager.stop()
        await microphoneManager.stop()
    }

    public func rotateSidecar(toAudioURL: URL, format: TranscriptFormat) async throws {
        try await systemManager.rotateSidecar(toAudioURL: toAudioURL, format: format)
        try await microphoneManager.rotateSidecar(toAudioURL: toAudioURL, format: format)
    }

    public func currentMetrics() async -> TranscriptionMetrics {
        let s = await systemManager.currentMetrics()
        let m = await microphoneManager.currentMetrics()
        return TranscriptionMetrics.merge([s, m])
    }

    // MARK: - Test-only

    public func testInternalIngestCounts() -> IngestCounts {
        IngestCounts(system: systemIngestCount, microphone: microphoneIngestCount)
    }
}
```

> Two helpers referenced here may not exist yet:
>   * `TranscriptionManager.fakeForTesting(source:)` — add a thin static helper in TranscriptionManager.swift that returns a manager wired with a `NoOpTranscriptionProvider` and writes to a temp directory.
>   * `TranscriptionMetrics.merge([...])` — if not present, add a static helper that field-wise sums (`chunksSent`, `billableSeconds`, `errorCount`) and `max`-merges `lastRTT`. The dual-mode pipeline already has a similar merge — reuse if so.

Add either helper if missing.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SourceSplitTranscriptionManagerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/Transcription/SourceSplitTranscriptionManager.swift \
        Sources/MacrecCore/Transcription/TranscriptionManager.swift \
        Tests/MacrecCoreTests/SourceSplitTranscriptionManagerTests.swift
git commit -m "feat(transcription): add SourceSplitTranscriptionManager skeleton

Composes two TranscriptionManager instances (one per SourceTag)
behind the existing TranscriptionDispatcher protocol. Routes
.system / .microphone ingests to the matching child manager
(SourceTag has only those two cases). Merge of TranscriptionEvent
streams is the next task.

Spec: docs/design/refined-request-stt-enhancements.md §5.1."
```

---

## Task C2: merge child event streams into one

**Files:**
- Modify: `Sources/MacrecCore/Transcription/SourceSplitTranscriptionManager.swift`
- Test: `Tests/MacrecCoreTests/SourceSplitEventMergeTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecCoreTests/SourceSplitEventMergeTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("SourceSplitTranscriptionManager event merge (Phase C2)")
struct SourceSplitEventMergeTests {

    @Test("events from both child streams interleave on the merged stream")
    func bothStreamsObserved() async throws {
        let mgr = SourceSplitTranscriptionManager.makeForTesting()
        let stream = try await mgr.start()

        // Inject a fake event into each child manager.
        await mgr.testInjectFakeEvent(.segmentUpdated(/* see fixture below */),
                                       to: .system)
        await mgr.testInjectFakeEvent(.segmentUpdated(/* see fixture below */),
                                       to: .microphone)

        var collected: [SourceTag] = []
        for await event in stream.prefix(2) {
            if case .segmentUpdated(let s) = event {
                collected.append(s.source)
            }
        }
        #expect(collected.contains(.system))
        #expect(collected.contains(.microphone))
    }
}
```

> The fixture / `testInjectFakeEvent(_:to:)` helper is added in Step 3 below alongside the merge implementation.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SourceSplitEventMergeTests`
Expected: FAIL — `start()` currently returns only the system stream.

- [ ] **Step 3: Implement the merge**

In `SourceSplitTranscriptionManager.swift`, replace the body of `start()`:

```swift
public func start() async throws -> AsyncStream<TranscriptionEvent> {
    let systemStream = try await systemManager.start()
    let microphoneStream = try await microphoneManager.start()

    // Merge two AsyncStreams into one by spawning two tasks that
    // forward into a single continuation. When BOTH child streams
    // finish, the continuation finishes.
    return AsyncStream<TranscriptionEvent> { continuation in
        let counter = MergeFinishCounter()  // local helper class below

        Task {
            for await event in systemStream {
                continuation.yield(event)
            }
            if await counter.finished() { continuation.finish() }
        }
        Task {
            for await event in microphoneStream {
                continuation.yield(event)
            }
            if await counter.finished() { continuation.finish() }
        }
    }
}
```

Add the helper at file scope:

```swift
/// Tracks "both children have finished" state for the merge in
/// SourceSplitTranscriptionManager.start(). Actor-isolated so the
/// two forwarding tasks don't race on the boolean flip.
private actor MergeFinishCounter {
    private var done = 0
    func finished() -> Bool {
        done += 1
        return done >= 2
    }
}
```

Add the test injection helper:

```swift
public func testInjectFakeEvent(_ event: TranscriptionEvent, to tag: SourceTag) async {
    switch tag {
    case .system:     await systemManager.testInjectEvent(event)
    case .microphone: await microphoneManager.testInjectEvent(event)
    }
}
```

If `TranscriptionManager.testInjectEvent(_:)` doesn't exist, add a thin actor-isolated helper that yields the event into the manager's continuation (only compiled in tests).

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SourceSplitEventMergeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacrecCore/Transcription/SourceSplitTranscriptionManager.swift \
        Sources/MacrecCore/Transcription/TranscriptionManager.swift \
        Tests/MacrecCoreTests/SourceSplitEventMergeTests.swift
git commit -m "feat(transcription): merge child event streams in source-split manager

start() now returns a merged AsyncStream that yields events from
both the system and microphone child managers. A small actor-isolated
finish counter ensures the merged stream finishes only after BOTH
children finish.

Spec: docs/design/refined-request-stt-enhancements.md §5.1."
```

---

## Task C3: per-source sidecar naming

**Files:**
- Locate the current sidecar-naming helper (search for `transcript.<ext>` in `Sources/MacrecCore/Transcription/Persistence/`); modify it.
- Test: `Tests/MacrecCoreTests/SourceSplitSidecarNamingTests.swift` (create)

- [ ] **Step 1: Find the naming helper**

Run: `grep -rn 'transcript' Sources/MacrecCore/Transcription/Persistence/ | grep -i 'url\|path\|file' | head`
Locate the function that derives the sidecar URL from `audioURL`, `format`, and `source`.

- [ ] **Step 2: Write the failing test**

Create `Tests/MacrecCoreTests/SourceSplitSidecarNamingTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("Sidecar naming for source-split mode (Phase C3)")
struct SourceSplitSidecarNamingTests {

    @Test("system source produces .system.transcript.<ext>")
    func systemSidecar() {
        let url = URL(fileURLWithPath: "/tmp/recording.m4a")
        let result = SidecarNaming.url(forAudio: url, source: .system, format: .jsonl)
        #expect(result.lastPathComponent == "recording.system.transcript.jsonl")
    }

    @Test("microphone source produces .mic.transcript.<ext>")
    func microphoneSidecar() {
        let url = URL(fileURLWithPath: "/tmp/recording.m4a")
        let result = SidecarNaming.url(forAudio: url, source: .microphone, format: .jsonl)
        #expect(result.lastPathComponent == "recording.mic.transcript.jsonl")
    }

    @Test("nil source preserves the legacy single-sidecar name")
    func legacyName() {
        let url = URL(fileURLWithPath: "/tmp/recording.m4a")
        let result = SidecarNaming.url(forAudio: url, source: nil, format: .jsonl)
        #expect(result.lastPathComponent == "recording.transcript.jsonl")
    }

    @Test("preserves split-layout audio extension naming")
    func splitLayoutCoexistence() {
        let micAudio = URL(fileURLWithPath: "/tmp/recording.mic.m4a")
        let result = SidecarNaming.url(forAudio: micAudio, source: .microphone, format: .jsonl)
        #expect(result.lastPathComponent == "recording.mic.transcript.jsonl")
    }
}

// SidecarNaming.url takes an OPTIONAL source. nil → legacy
// `.transcript.<ext>` filename (single-source path, byte-equiv with
// today). .system → `.system.transcript.<ext>`; .microphone →
// `.mic.transcript.<ext>` (the user-facing infix is "mic" — short
// and matches the existing audio-file naming convention from the
// `--layout split` mode — but the SourceTag case name remains
// `.microphone`).
```

- [ ] **Step 2.5: Run the test to verify it fails**

Run: `swift test --filter SourceSplitSidecarNamingTests`
Expected: FAIL — naming helper does not yet differentiate by source for `.system` / `.mic`, OR `SidecarNaming` doesn't exist as a public surface.

- [ ] **Step 3: Implement the naming logic**

If a `SidecarNaming` type exists but takes only `(audioURL, format)`, extend it. Otherwise create `Sources/MacrecCore/Transcription/Persistence/SidecarNaming.swift`:

```swift
import Foundation

public enum SidecarNaming {

    /// Derive the sidecar URL for a given audio file, source tag,
    /// and transcript format. Preserves the existing single-source
    /// `.transcript.<ext>` convention for `.mixed` (DT-INV-style
    /// byte-equivalence) and adds `.system.transcript.<ext>` /
    /// `.mic.transcript.<ext>` for the new source-split mode
    /// (plan-012 Phase C3).
    public static func url(
        forAudio audioURL: URL,
        source: SourceTag?,
        format: TranscriptFormat
    ) -> URL {
        let dir = audioURL.deletingLastPathComponent()
        let name = audioURL.deletingPathExtension().lastPathComponent
        let infix: String
        switch source {
        case .system:     infix = "system.transcript"
        case .microphone: infix = "mic.transcript"
        case nil:         infix = "transcript"
        }
        let filename = "\(name).\(infix).\(format.rawValue)"
        return dir.appendingPathComponent(filename)
    }
}
```

If a sibling helper already exists, replace its body with the above logic (back-compat with `.mixed`).

Migrate any existing callers to the new signature: search `grep -rn 'sidecarURL\|transcriptURL' Sources/MacrecCore/`. Update each call site.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SourceSplitSidecarNamingTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the broader sidecar / persistence tests**

Run: `swift test --filter Sidecar; swift test --filter Persistence`
Expected: clean — `.mixed` callers see byte-equivalent output.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacrecCore/Transcription/Persistence/ \
        Tests/MacrecCoreTests/SourceSplitSidecarNamingTests.swift
git commit -m "feat(transcription): per-source sidecar naming for split mode

SidecarNaming.url(forAudio:source:format:) returns
'<basename>.system.transcript.<ext>' for .system, '.mic.transcript'
for .mic, and the legacy '.transcript.<ext>' for .mixed/.both —
preserving byte-equivalence for the single-source path.

Spec: docs/design/refined-request-stt-enhancements.md §5.3."
```

---

## Task C4: `RecordingSession` dispatcher selection

**Files:**
- Modify: `Sources/MacrecCore/RecordingSession.swift`
- Test: `Tests/MacrecCoreTests/RecordingSessionDispatcherSelectionTests.swift` (create)

- [ ] **Step 1: Locate the dispatcher-construction site**

Run: `grep -n 'TranscriptionDispatcher\|TranscriptionManager(' Sources/MacrecCore/RecordingSession.swift`
Note the function that builds the `(any TranscriptionDispatcher)?`.

- [ ] **Step 2: Write the failing test**

Create `Tests/MacrecCoreTests/RecordingSessionDispatcherSelectionTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecCore

@Suite("RecordingSession transcription dispatcher selection (Phase C4)")
struct RecordingSessionDispatcherSelectionTests {

    @Test("source=.both with single mode yields a SourceSplitTranscriptionManager")
    func bothPicksSplit() throws {
        var opts = RecordingOptions.minimalForTesting()
        opts.transcriptionProviderId = "apple"
        opts.transcribeSource = .both
        let dispatcher = try TranscriptionDispatcherSelector.select(for: opts)
        #expect(dispatcher is SourceSplitTranscriptionManager)
    }

    @Test("source=.mixed yields a single TranscriptionManager")
    func mixedPicksSingle() throws {
        var opts = RecordingOptions.minimalForTesting()
        opts.transcriptionProviderId = "apple"
        opts.transcribeSource = .mixed
        let dispatcher = try TranscriptionDispatcherSelector.select(for: opts)
        #expect(dispatcher is TranscriptionManager)
    }

    @Test("dual mode preserves DualTranscriptionManager wiring (unchanged)")
    func dualUnchanged() throws {
        var opts = RecordingOptions.minimalForTesting()
        opts.transcriptionMode = .dual
        opts.dualLocaleA = "en-US"
        opts.dualLocaleB = "el-GR"
        opts.dualSource = .mixed
        opts.dualFormat = .jsonl
        let dispatcher = try TranscriptionDispatcherSelector.select(for: opts)
        #expect(dispatcher is DualTranscriptionManager)
    }
}
```

> The factory `TranscriptionDispatcherSelector.select(for:)` may not yet exist. If `RecordingSession` builds the dispatcher inline, extract that logic into a new `Sources/MacrecCore/Transcription/TranscriptionDispatcherSelector.swift` so it's testable in isolation. The `RecordingSession` then just calls the selector.

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter RecordingSessionDispatcherSelectionTests`
Expected: FAIL — `TranscriptionDispatcherSelector` does not exist; `.both` either errors out or returns a single TranscriptionManager.

- [ ] **Step 4: Extract / write the selector**

Create `Sources/MacrecCore/Transcription/TranscriptionDispatcherSelector.swift`:

```swift
import Foundation
import Logging

public enum TranscriptionDispatcherSelector {

    /// Returns the dispatcher to use for the given RecordingOptions.
    /// Logic:
    ///   * dual mode → DualTranscriptionManager (unchanged).
    ///   * single mode + source == .both → SourceSplitTranscriptionManager
    ///     (plan-012 Phase C).
    ///   * single mode + source != .both → TranscriptionManager (unchanged).
    public static func select(for opts: RecordingOptions) throws -> any TranscriptionDispatcher {
        if opts.transcriptionMode == .dual {
            return try DualTranscriptionManager.makeFromOptions(opts)
        }
        if opts.transcribeSource == .both {
            // ElevenLabs tier warning per spec §5.2 / AC-SS-7.
            if opts.transcriptionProviderId == "elevenlabs" {
                Logger(label: "macrec.transcription.dispatcher").warning(
                    "ElevenLabs Free/Starter tiers cap concurrent STT requests at 8; --transcribe-source both will run two parallel POSTs and may surface concurrent_limit_exceeded (HTTP 429)."
                )
            }
            let sys = try TranscriptionManager.makeFromOptions(opts, source: .system)
            let mic = try TranscriptionManager.makeFromOptions(opts, source: .microphone)
            return SourceSplitTranscriptionManager(systemManager: sys, microphoneManager: mic)
        }
        return try TranscriptionManager.makeFromOptions(opts)
    }
}
```

> If the existing `RecordingSession` builds the dispatcher inline, extract its body into `TranscriptionManager.makeFromOptions(_ opts:source:)` and `DualTranscriptionManager.makeFromOptions(_:)` first so the selector can call them. Keep behaviour byte-equivalent for the single-mode and dual-mode paths.

Then update `RecordingSession.swift` to call the selector instead of constructing inline:

```swift
// before:
//   let mgr = try TranscriptionManager(options: opts, ...)
// after:
let dispatcher = try TranscriptionDispatcherSelector.select(for: opts)
self.dispatcher = dispatcher
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter RecordingSessionDispatcherSelectionTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the full transcription test suite**

Run: `swift test --filter Transcription; swift test --filter Recording`
Expected: clean — single-mode and dual-mode paths preserved.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacrecCore/Transcription/TranscriptionDispatcherSelector.swift \
        Sources/MacrecCore/Transcription/TranscriptionManager.swift \
        Sources/MacrecCore/Transcription/Dual/DualTranscriptionManager.swift \
        Sources/MacrecCore/RecordingSession.swift \
        Tests/MacrecCoreTests/RecordingSessionDispatcherSelectionTests.swift
git commit -m "feat(transcription): dispatcher selector for source-split mode

Extracts the single-/dual-/split-mode dispatcher choice into
TranscriptionDispatcherSelector. Single-mode + source==.both now
returns a SourceSplitTranscriptionManager wired with two
TranscriptionManager children (one per SourceTag). Single-mode
and dual-mode paths preserved byte-equivalent. Logs a one-line
warning when provider == elevenlabs && source == .both.

Spec: docs/design/refined-request-stt-enhancements.md §5.1, §5.2."
```

---

## Task C5: extract `SourceLane` from `LiveTranscriptPanel.singleBody`

**Files:**
- Create: `Sources/macrec-ui/Views/Transcription/SourceLane.swift`
- Modify: `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`
- Test: `Tests/MacrecUITests/SourceLaneFilteringTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecUITests/SourceLaneFilteringTests.swift`:

```swift
import Testing
import Foundation
@testable import MacrecUIKit
@testable import MacrecCore

@Suite("SourceLane filtering logic (Phase C5)")
struct SourceLaneFilteringTests {

    @Test("filters segments by source")
    func filtersBySource() {
        let segments: [TranscriptSegment] = [
            TranscriptSegment(timestamp: Date(), text: "sys", source: .system),
            TranscriptSegment(timestamp: Date(), text: "mic", source: .microphone),
        ]
        let onlySystem = SourceLaneFilter.segments(segments, for: .system)
        #expect(onlySystem.count == 1)
        #expect(onlySystem.first?.text == "sys")

        let onlyMic = SourceLaneFilter.segments(segments, for: .microphone)
        #expect(onlyMic.count == 1)
        #expect(onlyMic.first?.text == "mic")
    }

    @Test("empty list filters to empty")
    func emptyList() {
        let segments: [TranscriptSegment] = []
        #expect(SourceLaneFilter.segments(segments, for: .system).isEmpty)
        #expect(SourceLaneFilter.segments(segments, for: .microphone).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SourceLaneFilteringTests`
Expected: FAIL — `SourceLaneFilter` does not exist.

- [ ] **Step 3: Add the filter helper**

Create `Sources/MacrecUIKit/SourceLaneFilter.swift`:

```swift
import Foundation
import MacrecCore

/// Pure filtering helper for the source-split live transcript panel.
/// Lives in MacrecUIKit so it's unit-testable without spinning up
/// SwiftUI. Plan-012 Phase C5.
public enum SourceLaneFilter {
    public static func segments(
        _ segments: [TranscriptSegment],
        for source: SourceTag
    ) -> [TranscriptSegment] {
        segments.filter { $0.source == source }
    }
}
```

- [ ] **Step 4: Extract `SourceLane` from `LiveTranscriptPanel.singleBody`**

Create `Sources/macrec-ui/Views/Transcription/SourceLane.swift`:

```swift
// macrec-ui/Views/Transcription/SourceLane.swift — plan-012 Phase C5.
//
// Single source-tagged transcript lane. Extracted from
// LiveTranscriptPanel.singleBody so the source-split panel
// (Task C6) can compose two of these without forking the rendering
// logic. The single-mode singleBody also delegates to one of these
// (with no source filter) so there's exactly one rendering code path.

import MacrecCore
import MacrecUIKit
import SwiftUI

struct SourceLane: View {
    @Environment(\.recordingController) private var recordingController
    @Environment(\.palette) private var palette

    /// `nil` → render every segment (used by singleBody in non-split mode).
    /// non-nil → filter to segments whose `source` matches.
    let filter: SourceTag?

    /// Optional header label rendered above the scroll view (e.g.
    /// "System audio" / "Microphone"). `nil` for the unfiltered case
    /// (singleBody) so the existing UI is byte-equivalent.
    let headerLabel: String?

    private var segments: [TranscriptSegment] {
        let all = recordingController?.transcriptSegments ?? []
        guard let filter else { return all }
        return SourceLaneFilter.segments(all, for: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let headerLabel {
                Text(headerLabel)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(segments) { segment in
                            SegmentChipRow(segment: segment)
                                .id(segment.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.fieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.separator, lineWidth: 0.5)
                )
                .onChange(of: segments.count) { _, _ in scrollToBottom(proxy: proxy) }
                .onChange(of: segments.last?.lastUpdated) { _, _ in scrollToBottom(proxy: proxy) }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let target = segments.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

/// Segment chip row, extracted from the existing `segmentView(_:)`
/// helper in LiveTranscriptPanel. Renders the language chip and the
/// new (Phase A8) speaker chip alongside the segment text.
struct SegmentChipRow: View {
    @Environment(\.palette) private var palette
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let lang = segment.language, !lang.isEmpty {
                Text(lang.prefix(2).uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(palette.chipBackground).cornerRadius(3)
            }
            if let speakerRaw = segment.speaker,
               let label = SpeakerSidecarLabel.label(for: speakerRaw) {
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(palette.chipBackground).cornerRadius(3)
            }
            Text(segment.text)
                .font(.system(size: 11))
                .foregroundStyle(segment.isSettled ? palette.value : palette.secondary)
                .italic(!segment.isSettled)
        }
    }
}
```

- [ ] **Step 5: Refactor `LiveTranscriptPanel.singleBody` to delegate to `SourceLane`**

In `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`, inside `singleBody` where the existing `ScrollViewReader { ... }` block lives, replace that block with:

```swift
SourceLane(filter: nil, headerLabel: nil)
```

Also remove the now-duplicated local `segmentView(_:)` helper (`SegmentChipRow` replaces it).

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter SourceLaneFilteringTests`
Expected: PASS (2 tests).

- [ ] **Step 7: Build the UI to confirm it compiles + visual smoke test**

Run: `swift build --product macrec-ui`
Run: `bash scripts/package-macrec-ui-app.sh && open dist/macrec-ui.app`
Confirm the single-mode transcript still renders identically (DT-INV preservation).

- [ ] **Step 8: Commit**

```bash
git add Sources/MacrecUIKit/SourceLaneFilter.swift \
        Sources/macrec-ui/Views/Transcription/SourceLane.swift \
        Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift \
        Tests/MacrecUITests/SourceLaneFilteringTests.swift
git commit -m "refactor(macrec-ui): extract SourceLane from LiveTranscriptPanel

SourceLane (with optional source filter + optional header) and
SegmentChipRow take over the rendering. singleBody now delegates to
SourceLane(filter: nil, headerLabel: nil) so there's exactly one
rendering code path. SourceLaneFilter (in MacrecUIKit) is the pure
filtering helper, unit-tested in isolation.

Spec: docs/design/refined-request-stt-enhancements.md §5.5."
```

---

## Task C6: `SourceSplitTranscriptView` + three-way branch in `LiveTranscriptPanel`

**Files:**
- Create: `Sources/macrec-ui/Views/Transcription/SourceSplitTranscriptView.swift`
- Modify: `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`
- Test: `Tests/MacrecUITests/LiveTranscriptPanelBranchingTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/MacrecUITests/LiveTranscriptPanelBranchingTests.swift`:

```swift
import Testing
@testable import MacrecUIKit

@Suite("LiveTranscriptPanel three-way branching logic (Phase C6)")
struct LiveTranscriptPanelBranchingTests {

    @Test("dual mode wins regardless of source")
    func dualWins() {
        let branch = LiveTranscriptPanelBranchSelector.branch(
            mode: .dual,
            source: .both
        )
        #expect(branch == .dual)
    }

    @Test("single mode + source==.both → split branch")
    func singleBoth() {
        let branch = LiveTranscriptPanelBranchSelector.branch(
            mode: .single,
            source: .both
        )
        #expect(branch == .sourceSplit)
    }

    @Test("single mode + source ∈ {system,mic,mixed} → singleBody (DT-INV)")
    func singleOther() {
        for src: TranscriptionSource in [.system, .mic, .mixed] {
            let branch = LiveTranscriptPanelBranchSelector.branch(
                mode: .single,
                source: src
            )
            #expect(branch == .single)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LiveTranscriptPanelBranchingTests`
Expected: FAIL — `LiveTranscriptPanelBranchSelector` does not exist.

- [ ] **Step 3: Add the branch selector**

Create `Sources/MacrecUIKit/LiveTranscriptPanelBranchSelector.swift`:

```swift
import Foundation
import MacrecCore

/// Pure branch selector for LiveTranscriptPanel's three-way dispatch.
/// Lives in MacrecUIKit so it's unit-testable without SwiftUI.
/// Plan-012 Phase C6.
public enum LiveTranscriptPanelBranch: Equatable, Sendable {
    case single
    case dual
    case sourceSplit
}

public enum LiveTranscriptPanelBranchSelector {
    public static func branch(
        mode: LiveTranscriptionMode,
        source: TranscriptionSource
    ) -> LiveTranscriptPanelBranch {
        if mode == .dual { return .dual }
        if source == .both { return .sourceSplit }
        return .single
    }
}
```

- [ ] **Step 4: Build the new view**

Create `Sources/macrec-ui/Views/Transcription/SourceSplitTranscriptView.swift`:

```swift
// macrec-ui/Views/Transcription/SourceSplitTranscriptView.swift —
// plan-012 Phase C6. Two-lane stacked view used when single-mode +
// --transcribe-source both is active. Each lane is a SourceLane with
// the matching SourceTag filter and a friendly header.

import MacrecCore
import MacrecUIKit
import SwiftUI

struct SourceSplitTranscriptView: View {
    var body: some View {
        VStack(spacing: 8) {
            SourceLane(filter: .system,     headerLabel: String(localized: "System audio"))
            SourceLane(filter: .microphone, headerLabel: String(localized: "Microphone"))
        }
        .frame(maxHeight: .infinity)
    }
}
```

- [ ] **Step 5: Wire the third branch into `LiveTranscriptPanel.body`**

In `Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift`, replace the existing `body` with:

```swift
var body: some View {
    let branch = LiveTranscriptPanelBranchSelector.branch(
        mode: transcriptionMode,
        source: transcriptionSource
    )
    switch branch {
    case .dual:        dualBody
    case .sourceSplit: sourceSplitBody
    case .single:      singleBody
    }
}

/// Source-split body — Phase C6. Wraps SourceSplitTranscriptView in
/// the same chrome / outer .frame(...) modifier as singleBody so the
/// panel claims its vertical slot identically.
private var sourceSplitBody: some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            Text("Transcript")
                .font(.caption)
                .foregroundStyle(palette.secondary)
            Spacer()
            if !segments.isEmpty {
                Button {
                    recordingController?.clearTranscriptSegments()
                } label: {
                    Image(systemName: "trash")
                        .imageScale(.small)
                        .foregroundStyle(palette.secondary)
                }
                .buttonStyle(.borderless)
            }
            TranscriptionStatusBadge()
        }
        SourceSplitTranscriptView()
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.groupBackground))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.groupStroke, lineWidth: 0.5))
    .frame(minHeight: Self.minBodyHeight, maxHeight: .infinity, alignment: .top)
}
```

Add a new `@AppStorage` for the source picker (the existing key is already used by the source `Picker` elsewhere in `RootView`):

```swift
@AppStorage("com.macrec.ui.transcribeSource")
private var transcribeSourceRaw: String = TranscriptionSource.mixed.rawValue

private var transcriptionSource: TranscriptionSource {
    TranscriptionSource(rawValue: transcribeSourceRaw) ?? .mixed
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter LiveTranscriptPanelBranchingTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Build + manual smoke test**

Run: `swift build --product macrec-ui`
Run: `bash scripts/package-macrec-ui-app.sh && open dist/macrec-ui.app`
Pick `--transcribe-source = both` in the popover; start a recording with some system audio + mic input; confirm the panel shows two stacked lanes (System audio / Microphone) and each scrolls independently.

- [ ] **Step 8: Commit**

```bash
git add Sources/MacrecUIKit/LiveTranscriptPanelBranchSelector.swift \
        Sources/macrec-ui/Views/Transcription/SourceSplitTranscriptView.swift \
        Sources/macrec-ui/Views/Transcription/LiveTranscriptPanel.swift \
        Tests/MacrecUITests/LiveTranscriptPanelBranchingTests.swift
git commit -m "feat(macrec-ui): two-lane SourceSplitTranscriptView for source==both

LiveTranscriptPanel.body now branches three ways:
  * dual mode → DualLiveTranscriptView (unchanged)
  * single + source==.both → SourceSplitTranscriptView (NEW)
  * single + source ∈ {system,mic,mixed} → singleBody (unchanged, DT-INV)

Branch selection is delegated to LiveTranscriptPanelBranchSelector
(MacrecUIKit) for unit testability.

Spec: docs/design/refined-request-stt-enhancements.md §5.4, §5.5."
```

---

## Task C7: `AppleSpeechParallelInstancesTest`

**Files:**
- Test: `Tests/MacrecUITests/AppleSpeechParallelInstancesTest.swift` (create)

- [ ] **Step 1: Write the test**

Create `Tests/MacrecUITests/AppleSpeechParallelInstancesTest.swift`:

```swift
import Testing
import Logging
@testable import MacrecCore

@Suite("Apple Speech parallel instance contract (Phase C7)")
struct AppleSpeechParallelInstancesTest {

    @Test("two AppleSpeechTranscriptionProvider instances coexist")
    @available(macOS 26.0, *)
    func twoInstancesCoexist() async throws {
        let logger = Logger(label: "test")
        let p1 = AppleSpeechTranscriptionProvider(logger: logger)
        let p2 = AppleSpeechTranscriptionProvider(logger: logger)

        // Open one streaming session per provider; assert both return.
        let s1 = try await p1.openStreamingSession(
            source: .system,
            options: TranscriptionOptions(languageHints: ["en-US"])
        )
        let s2 = try await p2.openStreamingSession(
            source: .microphone,
            options: TranscriptionOptions(languageHints: ["en-US"])
        )

        await s1.stop()
        await s2.stop()

        // If we got here without throwing, the two-instance contract holds.
        #expect(true)
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter AppleSpeechParallelInstancesTest`
Expected: PASS on macOS 26+; otherwise the `@available` gate skips it.

> If this test fails on a future macOS update, do NOT block the rest of Phase C — file an issue (`Issues - Pending Items.md`) so a follow-up plan can introduce round-robin sharing in `SourceSplitTranscriptionManager` for the Apple provider arm only.

- [ ] **Step 3: Commit**

```bash
git add Tests/MacrecUITests/AppleSpeechParallelInstancesTest.swift
git commit -m "test(apple-speech): lock two-instance contract for source-split mode

Constructs two AppleSpeechTranscriptionProvider instances and opens
a streaming session on each. If a future macOS update makes
SpeechAnalyzer single-instance-per-process, this test will fail loudly
and the SourceSplitTranscriptionManager will need a round-robin fallback.

Spec: docs/design/refined-request-stt-enhancements.md §5.2."
```

---

## Task C8: documentation updates for Phase C

**Files:**
- Modify: `docs/tools/macrec.md`
- Modify: `docs/design/project-functions.md`
- Modify: `docs/design/project-design.md`
- Modify: `Issues - Pending Items.md`

- [ ] **Step 1: Remove the v1-limitation paragraph in `docs/tools/macrec.md`**

Find and delete the block (around lines 603-607):

```markdown
> **v1 limitation — `--transcribe-source both`.** v1 ships a single
> transcription driver and emits one combined transcript stream.
> When `both` is requested with a non-split layout, the driver
> falls back to `mixed`. True per-source dual-driver transcription
> is tracked as a v2 follow-up (see `Issues - Pending Items.md`).
```

- [ ] **Step 2: Update the sidecar-naming table**

Find the table around line 595 and add a row for the new behaviour:

```markdown
| `--transcribe-source both` (any layout)                      | per `--layout`                              | `recording-….system.transcript.<ext>` AND `recording-….mic.transcript.<ext>` (plan-012) |
```

- [ ] **Step 3: Add a new "Source-split mode" subsection**

Place after the "Long-session behaviour" subsection:

```markdown
### Source-split mode (plan-012)

When `--transcribe-source both` is selected with single-mode
transcription, `macrec` runs **two** transcription drivers in
parallel — one for the system audio submix, one for the
microphone — and emits two sidecar files:

* `<basename>.system.transcript.<ext>` — only system-tagged segments.
* `<basename>.mic.transcript.<ext>` — only mic-tagged segments.

Both drivers are instances of the SAME provider (whatever
`--transcribe` selected). Each gets its own logger label
(`track=system` / `track=mic`) so log lines are easy to disambiguate.

**Per-provider compatibility:**

| Provider               | Notes                                                  |
|------------------------|--------------------------------------------------------|
| `apple` / `apple-cloud`| Independent SpeechAnalyzer / SFSpeechRecognizer instances. Validated in CI. |
| `gemini`               | Independent per-chunk REST POSTs.                       |
| `whisperkit` / `parakeet` | Doubled memory cost (~1.2 GB total when both lanes load the multilingual model). |
| `soniox`               | Two independent WebSocket connections.                  |
| `azure` / `azure-openai-realtime` | Two independent REST/WebSocket sessions; each counts independently against the realtime 60-min boundary. |
| `elevenlabs`           | Two parallel POSTs. Free/Starter tiers cap concurrent requests at 8 — `macrec` logs a warning at session start. |

**UI:** the live transcript panel renders TWO stacked auto-scrolling
lanes labelled `System audio` and `Microphone`. Dual-mode
(`--transcribe dual`) is unaffected.
```

- [ ] **Step 4: Register FRs in `project-functions.md`**

```markdown
**FR-SS-1** — `--transcribe-source both` runs two parallel
transcription drivers (one per `SourceTag`) and emits two sidecar
files (`*.system.transcript.<ext>` + `*.mic.transcript.<ext>`).
Plan-012 Phase C.
**FR-SS-2** — The live transcript panel renders two stacked
auto-scrolling lanes when single-mode + `source == .both`.
```

- [ ] **Step 5: Close the v2 follow-up in `Issues - Pending Items.md`**

Move the "True per-source dual-driver transcription" pending item to Completed with a one-line note:

```markdown
- **True per-source dual-driver transcription (was v2 follow-up)** —
  implemented in plan-012 Phase C. SourceSplitTranscriptionManager
  composes two TranscriptionManager instances; LiveTranscriptPanel
  renders a two-lane SourceSplitTranscriptView for source==.both.
```

- [ ] **Step 6: Update `project-design.md` §LT-7.1**

Find the LT-7.1 block describing the v1 fallback and update to reflect the now-fully-supported `both` path. Add a brief reference to `TranscriptionDispatcherSelector` (Task C4) as the dispatch-choice authority.

- [ ] **Step 7: Commit**

```bash
git add docs/tools/macrec.md \
        docs/design/project-functions.md \
        docs/design/project-design.md \
        "Issues - Pending Items.md"
git commit -m "docs: source-split transcription (plan-012 Phase C)

Removes the v1 --transcribe-source both fallback paragraph; adds a
new Source-split mode subsection with the per-provider compatibility
table; updates the sidecar-naming table; registers FR-SS-1/2 in
project-functions; closes the v2 follow-up tracker.

Spec: docs/design/refined-request-stt-enhancements.md §5.7."
```

---

# Phase D — Final integration sweep

## Task D1: end-to-end manual verification matrix

**Files:** none (manual pass).

- [ ] **Step 1: Build a release UI bundle**

Run: `bash scripts/package-macrec-ui-app.sh`
Run: `cp -R dist/macrec-ui.app /Applications/macrec-ui.app && open /Applications/macrec-ui.app`

- [ ] **Step 2: Walk the matrix**

For each cell, confirm acceptance criteria from spec §7:

| Cell | Provider     | Source       | Mode    | What to verify                                          |
|------|--------------|--------------|---------|---------------------------------------------------------|
| 1    | `apple`      | mixed        | single  | Existing baseline still works (DT-INV).                  |
| 2    | `apple`      | both         | single  | Two lanes render; two sidecars produced (AC-SS-1..4).    |
| 3    | `parakeet`   | mixed        | single  | Model downloads on first run; segments appear (AC-PK-1..2). |
| 4    | `parakeet`   | both         | single  | Two parallel Parakeet instances; ~1.2GB RAM expected.    |
| 5    | `soniox`     | mixed        | single  | Diarization on by default; speaker chips render (AC-SD-1). |
| 6    | `soniox` (diarize=false) | mixed | single | No speaker field in sidecar; no chip in UI (AC-SD-2).  |
| 7    | `apple`      | _(any)_      | dual    | Dual-mode unchanged (AC-SS-5).                          |
| 8    | `elevenlabs` | both         | single  | Warning logged at session start (AC-SS-7).               |

- [ ] **Step 3: Inspect produced sidecars**

For cell #2: `ls -la ~/Recordings/<basename>.{system,mic}.transcript.jsonl` and `head -5 …`. Confirm each contains only its own source tag and that JSONL fields match spec §4.4.

- [ ] **Step 4: Update CLAUDE.md "What changed" pointer**

Add a one-line entry near the top of the `macrec` Tools section in `CLAUDE.md` linking to plan-012:

```markdown
> Plan-012 (2026-05-…) added a Parakeet TDT V3 multilingual on-device
> provider, default-on Soniox speaker diarization, and true dual-driver
> source-split mode. See `docs/design/plan-012-stt-enhancements.md` for
> the full task list and `docs/design/refined-request-stt-enhancements.md`
> for the spec.
```

- [ ] **Step 5: Final full test run**

Run: `swift test`
Expected: every suite passes — including pre-existing snapshot tests (DT-INV preservation guarantees).

- [ ] **Step 6: Commit the doc tweak**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): link to plan-012 STT enhancements"
```

---

## Self-review checklist (run before declaring this plan ready)

After writing the plan, reviewer (engineer or follow-up agent) walks through:

1. **Spec coverage** — each numbered AC in `refined-request-stt-enhancements.md` §7 is implemented by at least one task above:
    * AC-PK-1..5 → Tasks B2, B3, B4.
    * AC-SD-1..6 → Tasks A2, A3, A4, A5, A7, A8.
    * AC-SS-1..7 → Tasks C1, C3, C4, C6, C8 plus the elevenlabs warning in Task C4 step 4.
2. **Placeholder scan** — there is exactly one externally-resolvable placeholder, the FluidAudio version pin (`<TAG_FROM_STEP_1>` in Task B1). It is intentionally externally-resolvable — the engineer runs `git ls-remote` in the same step that fills it.
3. **Type consistency** — the new types referenced across tasks all align: `ParakeetTranscriptionProvider.defaultModelName` (B2 → B3), `SonioxConfigBuilder.defaultDiarize` (A2 → A3 → A5 → A8), `SpeakerSidecarLabel.label(for:)` (A6 → A7 → A8 → C5), `SourceLaneFilter.segments(_:for:)` (C5 → exposed for the source-split UI in C6), `LiveTranscriptPanelBranchSelector.branch(mode:source:)` (C6).
4. **Order independence** — Phases A, B, C share zero state. Phase A may merge before Phase B starts. Phase C depends on Phase A's `TranscriptSegment.speaker` field for the speaker-chip rendering in `SegmentChipRow` (C5), so Phase A must complete before Phase C5 — but Phase B is fully independent of both.

If any of the above checks fails after editing, fix inline and re-verify.

---

## References

- Spec: `docs/design/refined-request-stt-enhancements.md` (source of truth for every task here).
- Architectural template (provider): `Sources/MacrecCore/Transcription/Providers/WhisperKitTranscriptionProvider.swift`.
- Architectural template (settings UI): `Sources/macrec-ui/Settings/Sections/ElevenLabsSettingsView.swift`, `WhisperKitSettingsView.swift`.
- Existing dual-channel UI primitives reused in Phase C5/C6: `Sources/macrec-ui/Views/Transcription/DualLiveTranscriptView.swift`, `DualLiveTranscriptLane.swift`.
- `docs/design/project-design.md` §LT-1 .. §LT-10, §SX-3, §DT-4 (transcription / dispatcher / sidecar architecture).
- FluidAudio: `https://github.com/FluidInference/FluidAudio`.
- Parakeet TDT V3 model card: `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3`.
