# Apple Cloud / Online Speech-to-Text API Investigation

**Date:** 2026-05-01
**Scope:** Determining whether Apple exposes any network-callable (REST, gRPC, WebSocket) STT API for third-party developers, and whether that API supports Greek (`el-GR`).
**Verdict (TL;DR):** Apple has **no public cloud/network STT API**. The closest Apple-owned mechanism that routes audio to Apple servers is `SFSpeechRecognizer` with `requiresOnDeviceRecognition = false`, which is a private Apple infrastructure call — not a public REST/gRPC endpoint a developer can call directly. It is available on macOS 14/15/26, it does support `el-GR`, but it carries a 1,000-request/hour quota and is deprecated in spirit by the new `SpeechAnalyzer` framework (macOS/iOS 26). No Apple product analogous to Google Cloud Speech-to-Text or OpenAI Whisper API exists.

---

## Q1 — Does `SFSpeechRecognizer` Have a Cloud / Server-Based Mode?

**Yes, it does — and it is still available on macOS 14, 15, and 26 (Tahoe).**

`SFSpeechRecognizer`, introduced in iOS 10 / macOS 10.15, has two internal recognition paths:

- **Server-based (cloud):** default behavior when `requiresOnDeviceRecognition = false` (which is the default). Audio is sent to Apple's private ASR infrastructure (the same backend that powers Siri and system dictation). The developer cannot bypass or directly address this endpoint — it is opaque Apple infrastructure.
- **On-device:** activated by setting `requiresOnDeviceRecognition = true` on the `SFSpeechRecognitionRequest`. Only available if `SFSpeechRecognizer.supportsOnDeviceRecognition` returns `true` for the chosen locale, which in turn requires the relevant dictation language asset to be installed by the OS.

### API Surface (macOS)

```swift
import Speech

// 1. Request authorization (shows OS dialog mentioning Apple servers)
SFSpeechRecognizer.requestAuthorization { status in
    // handle .authorized / .denied / .restricted / .notDetermined
}

// 2. Create a recognizer for Greek
let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "el-GR"))!

// 3. Create a request (server-based = default; on-device = opt-in)
let request = SFSpeechAudioBufferRecognitionRequest()
request.requiresOnDeviceRecognition = false   // explicitly choose server path
request.shouldReportPartialResults = true

// 4. Start recognition
let task = recognizer.recognitionTask(with: request) { result, error in
    guard let result = result else { return }
    print(result.bestTranscription.formattedString)
}

// Feed audio buffers:
// task's request.append(buffer) from AVAudioEngine tap
```

Source: [SFSpeechRecognizer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/sfspeechrecognizer)

### TCC / Entitlement Requirements

- The `NSSpeechRecognitionUsageDescription` key must be present in `Info.plist` (or equivalent for a CLI / SwiftPM app).
- `SFSpeechRecognizer.requestAuthorization(_:)` must be called and the user must grant the prompt before any recognition can start.
- On macOS the system-level dialog explicitly states that recordings will be sent to Apple's servers even when `requiresOnDeviceRecognition = false`. There is no API to suppress that language.

