# refined-request-001: ntakker-studio

Date: 2026-10-17. Slug: `ntakker-studio`.

## Request (verbatim)

> I want you to create an adjucent application named ntakker-studio. It must be a swift app to explore the recordings, allow user to study the transcriptions, navigate directly to the recording place where the transcription is pointing, cut the parts of the recording and readjusting the transctription timestamps, make questions and extract minutes from the transcription/recording, etc

## Decisions taken with the user (2026-10-17)

- **Cutting** writes a new copy. The original files are never changed; the cut audio and the re-timed transcripts go into a new folder next to the original.
- **Extras in v1**: rename speakers, edit transcript text, re-transcribe a recording, search across all recordings.
- **AI provider** for Q&A and minutes: the same configuration as ntakker's Ask (`NTAKKER_ASK_*` in `~/.tool-agents/ntakker/.env`).

## Scope

A normal (Dock) macOS SwiftUI app, `ntakker-studio`, built from the same Swift package as `ntakker` and `ntakker-cli`, with its own bundle id `com.giorgosmarinos.ntakker-studio`.

1. **Library**: lists the recordings under a library folder. Each recording is the audio file(s) and transcript sidecars that share a filename stem.
2. **Player**: plays a recording. A split recording (`.mic` + `.system`) plays both tracks together.
3. **Transcript study**: shows every transcript of the recording with time, speaker and source; highlights and follows the line being played; filter and find.
4. **Jump to moment**: clicking a line seeks the player to where it was spoken.
5. **Cut**: mark time ranges on a waveform and export a copy without them; transcript timestamps are shifted to match, and lines inside a cut are dropped.
6. **Ask and minutes**: ask questions about the whole recording and generate meeting minutes; answers cite `[mm:ss]` times that are clickable; results are saved next to the recording.
7. **Rename speakers**, saved per recording, used in the transcript view, Ask and minutes.
8. **Edit transcript text**, saved back to the sidecar (a one-time backup of the original is kept).
9. **Re-transcribe** a recording with one of ntakker's batch providers into a new transcript file.
10. **Search all recordings** for text, with results that open the recording at that moment.

## Out of scope for v1

- Recording (that stays in `ntakker`).
- Re-transcribing with streaming-only providers (Apple, Apple Cloud, Soniox, Azure Realtime).
- Editing SRT / VTT / TXT sidecars (JSONL is the source of truth; the others are not read).
