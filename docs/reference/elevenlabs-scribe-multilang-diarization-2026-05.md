# ElevenLabs Scribe v2 — Multi-Language and Diarization Capabilities

**Research date:** 2026-05-01  
**Model scope:** `scribe_v2` (batch) and `scribe_v2_realtime` (streaming)  
**Primary source:** https://elevenlabs.io/docs/api-reference/speech-to-text/convert

---

## A. Diarization Output Shape

### A1. Per-word `speaker_id` field

Yes. When `diarize=true` is sent, every object in `words[]` includes a `speaker_id` string field. This is confirmed by both the official capabilities docs and by the auto-generated Python SDK type `SpeechToTextWordResponseModel`.

Confirmed response shape from the official capabilities page (https://elevenlabs.io/docs/overview/capabilities/speech-to-text):

```json
{
  "language_code": "en",
  "language_probability": 1.0,
  "text": "...",
  "words": [
    {
      "text": "With",
      "start": 0.119,
      "end": 0.259,
      "type": "word",
      "speaker_id": "speaker_0"
    },
    {
      "text": " ",
      "start": 0.239,
      "end": 0.299,
      "type": "spacing",
      "speaker_id": "speaker_0"
    }
  ]
}
```

The full `SpeechToTextChunkResponseModel` (Python SDK source, https://github.com/elevenlabs/elevenlabs-python) contains:

```
language_code:        str           # e.g. "eng"
language_probability: float         # 0.0–1.0 confidence of detected language
text:                 str           # full raw transcript
words:                List[SpeechToTextWordResponseModel]
additional_formats:   Optional[List[AdditionalFormatResponseModel]]
transcription_id:     Optional[str]
entities:             Optional[List[DetectedEntity]]
audio_duration_secs:  Optional[float]
channel_index:        Optional[int]  # multichannel mode only
```

The `SpeechToTextWordResponseModel` fields are:

```
text:       str
start:      Optional[float]      # seconds
end:        Optional[float]      # seconds
type:       SpeechToTextWordResponseModelType  # "word" | "spacing" | "audio_event"
speaker_id: Optional[str]        # set when diarize=true
logprob:    float                # log probability; range (-inf, 0]; higher = more confident
characters: Optional[List[SpeechToTextCharacterResponseModel]]
```

Note that `logprob` is present on every word and serves as a per-word transcription confidence score. There is **no separate per-word diarization confidence field** in the schema.

### A2. Higher-level segments or utterances array

**No.** The API does not return a `segments[]` or `utterances[]` array in the top-level response. The only structured output is the flat `words[]` array. To produce speaker-turn blocks (i.e., contiguous runs of words from the same speaker), clients must group consecutive words sharing the same `speaker_id` themselves.

There is no automatic "turn" grouping in the API response as of 2026-05-01.

### A3. `speaker_id` format

By default: `"speaker_0"`, `"speaker_1"`, ..., `"speaker_N"` (zero-indexed integers, not GUIDs).

If `detect_speaker_roles=true` is also set (requires `diarize=true`; +10% cost surcharge; cannot be combined with `use_multi_channel=true`), the `speaker_id` values change to `"agent"` and `"customer"` instead.

Source: https://elevenlabs.io/docs/api-reference/speech-to-text/convert (`detect_speaker_roles` parameter description)

### A4. Per-word diarization confidence

**No dedicated diarization confidence field exists.** The `logprob` field present on each word reflects transcription probability, not speaker-assignment probability. There is no documented confidence score for the speaker label itself.

### A5. Diarization caveats, `num_speakers`, and `diarization_threshold`

Per the official API reference (https://elevenlabs.io/docs/api-reference/speech-to-text/convert):

- **Minimum audio duration:** The minimum file length for any transcription request is 100 ms. No separate minimum for diarization is documented.
- **`num_speakers` (integer, 1–32, optional, default null):** Described as "the **maximum** amount of speakers talking in the uploaded file." The docs say it "**can help** with predicting who speaks when." This phrasing indicates it is a **hint**, not a hard cap that constrains the model to exactly that count. When null, the model defaults to its internal maximum (32 for `scribe_v2` per the API reference; some third-party sources cite 48 for `scribe_v2` — the official API reference text says 32).
- **`diarization_threshold` (double, 0.1–0.4, optional):** Controls speaker-split aggressiveness. Higher value → fewer total speakers predicted (merges borderline speakers). Lower value → more speakers predicted (splits borderline speakers). Default is null, which selects a model-dependent threshold (typically 0.22). **Can only be set when `diarize=true` AND `num_speakers=null`.**

---

## B. Language Locking — Single Language

### B1. Is `language_code=el` a hard lock or a hint?

The API reference describes `language_code` as: "An ISO-639-1 or ISO-639-3 language\_code corresponding to the language of the audio file. Can **sometimes** improve transcription performance if known beforehand. Defaults to null, in this case the language is predicted automatically."

The word "sometimes" and the framing as an optional improvement hint — not a constraint — is the only characterisation in the official docs. ElevenLabs does **not** document this parameter as a hard lock. Real-world evidence from third-party integrations (LiveKit agents GitHub issue https://github.com/livekit/agents/issues/3759) confirms it is treated as a probabilistic bias: the complaint raised was that a framework defaulted `language_code` to `"en"`, preventing auto-detection — which would be irrelevant if the parameter were a strict lock.

**Conclusion:** `language_code` is a **soft hint / bias**, not a hard constraint. The model retains its auto-detection capability and may override the hint based on acoustic evidence.

### B2. Behaviour for bilingual audio when `language_code=el`

The official documentation is **silent** on this scenario. ElevenLabs does not document whether setting `language_code=el` causes English words spoken mid-sentence to be translated, romanised, transliterated, or passed through verbatim. From the general behaviour of Scribe v2's multilingual auto-detection capability (which handles code-switching natively), it is reasonable to expect that English words would be passed through in their original script when the model detects them — but this is **not explicitly documented** and should be treated as uncertain (LOW confidence).

---

## C. Multi-Language Allow-List — Does It Exist?

The following parameter surfaces were checked against the official API reference, the Python SDK source, and the changelog (https://elevenlabs.io/docs/changelog/2026/1/12):

| Parameter | Status |
|---|---|
| `language_codes[]` array | **Does not exist** |
| `additional_languages[]` | **Does not exist** |
| `allowed_languages` | **Does not exist** |
| `restrict_languages` boolean | **Does not exist** |
| "code-switching mode" with a language set | **Does not exist** |
| `secondary_language_code` | **Does not exist** |
| Per-word `detected_language` field | **Does not exist** |
| Per-segment `detected_language` field | **Does not exist** |

The response top-level object has a single `language_code` string (the detected language for the entire file) and a single `language_probability` float. There is no per-word or per-segment language field in the schema.

There is **no documented mechanism on the Scribe v2 batch endpoint to constrain detection to a user-specified set of languages.** There is no multi-language allow-list parameter.

---

## D. Streaming Variant (`scribe_v2_realtime`)

`scribe_v2_realtime` is a live WebSocket endpoint. It exists and is a distinct model ID (listed in https://elevenlabs.io/docs/overview/models). The WebSocket URL is documented at https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime (page rendered as JavaScript so not directly readable by fetch, but confirmed by web search).

Key characteristics relevant to `macrec-ui`:

- **Diarization: NOT supported.** Speaker diarization is explicitly absent from `scribe_v2_realtime`. For speaker labeling, you must use the batch `scribe_v2` model.
- **Latency:** ~150 ms to first partial.
- **Language locking:** `language_code` is accepted as a session config parameter and behaves the same as in batch (soft hint).
- **No multi-language allow-list** on the realtime endpoint either.
- **Keyterms:** up to 50 keyterms (max 20 characters each) accepted as query parameters when connecting.
- **`include_language_detection`** boolean is documented in session config.

The existing `openStreamingSession` stub in `macrec-ui` can be wired to `scribe_v2_realtime`, but doing so will yield no `speaker_id` labels. The streaming endpoint is **not** a drop-in replacement for batch when diarization is needed.

Source: Web search synthesis from https://elevenlabs.io/realtime-speech-to-text and https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime

---

## E. Practical Recommendation: Greek + English Only, with Speaker Turns

### Evaluated options

**Option 1 — `language_code=el`, post-filter non-Greek/Latin output.**  
Not viable. `language_code` is a hint; the model may still produce Italian or French text. There is no per-word `detected_language` field to filter on post-hoc. You cannot reliably identify "third language" words from the response schema alone.

**Option 2 — Two parallel requests (`language_code=el` + `language_code=en`), pick higher-confidence segment.**  
Technically possible using `language_probability` on the top-level response, but this is a coarse whole-file score, not a per-segment score. For mixed bilingual content neither single-language request will be fully correct. This approach doubles API cost and is not recommended.

**Option 3 — Omit `language_code` (auto-detect), post-filter by per-segment `detected_language`.**  
Not viable as described. No per-segment `detected_language` field exists in the response.

**Option 4 — `additional_formats` (SRT/VTT) for segmented output with language-per-segment.**  
The `additional_formats` parameter requests alternative output formats (SRT, VTT, etc.) of the same transcription. These are format conversions of the same `words[]` data and do not add a per-segment language field. This does not solve language disambiguation.

**Option 5 — `keyterms[]` biasing toward Greek + English vocabulary.**  
This is the most actionable partial mitigation available in the current API. Sending a `keyterms` list of common Greek words and domain-specific terms (names, product terms) biases the model toward recognising those terms correctly and reduces the chance of phonetically similar Italian/French substitutions. This does not hard-lock to two languages but materially reduces language confusion. Keyterms incur a +20% cost surcharge when more than 100 terms are provided; the first 100 terms are described as the core prompting set in the docs.

**Best available combination for this user's scenario:**

1. Set `language_code` to **null** (omit the field entirely). This enables Scribe v2's native auto-detection and code-switching, which is documented to handle mixed-language audio correctly.
2. Provide `keyterms` with a vocabulary of 20–50 domain-specific Greek terms and proper nouns most likely to be confused with other Romance languages (e.g. names, places, technical vocabulary).
3. Enable `diarize=true` and optionally `num_speakers=2` (as a hint if typically 2 speakers are present).
4. Client-side: group consecutive words with the same `speaker_id` into turn blocks and insert speaker-change markers in the displayed transcript.
5. Client-side language post-filter (limited option): detect runs of text using Unicode block analysis (Greek block: U+0370–U+03FF, U+1F00–U+1FFF; Latin block: U+0000–U+024F). If a contiguous word run is entirely in a non-Greek/non-Latin script or contains an unexpected language-marker, flag it. This is heuristic and imperfect but is the only client-side option given the absence of a per-word `detected_language` field.

---

## Recommended Fix for `macrec-ui`

### Question A — Diarization: why speaker turns are not visible in the UI

The API is returning `speaker_id` per word correctly when `diarize=true` is set. The root cause of the "wall of text" output is that no client-side grouping is performed. The `ElevenLabsTranscriptionProvider.transcribe(...)` method receives a flat `words[]` array and concatenates `word.text` values without inspecting `speaker_id` transitions.

**Fix:** After receiving the response, iterate `words[]` and emit a new speaker-turn block each time `speaker_id` changes:

```swift
// Post-processing in ElevenLabsTranscriptionProvider.transcribe(...)
// (illustrative Swift logic — adapt to actual model types)
var turns: [(speakerId: String, text: String)] = []
var currentSpeaker: String? = nil
var buffer = ""

for word in response.words {
    guard let sid = word.speakerId, word.type == "word" || word.type == "spacing" else {
        buffer += word.text
        continue
    }
    if sid != currentSpeaker {
        if let cs = currentSpeaker, !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            turns.append((speakerId: cs, text: buffer.trimmingCharacters(in: .whitespaces)))
        }
        currentSpeaker = sid
        buffer = word.text
    } else {
        buffer += word.text
    }
}
if let cs = currentSpeaker, !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
    turns.append((speakerId: cs, text: buffer.trimmingCharacters(in: .whitespaces)))
}
```

**Parameters to verify in `ElevenLabsConfig.swift`:**  
Confirm that the request already sends `diarize: true`. Consider exposing `diarizationThreshold: Double?` (range 0.1–0.4, default omitted) and `numSpeakers: Int?` (range 1–32, default omitted) as optional config fields. For two-person recordings, `numSpeakers = 2` provides a useful hint.

### Question C — Language confusion: no multi-language allow-list exists

There is no `language_codes[]`, `additional_languages[]`, or equivalent parameter in the Scribe v2 API as of 2026-05-01. The only mitigation available without breaking API changes is:

1. **Remove any hardcoded `language_code` from the request** (set to `nil`/omit). Auto-detect is the correct mode for bilingual Greek/English audio. If `ElevenLabsConfig.swift` currently defaults `languageCode` to a non-nil value, this default must be removed or made explicitly nullable with `nil` meaning "auto".

2. **Add a `keyterms: [String]` field to `ElevenLabsConfig.swift`**, populated with 20–50 Greek-domain terms the user commonly says. Pass this array as the `keyterms` form field in the multipart POST. This is the only documented parameter that biases toward a specific vocabulary without locking out other languages.

3. **Document the limitation** to the user: third-language output (Italian, French) cannot be eliminated via API parameters alone; the current API has no allow-list mechanism.

---

## Assumptions and Uncertainties

| Item | Confidence | Notes |
|---|---|---|
| `speaker_id` format is `speaker_N` (not GUIDs) | HIGH | Confirmed by docs example and SDK schema |
| No `segments[]` / `utterances[]` array in response | HIGH | Not present in `SpeechToTextChunkResponseModel` |
| `language_code` is a hint, not a hard lock | HIGH | API docs language + third-party evidence |
| No multi-language allow-list parameter exists | HIGH | Exhaustive check of API reference and SDK |
| `scribe_v2_realtime` does not support diarization | HIGH | Explicitly stated in multiple sources |
| Behaviour of `language_code=el` on English words | LOW | Not documented; behaviour is inferred |
| Max speakers for `scribe_v2` batch is 32 vs 48 | MEDIUM | API reference says 32; some third-party sources say 48; official reference takes precedence |

---

## References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | ElevenLabs API Reference — Create transcript | https://elevenlabs.io/docs/api-reference/speech-to-text/convert | All request parameters, `num_speakers`, `diarize`, `diarization_threshold`, `detect_speaker_roles`, `keyterms`, `language_code` definitions |
| 2 | ElevenLabs Capabilities — Speech to Text | https://elevenlabs.io/docs/overview/capabilities/speech-to-text | Official JSON response example with `words[]`, `speaker_id`, `language_code`, `language_probability` |
| 3 | ElevenLabs Models Overview | https://elevenlabs.io/docs/overview/models | `scribe_v2`, `scribe_v2_realtime`, `scribe_v1` model IDs and language support counts |
| 4 | ElevenLabs Python SDK — `SpeechToTextChunkResponseModel` | https://github.com/elevenlabs/elevenlabs-python/blob/main/src/elevenlabs/types/speech_to_text_chunk_response_model.py | Authoritative top-level response schema fields |
| 5 | ElevenLabs Python SDK — `SpeechToTextWordResponseModel` | https://github.com/elevenlabs/elevenlabs-python/blob/main/src/elevenlabs/types/speech_to_text_word_response_model.py | Authoritative per-word schema: `speaker_id`, `logprob`, `characters`, `type` |
| 6 | ElevenLabs Changelog — 2026-01-12 | https://elevenlabs.io/docs/changelog/2026/1/12 | Scribe v2 launch, keyterm prompting added, entity detection added |
| 7 | ElevenLabs Changelog — 2025-11-21 | https://elevenlabs.io/docs/changelog/2025/11/21 | `include_timestamps`, `quota_exceeded` event for Scribe |
| 8 | ElevenLabs — Keyterm prompting guide | https://elevenlabs.io/docs/eleven-api/guides/cookbooks/speech-to-text/batch/keyterm-prompting | Keyterms usage, limits (1000 batch / 50 realtime), cost surcharge |
| 9 | ElevenLabs — Realtime STT product page | https://elevenlabs.io/realtime-speech-to-text | `scribe_v2_realtime` latency, diarization exclusion, language support |
| 10 | LiveKit Agents — GitHub Issue #3759 | https://github.com/livekit/agents/issues/3759 | Evidence that `language_code` defaults to "en" in frameworks, confirming it is not hard-locked by the API |
| 11 | ElevenLabs Realtime API Reference | https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime | WebSocket session config parameters (page JS-rendered; confirmed via web search) |
