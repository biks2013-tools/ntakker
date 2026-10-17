# plan-024: ntakker-studio

Source: `docs/refined_requests/refined-request-001-ntakker-studio.md`.
Approved: 2026-10-17. The user asked for the app and answered the three scoping questions (cut writes a copy; all four extras; Ask config shared with ntakker).

## Architecture

Three new targets in `Package.swift`:

| Target | Kind | Path | Role |
|---|---|---|---|
| `NtakkerStudioKit` | library | `Sources/NtakkerStudioKit` | All logic that can be unit-tested: library scan, timing, metadata, transcript load/save, cut, retime, Ask prompts, search, re-transcribe, waveform peaks. |
| `ntakker-studio` | executable | `Sources/ntakker-studio` | SwiftUI Dock app. Embeds `Resources/NtakkerStudio-Info.plist` (`com.giorgosmarinos.ntakker-studio`). |
| `NtakkerStudioTests` | tests | `Tests/NtakkerStudioTests` | Swift Testing suites for the kit. |

Packaging: `scripts/package-ntakker-studio-app.sh` and `scripts/redeploy-ntakker-studio.sh`, mirroring the ntakker scripts.

### Key design points

- **Recording** = the audio files and transcript sidecars in one folder that share a stem. `<stem>.m4a|wav|caf` (mixed or stereo-split), `<stem>.mic.*` + `<stem>.system.*` (split), each `.partNN` its own recording. Transcripts: `<stem>.transcript.jsonl` and every `<stem>.<label>.transcript.jsonl` (per-source and re-transcriptions).
- **Library folder**: the studio's own setting. On first launch it adopts ntakker's output-folder setting; if that is unset, the user is asked to choose one (no silent default).
- **Timing**. Segment timestamps are wall-clock. The audio start is the first audio file's creation date (or `audioStart` in the studio metadata). Offset = timestamp − audio start; for batch providers the timestamp marks when the result arrived, so their duration is subtracted too. A per-recording sync nudge corrects what remains. Transcripts written by the studio (re-transcriptions, cuts) carry exact timestamps and are marked exact.
- **Studio metadata**: `<stem>.studio.json` — audio start, speaker names, sync nudge, exact-timing transcript list. Created only when the user changes something.
- **Cut** never modifies the original: a new folder `<name>-cut-<yyyy-MM-dd-HH-mm-ss>` next to the original gets every audio track cut (AVAudioFile, same format), every transcript re-timed, and a studio metadata file.
- **Text edits** rewrite the JSONL through `JSONLTranscriptWriter` into a temp file and replace atomically; the first edit keeps `<file>.orig`.
- **Ask / minutes** reuse `AskConfigResolver` + `AskClientFactory`; the whole transcript goes in as `[mm:ss] Speaker: text` lines; answers' `[mm:ss]` citations are clickable. Saved to `<stem>.studio-qa.md` and `<stem>.minutes.md`.
- **Re-transcribe** resolves provider settings through `ConfigResolver(toolName: "ntakker")` (same `.env` as ntakker) and builds the provider with `TranscriptionProviderFactory`. The provider-input mapping moves out of `RecordingSession` into a public `TranscriptionProviderFactoryInput(options:logger:)` so both use it. Batch providers only (gemini, whisperkit, parakeet, azure, elevenlabs).

## Tasks

- [x] **T1** Package targets, Info.plist, packaging scripts, empty app that launches.
- [x] **T2** Kit: `RecordingLibrary` scanner + models; tests.
- [x] **T3** Kit: `StudioMetadata`, `SegmentTiming`, `TranscriptDocument` (load, edit, save with backup); tests.
- [x] **T4** Kit: `CutPlan` + `TranscriptRetimer` (pure) + `AudioCutter` + `RecordingCutExporter`; tests (retime cases, audio frame counts).
- [x] **T5** Kit: `StudioAsk` prompts + `TimecodeLinks`; Q&A and minutes persistence; tests.
- [x] **T6** Kit: `TranscriptSearchIndex`; tests.
- [x] **T7** Core: `TranscriptionProviderFactoryInput(options:logger:)`; kit: `Retranscriber` (decode to 16 kHz, silence-aware chunking, exact timestamps); tests with `FakeTranscriptionProvider`.
- [x] **T8** Kit: `WaveformPeaks`.
- [x] **T9** App UI: library sidebar, player, waveform with cut selection, transcript pane (follow, click to seek, find, edit), inspector (Ask, Minutes, Speakers, Cut, Re-transcribe, Info), global search, settings.
- [x] **T10** Docs: `docs/tools/ntakker-studio.md`, CLAUDE.md Tools entry, `project-design.md`, `project-functions.md`, issues register.
- [x] **T11** Verify: build, tests, package, live check on real recordings.

## Verification

- `swift build`, `swift test --filter NtakkerStudioTests` green; existing suites unchanged.
- Live: open a real recording, play, click a line → audio at that line, cut a range → new folder with shorter audio and shifted transcript, Ask and minutes against the configured provider, search across the library.

## Addendum (2026-10-17): playback echo filter

User request: "can you add a real-time filter in studio to clear the echo?"

- [x] **T12** `SoftwareAECProcessor.processAligned` + `playbackConfiguration` + `resetAlignedTimeline` (core, 3 tests); `EchoDelayEstimator` (kit, 1 test); `PlayerController` rewritten on `AVAudioEngine` with a block reader that filters the mic against the delayed system track; "Remove echo" switch in the player bar.
  - Found: the echo on real recordings arrives 114–142 ms after the system audio, beyond the filter's 85 ms window. Delaying the reference by the measured delay raised the reduction from 3–7 dB to 15–16 dB on two of three recordings.
  - Live check: playback, transcript follow and the switch work in the app.

