# recording-tool — Project Overview (refreshed 2026-05-05)

## Status
Active project with substantial codebase. Plans 001 through 012 delivered or in progress. Greenfield phase is over.

## Purpose
macOS-only audio recording + live/batch transcription suite:
1. **System audio** capture via `ScreenCaptureKit` (Music, Spotify, Zoom, Teams, browsers, …).
2. **Microphone audio** capture via `AVFoundation`.
3. **Live transcription** via swappable providers (Apple on-device, Apple Cloud, Gemini Live, Soniox, Azure, Azure Realtime, ElevenLabs, WhisperKit, Parakeet via FluidAudio).
4. **Dual-channel transcription** (`--transcribe dual`) — Apple on-device + Apple Cloud concurrently.
5. **Source-split transcription** (plan-012 Phase C) — independent transcribers per source (system / microphone) with two sidecars.
6. **Conversational coaching** (`convo-coach` TS CLI) — streams LLM advice from sidecar transcripts.

## Products
- `ntakker-cli` — Swift CLI (executable target, embeds Resources/Info.plist).
- `ntakker` — Swift menu-bar app (executable target, embeds Resources/NtakkerUI-Info.plist; bundle id `com.giorgosmarinos.ntakker`, distinct from CLI).
- `NtakkerCore` — Swift library (capture, encoding, mixing, transcription providers, config).
- `NtakkerUIKit` — Swift library (UI domain layer: RecordingController, SessionCoordinator, …).
- `tools/dual-transcript-merger` — TypeScript CLI (npm-linkable) merging dual-channel JSONL sidecars.
- `tools/convo-coach` — TypeScript CLI (npm-linkable) streaming LLM coaching against sidecars.

## Tech stack
- **Swift** (approved Exception 001 to TS-only rule). `swift-tools-version:6.2`, deployment target `macOS 26` (Exception 002 — needed for `SpeechAnalyzer`). Language mode pinned to Swift 5 (`swiftLanguageModes: [.v5]`) to avoid mass strict-concurrency churn.
- **SPM** with one `Package.swift` at root.
- **Frameworks**: ScreenCaptureKit, AVFoundation, CoreAudio, AVFAudio, AppKit, SwiftUI, Speech (`SpeechAnalyzer` on macOS 26).
- **Dependencies**: `swift-argument-parser` (1.5.0+), `swift-log` (1.5.4+), `argmax-oss-swift` (==0.18.0, WhisperKit), `FluidAudio` (==0.8.2, Parakeet TDT V3 multilingual ASR).
- **Tests**: Swift Testing framework (`swift test`), with a `-F` workaround so the framework is found under `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` (no full Xcode required).
- **TypeScript** for `tools/*` (Vercel AI SDK in `convo-coach`).

## Layout
```
Sources/
  ntakker-cli/                 CLI entrypoint (Commands/, main.swift)
  ntakker/              Menu-bar app (AppDelegate, PopoverController, RootView, Settings/, Theme/)
  NtakkerCore/             Capture/, Encoding/, Mixing/, Transcription/, Config/, Permissions/, Devices/, Daemon/, Aligning/, Bootstrap/, Errors/, Logging/, RecordingSession.swift
  NtakkerUIKit/            RecordingController, SessionCoordinator, FilenameGenerator, LevelMeter*, SegmentNamer
Tests/
  NtakkerCoreTests/
  NtakkerUITests/
Resources/                Info.plist (CLI), NtakkerUI-Info.plist (UI app)
scripts/package-ntakker-app.sh  Packages dist/ntakker.app (ad-hoc signed)
bin/build-ntakker-app.sh
tools/
  dual-transcript-merger/ TS CLI (npm)
  convo-coach/            TS CLI (npm)
docs/
  design/                 plans, refined-requests, project-design.md (729k), project-functions.md, configuration-guide.md, mockups/
  reference/              Apple/vendor reference excerpts
  research/               deep technical research outputs
  tools/                  per-tool docs (ntakker-cli.md, ntakker.md, dual-transcript-merger.md, convo-coach.md)
test_scripts/             ad-hoc test scripts
prompts/                  numbered prompts
"Issues - Pending Items.md"  pending items / issues at root
```

## Approved exceptions (see CLAUDE.md "Project Memory")
- **Exception 001** — Swift instead of TypeScript for the macOS audio tool.
- **Exception 002** — `macOS 26` deployment target (for `SpeechAnalyzer`).
- **Exception 003** — `convo-coach` defaults `COACH_PROVIDER` to `azure-openai` when neither flag nor env var is set.

## Documentation map
- `CLAUDE.md` — project rules, exceptions, Tools index. **Authoritative.**
- `docs/design/project-design.md` — full architecture.
- `docs/design/project-functions.md` — functional requirements.
- `docs/design/plan-NNN-*.md` — plans (001 recording, 002 toolbar UI, 003 live transcription, 004 batch REST STT, 005 Apple Speech streaming, 006 Soniox, 007 additional engines, 008 UI redesign, 009 Soniox aggregator fix, 010 dual transcription, 011 convo-coach, 012 STT enhancements).
- `docs/design/configuration-guide.md` — config/env precedence guide.
- `docs/tools/<tool-name>.md` — per-tool full docs.
- `Issues - Pending Items.md` — pending items.
