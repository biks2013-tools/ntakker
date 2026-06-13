// Sources/NtakkerCore/Transcription/Providers/Azure/AzureOpenAIResponse.swift —
// plan-007 Phase A1 §A.5.
//
// `gpt-4o-mini-transcribe` only supports `response_format=json` and
// `response_format=text` (research §4). v1 always requests `json` so
// the response shape is the small `{ "text": "..." }` envelope.
// `verbose_json`, `srt`, and `vtt` are rejected by the model with
// HTTP 400 and are NEVER requested.

import Foundation

struct AzureOpenAIResponse: Decodable, Sendable {
    let text: String
}
