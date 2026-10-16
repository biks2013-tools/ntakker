# plan-020: EVAL-2026-10-16 transcript correctness

Source: `docs/reference/evaluation-2026-10-16-quality-performance.md`, §4 item 2 ("Transcript correctness").
Follows: `plan-019-eval-2026-10-16-leftovers-and-doc-drift.md`.
Approved: 2026-10-16 ("yes please", after plan-019 was proposed as the step before this wave); one commit per task.

## Tasks

### Soniox reconnect

- [x] **T1 (INF-1)** After a transport drop, `SonioxStreamingSession.runReconnect` replays the whole 5 s ring, including audio the old connection already transcribed. That duplicates text. Chunks that arrive during the replay are never sent, and 5 s is shorter than the worst-case outage (0 + 1 + 4 s backoff plus connect time).
  - Track absolute byte offsets for the ring chunks.
  - Record the committed boundary from final tokens' `end_ms`, measured relative to the connection's base offset.
  - On reconnect, replay only from that boundary, and loop until chunks that arrived during the replay are sent too.
  - Before reconnecting, drop the aggregator's non-final tokens and flush its committed finals.
  - Raise the ring to 30 s.
  - Tests use a mock transport factory.
- [x] **T2 (INF-2)** If `finish()` runs while a reconnect attempt is connecting or replaying, the attempt still installs the fresh socket, receive loop and keepalive, and they leak. Re-check `isFinished` after the replay and after the keepalive starts, and close or stop whatever was opened. Add a test.

### Azure realtime reconnect

- [x] **T3 (TR-13)** On every reconnect, including the planned 58-minute one, `AzureOpenAIRealtimeSession` replays the full ring of already-committed audio, which produces duplicate finals.
  - Count the samples sent on the current connection.
  - Take the committed boundary from `speech_stopped.audio_end_ms`, or from the send count at `input_audio_buffer.committed` when no `speech_stopped` arrived.
  - Replay only the uncommitted tail plus audio that was never sent.
  - Raise the ring to 15 s.
  - Done: the replay-tail calculation is unit-tested (`AzureRealtimeReplayTailTests`). The wiring is build-verified only, because the session forces `wss` and has no transport seam.

### convo-coach transcript input

- [x] **T4 (CC-2)** The JSONL parser only reads `channel: "A" | "B"`. ntakker writes `source: system | mic | mixed` plus `speaker`.
  - Map `mic` to A (the user) and `system` to B (the remote side), matching the default system prompt.
  - Render `speaker` in the prompt line.
  - Add tests.
- [x] **T5 (CC-3)** ntakker rewrites segments by id: a short in-place rewrite, or a tombstone plus an append. A `tail -f` stream sees the appended version as a second record.
  - De-duplicate records by `id`, with the later line winning, in `parseJsonl` (used by file and stdin mode).
  - Document that `tail -f` cannot see in-place rewrites and that file mode should be used for exact transcripts.

### Save and Ask completeness

- [x] **T6 (UI-1)** The first pause renames segment 1's audio to `.part01` but leaves its transcript sidecars under the bare name. Save then probes `<stem>.part01.transcript.jsonl`, finds nothing, reads only the first audio source, and ignores the `.system` and `.microphone` sidecars.
  - Rename the segment-1 transcript sidecars alongside the audio.
  - Make Save read and merge every part's transcript sidecars, both the mixed `<stem>.transcript.jsonl` and the per-source `.system` / `.microphone` ones, sorted by timestamp. Keep a probe for the bare segment-1 name so older sessions still work.
  - Done. The coordinator rename is tested (`UI-1` test in `SessionCoordinatorTests`). The exporter merge is build-verified only: `SessionExporter` lives in the app executable, which no test target imports. Save also now finds the questions sidecar, which is written next to the LAST segment; before, Save only looked next to the first.
- [x] **T6a (new, found during T6)** `JSONLTranscriptReader` excluded every id that had a tombstone. The writer's long-grow tombstone carries the same id as the line appended after it, so Save dropped every batch-provider segment that had grown past its slot. Fix: skip tombstone lines and keep the last valid line per id. A round-trip test against the real writer fails on the old reader.
- [x] **T7 (UI-6)** Ask "Full" / "15 min" and the Save fallback read `RecordingController.transcriptSegments`, which is capped at 100 for the live panel. Keep a separate uncapped session transcript for Ask and Save; the panel stays capped.

### Sanitizer

- [x] **T8 (TR-6)** `TranscriptSanitizer.clean` strips all leading punctuation, including the `[` of `[Speaker 1]`. Keep opening brackets and quotes (`( [ { " ' « “ ‘ ¿ ¡`).
- [x] **T9 (TR-7)** The hallucination list deletes genuine one-word answers such as "yeah", "ok" and "thanks" from 2 s chunks. Keep always dropping the phrases that are pure hallucinations ("thanks for watching", "subtitles by …", "you", fillers). Drop the plausible short replies only when the chunk is quiet; `TranscriptionManager` passes the chunk peak.

### Apple providers

- [x] **T10 (TR-5)** In Apple dual-locale mode every locale gets its own utterance id, so reconciliation never pairs finals and both languages are emitted. This is the cause of the baseline failure `"higher-confidence final wins per utterance"`.
  - Group finals from different locales by time overlap. Without time ranges, group them by arrival within the reconciliation window.
  - Emit partials from the primary locale only, and use that utterance id for the reconciled final so no orphan partial rows remain.
- [x] **T11 (TR-4)** The Apple Cloud 55 s rotation calls `endAudio()` and keeps routing audio to the ended request until the old final arrives, losing about 1.5–3 s per rotation.
  - Start the next request and task first, then end the old one. The old task keeps draining its final.
  - Track retired tasks so that only the current task's end starts a new task, and the stream finishes only once every task has ended.
  - Done; build-verified only. Apple Cloud needs a speech-recognition TCC grant that a raw test binary lacks (status `notDetermined`), and requesting one would show a prompt. Manual check: record more than 60 s with `apple-cloud` in the app and confirm the words spoken around 55 s survive.

## Verification

- `swift build` clean; `convo-coach` `npm test` green.
- New tests pass. The full suite (`--skip NtakkerCoreTests.RecordingSessionTests`) shows no failures beyond the plan-018 baseline list, and the AppleSpeech reconciliation baseline failure should turn green.
- Build-only items are called out in the wave result.
