---
topic: ElevenLabs Speech-to-Text (Scribe v2) — Wire Schema
researched_at: "2026-04-29"
researcher: research-agent
related_plan: docs/design/plan-007-additional-stt-engines.md
related_investigation: docs/reference/investigation-additional-stt-engines.md
verification_status: CONFIRMED — all claims backed by live ElevenLabs docs as of 2026-04-29
---

# ElevenLabs Speech-to-Text (Scribe v2) — Wire Schema Reference

## Overview

ElevenLabs Speech-to-Text exposes a **batch REST endpoint** (`POST /v1/speech-to-text`)
that accepts `multipart/form-data` and returns a JSON transcript with word-level
timestamps, optional diarization, and optional entity detection. A **realtime
WebSocket** variant (`scribe_v2_realtime`, GA since 2025-11-11) also exists but is
deferred to plan-007.

Source: [https://elevenlabs.io/docs/api-reference/speech-to-text/convert](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)

---

## 1. Endpoint URL

```
POST https://api.elevenlabs.io/v1/speech-to-text
```

**Verification (2026-04-29)**: The path `/v1/speech-to-text` is the current canonical
path. No versioned alias (`/v2/...`) exists as of this date.

**Region-specific endpoints**: No regional subdomains (`api.us.elevenlabs.io`,
`api.eu.elevenlabs.io`) appear in any public documentation. EU Data Residency is an
Enterprise-tier feature managed through account settings, not a URL variation. The
single global endpoint above is used by all tiers.

Source: [https://elevenlabs.io/docs/api-reference/introduction](https://elevenlabs.io/docs/api-reference/introduction)

---

## 2. Authentication

### Header

```
xi-api-key: {YOUR_API_KEY}
```

The key is generated at `https://elevenlabs.io/app/settings/api-keys`. It is a
workspace-scoped credential — multiple keys can exist per account.

### Auth Error Responses

| HTTP | `error_code` | `error_type` | Meaning |
|------|-------------|-------------|---------|
| 401 | `invalid_api_key` | `authentication_error` | Key is syntactically valid but not recognized |
| 401 | `missing_api_key` | `authentication_error` | `xi-api-key` header absent |
| 401 | `invalid_authorization_header` | `authentication_error` | Header malformed |
| 401 | `unauthorized` | `authentication_error` | Auth required (catch-all) |
| 403 | `insufficient_permissions` | `authorization_error` | Feature not available on current plan |
| 403 | `feature_not_available` | `authorization_error` | Scribe model not accessible at tier |
| 403 | `subscription_required` | `authorization_error` | Free tier feature gate |

Error JSON shape (FastAPI-flavored, but ElevenLabs uses its own schema):
```json
{
  "detail": {
    "status": "invalid_api_key",
    "message": "The provided API key is invalid."
  }
}
```

Source: [https://elevenlabs.io/docs/eleven-api/resources/errors](https://elevenlabs.io/docs/eleven-api/resources/errors),
[https://help.elevenlabs.io/hc/en-us/articles/19572237925521-API-Error-Code-400-or-401](https://help.elevenlabs.io/hc/en-us/articles/19572237925521-API-Error-Code-400-or-401)

---

## 3. Request Body — `multipart/form-data`

The endpoint accepts **only** `multipart/form-data`. There is no JSON+base64
alternative for the file payload.

### 3.1 Required Fields

| Field | Type | Notes |
|-------|------|-------|
| `model_id` | `string` (enum) | **Required**. Current GA values: `scribe_v1`, `scribe_v2`. Use `scribe_v2` for all new integrations. |

### 3.2 Audio Source (mutually exclusive — exactly one required)

| Field | Type | Notes |
|-------|------|-------|
| `file` | binary (file part) | Audio or video file. Max 3.0 GB. Min 100 ms audio length. |
| `cloud_storage_url` | `string` (URL) | **Deprecated** as of 2026-04. Max 2 GB. HTTPS only. |
| `source_url` | `string` (URL) | Replacement for `cloud_storage_url`. Supports HTTPS, YouTube, TikTok, other video hosts. |

Exactly one of `file`, `cloud_storage_url`, or `source_url` must be provided.

### 3.3 Optional Fields — Transcription Behavior

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `language_code` | `string` or `null` | `null` (auto-detect) | **ISO-639-1** (`en`) **or ISO-639-3** (`eng`) — both are accepted. Confirmed: the docs explicitly state "An ISO-639-1 or ISO-639-3 language_code". Auto-detect when `null`. |
| `tag_audio_events` | `boolean` | `true` | Annotates non-speech sounds: `(laughter)`, `(footsteps)`, `(music)`, etc. Appear as `type: "audio_event"` words. |
| `timestamps_granularity` | `string` (enum) | `word` | Allowed: `word`, `character`. Note: `segment` is **NOT** a documented value. `character` provides character-level timestamps within each word. |
| `no_verbatim` | `boolean` | `false` | If `true`, removes filler words, false starts, non-speech sounds. **Scribe v2 only.** |
| `temperature` | `double` or `null` | model-default | Range `0–2`. Higher = more diverse output. Omit for deterministic default. |
| `seed` | `integer` or `null` | `null` | Range `0–2147483647`. Best-effort determinism. |
| `file_format` | `string` (enum) | `other` | `pcm_s16le_16` or `other`. Use `pcm_s16le_16` for 16-bit PCM, 16 kHz, mono, little-endian — produces lower latency. |

### 3.4 Optional Fields — Diarization

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `diarize` | `boolean` | `false` | Enable speaker attribution. Each word gets a `speaker_id`. |
| `num_speakers` | `integer` or `null` | `null` (model max) | Range `1–32`. Hint for speaker count. Ignored when `diarization_threshold` is set. |
| `diarization_threshold` | `double` or `null` | model-default (~0.22) | Range `0.1–0.4`. Higher = fewer predicted speakers. Only valid when `diarize=true` and `num_speakers=null`. |
| `detect_speaker_roles` | `boolean` | `false` | Labels speakers as `agent` / `customer` instead of `speaker_0` / `speaker_1`. Requires `diarize=true`. Cannot combine with `use_multi_channel`. **+10% cost surcharge.** |

### 3.5 Optional Fields — Multi-Channel

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `use_multi_channel` | `boolean` | `false` | Each audio channel transcribed independently. Up to 5 channels. Returns `transcripts` object (not `text`). Each channel billed at full audio duration. Cannot combine with `detect_speaker_roles`. |

### 3.6 Optional Fields — Entity Detection / Redaction

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `entity_detection` | `string` or `[string]` or `null` | `null` | Detect entities. Value: `"all"`, a category string, or array of entity types. Categories: `"pii"`, `"phi"`, `"pci"`, `"other"`, `"offensive_language"`. **+30% cost surcharge.** |
| `entity_redaction` | `string` or `[string]` or `null` | `null` | Redact entities. Same format as `entity_detection`; must be a subset of it. When set, `entities` field is omitted from response. **+30% cost surcharge.** |
| `entity_redaction_mode` | `string` | `enumerated_entity_type` | How redacted text appears. Options: `redacted` → `{REDACTED}`, `entity_type` → `{ENTITY_TYPE}`, `enumerated_entity_type` → `{ENTITY_TYPE_N}`. |

#### Entity Categories and Types (56 total)

| Type key | Category | Regulatory frameworks |
|----------|----------|-----------------------|
| `name`, `name_given`, `name_family` | `pii` | CPRA, GDPR, HIPAA |
| `dob` | `pii` | CPRA, GDPR, HIPAA |
| `email_address` | `pii` | CPRA, GDPR, HIPAA |
| `phone_number` | `pii` | CPRA, GDPR, HIPAA |
| `ssn` | `pii` | CPRA, GDPR, HIPAA |
| `location_address`, `location_city`, `location_zip` | `pii` | CPRA, GDPR, HIPAA |
| `location_coordinate`, `location_country`, `location_state` | `pii` | GDPR, HIPAA |
| `ip_address` | `pii` | CPRA, GDPR, HIPAA |
| `credit_card`, `credit_card_expiration`, `cvv` | `pci` | CPRA, GDPR, HIPAA |
| `bank_account` | `pci` | CPRA, GDPR, HIPAA |
| `healthcare_number` | `phi` | CPRA, GDPR, HIPAA |
| `date`, `date_interval` | `phi` | HIPAA |
| `driver_license`, `passport_number`, `vehicle_id` | `pii` | CPRA, GDPR, HIPAA |
| `gender_sexuality`, `physical_attribute`, `origin` | `pii` (sensitive) | CPRA, GDPR Sensitive |
| `username`, `password`, `account_number` | `pii` | CPRA, GDPR |
| `occupation`, `age` | `pii` | GDPR, HIPAA |
| `url`, `filename` | `other` | — |
| `cardinal`, `ordinal`, `percent`, `time`, `money`, `event` | `other` | — |
| `numerical_pii` | `pii` | CPRA, GDPR, HIPAA |
| `name_medical_professional` | `pii` | CPRA, GDPR, HIPAA |
| `offensive_language` | `offensive_language` | — |

Source: [https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/entity-detection](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/entity-detection)

### 3.7 Optional Fields — Additional Formats

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `additional_formats` | `[object]` | `[]` | Request the transcript returned in supplemental formats (e.g., SRT, VTT). Each object specifies a format. Note: as of 2026-04-29, the exact sub-object schema is not publicly documented in the API reference — it is visible in the UI export (TXT, DOCX, PDF, JSON, SRT, VTT, HTML) but the programmatic request sub-object format is **unverified**. See §11 Open Questions. |

### 3.8 Optional Fields — Keyterms (Hot-word Boost)

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `keyterms` | `[string]` | `[]` | Up to 1,000 terms. Max 50 chars each. Max 5 words per term (after normalisation). Disallowed chars: `< > { } [ ] \`. When >100 keyterms provided, minimum billable duration is 20 seconds per request. **+20% cost surcharge per audio hour.** |

### 3.9 Optional Fields — Webhook / Async

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `webhook` | `boolean` | `false` | If `true`, returns early (`SpeechToTextWebhookResponseModel` with `request_id` only). Full transcript delivered to registered webhook URL. |
| `webhook_id` | `string` or `null` | `null` | Specific webhook to target. Only valid when `webhook=true`. If `null`, sends to all STT-configured webhooks. |
| `webhook_metadata` | `string` or `map` or `null` | `null` | Custom correlation data included in webhook payload. JSON string, max depth 2, max 16 KB. |

### 3.10 Optional Fields — Logging

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `enable_logging` | `boolean` (query param) | `true` | Set to `false` for Zero Retention mode (no log/transcript storage). **Enterprise customers only.** Passed as query parameter, not form field. |

---

## 4. Complete `curl` Examples

### Minimal Happy Path (file upload, `scribe_v2`)

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "model_id=scribe_v2" \
  -F "file=@/path/to/recording.wav;type=audio/wav"
```

### With Diarization + Entity Detection

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "model_id=scribe_v2" \
  -F "file=@/path/to/recording.m4a;type=audio/m4a" \
  -F "language_code=en" \
  -F "diarize=true" \
  -F "num_speakers=2" \
  -F "timestamps_granularity=word" \
  -F "tag_audio_events=false" \
  -F "entity_detection=pii"
```

### Async Webhook Mode

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "model_id=scribe_v2" \
  -F "file=@/path/to/long_recording.m4a;type=audio/m4a" \
  -F "webhook=true" \
  -F 'webhook_metadata={"job_id":"rec-20260429-001"}'
```

### PCM Fast-Path (pre-encoded 16-bit 16kHz mono WAV — lower latency)

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "model_id=scribe_v2" \
  -F "file_format=pcm_s16le_16" \
  -F "file=@/path/to/recording_16k_mono.wav;type=audio/wav"
```

---

## 5. Swift `URLRequest` Construction (pseudo-code reference)

```swift
// multipart/form-data boundary
let boundary = "ElevenLabsBoundary-\(UUID().uuidString)"
var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
request.httpMethod = "POST"
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

var body = Data()
// Helper: append text field
func appendField(_ name: String, _ value: String) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(value)\r\n".data(using: .utf8)!)
}
// Helper: append file field
func appendFile(_ name: String, filename: String, mimeType: String, data: Data) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n".data(using: .utf8)!)
}

appendField("model_id", "scribe_v2")
appendField("language_code", "en")          // optional
appendField("diarize", "false")             // optional
appendField("timestamps_granularity", "word") // optional
appendFile("file", filename: "recording.wav", mimeType: "audio/wav", data: audioData)
body.append("--\(boundary)--\r\n".data(using: .utf8)!)
request.httpBody = body

let (data, response) = try await URLSession.shared.data(for: request)
```

**MIME types for macrec formats:**

| macrec format | MIME type for `Content-Type` |
|--------------|------------------------------|
| `.m4a` (AAC) | `audio/m4a` or `audio/mp4` |
| `.wav` | `audio/wav` |
| `.caf` | **NOT officially listed** — see §8 and §11 |

---

## 6. Response Shape

### 6.1 Synchronous Success — `SpeechToTextChunkResponseModel`

HTTP 200 with `Content-Type: application/json`.

```json
{
  "language_code": "en",
  "language_probability": 0.99,
  "text": "Hello, this is a test recording.",
  "words": [
    {
      "text": "Hello",
      "start": 0.0,
      "end": 0.5,
      "type": "word",
      "speaker_id": "speaker_0"
    },
    {
      "text": ",",
      "start": 0.5,
      "end": 0.52,
      "type": "spacing",
      "speaker_id": "speaker_0"
    },
    {
      "text": "(laughter)",
      "start": 1.2,
      "end": 2.1,
      "type": "audio_event",
      "speaker_id": "speaker_0"
    }
  ],
  "entities": [
    {
      "text": "John Smith",
      "type": "name",
      "start_char": 10,
      "end_char": 20
    }
  ]
}
```

**Field catalogue:**

| Field | Type | Present when |
|-------|------|-------------|
| `language_code` | `string` | Always |
| `language_probability` | `float` (0–1) | Always |
| `text` | `string` | Always (single-channel) |
| `words[]` | `array` | Always |
| `words[].text` | `string` | Always |
| `words[].start` | `float` (seconds) | Always |
| `words[].end` | `float` (seconds) | Always |
| `words[].type` | `"word"` \| `"spacing"` \| `"audio_event"` | Always |
| `words[].speaker_id` | `string` (`"speaker_0"`, `"speaker_1"`, …) | When `diarize=true` |
| `words[].channel_index` | `integer` | When `use_multi_channel=true` |
| `entities[]` | `array` | When `entity_detection` is set (and `entity_redaction` is NOT set) |
| `entities[].text` | `string` | When `entity_detection` is set |
| `entities[].type` | `string` (entity type key) | When `entity_detection` is set |
| `entities[].start_char` | `integer` | When `entity_detection` is set |
| `entities[].end_char` | `integer` | When `entity_detection` is set |

**Fields NOT in the response** (common misconceptions):

- `transcription_id` — not present in current docs; use `request_id` from webhook.
- `created_at` / `duration_seconds` — not present in synchronous response.
- `model_version` — not returned.
- `additional_formats[]` in the response body — unverified; see §11.

### 6.2 Multi-Channel Response — `MultichannelSpeechToTextResponseModel`

When `use_multi_channel=true`, the top-level object has a `transcripts` key instead of `text`:

```json
{
  "language_code": "en",
  "language_probability": 0.99,
  "transcripts": [
    { "channel_index": 0, "text": "...", "words": [...] },
    { "channel_index": 1, "text": "...", "words": [...] }
  ]
}
```

### 6.3 Webhook Early-Return Response — `SpeechToTextWebhookResponseModel`

When `webhook=true`, the synchronous HTTP response contains only:

```json
{
  "request_id": "some-uuid-123"
}
```

The full transcript arrives asynchronously at the registered webhook endpoint.

### 6.4 Webhook POST Payload (async delivery)

```json
{
  "type": "speech_to_text_transcription",
  "event_timestamp": 1745900000,
  "data": {
    "request_id": "some-uuid-123",
    "webhook_metadata": { "job_id": "rec-20260429-001" },
    "transcription": {
      "language_code": "en",
      "language_probability": 0.98,
      "text": "Hello world!",
      "words": [...]
    }
  }
}
```

Webhook signature header: `elevenlabs-signature`. Verified via HMAC-SHA256 using the
webhook secret configured in ElevenLabs dashboard settings.

Source: [https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/webhooks](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/webhooks)

---

## 7. Error Response Shape

All errors follow the same envelope:

```json
{
  "detail": {
    "status": "error_code_slug",
    "message": "Human-readable description."
  }
}
```

Full error code matrix:

| HTTP | `detail.status` | `detail.error_type` | Trigger |
|------|----------------|--------------------|---------| 
| 400 | `bad_request` | `invalid_request` | Malformed request body |
| 400 | `invalid_content_type` | `invalid_request` | Missing/wrong Content-Type |
| 400 | `invalid_audio` | `validation_error` | Corrupt or unreadable audio |
| 400 | `invalid_audio_format` | `validation_error` | Unsupported format |
| 400 | `audio_too_short` | `validation_error` | Audio < 100 ms |
| 400 | `invalid_file_type` | `validation_error` | Non-audio file type |
| 401 | `invalid_api_key` | `authentication_error` | Bad key |
| 401 | `missing_api_key` | `authentication_error` | No `xi-api-key` header |
| 402 | `insufficient_credits` | `payment_required` | Account out of credits |
| 403 | `feature_not_available` | `authorization_error` | Plan does not include feature |
| 403 | `subscription_required` | `authorization_error` | Paid plan required |
| 413 | `request_too_large` | `invalid_request` | File > 3.0 GB |
| 422 | `invalid_parameters` | `validation_error` | Field value out of range or invalid |
| 422 | `unsupported_model` | `validation_error` | Unknown `model_id` |
| 422 | `audio_too_long` | `validation_error` | Audio exceeds 4.5 hour limit |
| 429 | `rate_limit_exceeded` | `rate_limit_error` | Too many requests / concurrent limit |
| 429 | `concurrent_limit_exceeded` | `rate_limit_error` | `detail.message` = "too_many_concurrent_requests" |
| 429 | `system_busy` | `rate_limit_error` | Platform congestion |
| 500 | `internal_error` | `internal_error` | Unexpected server error |
| 503 | `service_unavailable` | `service_unavailable` | Planned or unplanned downtime |
| 503 | `maintenance` | `service_unavailable` | Scheduled maintenance |

Source: [https://elevenlabs.io/docs/eleven-api/resources/errors](https://elevenlabs.io/docs/eleven-api/resources/errors),
[https://help.elevenlabs.io/hc/en-us/articles/19571824571921-API-Error-Code-429](https://help.elevenlabs.io/hc/en-us/articles/19571824571921-API-Error-Code-429)

---

## 8. Swift Error Enum Mapping

```swift
enum ElevenLabsSTTError: Error, LocalizedError {
    case invalidApiKey                       // 401: invalid_api_key / missing_api_key
    case insufficientCredits                 // 402: insufficient_credits
    case planFeatureGate(feature: String)    // 403: feature_not_available / subscription_required
    case fileTooLarge                        // 413: request_too_large (> 3 GB)
    case audioTooLong                        // 422: audio_too_long (> 4.5 hrs)
    case unsupportedFormat                   // 400/422: invalid_audio_format / invalid_file_type
    case invalidParameter(field: String, message: String) // 422: invalid_parameters
    case rateLimited(retryAfterSec: Double?) // 429: rate_limit_exceeded / concurrent_limit_exceeded
    case serverError(code: Int)              // 500/503
    case networkFailure(underlying: Error)   // URLError
    case decodingFailure(underlying: Error)  // JSONDecoder error on 200 body
}
```

Mapping logic:
- Parse `detail.status` from the error JSON.
- `retryAfterSec`: ElevenLabs does not return a `Retry-After` header — use exponential
  backoff with jitter (start 1 s, double, cap 32 s) for `429` responses.
  For `concurrent_limit_exceeded`, queue rather than retry.

---

## 9. Rate Limits, Concurrency Headers, and Pricing

### 9.1 Rate-Limit Response Headers

The following headers are confirmed in official documentation (as of 2026-04-29):

| Header | Description |
|--------|-------------|
| `current-concurrent-requests` | Number of your active concurrent requests right now |
| `maximum-concurrent-requests` | Your plan's cap |

Note: Headers `x-character-count`, `x-character-count-remaining`,
`xi-current-concurrency`, `xi-concurrency-limit` appear in community articles and
older SDK references but are **not confirmed in current official docs**. The correct
names are as listed above. Verify in code when the key is in hand.

The introduction page mentions `x-character-count` and `request-id` for TTS cost
tracking; whether identical headers apply to STT responses is **unconfirmed** — see §11.

Source: [https://help.elevenlabs.io/hc/en-us/articles/33472885290129](https://help.elevenlabs.io/hc/en-us/articles/33472885290129)

### 9.2 STT Concurrency Limits by Plan

Source: [https://help.elevenlabs.io/hc/en-us/articles/33472885290129-How-many-Speech-to-Text-requests-can-I-make-and-can-I-increase-it](https://help.elevenlabs.io/hc/en-us/articles/33472885290129-How-many-Speech-to-Text-requests-can-I-make-and-can-I-increase-it)

| Plan | STT Batch Concurrency | Realtime STT Concurrency |
|------|-----------------------|--------------------------|
| Free | 8 | 6 |
| Starter | 12 | 9 |
| Creator | 20 | 15 |
| Pro | 40 | 30 |
| Scale | 60 | 45 |
| Business | 60 | 45 |
| Enterprise | Elevated (custom) | Elevated (custom) |

**Internal parallelism** for long files (Scribe v1/v2 batch only):
Files > 8 minutes are chunked internally and transcribed in parallel.
Formula: `min(4, ceil(duration_seconds / 480))`.
- 15-minute file → concurrency = 2
- 120-minute file → concurrency = 4 (cap)

### 9.3 File Size and Duration Limits

| Limit | Value | HTTP status on breach |
|-------|-------|-----------------------|
| Max file size (upload) | **3.0 GB** | 413 `request_too_large` |
| Max file size (`cloud_storage_url`) | **2.0 GB** (deprecated) | 413 |
| Max audio duration | **4.5 hours** | 422 `audio_too_long` |
| Min audio duration | **100 ms** | 400 `audio_too_short` |

### 9.4 Pricing (Verified 2026-04-29)

Source: [https://elevenlabs.io/pricing/api](https://elevenlabs.io/pricing/api)

| Model | Per audio hour | Per audio minute (approx) | Extra: entity detection | Extra: keyterms | Extra: detect_speaker_roles |
|-------|---------------|---------------------------|------------------------|----------------|----------------------------|
| `scribe_v1` | $0.22 | ~$0.0037 | +$0.07/hr (+30%) | +$0.05/hr (+20%) | N/A |
| `scribe_v2` | $0.22 | ~$0.0037 | +$0.07/hr (+30%) | +$0.05/hr (+20%) | +10% of base |
| `scribe_v2_realtime` | $0.39 | ~$0.0065 | (not documented) | (available) | N/A |

**Free-tier inclusion**: 4 hours 30 minutes of Scribe v1/v2 batch transcription; 2 hours
30 minutes of Scribe v2 Realtime (per API pricing page as of 2026-04-29).

---

## 10. Supported Audio Formats

Source: [https://help.elevenlabs.io/hc/en-us/articles/15754340124305-What-audio-formats-do-you-support](https://help.elevenlabs.io/hc/en-us/articles/15754340124305-What-audio-formats-do-you-support)

| Format | Extension | MIME type to send | macrec support |
|--------|-----------|------------------|----------------|
| WAV | `.wav` | `audio/wav` | YES — primary format |
| M4A (AAC container) | `.m4a` | `audio/m4a` or `audio/mp4` | YES |
| AAC (bare) | `.aac` | `audio/aac` | YES (macrec can produce) |
| MP3 | `.mp3` | `audio/mpeg` | No (macrec doesn't produce) |
| FLAC | `.flac` | `audio/flac` | No |
| OGG | `.ogg` | `audio/ogg` | No |
| OPUS | `.opus` | `audio/opus` | No |
| AIFF | `.aiff` | `audio/aiff` | No |
| WebM | `.webm` | `audio/webm` | No |
| **CAF** | `.caf` | — | **NOT listed** — must convert before upload |

The docs say "All major audio and video formats are supported" but the explicit enumerated
list does not include CAF. The `AudioWAVEncoder` in `MacrecCore` (16 kHz mono 16-bit PCM
WAV) will produce a valid file that the `pcm_s16le_16` fast-path can leverage directly.

**Recommended wire format for macrec integration**: 16-bit PCM WAV with `file_format=pcm_s16le_16` for lowest latency, or M4A for smallest file size.

---

## 11. Webhook / Async Option (Detailed)

The ElevenLabs STT API supports an async webhook flow for all file sizes.

**Setup steps:**
1. Register a webhook endpoint at `https://elevenlabs.io/app/settings/webhooks`.
2. Set auth method: `HMAC` (recommended) or `OAuth`.
3. Enable the webhook for "Speech-to-Text" events.
4. In each API call, set `webhook=true`.

**Verification signature** (when HMAC is configured):
- Header on incoming webhook POST: `elevenlabs-signature`
- Algorithm: HMAC-SHA256 using the webhook secret shown in dashboard
- The SDK's `webhooks.constructEvent(payload, signature, secret)` handles this.
- Raw: `HMAC-SHA256(key=webhook_secret, message=raw_request_body)` → hex-encode → compare.

**Failure behaviour**: Retries up to 5 times (0 s, 30 s, 2 min, 8 min, 30 min + ±10% jitter).
Auto-disabled after 10 consecutive failures if no success in 7 days.

**Retry deduplication**: The `request_id` in `data.request_id` is stable across retries.
Handlers must be idempotent.

Source: [https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/webhooks](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/webhooks),
[https://elevenlabs.io/docs/eleven-api/resources/webhooks](https://elevenlabs.io/docs/eleven-api/resources/webhooks)

---

## 12. Realtime WebSocket Status (plan-007 scope)

**Confirmed**: ElevenLabs exposes a realtime STT WebSocket endpoint for `scribe_v2_realtime`.
GA since 2025-11-11. Latency ~150 ms first-partial. 90+ languages. Priced at $0.39/hr.

API reference: [https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)

Wire protocol details (raw WebSocket URL, binary frame layout, JSON event envelope)
are SDK-mediated and not fully documented in the public API reference.

**Decision (plan-007)**: ElevenLabs is implemented as **batch-only** in plan-007 v1.
`scribe_v2_realtime` is captured as a plan-007 follow-up as recommended in the
investigation document. This aligns with investigation finding #2 and refined-request
Assumption A-5 (now partially refuted but intentionally deferred).

---

## 13. SDK Reference (No Official Swift SDK)

ElevenLabs does **not** publish an official Swift SDK. The two official SDKs are:
- Python: `pip install elevenlabs` → `client.speech_to_text.convert(...)`
- JavaScript: `npm install @elevenlabs/elevenlabs-js` → `client.speechToText.convert(...)`

The Python SDK argument names match the form-field names documented above
(`model_id`, `language_code`, `diarize`, `num_speakers`, `timestamps_granularity`,
`tag_audio_events`, `entity_detection`, `keyterms`, `webhook`, `webhook_id`,
`webhook_metadata`, `no_verbatim`, `temperature`, `seed`, `use_multi_channel`,
`detect_speaker_roles`, `diarization_threshold`, `entity_redaction`,
`entity_redaction_mode`, `file_format`, `source_url`).

This confirms the field names are correct for Swift `URLComponents` + multipart body
construction without an SDK.

Source: [https://elevenlabs.io/docs/api-reference/introduction](https://elevenlabs.io/docs/api-reference/introduction),
[https://elevenlabs.io/docs/api-reference/speech-to-text/convert](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)

---

## 14. Open Questions / Verify in Code

Items the public docs leave ambiguous or unconfirmed as of 2026-04-29:

| # | Question | Confidence | Impact |
|---|----------|-----------|--------|
| OQ-1 | **Exact response headers for rate-limit monitoring.** Docs confirm `current-concurrent-requests` and `maximum-concurrent-requests`. Older references mention `x-character-count`, `xi-current-concurrency`. Verify actual header names in first live call. | LOW | Medium — affects monitoring dashboard |
| OQ-2 | **`additional_formats` request field sub-object schema.** The field appears in the API reference but the exact object shape (file_format enum values, encoding options) is not publicly documented. The UI exports SRT/VTT but whether these are requestable via API parameter is unconfirmed. | LOW | Low for plan-007 (not needed for basic batch flow) |
| OQ-3 | **CAF format acceptance.** The docs say "all major audio and video formats" but the enumerated list excludes CAF. The `AudioWAVEncoder` (WAV 16 kHz) is the safe path. Verify by uploading a CAF in a test call. | MEDIUM | Low — WAV path is safe fallback |
| OQ-4 | **`Retry-After` header presence on 429.** Docs do not mention this header for STT. Assume absent and use exponential backoff. | MEDIUM | Low — backoff is the fallback anyway |
| OQ-5 | **`request_id` field in synchronous (non-webhook) 200 response.** The webhook response shape includes `request_id`; whether the synchronous shape also returns it for correlation logging is unclear from docs. | MEDIUM | Low for v1 — only needed for audit trail |
| OQ-6 | **`timestamps_granularity=character` exact shape.** Docs say it "provides character-level timestamps per word" — unclear if this means an additional `characters[]` array in each word object or a different flattened schema. | MEDIUM | Low for plan-007 (word granularity is sufficient) |
| OQ-7 | **`enable_logging=false` query param for enterprise users.** Confirm it is a URL query parameter, not a form field. Docs say "query parameter" but this is a multipart endpoint. | MEDIUM | Medium for privacy/enterprise users |

---

## Assumptions & Scope

| Assumption | Confidence | Impact if wrong |
|------------|-----------|----------------|
| Endpoint path `/v1/speech-to-text` is stable and not renamed between scribe_v1/v2 | HIGH | Would break all requests — easy to detect on first compile+test |
| Both `scribe_v1` and `scribe_v2` are GA and accessible on all paid tiers | HIGH | Plan-007 would need a model availability check |
| `language_code` accepts both ISO-639-1 and ISO-639-3 | HIGH | Confirmed verbatim in API docs |
| `timestamps_granularity` values are `word` and `character` only (not `segment`) | HIGH | Investigation flagged `segment` as a possible value; docs show only `word`/`character` |
| CAF is not an accepted input format | MEDIUM | If CAF is silently accepted, no conversion step is needed for macrec's third format |
| Concurrency limits in §9.2 table are current as of 2026-04-29 | MEDIUM | ElevenLabs updates tier caps without versioning — re-verify before shipping |
| Error envelope uses `detail.status` + `detail.message` consistently | HIGH | Confirmed by errors doc and SDK internals |

---

## References

| # | Source | URL | Information gathered |
|---|--------|-----|---------------------|
| 1 | ElevenLabs API Reference — Convert transcript | https://elevenlabs.io/docs/api-reference/speech-to-text/convert | All request fields, response shapes, 422 error |
| 2 | ElevenLabs API Reference — Introduction | https://elevenlabs.io/docs/api-reference/introduction | Auth header, SDK install, TTS tracking headers |
| 3 | ElevenLabs Docs — Speech-to-Text capability | https://elevenlabs.io/docs/overview/capabilities/speech-to-text | Response JSON example with words[], speaker_id |
| 4 | ElevenLabs Docs — Speech-to-Text (alternate URL) | https://elevenlabs.io/docs/capabilities/speech-to-text | Confirmed words[] schema |
| 5 | ElevenLabs Errors reference | https://elevenlabs.io/docs/eleven-api/resources/errors | Full error code table with slugs and types |
| 6 | ElevenLabs Webhooks reference | https://elevenlabs.io/docs/eleven-api/resources/webhooks | Webhook events, retry schedule, auto-disable logic |
| 7 | ElevenLabs — Async STT webhook guide | https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/webhooks | Full webhook payload shape, signature verification |
| 8 | ElevenLabs — Entity detection guide | https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/entity-detection | All 56 entity types with regulatory frameworks |
| 9 | ElevenLabs API Pricing | https://elevenlabs.io/pricing/api | Scribe v1/v2 $0.22/hr, realtime $0.39/hr, surcharge rates |
| 10 | ElevenLabs — STT concurrency limits help article | https://help.elevenlabs.io/hc/en-us/articles/33472885290129 | Per-plan concurrency table for STT batch and realtime |
| 11 | ElevenLabs — General concurrency help article | https://help.elevenlabs.io/hc/en-us/articles/14312733311761 | TTS concurrency table; link to STT-specific article |
| 12 | ElevenLabs — API error 429 help article | https://help.elevenlabs.io/hc/en-us/articles/19571824571921-API-Error-Code-429 | 429 messages: too_many_concurrent_requests / system_busy |
| 13 | ElevenLabs — API error 400/401 help article | https://help.elevenlabs.io/hc/en-us/articles/19572237925521-API-Error-Code-400-or-401 | xi-api-key typo guidance, 401 behaviour |
| 14 | ElevenLabs — Audio formats | https://help.elevenlabs.io/hc/en-us/articles/15754340124305 | Confirmed: AAC, AIFF, OGG, MP3, OPUS, WAV, FLAC, M4A, WebM; CAF not listed |
| 15 | ElevenLabs Pricing (main) | https://elevenlabs.io/pricing | Plan tier names and included hours |
| 16 | ElevenLabs Realtime STT reference | https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime | Existence of scribe_v2_realtime WebSocket (plan-007 scope) |
| 17 | WebSearch — Scribe v2 pricing 2026 | via WebSearch | Confirmed $0.22/hr batch, $0.39/hr realtime, 93.5% FLEURS accuracy |
| 18 | WebSearch — Rate limits / concurrency 2026 | via WebSearch | Confirmed current-concurrent-requests header names |