Source: [Apple Developer Forums — SFSpeechRecognizer on macOS](https://developer.apple.com/forums/thread/702323)

### Rate Limits (Server Path)

- **1,000 requests per hour, per device** (not per app). The limit applies regardless of audio length.
- Each request allows a maximum of **one minute of audio**.
- Additionally, Apple documentation states each app "may be throttled globally based on the number of requests it makes per day," but no per-day numeric limit is published officially.
- Exceeding the limit produces `kAFAssistantErrorDomain Code=203 "Quota limit reached"`.

Source: [Technical Q&A QA1951 — Speech Framework Rate Limits](https://developer.apple.com/library/archive/qa/qa1951/_index.html)

### Does `el-GR` (Greek) Appear in the Server-Side Supported Locale Set?

**Yes.** The `SFSpeechRecognizer.supportedLocales()` static method returns the full set of locales the framework can handle (on-device _and_ server-side combined). An independently verified runtime dump of `supportedLocales()` confirms `el-GR` is present in the list alongside ~57 other locales.

Full list (as of 2022–2025 runtime dump, GitHub Gist):
`ar-SA, ca-ES, cs-CZ, da-DK, de-AT, de-CH, de-DE, el-GR, en-AU, en-CA, en-GB, en-ID, en-IE, en-IN, en-NZ, en-PH, en-SA, en-SG, en-US, en-ZA, es-CL, es-CO, es-ES, es-MX, es-US, fi-FI, fr-BE, fr-CA, fr-CH, fr-FR, he-IL, hr-HR, hu-HU, id-ID, it-CH, it-IT, ja-JP, ko-KR, ms-MY, nb-NO, nl-BE, nl-NL, pl-PL, pt-BR, pt-PT, ro-RO, ru-RU, sk-SK, sv-SE, th-TH, tr-TR, uk-UA, vi-VN, yue-CN, zh-CN, zh-HK, zh-TW`

Source: [SFSpeechRecognizer supportedLocales runtime dump (GitHub Gist)](https://gist.github.com/bilawal-liaqat/03e3cefa255dca43ea4ae45f527b6ada)

**Important caveat:** Apple does not publish separate lists for "server-side supported" vs. "on-device supported". The `supportedLocales()` return value is the union. On-device support for `el-GR` is **not guaranteed** — Greek is not confirmed as a downloadable on-device dictation asset on macOS. The server path for `el-GR` is, however, expected to work given Greek's presence in the `supportedLocales()` set.

### Does the Developer Hit the Server Endpoint Directly via HTTPS?

**No.** The Apple ASR server is not a public endpoint. `SFSpeechRecognizer` internally tunnels audio to Apple's private infrastructure using a protocol that Apple does not expose. Developers interact exclusively through the framework API; there is no REST or gRPC URL to call.

---

## Q2 — Are There Other Apple-Owned Cloud STT Products?

### Siri / SiriKit

**No direct STT API.** SiriKit (and App Intents / App Intent Domains in iOS 18+) allows apps to register intent handlers. When a user speaks to Siri, Apple's speech recognition layer converts the audio, determines intent, and dispatches a structured `INIntent` object to the app. The app receives **text** (the resolved intent), not raw audio, and cannot trigger Siri speech recognition on arbitrary audio. SiriKit is not a callable STT endpoint.

Source: [SiriKit — Apple Developer Documentation](https://developer.apple.com/documentation/sirikit/); [Bring your app to Siri — WWDC24 Session 10133](https://developer.apple.com/videos/play/wwdc2024/10133/)

### Apple Foundation Models (WWDC 2025)

**Text-only; no audio/speech input.** The Foundation Models framework (introduced WWDC 2025, macOS/iOS 26) exposes the ~3B-parameter on-device Apple Intelligence language model for text-in / text-out tasks (summarization, structured extraction, guided generation). It is fully on-device and explicitly documented as not supporting server-side models. Audio must first be transcribed (e.g., via `SFSpeechRecognizer` or `SpeechTranscriber`) before being passed to Foundation Models as text.

Source: [Meet the Foundation Models framework — WWDC25 Session 286](https://developer.apple.com/videos/play/wwdc2025/286/); [Foundation Models — Apple Developer Documentation](https://developer.apple.com/documentation/FoundationModels)

### Apple Translation Framework (macOS 14.4 / iOS 17.4+)

**Text-to-text translation only; no STT.** The `Translation` framework introduced at WWDC 2024 takes `String` input and returns translated `String` output. It has no audio or microphone input surface. Translation models run on-device via CoreML. There is no network call or cloud endpoint involved.

Source: [Meet the Translation API — WWDC24 Session 10117](https://developer.apple.com/videos/play/wwdc2024/10117/)

### Apple Intelligence / Private Cloud Compute

Apple Intelligence (iOS 18 / macOS 15+) uses Private Cloud Compute for certain LLM tasks that exceed on-device capacity. This is **not a developer-accessible API**. It is an internal Apple routing mechanism; third-party apps cannot invoke it directly.

### Any Other Apple Cloud STT Endpoint?

No App Store Connect API, iCloud API, or Apple Translate STT endpoint was found. The docs are silent on any such product.

---

## Q3 — Supported Locale List for the Server-Based `SFSpeechRecognizer` Path

Apple does not publish a separate list of "server-only supported locales." The canonical source is the runtime call `SFSpeechRecognizer.supportedLocales()`, which returns locales supported by any path (server or on-device).

`el-GR` is confirmed present in this set (see Q1 above and the GitHub Gist source).

Apple's official documentation page for `supportedLocales()` states:
> "Returns the set of locales that are supported by the speech recognizer."

Source: [supportedLocales() — Apple Developer Documentation](https://developer.apple.com/documentation/speech/sfspeechrecognizer/1649889-supportedlocales)

The docs are silent on which subset of `supportedLocales()` is handled server-side vs. on-device. Based on documented behavior and community research, on-device support is the narrower set (~10–12 locales at a given time), while the full 57-locale `supportedLocales()` set is served via Apple's cloud infrastructure for locales not available on-device.

---

## Q4 — Is `requiresOnDeviceRecognition = false` Meaningful on macOS?

**Yes — macOS uses the server-based path when `requiresOnDeviceRecognition = false`, which is the default.**

The claim that macOS only offers on-device recognition is incorrect. Apple's documentation states "always assume that performing speech recognition requires a network connection," which directly implies a network (server) path exists on macOS. The system-level authorization dialog on macOS explicitly warns that audio is sent to Apple's servers, confirming the cloud path is active.

On-device recognition on macOS requires the specific dictation language asset to be installed. If it is not installed, setting `requiresOnDeviceRecognition = true` fails with `kAFAssistantErrorDomain Code=1101 "No asset installed for language=<locale>"`. Leaving `requiresOnDeviceRecognition` at its default `false` falls back automatically to the server path, which is more broadly available.

Source: [Apple Developer Forums — Failure of speech recognition (Code 1101)](https://developer.apple.com/forums/thread/731230); [requiresOnDeviceRecognition — Apple Developer Documentation](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

### macOS-Specific Notes

- `AVAudioSession` is not available on macOS. Use `AVAudioEngine` with an `AVAudioInputNode` tap to feed audio buffers to `SFSpeechAudioBufferRecognitionRequest`.
- The authorization dialog wording cannot be suppressed even when using on-device mode.
- `SFSpeechRecognizer` is listed as available on macOS in Apple's documentation and the WWDC19 "Advances in Speech Recognition" session.

Source: [Advances in Speech Recognition — WWDC19 Session 256](https://developer.apple.com/videos/play/wwdc2019/256/)

---

## Q5 — The New SpeechAnalyzer API (macOS/iOS 26) and Where It Stands

At WWDC 2025, Apple introduced `SpeechAnalyzer` as the successor to `SFSpeechRecognizer`. Key facts relevant to this investigation:

- **Fully on-device.** The `SpeechTranscriber` model (the core of `SpeechAnalyzer`) runs entirely on-device with no server round-trip.
- **Greek is NOT in the launch locale set.** The `SpeechTranscriber.supportedLocales` set at launch (WWDC 2025 / iOS 26 beta) contains 42 locales: `ar_SA, da_DK, de_AT, de_CH, de_DE, en_AU, en_CA, en_GB, en_IE, en_IN, en_NZ, en_SG, en_US, en_ZA, es_CL, es_ES, es_MX, es_US, fi_FI, fr_BE, fr_CA, fr_CH, fr_FR, he_IL, it_CH, it_IT, ja_JP, ko_KR, ms_MY, nb_NO, nl_BE, nl_NL, pt_BR, ru_RU, sv_SE, th_TH, tr_TR, vi_VN, yue_CN, zh_CN, zh_HK, zh_TW`. **`el-GR` (Greek) is absent.**
- Apple states "more languages to come."
- The `DictationTranscriber` (fallback class within `SpeechAnalyzer`) covers the same locales as iOS 10's on-device `SFSpeechRecognizer`, removing the need for users to configure Siri/dictation manually. Whether this adds Greek on-device support is not confirmed.
- `SFSpeechRecognizer` is not formally deprecated in macOS/iOS 26 but Apple is directing developers toward `SpeechAnalyzer` for new development.
- `SpeechAnalyzer` requires macOS 26+ (this project already targets macOS 26, per Exception 002 in CLAUDE.md).

Source: [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25 Session 277](https://developer.apple.com/videos/play/wwdc2025/277/); [SpeechAnalyzer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer)

---

## Summary Verdict

Apple does **not** offer a public cloud speech-to-text API analogous to Google Cloud Speech-to-Text, AWS Transcribe, or OpenAI Whisper API. There is no REST/gRPC/WebSocket endpoint a developer can call directly to have Apple perform STT in the cloud.

The **only** mechanism by which Apple-owned infrastructure performs STT on behalf of a third-party app is through `SFSpeechRecognizer` with `requiresOnDeviceRecognition = false`, which silently routes audio to Apple's private servers via an opaque SDK layer. This is technically "cloud recognition" but it is not a public API.

---

## Recommendation for `macrec-ui`

### If Wiring `SFSpeechRecognizer` as `AppleCloudTranscriptionProvider`

This is viable with the following constraints accepted:

**Swift API:**
```swift
import Speech

class AppleCloudTranscriptionProvider {
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private let request = SFSpeechAudioBufferRecognitionRequest()

    init(locale: Locale = Locale(identifier: "el-GR")) throws {
        guard SFSpeechRecognizer.supportedLocales().contains(locale) else {
            throw TranscriptionError.localeNotSupported
        }
        guard let r = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.recognizerUnavailable
        }
        self.recognizer = r
        request.requiresOnDeviceRecognition = false  // server path
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
    }

    func start(audioEngine: AVAudioEngine) throws {
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request.append(buf)
        }
        task = recognizer.recognitionTask(with: request) { result, error in
            // handle partials and finals
        }
    }
}
```

**Entitlement / Info.plist key required:**
```
NSSpeechRecognitionUsageDescription = "macrec-ui transcribes recordings using Apple speech recognition."
```

**Quota caveats to communicate to the user:**
- 1,000 recognition requests per hour per device (shared with all other apps using `SFSpeechRecognizer` on the same machine).
- 1-minute maximum audio per request — for long recordings the provider must segment audio and submit multiple requests.
- No SLA; Apple may throttle or modify the server-side quota without notice.
- Audio is transmitted to Apple's servers; the user sees a system dialog informing them of this.

**Greek support:** `el-GR` is in `SFSpeechRecognizer.supportedLocales()`. Server-side recognition for Greek is expected to work. On-device Greek is not a reliable fallback on macOS 14/15 (missing asset problem).

### If Apple Cloud STT Is Not Sufficient

The user already has:
- **Soniox** — good multi-language streaming, worth investigating Greek support specifically (Soniox documents 20+ languages; Greek availability should be verified at [soniox.com/languages](https://soniox.com)).
- **Google Gemini Live** — already wired in `macrec-ui` v1.
- **Azure OpenAI / Azure Speech** — Azure Cognitive Services Speech supports `el-GR`.
- **ElevenLabs** — primarily TTS; their STT ("Scribe") coverage of Greek should be verified.

**Recommendation:** Wire `SFSpeechRecognizer` (server path) as `AppleCloudTranscriptionProvider` for users who want a zero-cost, privacy-familiar Apple-branded option for languages they trust Apple with. Clearly document the 1,000 req/hr quota and the 1-minute audio-segment limit in the UI. For Greek specifically, this path should work. Flag that `SpeechAnalyzer` (on-device, macOS 26, already in our deployment target) does NOT support Greek at launch and cannot be the solution for this user's immediate need.

---

## Assumptions and Scope

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| `SFSpeechRecognizer` server path is still active on macOS 26 (Tahoe beta) | MEDIUM | If Apple silently disabled the server path on macOS 26 alongside launching `SpeechAnalyzer`, the provider would fail at runtime. Verify with `recognizer.isAvailable` at startup. |
| `el-GR` in `supportedLocales()` means the server path accepts Greek | HIGH | It is possible Apple removed Greek from the server path without removing it from `supportedLocales()`. A real device test is required for confirmation. |
| `SpeechTranscriber.supportedLocales` at WWDC25 launch does not include Greek | HIGH | Apple could add it in a later beta/GM. Check `SpeechTranscriber.supportedLocales` at runtime on the user's device. |
| Translation framework is text-only | HIGH | This is explicitly stated in WWDC24 session 10117 and official documentation. |
| Foundation Models is text-only, on-device | HIGH | Explicitly documented in WWDC25 session 286. |

---

## References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Apple Developer Docs — SFSpeechRecognizer | https://developer.apple.com/documentation/speech/sfspeechrecognizer | API surface, `requiresOnDeviceRecognition`, `supportsOnDeviceRecognition` |
| 2 | Apple Developer Docs — SFSpeechRecognitionRequest | https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest | `requiresOnDeviceRecognition` property details |
| 3 | Apple Developer Docs — supportedLocales() | https://developer.apple.com/documentation/speech/sfspeechrecognizer/1649889-supportedlocales | Method definition |
| 4 | Apple Technical Q&A QA1951 | https://developer.apple.com/library/archive/qa/qa1951/_index.html | Official 1,000 req/hr quota, 1-min audio limit |
| 5 | Apple Developer Forums — SFSpeechRecognizer on macOS | https://developer.apple.com/forums/thread/702323 | macOS-specific behavior, AVAudioSession unavailability, server warning in dialog |
| 6 | Apple Developer Forums — Code 1101 / on-device asset failure | https://developer.apple.com/forums/thread/731230 | On-device language asset requirement, `kAFAssistantErrorDomain Code=1101` |
| 7 | Apple Developer Forums — supportsOnDeviceRecognition returns false | https://developer.apple.com/forums/thread/125969 | Unreliability of on-device flag; server is fallback |
| 8 | GitHub Gist — SFSpeechRecognizer supportedLocales runtime dump | https://gist.github.com/bilawal-liaqat/03e3cefa255dca43ea4ae45f527b6ada | Full locale list confirming `el-GR` |
| 9 | WWDC25 Session 277 — Bring advanced speech-to-text with SpeechAnalyzer | https://developer.apple.com/videos/play/wwdc2025/277/ | SpeechAnalyzer/SpeechTranscriber introduction, on-device only, launch language list |
| 10 | Apple Developer Docs — SpeechAnalyzer | https://developer.apple.com/documentation/speech/speechanalyzer | Class overview |
| 11 | Apple Developer Docs — SpeechTranscriber.supportedLocales | https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales | Launch locale list (42 locales, no Greek) |
| 12 | WWDC25 Session 286 — Meet the Foundation Models framework | https://developer.apple.com/videos/play/wwdc2025/286/ | Text-only, on-device, no audio input |
| 13 | Apple Developer Docs — Foundation Models | https://developer.apple.com/documentation/FoundationModels | Framework scope confirmation |
| 14 | WWDC24 Session 10117 — Meet the Translation API | https://developer.apple.com/videos/play/wwdc2024/10117/ | Translation framework is text-to-text only |
| 15 | WWDC19 Session 256 — Advances in Speech Recognition | https://developer.apple.com/videos/play/wwdc2019/256/ | Historical context on macOS availability of SFSpeechRecognizer |
| 16 | Apple Developer Docs — SiriKit | https://developer.apple.com/documentation/sirikit/ | SiriKit intent-based model; no raw STT API exposed |
| 17 | WWDC24 Session 10133 — Bring your app to Siri | https://developer.apple.com/videos/play/wwdc2024/10133/ | App Intent Domains; structured intent only, no STT API |
| 18 | Anton Gubarenko — iOS 26 SpeechAnalyzer Guide | https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide | Comprehensive SpeechAnalyzer walkthrough; SFSpeechRecognizer limitations summary |
| 19 | Apple Developer Docs — requiresOnDeviceRecognition | https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition | Property documentation, default = false |

### Recommended for Deep Reading

- **QA1951** (source 4): The only official Apple document that explicitly quantifies the server-side quota. Short and authoritative.
- **WWDC25 Session 277** (source 9): Confirms `SpeechAnalyzer` is the new direction, on-device only, and lists the 42 launch locales (Greek absent). Critical for deciding whether `SpeechAnalyzer` can replace `SFSpeechRecognizer` for Greek in future.
- **Developer Forums thread 731230** (source 6): Real-world evidence of on-device asset failures on macOS; confirms server path as the reliable macOS fallback.

---

## Clarifying Questions for Follow-Up

1. Should `AppleCloudTranscriptionProvider` segment audio automatically at the 1-minute boundary and stitch transcript segments, or should it surface the limit to the user as a hard constraint?
2. Should the provider surface `isAvailable` state (which can become `false` transiently when Apple's servers are unreachable) in the `macrec-ui` status UI?
3. Is the user aware that all audio transcribed via `SFSpeechRecognizer` (server path) is transmitted to Apple — and is this acceptable given the recording content (meetings, calls, system audio)?
4. Should we attempt `SpeechAnalyzer` / `DictationTranscriber` as a Greek-language on-device fallback for macOS 26, and track whether Apple adds `el-GR` to `SpeechTranscriber.supportedLocales` in a future OS update?
5. Is Soniox already confirmed to support Greek (`el-GR`) in the existing `macrec-ui` wiring, or should that be investigated separately?
