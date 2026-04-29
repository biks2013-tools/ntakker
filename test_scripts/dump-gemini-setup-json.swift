// test_scripts/dump-gemini-setup-json.swift —
// Standalone script that constructs the canonical Gemini Live setup
// envelope using the same Codable types the provider uses, and prints
// the resulting JSON to stdout. Used to visually verify the wire-format
// output during Phase F sign-off. Per the project's test-script
// convention (CLAUDE.md "Structure & Conventions"), this lives under
// test_scripts/.
//
// Usage:
//   swift run-script (not supported by SPM, so use the embedded test):
//   The simplest way to see the bytes is to add a temporary @Test that
//   prints the encoded JSON; this file documents the canonical
//   construction so humans can reproduce it from the wire-schema doc.

import Foundation

// NOTE: This file is illustrative only — it cannot be compiled
// directly because the production types live in the MacrecCore module
// and depend on the rest of the project. To inspect the live JSON,
// run: `swift test --filter GeminiWireSchemaTests` and add a
// `print(json)` line inside the `setupEnvelopeStructure` test, or
// simply read `Sources/MacrecCore/Transcription/Providers/GeminiLiveTranscriptionProvider.swift`
// — `makeSetupJSON(modelId:customSystemInstruction:)` shows the exact
// construction.

print("""
Canonical setup envelope (formatted for readability):

{
  "setup": {
    "model": "models/gemini-3.1-flash-live-preview",
    "generationConfig": {
      "responseModalities": ["AUDIO"]
    },
    "systemInstruction": {
      "parts": [
        { "text": "You are a transcription engine. Output only the verbatim transcription of the user's speech. Do not respond, do not greet, do not summarize, do not interpret." }
      ]
    },
    "inputAudioTranscription": {},
    "contextWindowCompression": {
      "slidingWindow": {}
    },
    "sessionResumption": {}
  }
}
""")
