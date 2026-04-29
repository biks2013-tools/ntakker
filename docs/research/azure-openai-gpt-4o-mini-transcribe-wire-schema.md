# Azure OpenAI `gpt-4o-mini-transcribe` — Batch REST Wire Schema

**Purpose**: Deterministic reference for the Swift planner writing
`plan-007-additional-stt-engines.md` Phase A. Everything a Swift engineer
needs to build `URLRequest` construction, multipart-body assembly,
response decoding, error mapping, and retry logic without further
ambiguity.

**Verification date**: 2026-04-29  
**Primary sources**: Microsoft Learn reference docs, OpenAI speech-to-text
guide, Azure pricing page, Azure What's New log.

---

## 1. Endpoint URL Pattern

```
POST https://{resource-name}.openai.azure.com/openai/deployments/{deployment-name}/audio/transcriptions?api-version={api-version}
```

| Component | Value / Description |
|---|---|
| `resource-name` | The Azure OpenAI resource name (not the full domain — just the subdomain label, e.g. `myaoi`) |
| `deployment-name` | The name of the deployment the user created in Azure AI Foundry (e.g. `gpt-4o-mini-transcribe`). This is **not** the model name. Users choose this name freely. |
| `api-version` | See table below |

### Recommended `api-version` values

| Version | Type | Notes |
|---|---|---|
| `2024-10-21` | **GA** | Last stable release; covers audio transcriptions. Use for production if new model features are not required. |
| `2025-03-01-preview` | Preview | First version to support `gpt-4o-mini-transcribe` via REST POST. **Recommended for this integration.** |
| `2025-04-01-preview` | Preview | Latest preview as of 2026-04-29; adds WebSocket/Realtime transcription (`intent=transcription`). REST batch still works. |

**Decision for plan-007**: Use `2025-03-01-preview` for REST batch. The
model is not available at all on `2024-10-21` GA; the preview version is
required. Log a note to bump to a future GA version once audio models
graduate from preview.

Source: [Azure OpenAI reference (GA)](https://learn.microsoft.com/en-us/azure/ai-services/openai/reference),
[Azure OpenAI reference (preview)](https://learn.microsoft.com/en-us/azure/ai-services/openai/reference-preview)

---

## 2. Authentication

### v1: API Key (selected for plan-007 per Assumption A-7)

```
api-key: {AZURE_OPENAI_API_KEY}
```

The `api-key` header is the only required authentication header for v1.
No `Authorization` header is needed when using API key mode.

### v2 (deferred): Microsoft Entra ID Bearer Token

```
Authorization: Bearer {Azure_OpenAI_Auth_Token}
```

Token must be scoped to `https://cognitiveservices.azure.com` (classic
portal) or `https://ai.azure.com/.default` (Foundry portal). Generate
via `az account get-access-token --resource https://cognitiveservices.azure.com`.

Source: [Azure OpenAI reference-preview authentication section](https://learn.microsoft.com/en-us/azure/ai-services/openai/reference-preview)

### 401 vs 403 distinction

| Status | Meaning | Typical `message` |
|---|---|---|
| **401** | API key missing, invalid, or expired | `"Unauthorized. Access token is missing, invalid, audience is incorrect (https://cognitiveservices.azure.com), or have expired."` |
| **403** | Valid credentials but insufficient RBAC role or network restriction | `"Access denied due to Virtual Network/Firewall rules."` or role-based error |

Both 401 and 403 can also carry:
```json
{ "statusCode": 401, "message": "..." }
```
(APIM gateway format — note `statusCode` at root, not nested under `error`)

---

## 3. Request: Multipart Form-Data Body

`Content-Type: multipart/form-data; boundary=<boundary>`

All fields are sent as form parts. The `file` part carries the binary audio.

### Complete field table

| Field name | Part type | Required | Allowed values | Default | Notes |
|---|---|---|---|---|---|
| `file` | file part (binary) | YES | See §5 for MIME types | — | File extension determines Content-Type. For m4a use `audio/m4a`. |
| `model` | text | **YES on Azure** | The deployment name string | — | On Azure, the `model` field **must equal the deployment name** (e.g. `"gpt-4o-mini-transcribe"`). It is NOT omitted. This differs from OpenAI direct where `model` selects the model variant; on Azure the deployment is already scoped by the URL path, but the field is still required for API conformance. |
| `language` | text | No | ISO-639-1 code (`en`, `el`, `fr`, …) | Auto-detect | BCP-47 / ISO-639-1 two-letter codes. If omitted the model auto-detects. Supported languages: Afrikaans, Arabic, Armenian, Azerbaijani, Belarusian, Bosnian, Bulgarian, Catalan, Chinese, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, Galician, German, Greek, Hebrew, Hindi, Hungarian, Icelandic, Indonesian, Italian, Japanese, Kannada, Kazakh, Korean, Latvian, Lithuanian, Macedonian, Malay, Marathi, Maori, Nepali, Norwegian, Persian, Polish, Portuguese, Romanian, Russian, Serbian, Slovak, Slovenian, Spanish, Swahili, Swedish, Tagalog, Tamil, Thai, Turkish, Ukrainian, Urdu, Vietnamese, Welsh (98 total trained, ≥50 listed here have <50% WER). |
| `prompt` | text | No | Freeform string | — | Context / vocabulary hint. For `gpt-4o-mini-transcribe` this is a GPT-style prompt (unlike Whisper's style-matching prompt). E.g. `"The conversation is about Apple ScreenCaptureKit and AVFoundation APIs."` |
| `response_format` | text | No | `json` \| `text` | `json` | **Only `json` and `text` are supported for `gpt-4o-mini-transcribe`.** `verbose_json`, `srt`, and `vtt` are Whisper-only and are **rejected** by this model with a 400 error. |
| `temperature` | text (float) | No | 0.0 – 1.0 | 0 | Higher = more random. 0 = log-probability auto-increase. |
| `timestamp_granularities[]` | text (repeated) | No | `word` \| `segment` | — | **NOT SUPPORTED** for `gpt-4o-mini-transcribe`. These require `verbose_json`, which this model does not support. Sending these fields does not cause an error but they are silently ignored (or may cause a 400 — treat as unsupported). |
| `stream` | text (bool) | No | `true` \| `false` | `false` | If `true`, response is SSE stream of `transcript.text.delta` / `transcript.text.done` events. The batch (non-streaming) path sets this to `false` (default). |
| `include[]` | text (repeated) | No | `logprobs` | — | If `include[]=logprobs`, the response JSON includes `logprobs` array (per-token log probabilities). Only meaningful with `response_format=json`. |

**Important Azure-specific note on `model` field**: The Azure API spec
requires the `model` form field to match the deployment name. Omitting it
may return a 400. Always include it.

Source: [OpenAI Speech-to-Text guide](https://platform.openai.com/docs/guides/speech-to-text),
[OpenAI API reference — createTranscription](https://platform.openai.com/docs/api-reference/audio/createTranscription),
[Azure What's New — December 2025 ASR update](https://learn.microsoft.com/en-us/azure/ai-services/openai/whats-new)

---

## 4. Response Shapes

### 4.1 `response_format=json` (default, recommended)

HTTP 200, `Content-Type: application/json`

```json
{
  "text": "Hello, this is a test recording of the ScreenCaptureKit integration."
}
```

Optional additional field when `include[]=logprobs`:

```json
{
  "text": "Hello, this is a test recording.",
  "logprobs": [
    { "token": "Hello",  "logprob": -0.00007, "bytes": [72, 101, 108, 108, 111] },
    { "token": ",",      "logprob": -0.0014,  "bytes": [44] },
    ...
  ]
}
```

### 4.2 `response_format=text`

HTTP 200, `Content-Type: text/plain`

```
Hello, this is a test recording of the ScreenCaptureKit integration.
```

Plain text with no JSON envelope.

### 4.3 `verbose_json` — NOT SUPPORTED

Sending `response_format=verbose_json` returns HTTP 400:
```json
{
  "error": {
    "code": "invalid_request_error",
    "message": "response_format 'verbose_json' is not supported for model 'gpt-4o-mini-transcribe'. Supported formats: json, text.",
    "type": "invalid_request_error",
    "param": "response_format"
  }
}
```

### 4.4 `srt` / `vtt` — NOT SUPPORTED

Same pattern as `verbose_json` — 400 with `invalid_request_error`.

### 4.5 Timestamp / word-level data

Not available for `gpt-4o-mini-transcribe`. No `segments[]` or `words[]`
arrays are returned in any response format. If the caller needs
segment-level timestamps, they must use `whisper-1` instead, which
supports `verbose_json` with `timestamp_granularities[]=segment`.

Source: [OpenAI speech-to-text guide — Transcriptions section](https://platform.openai.com/docs/guides/speech-to-text),
[LangChain4j issue #3604 confirming format limitations](https://github.com/langchain4j/langchain4j/issues/3604)

---

## 5. Supported Audio Formats and File Limits

### Accepted MIME types / extensions

| Extension | MIME type to send | Notes |
|---|---|---|
| `.mp3` | `audio/mpeg` | |
| `.mp4` | `audio/mp4` | |
| `.mpeg` | `audio/mpeg` | |
| `.mpga` | `audio/mpeg` | |
| `.m4a` | `audio/m4a` | **This project's primary format.** Confirmed supported. |
| `.wav` | `audio/wav` | **This project's secondary format.** Confirmed supported. |
| `.webm` | `audio/webm` | |
| `.flac` | `audio/flac` | |
| `.ogg` | `audio/ogg` | |

**Note**: `caf` (Core Audio Format, produced by AVFoundation) is **NOT** in
the supported list. The Swift encoder should not send CAF directly. Convert
to m4a or wav before upload. The project already records m4a and wav by
default, so no conversion is needed for the default output layout.

### File size limit

**25 MB hard cap** (same as Whisper). Exceeding this returns HTTP 413
with `error.code = "file_too_large"`. The Azure error message confirmed:
`"File is too large. Maximum file size is 25 MB."` No duration limit is
explicitly documented separately from the size cap; at typical m4a bitrates
(~128 kbps) 25 MB corresponds to roughly 25 minutes of audio.

Source: [OpenAI speech-to-text guide](https://platform.openai.com/docs/guides/speech-to-text),
search results confirming 25 MB limit

---

## 6. Complete `curl` Examples

### 6.1 Happy path — `response_format=json`

```bash
ENDPOINT="https://myaoi.openai.azure.com"
DEPLOYMENT="gpt-4o-mini-transcribe"
API_VERSION="2025-03-01-preview"
API_KEY="<your-azure-openai-api-key>"
AUDIO_FILE="/path/to/recording.m4a"

curl -s -X POST \
  "${ENDPOINT}/openai/deployments/${DEPLOYMENT}/audio/transcriptions?api-version=${API_VERSION}" \
  -H "api-key: ${API_KEY}" \
  -F "file=@${AUDIO_FILE};type=audio/m4a" \
  -F "model=${DEPLOYMENT}" \
  -F "response_format=json" \
  -F "language=en"
```

Expected response:
```json
{ "text": "Hello, this is a test recording." }
```

### 6.2 With prompt and logprobs

```bash
curl -s -X POST \
  "${ENDPOINT}/openai/deployments/${DEPLOYMENT}/audio/transcriptions?api-version=${API_VERSION}" \
  -H "api-key: ${API_KEY}" \
  -F "file=@${AUDIO_FILE};type=audio/m4a" \
  -F "model=${DEPLOYMENT}" \
  -F "response_format=json" \
  -F "language=en" \
  -F "temperature=0.0" \
  -F "prompt=Transcript of a software engineering meeting covering ScreenCaptureKit and AVFoundation." \
  -F "include[]=logprobs"
```

### 6.3 Plain text response

```bash
curl -s -X POST \
  "${ENDPOINT}/openai/deployments/${DEPLOYMENT}/audio/transcriptions?api-version=${API_VERSION}" \
  -H "api-key: ${API_KEY}" \
  -F "file=@${AUDIO_FILE};type=audio/m4a" \
  -F "model=${DEPLOYMENT}" \
  -F "response_format=text"
```

### 6.4 `verbose_json` (will fail — for testing error handling)

```bash
curl -s -X POST \
  "${ENDPOINT}/openai/deployments/${DEPLOYMENT}/audio/transcriptions?api-version=${API_VERSION}" \
  -H "api-key: ${API_KEY}" \
  -F "file=@${AUDIO_FILE};type=audio/m4a" \
  -F "model=${DEPLOYMENT}" \
  -F "response_format=verbose_json"
# Returns HTTP 400 — use this to verify .unsupportedFormat handling
```

---

## 7. Error Response Shape

All errors follow a JSON envelope. Two formats appear depending on which
layer returns the error:

### Format A — API layer (most errors)

```json
{
  "error": {
    "code": "invalid_api_key",
    "message": "Incorrect API key provided: abc*****xyz. You can find your API key at https://portal.azure.com.",
    "type": "authentication_error",
    "param": null,
    "inner_error": null
  }
}
```

### Format B — APIM gateway layer (some 401 / network errors)

```json
{
  "statusCode": 401,
  "message": "Unauthorized. Access token is missing, invalid, audience is incorrect (https://cognitiveservices.azure.com), or have expired."
}
```

The Swift decoder must handle **both** formats. Suggested approach:
try decoding `error.code` first; if `error` key is absent, fall back to
reading top-level `statusCode` + `message`.

### Error field semantics

| JSON field | Type | Description |
|---|---|---|
| `error.code` | String | Machine-readable error code. Primary dispatch key. |
| `error.message` | String | Human-readable description. Surface in user remediation. |
| `error.type` | String | Broad category (`authentication_error`, `invalid_request_error`, `rate_limit_error`, `server_error`). |
| `error.param` | String? | Which request parameter caused the error (if applicable). |
| `error.inner_error` | Object? | Nested Azure-specific detail. May contain `code` and `content_filter_result`. |

---

## 8. HTTP Error Code Matrix → Swift `AzureSTTError` Cases

| HTTP Status | `error.code` strings observed | Swift case | Retry? | Notes |
|---|---|---|---|---|
| **400** | `invalid_request_error`, `invalid_value`, `invalid_audio`, `unsupported_format` | `.invalidRequest(message: String)` | No | Bad params, unsupported `response_format`, malformed audio |
| **400** | `file_too_large` | `.fileTooLarge` | No | File exceeds 25 MB |
| **400** | `invalid_audio_format` | `.unsupportedAudioFormat` | No | e.g. CAF sent directly |
| **401** | `invalid_api_key`, `Unauthorized` | `.invalidApiKey` | No | Check `AZURE_OPENAI_API_KEY` and expiry |
| **403** | `PermissionDenied`, `AccessDenied`, VNet firewall | `.permissionDenied` | No | RBAC role missing or network policy block |
| **404** | `DeploymentNotFound`, `ResourceNotFound` | `.deploymentNotFound` | No | Deployment name mismatch or wrong region |
| **408** | `request_timeout` (rare) | `.networkTimeout` | Yes (backoff) | Server-side read timeout |
| **413** | `file_too_large` | `.fileTooLarge` | No | Also triggered at HTTP level before body is parsed |
| **415** | `unsupported_media_type` | `.unsupportedAudioFormat` | No | Wrong `Content-Type` on file part |
| **429** | `rate_limit_exceeded`, `quota_exceeded` | `.rateLimited(retryAfterSec: Double?)` | Yes | Read `Retry-After` header (see §9) |
| **500** | `server_error`, `internal_server_error` | `.serverError(statusCode: Int)` | Yes (limited) | Transient; retry up to 3× with backoff |
| **503** | `service_unavailable` | `.serverError(statusCode: Int)` | Yes (limited) | Service degradation; retry up to 3× |
| Network | (no HTTP) | `.networkError(underlying: Error)` | Yes | DNS failure, TLS, URLSession timeout |

### Swift enum sketch

```swift
enum AzureSTTError: Error, Sendable {
    case invalidApiKey
    case permissionDenied
    case deploymentNotFound
    case fileTooLarge                          // 413 or 400/file_too_large
    case unsupportedAudioFormat                // 415 or 400/unsupported_format
    case invalidRequest(message: String)       // other 400s
    case rateLimited(retryAfterSec: Double?)   // 429
    case networkTimeout                        // 408
    case serverError(statusCode: Int)          // 500, 503
    case networkError(underlying: Error)       // URLSession errors
    case unexpectedResponse(statusCode: Int, body: Data)
}
```

Sources: [Azure Q&A — 401 error shape](https://learn.microsoft.com/en-us/answers/questions/2069293/failed-to-call-azure-openai-api),
[Search result — error JSON shapes](https://learn.microsoft.com/en-us/answers/questions/2263455/azure-ai-services-getting-403-error),
[OpenAI error codes guide](https://developers.openai.com/api/docs/guides/error-codes)

---

## 9. Retry Semantics

### 429 Rate-Limit Response Headers

The server returns:

```
HTTP/1.1 429 Too Many Requests
Retry-After: 10
x-ratelimit-remaining-requests: 0
x-ratelimit-remaining-tokens: 0
```

The `Retry-After` header value is in **seconds** (integer). If absent,
default to 10 seconds before first retry.

### 429 Body Example

```json
{
  "error": {
    "code": "429",
    "message": "Requests to the Azure OpenAI Whisper Deployments Operation have exceeded call rate limit of your current OpenAI S0 pricing tier. Please retry after 10 seconds."
  }
}
```

### Recommended Retry Policy

| Attempt | Wait before retry | Notes |
|---|---|---|
| 1st retry | `Retry-After` seconds (default 10 s) | Read header first |
| 2nd retry | 2× previous wait + jitter (±20%) | Exponential backoff |
| 3rd retry | 4× base + jitter | |
| Give up | — | Surface `.rateLimited` to caller |

- Apply only to: 429, 408, 500, 503, and `URLError.timedOut` / `URLError.networkConnectionLost`
- Do NOT retry: 400, 401, 403, 404, 413, 415
- Maximum retry attempts: **3** (configurable)
- Jitter: ±20% of computed wait to avoid thundering herd

Source: Search results confirming `Retry-After` header and 429 semantics

---

## 10. Response Headers to Log

Azure adds several headers to every response. The Swift logger
(`TranscriptSidecarWriter` or a dedicated `RequestLogger`) should capture:

| Header | Description | Use |
|---|---|---|
| `apim-request-id` | Unique ID assigned by Azure API Management. Correlates with Azure Monitor / Log Analytics entries. | Include in error logs for support escalation |
| `x-request-id` | Alternative request ID (may duplicate `apim-request-id` or be set by a different layer). | Log alongside `apim-request-id` |
| `x-ms-region` | Azure region that served the request (e.g. `East US 2`, `Sweden Central`). | Log to verify region pinning |
| `x-ratelimit-remaining-requests` | Remaining request quota in the current window. | Log to detect approaching rate limit |
| `x-ratelimit-remaining-tokens` | Remaining token quota in the current window. | Log for capacity planning |
| `Retry-After` | Seconds to wait before retrying on 429. | Drive retry logic |

Example real-world header block:
```
apim-request-id: c2253873-ed2d-4ce3-85e5-7807e82f5ad0
x-ms-region: East US 2
x-ratelimit-remaining-tokens: 991828
x-ratelimit-remaining-requests: 59
```

Source: [Journey of the Geek — Azure OpenAI response headers](https://journeyofthegeek.com/2024/05/17/azure-openai-service-the-value-of-response-headers-and-log-correlation/)

---

## 11. Region Availability

As of 2026-04-29, `gpt-4o-mini-transcribe` is available via the
**Global Standard** deployment type. This means requests route through
Microsoft's global infrastructure, with compute physically served from
East US 2 (primary) and potentially other Global Standard locations.

| Deployment type | Regions | Data residency |
|---|---|---|
| Global Standard | East US 2 (confirmed); other Global Standard nodes | Data may be processed in any Global Standard node — **no strict geo pinning** |
| Regional / Data Zone | Not yet confirmed as available for this model | Would allow EU data zone or single-region pinning |

**EU/GDPR caveat**: As of the verification date, there is no confirmed
Regional or Data Zone deployment of `gpt-4o-mini-transcribe`. Customers
requiring EU data residency should verify current availability via the
[Azure AI Foundry quota page](https://ai.azure.com) before committing to
this model for compliance-sensitive workloads.

Source: [Azure Q&A — EU data zone availability](https://learn.microsoft.com/en-us/answers/questions/2259083/gpt-4o-transcribe-availability-within-eu-data-zone),
[MS Foundry blog announcement](https://devblogs.microsoft.com/foundry/get-started-azure-openai-advanced-audio-models/),
[Region support page](https://learn.microsoft.com/en-us/azure/foundry/reference/region-support)

---

## 12. Pricing

| Model | Rate | Per hour equivalent |
|---|---|---|
| `gpt-4o-mini-transcribe` | **$0.003 / minute** | $0.18 / hour |
| `gpt-4o-transcribe` (full) | $0.006 / minute | $0.36 / hour |
| `whisper-1` | $0.006 / minute | $0.36 / hour |

Billing is by the minute, rounded to the nearest second. This rate applies
to the OpenAI-direct price; Azure OpenAI pricing may carry a small regional
or SKU uplift — verify current Azure-specific rates on the
[Azure OpenAI pricing page](https://azure.microsoft.com/en-us/pricing/details/azure-openai/).

**Note**: The Azure pricing page renders token prices dynamically with
JavaScript and does not expose audio transcription per-minute rates in the
HTML source. The $0.003/min figure is confirmed from OpenAI's own pricing
page and multiple independent sources; treat it as a best-estimate baseline
for Azure (Global Standard SKU) pending explicit verification against the
Azure pricing calculator.

Source: [OpenAI API pricing page](https://openai.com/api/pricing/),
[OpenAI transcription pricing (CostGoat)](https://costgoat.com/pricing/openai-transcription),
[TokenMix blog — gpt-4o-transcribe pricing](https://tokenmix.ai/blog/gpt-4o-transcribe-speech-to-text-api-guide-2026)

---

## 13. Data Privacy and Training Policy

### "Not used to train" commitment

When using Azure OpenAI Service:

1. **Customer data is NOT sent to OpenAI's systems.** Azure OpenAI runs OpenAI models within Microsoft's own Azure infrastructure. The endpoint `*.openai.azure.com` does not interact with OpenAI's API or ChatGPT.
2. **Audio input (prompts) and transcription output (completions) are NOT used to train or retrain** Microsoft's or OpenAI's base models. This is a contractual commitment under Microsoft's Data Processing Agreement (DPA), not just policy.
3. **Models are stateless during inference.** No prompts or outputs are stored in the model itself.
4. **Data is NOT shared with other Azure customers.**

### Data residency

- Audio data is processed in the Azure region where your Azure OpenAI resource is deployed (for Regional deployments).
- For Global Standard deployments, data may be routed to any Global Standard compute node — there is **no strict single-region pinning** at the compute layer, though Microsoft keeps data within its infrastructure.
- Logs (`apim-request-id` correlated) are stored in Azure Monitor in the resource's region.
- For abuse-monitoring content filtering, data may be temporarily held in-region (encrypted at rest, AES-256 / FIPS 140-2) and is NOT used for model training.

### Modified abuse monitoring

Organisations in healthcare, legal, or finance sectors can apply for a
modified abuse-monitoring policy that eliminates even the temporary storage
of prompts and completions for the abuse-detection step.

### Privacy disclosure copy for plan-007 §8 (R-8)

Proposed text for the one-time FR-53 disclosure dialog when the user first
selects Azure OpenAI as the transcription provider:

> "Audio will be sent to Microsoft Azure OpenAI Service for transcription.
> Microsoft contractually commits that your audio and transcripts are never
> used to train AI models and are never shared with OpenAI or other parties.
> Data is processed in the Azure region associated with your resource
> (currently Global Standard, which may route through East US 2). A
> Data Processing Agreement covers this transfer. For full details, see
> Microsoft's Azure OpenAI data privacy documentation at
> https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy
> and the Microsoft Online Services DPA at https://aka.ms/DPA."

Source: [Azure OpenAI data privacy Q&A](https://learn.microsoft.com/en-us/answers/questions/2336991/what-are-the-data-residency-privacy-rules-for-usin),
[Microsoft blog — no-training commitment](https://kurtsh.com/2025/07/27/info-microsoft-365-copilot-azure-openai-service-do-not-train-microsofts-or-openais-llms-or-other-ai-models/),
[Bright Inventions — Azure OpenAI privacy explained](https://brightinventions.pl/blog/azure-openai-service-privacy-policies-explained/)

---

## 14. WebSocket / Streaming Variant (Now in scope — Phase A2 of plan-007)

> **2026-04-29 update**: The realtime path is **no longer deferred**. It
> moved into plan-007 Phase A2; see
> `docs/research/azure-openai-realtime-transcription-wire-schema.md` for
> the full wire schema, lifecycle, error matrix, and pricing. The
> sketch below is kept for back-reference but is partially outdated —
> specifically, the example session-setup JSON below previously included
> a `"model"` field that triggers a server bug on Azure. **That field
> has been struck.**

A WebSocket-based real-time transcription endpoint exists and is supported
by `gpt-4o-mini-transcribe`:

```
wss://{resource-name}.openai.azure.com/openai/realtime?api-version=2025-04-01-preview&intent=transcription
```

Authentication: `api-key: {AZURE_OPENAI_API_KEY}` header (same as REST).

> ### ⚠️ AZURE-SPECIFIC BUG — DO NOT INCLUDE THE `model` FIELD
>
> Including `"model": "gpt-4o-mini-transcribe"` in the
> `transcription_session.update.session.input_audio_transcription`
> object causes the next item to fail with
> `conversation.item.input_audio_transcription.failed { error.type: "server_error" }`.
> The model is implied by the deployment specified at connection time.
>
> **The Swift Codable for the session config MUST OMIT the `model` field
> entirely on Azure.** This is documented in detail in the realtime
> research file's §1.5 / §4.1 and §13 (the comparison table with
> OpenAI direct).

Session setup message (corrected — `model` field stripped):

```json
{
  "type": "transcription_session.update",
  "session": {
    "input_audio_format": "pcm16",
    "input_audio_transcription": {
      "language": "en",
      "prompt": "Optional context"
    },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": 300,
      "silence_duration_ms": 200,
      "create_response": false
    },
    "input_audio_noise_reduction": { "type": "near_field" }
  }
}
```

Audio is sent as base64-encoded PCM16 chunks at **24 kHz required**
(16 kHz unconfirmed for the realtime path; the OpenAI docs and
TechCommunity blog both use 24 kHz, and the realtime research §6
treats 24 kHz as the wire requirement) mono, wrapped in
`input_audio_buffer.append` messages — text frames carrying JSON, NOT
binary frames. Events emitted:

- `session.created` — initial server hello
- `session.updated` — ack of `transcription_session.update`
- `input_audio_buffer.speech_started` / `…speech_stopped` — VAD signals
- `input_audio_buffer.committed` — utterance boundary
- `conversation.item.input_audio_transcription.delta` — incremental text
- `conversation.item.input_audio_transcription.completed` — final segment
- `conversation.item.input_audio_transcription.failed` — per-item failure
- `error` — session-level (recoverable)
- `rate_limits.updated` — quota state

The Swift implementation uses `URLSessionWebSocketTask` (Foundation).
The full Phase A2 wire schema, reconnect-with-replay flow, 60-min
session-cap handling, error matrix, and pricing live in
`docs/research/azure-openai-realtime-transcription-wire-schema.md` —
moved into plan-007 Phase A2; see
`azure-openai-realtime-transcription-wire-schema.md` for the full wire
schema.

Source: [Azure Foundry TechCommunity blog — Realtime transcription](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/real-time-speech-transcription-with-gpt-4o-transcribe-and-gpt-4o-mini-transcribe/4410353),
[OpenAI speech-to-text guide — Streaming section](https://platform.openai.com/docs/guides/speech-to-text),
`docs/research/azure-openai-realtime-transcription-wire-schema.md` (§1.5 / §4.1 — model-field bug; §6 — 24 kHz audio; §9 — reconnect; §10 — pricing)

---

## 15. Model Version and Retirement Notes

| Model ID | Version | Status | Retirement |
|---|---|---|---|
| `gpt-4o-mini-transcribe` | `2025-03-20` | Preview | Retired 2025-10-15 (already passed — do not use this pinned version) |
| `gpt-4o-mini-transcribe` | `2025-12-15` | Preview | Active as of 2026-04-29; ~50% lower WER vs prior version |

The Swift configuration should store the deployment name only (not a model
version string). The version is determined at deployment creation time in
Azure AI Foundry. Rename the deployment to track version changes if needed.

The latest model snapshot `gpt-4o-mini-transcribe-2025-12-15` offers:
- ~50% lower WER than the previous version on English benchmarks
- Improved multilingual performance (Japanese, Indic, others)
- Up to 4× fewer silence hallucinations

Source: [Azure What's New — December 2025](https://learn.microsoft.com/en-us/azure/ai-services/openai/whats-new)

---

## 16. Swift URLRequest Construction Reference

### Multipart boundary helper pattern

```swift
// Constants
let boundary = UUID().uuidString
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
request.setValue(apiKey, forHTTPHeaderField: "api-key")

// Build body
var body = Data()

// Helper: text field
func appendField(_ name: String, value: String) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(value)\r\n".data(using: .utf8)!)
}

// Helper: file field
func appendFile(_ name: String, filename: String, mimeType: String, data: Data) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n".data(using: .utf8)!)
}

appendFile("file", filename: "recording.m4a", mimeType: "audio/m4a", data: audioData)
appendField("model", value: deploymentName)
appendField("response_format", value: "json")
if let lang = language { appendField("language", value: lang) }
if let prompt = prompt { appendField("prompt", value: prompt) }

body.append("--\(boundary)--\r\n".data(using: .utf8)!)
request.httpBody = body
```

### Response header logging

```swift
if let httpResponse = response as? HTTPURLResponse {
    let apimId     = httpResponse.value(forHTTPHeaderField: "apim-request-id") ?? "nil"
    let requestId  = httpResponse.value(forHTTPHeaderField: "x-request-id") ?? "nil"
    let region     = httpResponse.value(forHTTPHeaderField: "x-ms-region") ?? "nil"
    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
    logger.info("Azure STT response: status=\(httpResponse.statusCode) apim-id=\(apimId) x-request-id=\(requestId) region=\(region)")
}
```

---

## 17. Assumptions and Uncertainties

| Claim | Confidence | Notes |
|---|---|---|
| `gpt-4o-mini-transcribe` requires `api-version=2025-03-01-preview` or later | HIGH | Confirmed from multiple sources; model not present in `2024-10-21` GA |
| `model` form field is required on Azure | MEDIUM | Azure API spec requires it; OpenAI direct may not. Include it to be safe. |
| `response_format=verbose_json` is rejected | HIGH | Confirmed from OpenAI docs and multiple developer reports |
| `verbose_json` and `srt`/`vtt` are Whisper-only | HIGH | OpenAI speech-to-text guide states this explicitly |
| `timestamp_granularities[]` silently ignored vs. 400 | LOW | Behavior not explicitly documented for this model; assume unsupported, do not send |
| Azure pricing equals OpenAI pricing ($0.003/min) | MEDIUM | Azure pricing page renders prices via JS (not scraped); OpenAI direct is $0.003/min confirmed |
| `caf` format not supported | HIGH | Not in the documented list; do not send without testing |
| `gpt-4o-mini-transcribe` not available in EU regional deployments | MEDIUM | Confirmed at announcement; may have changed since — verify before production EU deployment |
| 401 APIM format vs API format | MEDIUM | Both formats observed in practice; Swift decoder must handle both |

### Clarifying questions for the planner

1. Should the plan commit to `2025-03-01-preview` or use a config variable for `api-version` so users can pin it? (Recommended: config variable with `2025-03-01-preview` as the documented starting point — no fallback allowed per CLAUDE.md.)
2. Should `model` be the deployment name (sent explicitly) or omitted? (Recommendation: send it equal to deployment name to match Azure spec.)
3. Is logprobs support required in v1? If yes, decode the `logprobs` array in the Swift response struct.
4. What is the maximum single-file duration the project is expected to produce? (Determine whether chunking is needed — 25 MB ≈ 25 min at 128 kbps m4a.)
5. Should the plan include the WebSocket/Realtime path in a Phase A-2, or defer entirely to plan-007?

---

## References

| # | Source | URL | Information gathered |
|---|---|---|---|
| 1 | Azure OpenAI Reference (GA `2024-10-21`) | https://learn.microsoft.com/en-us/azure/ai-services/openai/reference | Endpoint pattern, auth, GA api-version |
| 2 | Azure OpenAI Reference Preview (`2025-04-01-preview`) | https://learn.microsoft.com/en-us/azure/ai-services/openai/reference-preview | Preview api-version, auth options |
| 3 | OpenAI Speech-to-Text Guide | https://platform.openai.com/docs/guides/speech-to-text | Supported formats, model capabilities, `verbose_json` restriction |
| 4 | OpenAI createTranscription API Reference | https://platform.openai.com/docs/api-reference/audio/createTranscription | Field names, types, SSE streaming format |
| 5 | Azure Foundry — Get Started with Advanced Audio Models | https://devblogs.microsoft.com/foundry/get-started-azure-openai-advanced-audio-models/ | Model availability (East US 2), `api-version=2025-03-01-preview` |
| 6 | Azure TechCommunity — Realtime Transcription | https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/real-time-speech-transcription-with-gpt-4o-transcribe-and-gpt-4o-mini-transcribe/4410353 | WebSocket URL, session config, PCM16 format, `2025-04-01-preview` |
| 7 | Azure OpenAI What's New | https://learn.microsoft.com/en-us/azure/ai-services/openai/whats-new | `gpt-4o-mini-transcribe-2025-12-15` features, retirement of `2025-03-20` |
| 8 | Azure Foundry Models page | https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure | Region availability table |
| 9 | Azure region support | https://learn.microsoft.com/en-us/azure/foundry/reference/region-support | Regional model deployment reference |
| 10 | Azure Q&A — EU data zone | https://learn.microsoft.com/en-us/answers/questions/2259083/gpt-4o-transcribe-availability-within-eu-data-zone | EU regional availability gap |
| 11 | Azure Q&A — 401 error | https://learn.microsoft.com/en-us/answers/questions/2069293/failed-to-call-azure-openai-api | 401 APIM error format |
| 12 | Azure Q&A — 403 error | https://learn.microsoft.com/en-us/answers/questions/2263455/azure-ai-services-getting-403-error | 403 error semantics |
| 13 | OpenAI error codes guide | https://developers.openai.com/api/docs/guides/error-codes | Error code vocabulary |
| 14 | Journey of the Geek — response headers | https://journeyofthegeek.com/2024/05/17/azure-openai-service-the-value-of-response-headers-and-log-correlation/ | `apim-request-id`, `x-ms-region`, `x-ratelimit-*` headers |
| 15 | OpenAI API pricing | https://openai.com/api/pricing/ | $0.003/min for gpt-4o-mini-transcribe |
| 16 | CostGoat — OpenAI transcription pricing | https://costgoat.com/pricing/openai-transcription | Pricing cross-check |
| 17 | Azure OpenAI pricing page | https://azure.microsoft.com/en-us/pricing/details/azure-openai/ | Audio model section (JS-rendered; specific rates not scraped) |
| 18 | Azure data privacy Q&A | https://learn.microsoft.com/en-us/answers/questions/2336991/what-are-the-data-residency-privacy-rules-for-usin | No-training commitment, data residency |
| 19 | Microsoft blog — no LLM training | https://kurtsh.com/2025/07/27/info-microsoft-365-copilot-azure-openai-service-do-not-train-microsofts-or-openais-llms-or-other-ai-models/ | Contractual no-training guarantee |
| 20 | Bright Inventions — Azure OpenAI privacy | https://brightinventions.pl/blog/azure-openai-service-privacy-policies-explained/ | Abuse monitoring, data processing details |
| 21 | LangChain4j issue #3604 | https://github.com/langchain4j/langchain4j/issues/3604 | `verbose_json` rejection confirmed |
| 22 | Azure OpenAI model retirements | https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/model-retirements | Version retirement dates |
