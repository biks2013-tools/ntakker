<macrec>
    <objective>
        `macrec` is a macOS-only command-line audio recording tool that captures
        the system audio submix (everything routed to the default output device,
        such as Music, Spotify, Zoom, Teams, browsers) and the microphone in a
        single synchronized recording. It is implemented in Swift on top of
        `ScreenCaptureKit` (system audio) and `AVFoundation` (microphone), and
        targets developers, podcasters, support engineers, and meeting-recording
        workflows that need to capture both sides of a conversation without
        installing a virtual audio driver. The tool produces `m4a` (AAC),
        `wav`, or `caf` (Core Audio Format) files in three layouts — `mixed`
        (single stereo file), `split` (two files, one per source), and
        `stereo-split` (single stereo file with the mic pinned to one channel
        and system audio to the other). It runs in the foreground (Ctrl-C to
        stop) or detached as a background daemon, with a companion `stop`
        subcommand for clean finalization. Optionally, foreground recordings
        can stream the captured audio in parallel to a real-time speech-to-text
        provider (Google Gemini Live in v1, opt-in via `--transcribe`) and
        write a JSONL / TXT / SRT / VTT transcript sidecar alongside the
        audio file.
    </objective>
    <command>
        macrec <subcommand> [options]
    </command>
    <info>
        ## What changed in v1.5

        > Default `--transcribe` value flipped from `none` to `apple`. Plain
        > `macrec start` now produces an on-device transcript sidecar by
        > default (Apple SpeechAnalyzer; no API key, no network). To restore
        > the old behaviour, set `MACREC_TRANSCRIBE=none` in your `.env` (or
        > pass `--transcribe none` on the CLI).
        >
        > A new provider id `apple` is now accepted alongside `gemini`
        > (and the deprecated `gemini-live` alias for `gemini`). Apple is
        > the only provider that supports comma-separated locale lists in
        > `--transcribe-language` for parallel dual-locale recognition.

        ## Overview

        `macrec` is the only first-party tool in this project so far. It
        compiles as a standalone Swift Package Manager executable (target
        `macrec`, library target `MacrecCore`) and runs on macOS 14 (Sonoma)
        and later. The command surface mirrors classic Unix audio tools: a
        small set of subcommands, a single required output flag, and a
        four-source configuration precedence chain (CLI > local `.env` > user
        `.env` > shell env).

        Subcommands at a glance:

        - `macrec start`             — begin a recording (foreground or detached).
        - `macrec stop`              — stop a recording started with `start --detach`.
        - `macrec list-devices`      — list available audio input devices.
        - `macrec check-permissions` — print Screen Recording and Microphone TCC state.

        Pipeline:

        ```
        ScreenCaptureKit (system audio)  ─┐
                                          ├─► HostClockAligner ─► BufferSummer ─► Recorder ─► .m4a / .wav / .caf
        AVFoundation     (microphone)    ─┘                          (mixed / split / stereo-split)
        ```

        ## Subcommands

        ### `start`

        Begins a recording. Stop with Ctrl-C (SIGINT) or SIGTERM in foreground
        mode, or with `macrec stop` when started with `--detach`.

        Verbatim help (from `swift run macrec start --help`):

        ```
        OVERVIEW: Begin a recording. Stop with Ctrl-C (SIGINT) or SIGTERM (foreground),
        or with 'macrec stop' (when started with --detach).

        USAGE: macrec start <options>

        OPTIONS:
          -o, --output <output>   Output file path (required).
          --format <format>       Output format (m4a | wav | caf). Default: m4a.
          --layout <layout>       Track layout (mixed | split | stereo-split). Default:
                                  mixed.
          --mic-channel <mic-channel>
                                  Stereo-split mic channel (left | right). Default:
                                  left.
          --sample-rate <sample-rate>
                                  Sample rate in Hz (44100 | 48000). Default: 48000.
          --bit-depth <bit-depth> Bit depth (16 | 24, PCM only). Default: 16.
          --bitrate <bitrate>     AAC bitrate in kbps (64-320) or bps (64000-320000).
                                  Default: 192.
          --mic-device <mic-device>
                                  Microphone device name or UID. Default: system
                                  default.
          --log-level <log-level> Log verbosity (quiet | info | debug). Default: info.
          --max-duration <max-duration>
                                  Auto-stop after N seconds. Default: run until SIGINT.
          --overwrite             Overwrite an existing output file.
          --detach                Run the recording in the background (double-fork
                                  daemon). The shell prompt returns immediately; PID is
                                  written to --pid-file. Stop with 'macrec stop'.
                                  (FR-25)
          --pid-file <pid-file>   PID file path for --detach mode. Default:
                                  ~/.tool-agents/macrec/macrec.pid. Env:
                                  MACREC_PID_FILE. (FR-25/FR-27/FR-28)
          --log-file <log-file>   Log file path for --detach mode (mode 0600, append).
                                  Default: ~/.tool-agents/macrec/macrec.log. Env:
                                  MACREC_LOG_FILE. (FR-29)
          --transcribe <provider>
                                  Live transcription provider. Default: apple
                                  (changed from `none` in v1.5 / plan-005).
                                  Allowed: none | apple | apple-cloud | gemini
                                  | soniox | whisperkit | azure |
                                  azure-openai-realtime | elevenlabs | dual.
                                  (`gemini-live` is accepted as a deprecated
                                  alias for one release; the resolver lowers
                                  it to `gemini` and logs a deprecation
                                  notice.) Pass `dual` to enable dual-mode
                                  transcription (Channel A on-device + Channel
                                  B cloud); the four --transcribe-dual-* flags
                                  below become required. Env: MACREC_TRANSCRIBE.
                                  (FR-48 / plan-003 / plan-004 / plan-005 /
                                  plan-006 / plan-007 / plan-010)
          --soniox-endpoint <url>
                                  Soniox WebSocket endpoint override (for
                                  EU/JP data residency). Default:
                                  wss://stt-rt.soniox.com/transcribe-websocket.
                                  Env: MACREC_SONIOX_ENDPOINT. (plan-006)
          --transcribe-source <source>
                                  Audio source for transcription. Default: mixed.
                                  Allowed: system | mic | mixed | both. Env:
                                  MACREC_TRANSCRIBE_SOURCE. (FR-47)
          --transcribe-format <format>
                                  Sidecar transcript format. Default: jsonl.
                                  Allowed: jsonl | txt | srt | vtt. Env:
                                  MACREC_TRANSCRIBE_FORMAT. (FR-51)
          --transcribe-model <model-id>
                                  Provider-specific model id override. Default:
                                  provider's pinned default (currently
                                  `gemini-3-flash-preview` for the
                                  `gemini` provider). Env:
                                  MACREC_TRANSCRIBE_MODEL. See "Model id"
                                  below for the allowed list and the
                                  documented HTTP-4xx fallback. (plan-003
                                  §LT-5.2 / plan-004 §9.1)
          --transcribe-language <bcp-47[,bcp-47...]>
                                  Hint the spoken-language code (BCP-47, e.g.
                                  en-US). Comma-separated values activate
                                  dual-locale parallel recognition on the
                                  `apple` provider (e.g. `en-US,el-GR`).
                                  `gemini` uses only the first hint and
                                  ignores the rest. Default: provider
                                  auto-detect. Env: MACREC_TRANSCRIBE_LANGUAGE.
          --transcribe-key-expires-at <iso-8601>
                                  Optional ISO-8601 date marking when the
                                  configured API key expires. If past, a warning
                                  is logged at start; recording is NOT blocked.
                                  Env: MACREC_TRANSCRIBE_KEY_EXPIRES_AT.
                                  (plan-003 §LT-5.2)
          --transcribe-dual-locale-a <bcp-47>
                                  Channel A (Apple on-device) BCP-47 locale,
                                  e.g. en-US. Required when --transcribe dual.
                                  No engine-layer default — missing value
                                  raises exit 64. Env:
                                  MACREC_TRANSCRIBE_DUAL_LOCALE_A. (plan-010
                                  §DT-10)
          --transcribe-dual-locale-b <bcp-47>
                                  Channel B (Apple Cloud) BCP-47 locale, e.g.
                                  el-GR. Required when --transcribe dual. No
                                  engine-layer default. Env:
                                  MACREC_TRANSCRIBE_DUAL_LOCALE_B. (plan-010
                                  §DT-10)
          --transcribe-dual-source <source>
                                  Audio source for dual-mode transcription
                                  (system | mic | mixed | both). Required when
                                  --transcribe dual. Env:
                                  MACREC_TRANSCRIBE_DUAL_SOURCE. (plan-010
                                  §DT-10)
          --transcribe-dual-format <format>
                                  Sidecar transcript format for dual mode
                                  (jsonl | txt | srt | vtt). Required when
                                  --transcribe dual. Env:
                                  MACREC_TRANSCRIBE_DUAL_FORMAT. (plan-010
                                  §DT-10)
          --version               Show the version.
          -h, --help              Show help information.
        ```

        > **Security note — no `--transcribe-key` flag exists.** API keys are
        > never accepted on the command line (they would otherwise leak into
        > shell history, `ps`, and process-tree dumps). The provider-specific
        > vendor-canonical env var (`GOOGLE_API_KEY` for `gemini`,
        > `SONIOX_API_KEY` for `soniox`, `AZURE_OPENAI_API_KEY` for `azure`
        > and `azure-openai-realtime`, `ELEVENLABS_API_KEY` for `elevenlabs`)
        > is the only accepted source, resolved through the four-tier
        > configuration chain. Recommended storage:
        > `~/.tool-agents/macrec/.env` (mode `0600`). See
        > [docs/design/configuration-guide.md](../design/configuration-guide.md)
        > §2.21 (Gemini), §2.23 (Soniox), §LT-Az (Azure batch),
        > §LT-Az-RT (Azure realtime), §LT-EL (ElevenLabs).
        >
        > **Azure-specific extras.** Both Azure providers also need
        > `AZURE_OPENAI_ENDPOINT` (e.g.
        > `https://my-resource.openai.azure.com`) and
        > `AZURE_OPENAI_DEPLOYMENT` (the user-chosen deployment name
        > backing `gpt-4o-mini-transcribe`). The api-version is
        > optional — it falls back to `2025-04-01-preview` (the
        > documented starter that covers both batch and realtime).
        >
        > **Azure realtime session boundary.** Azure caps any single
        > realtime session at **60 minutes**; the provider transparently
        > reconnects at **58 min** with a 5 s audio replay so long
        > recordings continue without user intervention. Close codes
        > 1006 / 1001 / 1011 (transient transport errors) trigger the
        > same reconnect-with-replay path with up to 3 attempts.
        >
        > **ElevenLabs concurrency cap.** Free / Starter plans cap
        > concurrent STT requests at 8. When `--transcribe-source both`
        > produces parallel mic+system requests on a free tier, the
        > provider may surface `concurrent_limit_exceeded` (HTTP 429)
        > immediately without retry — see
        > `configuration-guide.md` §LT-EL for the per-tier table.

        Examples:

        ```sh
        # 1. Minimal foreground recording into ~/recordings/test.m4a; stop with Ctrl-C.
        macrec start --output ~/recordings/test.m4a

        # 2. Record for exactly 30 s, overwriting any existing file.
        macrec start --output /tmp/sample.m4a --max-duration 30 --overwrite

        # 3. Detached background recording (returns the prompt immediately).
        #    Stop later with `macrec stop`.
        macrec start --detach --output ~/recordings/meeting.m4a --overwrite

        # 4. Two-file split layout (mic + system as separate files).
        #    Output naming is derived from --output: writes
        #    `~/recordings/podcast.mic.m4a` and `~/recordings/podcast.system.m4a`.
        macrec start --layout split --output ~/recordings/podcast.m4a

        # 5. Stereo-split with system on the left, mic on the right;
        #    use a specific mic device (find its UID with `macrec list-devices`).
        macrec start \
            --layout stereo-split --mic-channel right \
            --mic-device "BuiltInMicrophoneDevice" \
            --output ~/recordings/interview.m4a

        # 6. Recording with no transcription (default behaviour — identical
        #    to pre-plan-003 builds; no network connections, no sidecar files).
        macrec start --output ~/recordings/talk.m4a

        # 7. Recording with Gemini transcription writing a JSONL sidecar.
        #    GOOGLE_API_KEY must be exported (or in ~/.tool-agents/macrec/.env).
        #    Produces ~/recordings/talk.m4a + ~/recordings/talk.transcript.jsonl.
        export GOOGLE_API_KEY=...   # from https://aistudio.google.com/app/apikey
        macrec start \
            --transcribe gemini \
            --transcribe-source mixed \
            --transcribe-format jsonl \
            --output ~/recordings/talk.m4a

        # 8. Mic-only Gemini transcription with an SRT sidecar
        #    (final-only cues, suitable for video-editor import).
        macrec start \
            --transcribe gemini \
            --transcribe-source mic \
            --transcribe-format srt \
            --output ~/recordings/lecture.m4a

        # 9. Detached background recording WITH transcription (plan-004
        #    lifted the v1 detach-incompatible restriction; the REST
        #    batch architecture has no terminal-output dependency).
        #    Stop later with `macrec stop`.
        macrec start \
            --detach \
            --transcribe gemini \
            --transcribe-format jsonl \
            --output ~/recordings/meeting.m4a --overwrite

        # 10. Soniox cloud streaming with bilingual Greek + English hints
        #     and a JSONL sidecar.  SONIOX_API_KEY must be exported (or in
        #     ~/.tool-agents/macrec/.env). Produces ~/talk.m4a +
        #     ~/talk.transcript.jsonl. Default model: stt-rt-v4.
        export SONIOX_API_KEY=sk_...   # from https://console.soniox.com
        macrec start --transcribe soniox --transcribe-language el,en \
            --output ./talk.m4a --transcribe-format jsonl

        # 11. Azure OpenAI batch (REST) transcription using
        #     gpt-4o-mini-transcribe. Requires AZURE_OPENAI_API_KEY,
        #     AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT (find
        #     the deployment name in Azure Foundry → Models + endpoints).
        export AZURE_OPENAI_API_KEY=...
        export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
        export AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini-transcribe
        macrec start --transcribe azure --transcribe-format jsonl \
            --output ~/recordings/meeting.m4a

        # 12. Azure OpenAI realtime (WebSocket) transcription with
        #     `intent=transcription`. Same env vars as #11; produces
        #     volatile partials + stable finals on the JSONL sidecar.
        macrec start --transcribe azure-openai-realtime \
            --transcribe-format jsonl \
            --output ~/recordings/standup.m4a

        # 13. ElevenLabs Scribe v2 batch transcription with diarization
        #     and per-word speaker labels. ELEVENLABS_API_KEY must be
        #     exported (or in ~/.tool-agents/macrec/.env).
        export ELEVENLABS_API_KEY=sk_...   # from https://elevenlabs.io/app/settings/api-keys
        export ELEVENLABS_DIARIZE=true
        export ELEVENLABS_NUM_SPEAKERS=2
        macrec start --transcribe elevenlabs \
            --transcribe-format jsonl \
            --output ~/recordings/interview.m4a
        ```

        ### `stop`

        Stops a detached recording started with `macrec start --detach`. Reads
        the PID file (default `~/.tool-agents/macrec/macrec.pid`), sends
        `SIGTERM`, and polls every 100 ms for clean exit, up to
        `--stop-timeout` seconds.

        Verbatim help:

        ```
        OVERVIEW: Stop a detached recording started with 'macrec start --detach'.

        USAGE: macrec stop [--pid-file <pid-file>] [--stop-timeout <stop-timeout>]

        OPTIONS:
          --pid-file <pid-file>   PID file path of the detached recording. Default:
                                  ~/.tool-agents/macrec/macrec.pid. Env:
                                  MACREC_PID_FILE.
          --stop-timeout <stop-timeout>
                                  Seconds to wait for the recording process to exit
                                  cleanly after SIGTERM. Default: 35. Env:
                                  MACREC_STOP_TIMEOUT.
          --version               Show the version.
          -h, --help              Show help information.
        ```

        Decision tree (project-design.md §14.3):

        - PID file missing               → `MacrecError.noActiveRecording`,    exit 78.
        - PID file present but stale     → remove file, `MacrecError.staleRecording`, exit 75.
        - PID file malformed             → remove file, treated as stale,      exit 75.
        - PID file live, exits in time   →                                     exit 0.
        - PID file live, timeout fires   → `MacrecError.stopTimeout`,          exit 70.

        Examples:

        ```sh
        # 1. Stop the default detached recording.
        macrec stop

        # 2. Stop a recording that used a custom --pid-file.
        macrec stop --pid-file /tmp/macrec.session1.pid

        # 3. Wait up to 60 s instead of the default 35 s for finalization.
        macrec stop --stop-timeout 60
        ```

        ### `list-devices`

        Prints one record per available input audio device, in a parseable
        single-record-per-line format. Always exits 0 if at least one device
        is found; throws `MacrecError.noInputDevicesAvailable` (exit 70) if
        the system reports zero inputs.

        Verbatim help:

        ```
        OVERVIEW: Print available audio input devices.

        USAGE: macrec list-devices

        OPTIONS:
          --version               Show the version.
          -h, --help              Show help information.
        ```

        Output format (locked, parseable):

        ```
        name=<name>  uid=<uid>  channels=<n>  sample-rate-range=<min>..<max>
        ```

        Example:

        ```sh
        $ macrec list-devices
        name=MacBook Pro Microphone  uid=BuiltInMicrophoneDevice  channels=1  sample-rate-range=48000..48000
        name=External USB Mic         uid=AppleUSBAudioEngine:Acme:USB Mic:1234:1  channels=2  sample-rate-range=44100..96000
        ```

        Pipe to `awk` or `cut -d= -f2` for scripting.

        ### `check-permissions`

        Prints the current Screen Recording and Microphone TCC state to
        stderr and exits 0 if both are authorized, 77 (`EX_NOPERM`) otherwise.
        Useful as a pre-flight gate in shell scripts.

        Verbatim help:

        ```
        OVERVIEW: Print Screen Recording and Microphone permission state.

        USAGE: macrec check-permissions

        OPTIONS:
          --version               Show the version.
          -h, --help              Show help information.
        ```

        Example:

        ```sh
        if macrec check-permissions; then
            macrec start --output ~/recordings/now.m4a --max-duration 60
        else
            echo "Grant Screen Recording + Microphone in System Settings, then re-run."
        fi
        ```

        ## Configuration precedence

        Every configuration value is resolved in this order, from lowest
        priority to highest:

        1. Shell environment       (`process.env` equivalent — `ProcessInfo.processInfo.environment`).
        2. User `.env`             (`~/.tool-agents/macrec/.env`, mode 0600).
        3. Local `.env`            (`./.env` in the current working directory).
        4. CLI flags               (always win).

        Higher-priority sources override lower ones on a per-key basis. The
        canonical env-var names use the `MACREC_*` prefix, with the
        intentional exception of `OUTPUT_PATH` (which is unprefixed because
        the configuration design predates the prefix convention).

        See `docs/design/configuration-guide.md` for the full per-variable
        table (allowed values, defaults, recommended storage tier).

        ## Permissions

        `macrec` requires two macOS TCC permissions:

        - **Screen Recording** — required by `ScreenCaptureKit` to capture
          the system audio submix. macOS attaches audio capture authorization
          to the Screen Recording namespace; there is no separate "system
          audio" entitlement.
        - **Microphone** — required by `AVFoundation` to capture the input
          device.

        On first run, `macrec` triggers the standard system prompts. After
        the user approves, the same-process state cannot be re-read (a known
        macOS TCC limitation), so `macrec start` exits with
        `MacrecError.screenRecordingPermissionNotDetermined` (exit 75) or
        `MacrecError.microphonePermissionNotDetermined` (also 75); re-run the
        command to pick up the granted state.

        Subsequent denials surface as
        `MacrecError.screenRecordingPermissionDenied` /
        `MacrecError.microphonePermissionDenied` (exit 77, `EX_NOPERM`) with
        an explicit System Settings path printed to stderr (see
        project-design.md §8 for the locked strings).

        ### Speech Recognition (for `--transcribe apple`)

        When `--transcribe apple` is selected (the v1.5 default),
        `macrec` also needs the **Speech Recognition** TCC grant. The
        `Info.plist` carries `NSSpeechRecognitionUsageDescription`; the
        first run that opts into the Apple provider triggers a system
        prompt. Denying the prompt — or revoking the grant later in
        System Settings → Privacy & Security → Speech Recognition —
        causes `macrec start` to exit 77 (`EX_NOPERM`) via
        `MacrecError.speechRecognitionPermissionDenied` before any
        capture session opens; no audio file is produced.

        > **R-2 / PEND-AS-1 caveat.** Because development builds are
        > ad-hoc-signed, every `swift build` rebuild can change the
        > binary's TCC identity and re-trigger the prompt. The
        > workarounds documented in the next section (re-grant after a
        > rebuild burst, or build once and re-use the same binary) apply
        > equally to Speech Recognition. Tracked in
        > `Issues - Pending Items.md` PEND-AS-1.

        ### TCC ad-hoc-signing instability for development builds (R-2)

        Because `swift build` produces an ad-hoc-signed binary that lives at
        `.build/<config>/macrec`, every rebuild can change the TCC identity
        and re-trigger the system prompts. Workarounds:

        - Reset and re-grant after a series of rebuilds:
          ```sh
          tccutil reset ScreenCapture
          tccutil reset Microphone
          ```
        - For long-running development sessions, build once and re-use the
          same binary across iterations.
        - For shipping builds, wrap the binary in a properly-signed `.app`
          bundle (out of scope for v1).

        See `Issues - Pending Items.md` (R-2) and design §8.

        ## Exit codes

        Locked by project-design.md §9.5. The mapping below is sourced
        directly from `Sources/MacrecCore/Errors/MacrecError.swift`.

        | Code | Symbolic         | `MacrecError` cases                                                                                                                | Meaning                                  |
        |------|------------------|------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------|
        | 0    | success          | normal completion or SIGINT-finalized recording or clean `stop`                                                                    | success                                  |
        | 1    | generic          | `unknown`, `ioError`, `finishWritingFailed`                                                                                        | generic / unexpected runtime failure     |
        | 2    | partial output   | `writerFinalizationTimeout`                                                                                                        | finalization timed out (file may be partial) |
        | 64   | `EX_USAGE`       | `invalidConfigValue`, `dotEnvParseError`                                                                                           | usage error / invalid argument           |
        | 66   | `EX_NOINPUT`     | `outputParentMissing`, `outputAlreadyExists`, `pidFileWriteFailed`                                                                  | output / PID file path error             |
        | 70   | `EX_SOFTWARE`    | `noInputDevicesAvailable`, `scStreamFailedToStart`, `scStreamSilentStopExceeded`, `avCaptureFailedToStart`, `writerFailedToStart`, `stopTimeout` | runtime failure                          |
        | 75   | `EX_TEMPFAIL`    | `screenRecordingPermissionNotDetermined`, `microphonePermissionNotDetermined`, `staleRecording`                                    | retryable                                |
        | 77   | `EX_NOPERM`      | `screenRecordingPermissionDenied`, `microphonePermissionDenied`, `microphonePermissionRestricted`                                  | permission denied                        |
        | 78   | `EX_CONFIG`      | `missingRequiredConfig`, `micDeviceNotFound`, `alreadyRecording`, `noActiveRecording`, `transcriptionApiKeyMissing` | configuration / workflow error           |

        Plan-003 added two new error → exit-code mappings (project-design.md
        §LT-4):

        - `transcriptionApiKeyMissing` → **78** (`EX_CONFIG`). Raised by
          `ConfigResolver.resolve(...)` BEFORE any audio capture begins when a
          non-`none` provider is selected and no API key is found in any tier
          of the configuration chain. **No audio file is created.** (AC-LT-4.)
        - `transcriptionInvalidProvider` → **64** (`EX_USAGE`). Raised when
          `--transcribe` receives an unrecognised provider name.

        > **Detach mode is compatible with `--transcribe`.** The plan-003-era
        > `transcriptionDetachUnsupported` cross-check has been removed by
        > plan-004 Phase G.1. The REST batch architecture POSTs audio chunks
        > over plain HTTPS and writes the JSONL sidecar alongside the audio
        > file with no foreground stderr/stdout dependency, so a detached
        > daemon produces the same sidecar as a foreground recording. The
        > `MacrecError.transcriptionDetachUnsupported` case has been deleted
        > from `MacrecError`.

        ## Live transcription

        `macrec` can stream the captured audio to a streaming speech-to-text
        provider in parallel with the on-disk recording, producing a sidecar
        transcript file alongside the audio file. The feature is **opt-in**;
        with no `--transcribe` flag and no `MACREC_TRANSCRIBE` env var, the
        recording behaviour is byte-for-byte identical to pre-plan-003 builds
        (AC-LT-1 / AC-LT-16). Architecture and decision rationale live in
        `docs/design/project-design.md` §LT-1 .. §LT-10; functional
        requirements are FR-45 .. FR-58 in `docs/design/project-functions.md`.

        ### Supported providers (v1)

        | Provider id    | Description                                                                                       | Required env var   |
        |----------------|---------------------------------------------------------------------------------------------------|--------------------|
        | `none`         | Transcription disabled — true no-op.                                                              | _(none)_           |
        | `apple`        | **Default (v1.5+).** On-device Apple SpeechAnalyzer (macOS 26+). No API key, no network. Supports dual-locale parallel recognition via comma-separated `--transcribe-language` (e.g. `en-US,el-GR`). | _(none)_         |
        | `whisperkit`   | On-device WhisperKit (Apple silicon CoreML).  No API key, no network.                              | _(none)_           |
        | `parakeet`     | **On-device Parakeet TDT V3 multilingual** via FluidAudio (CoreML, ANE). ~25 European languages including Greek. ~600MB lazy first-launch download. Batch architecture. No API key. (plan-012) | _(none)_ |
        | `gemini`       | Google Gemini REST batch API (HTTPS POST; 2.5 s WAV chunks at 16 kHz mono PCM16; plan-004).       | `GOOGLE_API_KEY`   |
        | `gemini-live`  | Deprecated alias for `gemini` (one-release transition; resolver lowers it to `gemini` and warns). | `GOOGLE_API_KEY`   |
        | `soniox`       | **Soniox cloud streaming** (WebSocket; PCM16 16 kHz mono frames; plan-006). Default model `stt-rt-v4`. Supports language identification across multiple BCP-47 hints (e.g. `el,en`); endpoint detection is enabled; speaker diarization is OFF in v1. ~$0.12/hour at list price. | `SONIOX_API_KEY`   |
        | `dual`         | **Dual-mode transcription** (plan-010). NOT a single provider — runs `apple` (on-device, Channel A) AND `apple-cloud` (cloud, Channel B) in parallel against the same audio source. Required co-flags: `--transcribe-dual-locale-{a,b}`, `--transcribe-dual-source`, `--transcribe-dual-format`. The single-mode co-flags `--transcribe-language`, `--transcribe-source`, `--transcribe-format`, `--transcribe-model` are forbidden in dual mode. | _(none — Channel B uses the system Speech Recognition grant; Channel A is on-device)_ |

        Additional providers (OpenAI Realtime, Deepgram Streaming,
        AssemblyAI Streaming) are admitted by the `TranscriptionProvider`
        protocol (NFR-21) and tracked as v2 follow-ups.

        ### Two-tier requirement

        Two configuration values must be present together when transcription
        is enabled:

        1. **`MACREC_TRANSCRIBE` (or `--transcribe`)** picks the provider.
           Resolved through the four-tier chain (shell env → user `.env` →
           local `.env` → CLI flag). Default `none`.
        2. **The provider's required API key** must be resolvable by the
           same chain at recording start. For `gemini` (and its deprecated
           alias `gemini-live`) this is `GOOGLE_API_KEY`; for `soniox` it
           is `SONIOX_API_KEY`. If the chosen provider needs a key and
           none is found, `ConfigResolver` raises
           `MacrecError.transcriptionApiKeyMissing(provider:)` (exit `78`)
           **before** any capture session is opened — no audio file is
           created (AC-LT-4 / AC-SX-4).

        ### Sidecar file naming

        The sidecar lives next to the audio file, with the same basename and
        an inserted `.transcript` infix before the format extension. The
        rules track the recording's segmentation (FR-51, project-design
        §LT-7.1):

        | Recording case                                              | Audio output                                | Sidecar(s)                                                          |
        |-------------------------------------------------------------|---------------------------------------------|---------------------------------------------------------------------|
        | Single segment, `mixed` / `stereo-split`                    | `recording-….m4a`                           | `recording-….transcript.<ext>`                                      |
        | Multi-segment (pause/resume or split)                       | `recording-….part01.m4a`, `…part02.m4a`     | `recording-….part01.transcript.<ext>`, `recording-….part02.transcript.<ext>` |
        | `--layout split` + `--transcribe-source` ∈ {mixed,system,mic} | `recording-….mic.m4a`, `recording-….system.m4a` | one sidecar reflecting the chosen single stream                      |
        | `--transcribe-source both` (any layout, plan-012)           | per `--layout`                                  | `recording-….system.transcript.<ext>` AND `recording-….microphone.transcript.<ext>` (true dual-driver, plan-012) |

        `<ext>` is one of `jsonl` (default), `txt`, `srt`, `vtt`.

        ### Source-split mode (plan-012)

        When `--transcribe-source both` is selected with single-mode
        transcription, `macrec` runs **two** transcription drivers in
        parallel — one for the system audio submix, one for the
        microphone — and emits two sidecar files
        (`<basename>.system.transcript.<ext>` and
        `<basename>.microphone.transcript.<ext>`). Both drivers are
        instances of the SAME provider (whatever `--transcribe`
        selected). Each gets its own logger label (`track=system` /
        `track=mic`) so log lines stay disambiguable.

        **Per-provider compatibility:**

        | Provider                  | Notes                                                  |
        |---------------------------|--------------------------------------------------------|
        | `apple` / `apple-cloud`   | Independent `SpeechAnalyzer` / `SFSpeechRecognizer` instances. The two-instance contract is locked by `AppleSpeechParallelInstancesTest`. |
        | `gemini`                  | Independent per-chunk REST POSTs.                       |
        | `whisperkit` / `parakeet` | Doubled memory cost (~1.2 GB total when both lanes load the multilingual model). |
        | `soniox`                  | Two independent WebSocket connections.                  |
        | `azure` / `azure-openai-realtime` | Two independent REST/WebSocket sessions; each counts independently against the realtime 60-min boundary. |
        | `elevenlabs`              | Two parallel POSTs. Free/Starter tiers cap concurrent requests at 8 — `macrec` logs a warning at session start. |

        **UI:** the live transcript panel renders TWO stacked auto-
        scrolling lanes labelled `System audio` and `Microphone`.
        Dual-mode (`--transcribe dual`) is unaffected — its existing
        Channel A / Channel B layout takes precedence over source-split.

        ### Long-session behaviour

        plan-004 replaced the original Gemini Live WebSocket architecture
        with a Gemini REST batch architecture: `TranscriptionManager`
        coalesces audio into 2.5 s WAV chunks at 16 kHz mono PCM16 and
        POSTs each chunk to the REST endpoint as an independent request.
        There is no long-lived connection to keep alive, no
        ~10-minute session cap, and no reconnect/backoff state machine.
        Per-chunk request failures (HTTP 5xx, transient network errors)
        are surfaced as non-fatal `error` events on the events stream and
        recorded in `TranscriptionMetrics.errorCount`; recording continuity
        is **never** affected by transcription request failures (NFR-17,
        AC-LT-10).

        ### Privacy warning

        > **Audio leaves the machine.** When `--transcribe gemini` is
        > active, the captured PCM audio (mic, system, or both depending on
        > `--transcribe-source`) is downsampled to 16 kHz mono PCM16,
        > packaged as 2.5 s WAV chunks, and POSTed over HTTPS to
        > `https://generativelanguage.googleapis.com` (Google's Gemini REST
        > API) where it is processed on Google's servers. No PII metadata
        > is transmitted (NFR-20: filename, mic device name, host name,
        > user name are stripped from the wire payload), but the raw audio
        > itself **is** sent. Review your organisation's data-handling
        > policy before enabling on calls containing confidential content.
        > The default `--transcribe none` keeps every byte local.

        ### Cost / volume metrics

        At session end, an `info`-level log line records
        `chunksSent`, `billableSeconds`, `errorCount`, and `lastRTT`
        (FR-58). The same counters surface in the post-stop UI summary
        (macrec-ui) and on the events stream consumed by
        `SessionCoordinator`. Use `billableSeconds` × the provider's
        published per-second rate to estimate cost per recording. (The
        plan-003 §LT-7.2 / §LT-9.1 512-byte JSONL header line was
        dropped by plan-004 — JSONL sidecars now carry one record per
        coalesced segment with id-keyed in-place rewrite, and metrics
        are surfaced via `TranscriptionMetrics` rather than a file
        header.)

        ### Model id

        The `--transcribe-model` flag (env `MACREC_TRANSCRIBE_MODEL`)
        overrides the provider's pinned default model. For `gemini`:

        - **Default**: `gemini-3-flash-preview` (the documented Google
          REST audio model per
          <https://ai.google.dev/gemini-api/docs/audio>).
        - **Allowed list** (validated by
          `TranscriptionProviderFactory.build`):
            - `gemini-3-flash-preview` (default)
            - `gemini-3.1-flash-live-preview` (Live-API SKU; returns
              HTTP 404 on the REST endpoint — kept in the allow-list
              only for backward-compat configs)
            - `gemini-2.5-flash`
            - `gemini-2.5-pro`
            - `gemini-2.0-flash`

        Any value outside the allowed list is sent through to the API
        as-is with a `warning` log line; the provider may then return
        an HTTP 4xx if the model id is unknown.

        > **History.** The plan-004 brainstorming session (2026-04-28)
        > initially pinned `gemini-3.1-flash-live-preview` as the
        > default per user direction. Empirical verification later
        > that day showed it returns HTTP 404 on `:generateContent`
        > (it is the Live API SKU, not a REST SKU). PEND-LT-6 was
        > closed by switching the default to `gemini-3-flash-preview`.
        > If your config explicitly sets the old id, expect 4xx
        > errors and switch to the new default.
        > Tracked under `Issues - Pending Items.md` PEND-LT-6.

        ### Bandwidth

        Each 2.5 s @ 16 kHz mono PCM16 WAV chunk is approximately
        80 KB on the wire. Base64-encoded inside the JSON request body
        it inflates to roughly 107 KB per request. Concrete envelope:

        | Setting                              | Per chunk | Per minute | Per 60-minute session |
        |--------------------------------------|-----------|------------|-----------------------|
        | One source (`mixed`, `system`, `mic`) | ~107 KB   | ~2.5 MB    | ~155 MB upstream       |
        | `--transcribe-source both`           | ~214 KB   | ~5.0 MB    | ~310 MB upstream       |

        For very long recordings with `--transcribe-source both`,
        cumulative upstream bandwidth can approach a few GB. Run on a
        stable network connection; transient request failures are
        non-fatal but inflate `TranscriptionMetrics.errorCount`.

        ### Soniox (cloud streaming, plan-006)

        Soniox is a cloud streaming STT provider added in plan-006. Unlike
        Gemini's REST-batch architecture, Soniox uses a single
        long-running WebSocket connection — the captured PCM audio is
        downsampled to 16 kHz mono Int16 LE, packaged into ~120 ms
        binary frames, and streamed to the Soniox endpoint. Token
        batches return on the same socket and are aggregated into
        partial / final transcript events by `SonioxTokenAggregator`.

        #### Defaults

        | Setting                | Default                                                  |
        |------------------------|----------------------------------------------------------|
        | Model                  | `stt-rt-v4` (overridable via `--transcribe-model`)       |
        | Endpoint               | `wss://stt-rt.soniox.com/transcribe-websocket` (US)      |
        | Language hints         | `["el", "en"]` (overridable via `--transcribe-language`) |
        | Language identification| **ON** (per-token language tags exposed in JSONL sidecar) |
        | Endpoint detection     | **ON** (server emits `<end>` markers between utterances) |
        | Speaker diarization    | **ON** by default since plan-012 (overridable via `MACREC_SONIOX_DIARIZE` / `--soniox-diarize`; UI toggle at Settings → Soniox → "Diarize speakers") |

        #### Endpoint regions

        For data-residency requirements, override the endpoint via
        `--soniox-endpoint <url>` or `MACREC_SONIOX_ENDPOINT`:

        | Region | Endpoint URL                                          |
        |--------|--------------------------------------------------------|
        | US     | `wss://stt-rt.soniox.com/transcribe-websocket` (default) |
        | EU     | `wss://stt-rt.eu.soniox.com/transcribe-websocket`     |
        | JP     | `wss://stt-rt.jp.soniox.com/transcribe-websocket`     |

        See <https://soniox.com/docs/stt/data-residency> for the
        authoritative list. The resolver validates the URL is `ws://`
        or `wss://` and raises `MacrecError.invalidConfigValue`
        (exit 64) otherwise.

        #### API key

        `SONIOX_API_KEY` is the only accepted source for the credential
        — there is no `--soniox-api-key` CLI flag (avoids leakage into
        shell history). Obtain a key at <https://console.soniox.com>
        (Account → API keys), then add it to
        `~/.tool-agents/macrec/.env` (mode `0600`):

        ```sh
        chmod 0700 ~/.tool-agents/macrec
        echo 'SONIOX_API_KEY=sk_...' >> ~/.tool-agents/macrec/.env
        chmod 0600 ~/.tool-agents/macrec/.env
        ```

        Pair the key with `MACREC_SONIOX_KEY_EXPIRES_AT` (ISO-8601 date)
        if your team rotates keys on a fixed cadence; the resolver emits
        a soft renewal reminder in the 7 days before expiry. The
        per-provider variable takes precedence over the shared
        `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`.

        #### Cost

        Soniox bills approximately **$0.12 per audio-hour** at list price
        for `stt-rt-v4` (verify against <https://soniox.com/pricing> for
        the current rate). The session-end log line records
        `billableSeconds` so you can compute the cost per recording as
        `billableSeconds / 3600 * 0.12`.

        #### Latency targets (observability)

        Plan-006 §F-3 defines two soft latency targets emitted as
        `info`-level metrics on session end:

        - **P95 first-partial** ≤ 500 ms (time from Start to the first
          partial token from Soniox).
        - **P95 utterance-end → final** ≤ 1.5 s (time from the
          server-emitted `<end>` marker to the final settled segment).

        These are observability thresholds only — exceeding them does
        not stop the recording or produce a hard error.

        #### Recording-integrity isolation invariant (NFR-SX-1)

        > **Soniox failures cannot stop the recording.** Per
        > project-design §LT-1 / NFR-SX-1, every Soniox WebSocket error
        > (TLS handshake failure, control-frame error, server-emitted
        > `error_code`, network drop) is surfaced as a non-fatal
        > `TranscriptionEvent.error` and recorded in
        > `TranscriptionMetrics.errorCount`. The on-disk audio file
        > continues to capture without interruption. The Soniox subsystem
        > runs on a separate Task tree from `Recorder` — cancellation,
        > exceptions, and even Swift task-priority inversion in the
        > Soniox path cannot back-pressure the recording pipeline. This
        > invariant is enforced by `SonioxRecordingIsolationTests`.

        #### Privacy reminder

        > **Audio leaves the machine.** When `--transcribe soniox` is
        > active, the captured PCM audio (mic, system, or both) is
        > downsampled to 16 kHz mono PCM16 and streamed to
        > `wss://stt-rt.soniox.com` (or the configured EU/JP endpoint).
        > Soniox does not store audio by default, but org-level
        > retention is configurable in the Soniox console
        > (<https://soniox.com/console>) — review your organisation's
        > data-handling policy and the Soniox privacy notice
        > (<https://soniox.com/privacy>) before enabling on calls
        > containing confidential content.

        #### Speaker diarization (plan-012)

        When `enable_speaker_diarization=true` (the default since plan-012
        Phase A), Soniox tags each token with a `speaker` field. The
        `SonioxTokenAggregator` finalises the active partial whenever
        the incoming speaker changes, producing one segment per speaker
        turn. The speaker is propagated via the optional
        `TranscriptSegment.speaker` field and rendered in every sidecar
        format:

        | Format | Rendering when `segment.speaker == "spk:1"` |
        |--------|---------------------------------------------|
        | JSONL  | optional `"speaker":"spk:1"` field after `language` (RAW provider value, omitted when nil) |
        | TXT    | `[12:34:56] mic [en] [S1]: hello world`     |
        | SRT    | cue text becomes `S1: hello world`          |
        | VTT    | cue text becomes `<v S1>hello world</v>`    |

        The `SpeakerSidecarLabel` helper is the single source of truth
        for mapping the provider-opaque id to the display label
        (`spk:N` → `SN`).

        **Override:** set `MACREC_SONIOX_DIARIZE=false` (or pass
        `--soniox-diarize false`) to revert to non-diarized output.
        The UI toggle lives at **Settings → Soniox → "Diarize
        speakers"**. Per-source/non-Soniox sidecars are byte-equivalent
        to the pre-plan-012 layout (DT-INV preservation).

        ### Parakeet (on-device, multilingual; plan-012)

        Parakeet is the third on-device option, alongside Apple Speech
        and WhisperKit. Backed by FluidAudio's CoreML port of NVIDIA's
        `parakeet-tdt-0.6b-v3` model.

        **Why use it over WhisperKit:** Parakeet TDT V3 is significantly
        faster than Whisper large-v3 on Apple Silicon (Apple Neural
        Engine optimised) at comparable WER on the supported European
        languages. Especially strong on Greek, Polish, Turkish, and
        other locales where Apple-shipped on-device assets are
        unavailable.

        **Defaults:**

        | Setting          | Default                                                  |
        |------------------|----------------------------------------------------------|
        | Model            | `parakeet-tdt-0.6b-v3` (FluidAudio's `AsrModelVersion.v3` — multilingual) |
        | Language hint    | _(auto-detect — `MACREC_PARAKEET_LANGUAGE` is informational only because FluidAudio v0.8.x has no per-call language API)_ |
        | Streaming        | NOT supported (batch-only, mirrors WhisperKit)            |
        | API key          | Not required                                              |
        | First-launch DL  | ~600 MB to Application Support (cached after)             |

        **Examples:**

        ```sh
        # Parakeet — defaults to v3 multilingual.
        macrec start --transcribe parakeet \
            --output ~/recordings/greek-meeting.m4a

        # Override the model id (forward-compat — currently
        # informational, FluidAudio v0.8.x clamps to v3 internally).
        macrec start --transcribe parakeet \
            --parakeet-model parakeet-tdt-0.6b-v3 \
            --parakeet-language el \
            --output ~/recordings/heavy.m4a
        ```

        **Model-resolution precedence** (mirrors WhisperKit):

        1. `--parakeet-model` / `MACREC_PARAKEET_MODEL` (Parakeet-specific override).
        2. `--transcribe-model` / `MACREC_TRANSCRIBE_MODEL` (shared).
        3. Provider default (`parakeet-tdt-0.6b-v3`).

        **Why the version pin (FluidAudio v0.8.2):** v0.9.x bumped the
        package's swift-tools-version to 6.0 and the new
        `StreamingAsrManager.swift` triggers Swift 6 strict-concurrency
        errors when built. v0.8.x uses tools 5.10 and exposes the same
        batch ASR surface (`AsrManager` / `AsrModels.downloadAndLoad
        (version: .v3)`). Because we're batch-only by design, the
        absence of the streaming manager is irrelevant. Bump the pin
        once upstream resolves the strict-concurrency issue.

        ### Dual-mode transcription (plan-010)

        Dual mode runs **two** live-transcription channels in parallel
        against the same captured audio:

        - **Channel A — Apple on-device.** `SpeechAnalyzer +
          SpeechTranscriber` (macOS 26+). Locale set sourced from
          `SpeechTranscriber.supportedLocales` (~42 locales; English
          variants present, Greek **not** present at macOS 26 launch).
          No API key, no network.
        - **Channel B — Apple Cloud.** `SFSpeechRecognizer` with
          `requiresOnDeviceRecognition = false`. Locale set sourced
          from `SFSpeechRecognizer.supportedLocales()` (~57 locales,
          includes `el-GR`). No API key required, but every call hits
          Apple's Speech Recognition cloud — the **`apple-cloud`
          quota / latency / privacy disclaimers from single-mode
          `apple-cloud` apply identically** (see "Privacy warning"
          below for the reused disclosure copy).

        Per-channel locale choice is asymmetric on purpose. The v1
        defaults are `en-US` for Channel A and `el-GR` for Channel B
        — i.e. the on-device side captures inserted English words and
        the cloud side captures Greek dialogue. Defaults are
        AppStorage values written by the UI on first launch; the CLI
        does **not** apply them silently. Missing required dual-mode
        values raise `MacrecError.transcriptionConfigurationMissing`
        (exit 64) per the project's no-fallback rule (CLAUDE.md).

        Both channels write into ONE merged sidecar (DT-INV-3). Each
        segment is tagged with the channel via the existing
        `TranscriptSegment.model` field (`"apple"` for A,
        `"apple-cloud"` for B); the per-format on-disk conventions
        listed below add an additional human-readable channel cue.

        #### CLI flags

        ```sh
        macrec start \
            --transcribe dual \
            --transcribe-dual-locale-a en-US \
            --transcribe-dual-locale-b el-GR \
            --transcribe-dual-source mixed \
            --transcribe-dual-format jsonl \
            --output ~/recordings/bilingual-meeting.m4a
        ```

        | Flag                            | Env var                              | Allowed values                       |
        |---------------------------------|--------------------------------------|--------------------------------------|
        | `--transcribe dual`             | `MACREC_TRANSCRIBE=dual`             | enables dual mode                    |
        | `--transcribe-dual-locale-a`    | `MACREC_TRANSCRIBE_DUAL_LOCALE_A`    | any BCP-47 in `SpeechTranscriber.supportedLocales` |
        | `--transcribe-dual-locale-b`    | `MACREC_TRANSCRIBE_DUAL_LOCALE_B`    | any BCP-47 in `SFSpeechRecognizer.supportedLocales()` |
        | `--transcribe-dual-source`      | `MACREC_TRANSCRIBE_DUAL_SOURCE`      | `system | mic | mixed | both`        |
        | `--transcribe-dual-format`      | `MACREC_TRANSCRIBE_DUAL_FORMAT`      | `jsonl | txt | srt | vtt`            |

        All four `MACREC_TRANSCRIBE_DUAL_*` env vars resolve through
        the standard four-tier chain (shell env → `~/.tool-agents/macrec/.env`
        → `./.env` → CLI flag, lowest to highest priority — same as
        every other `MACREC_TRANSCRIBE_*` family member). There is
        intentionally NO `MACREC_TRANSCRIBE_DUAL` boolean env var — set
        `MACREC_TRANSCRIBE=dual` (or pass `--transcribe dual`) to
        flip the resolver into dual mode.

        #### Mutual exclusivity (single-mode-only co-flags)

        The following single-mode co-flags are **forbidden** when
        `--transcribe dual` is selected — passing them raises
        `MacrecError.transcriptionConfigConflict` (exit 64):

        | Single-mode flag           | Dual-mode equivalent                                |
        |----------------------------|-----------------------------------------------------|
        | `--transcribe-language`    | `--transcribe-dual-locale-a` + `--transcribe-dual-locale-b` |
        | `--transcribe-source`      | `--transcribe-dual-source`                          |
        | `--transcribe-format`      | `--transcribe-dual-format`                          |
        | `--transcribe-model`       | _(no equivalent — providers are pinned to apple + apple-cloud)_ |

        #### Sidecar conventions (design `§DT-7`)

        All four sidecar formats remain byte-equivalent to single mode
        when single mode is used; dual mode adds a per-segment channel
        cue. The channel label is the uppercased BCP-47 primary subtag
        of the segment's locale (`en-US` → `EN`; `el-GR` → `EL`),
        computed via `DualSidecarLabel.channelLabel(for:)` (one
        canonical implementation; if the convention changes, only that
        helper changes).

        - **JSONL (`--transcribe-dual-format jsonl`)** — adds an
          OPTIONAL `channel` field (`"A"` for `apple`, `"B"` for
          `apple-cloud`) appended as the LAST field of each line for
          grep/jq convenience. Single-mode JSONL output is byte-identical
          to today (no `channel` key emitted).

          ```jsonl
          {"id":"E1...","timestamp":"2026-05-01T12:00:01.230Z","text":"Hello world","source":"system","model":"apple","language":"en-US","channel":"A","durationSec":0.88,"isFinal":true}
          {"id":"7C...","timestamp":"2026-05-01T12:00:01.920Z","text":"Καλημέρα","source":"system","model":"apple-cloud","language":"el-GR","channel":"B","durationSec":1.50,"isFinal":true}
          ```

        - **TXT (`--transcribe-dual-format txt`)** — prefixes each
          line with `[<LANG>] ` after the timestamp. Single-mode TXT
          output remains unchanged (no `[EN]` / `[EL]` prefix).

          ```
          [00:00:01.230] [EN] Hello world
          [00:00:01.920] [EL] Καλημέρα
          [00:00:03.110] [EN] this is a test
          ```

        - **SRT (`--transcribe-dual-format srt`)** — prefixes the cue
          text with `<LANG>: `. Cue numbers are monotonic across both
          channels (one shared counter); cue overlap between A and B
          is intentional and tolerated by mainstream players (mpv,
          VLC).

          ```
          1
          00:00:01,230 --> 00:00:02,110
          EN: Hello world

          2
          00:00:01,920 --> 00:00:03,420
          EL: Καλημέρα
          ```

        - **VTT (`--transcribe-dual-format vtt`)** — wraps each cue
          text in a WebVTT voice tag `<v EN>...</v>` /
          `<v EL>...</v>`.

          ```
          WEBVTT

          00:00:01.230 --> 00:00:02.110
          <v EN>Hello world</v>

          00:00:01.920 --> 00:00:03.420
          <v EL>Καλημέρα</v>
          ```

        #### apple-cloud caveat reuse

        > **Channel B hits the cloud.** Dual mode runs Channel B
        > through `SFSpeechRecognizer` with
        > `requiresOnDeviceRecognition = false`; the captured audio is
        > sent to **Apple's Speech Recognition servers**. Every
        > `apple-cloud` caveat documented for single-mode
        > `--transcribe apple-cloud` applies to Channel B identically:
        >
        > - **Quota.** Apple enforces a device-wide quota of
        >   approximately 1,000 requests per hour and roughly 60
        >   seconds of audio per request; `macrec` rotates the
        >   underlying recognition task every 55 seconds to stay
        >   inside that limit.
        > - **Latency.** Channel B latency depends on Apple's cloud
        >   round-trip; Channel A (on-device) is always lower-latency.
        >   Per-channel latency is exposed via the dual metrics
        >   surface (`DualChannelMetrics`; v1 surfaces in macrec-ui
        >   only).
        > - **Privacy.** The exact `appleCloudBodyText` disclosure
        >   shown by macrec-ui's privacy sheet covers Channel B
        >   verbatim (FR-8 / DT-11). The fact that the SAME audio
        >   also reaches an on-device provider (Channel A) does not
        >   change Channel B's privacy posture and does not require
        >   new disclosure.
        >
        > See "Privacy warning" above for the full disclosure body.
        > Channel A (on-device) requires the **Speech Recognition**
        > TCC grant — same prompt as single-mode `--transcribe apple`
        > — but performs no network IO.

        #### Recording-integrity isolation invariant

        Per design §DT-4 (channel isolation, FR-4), a runtime failure
        in either channel is surfaced as a non-fatal
        `TranscriptionEvent.dualChannelError(channel:detail:)` on the
        merged event stream. The sibling channel keeps streaming and
        the on-disk recording is **never** affected. Cancelling or
        stopping one channel does not cascade.

        ## Building from source

        Requires:

        - macOS 14 (Sonoma) or later — `ScreenCaptureKit` audio capture
          requires macOS 13+; the codebase targets 14 to use the latest
          AsyncSequence APIs.
        - Swift 5.9+ toolchain (Xcode 15.0+, or Apple CommandLineTools with
          Swift 5.9; CommandLineTools cannot run XCTest — see R-17).

        Commands:

        ```sh
        swift build              # debug build at .build/debug/macrec
        swift build -c release   # release build at .build/release/macrec
        swift test               # unit tests (requires Xcode for the test runner — see R-17)
        swift run macrec --help  # one-shot run from the build cache
        ```

        ## Limitations / known issues

        - **macOS only.** Linux and Windows are out of scope; the entire
          capture stack is `ScreenCaptureKit` + `AVFoundation`.
        - **System audio capture requires Screen Recording permission.**
          This is a hard macOS TCC requirement, not a project decision.
        - **No log rotation in detach mode** (FR-29 v1 limitation). The log
          file at `~/.tool-agents/macrec/macrec.log` grows monotonically;
          users manage it manually (truncate / archive between recordings).
          Tracked for v2.
        - **Recording during system sleep is paused** (R-13). `SCStream`
          stops delivering buffers when the host sleeps; on wake the
          watchdog resets its baseline and the stream resumes, but audio
          captured during sleep is not present. A `willSleep` /
          `didWake` notification handler is implemented to reset state.
        - **Bluetooth output route may mute the submix in rare configs**
          (R-9). Specific Bluetooth devices have been observed to drop the
          system submix from `ScreenCaptureKit`; use a wired output route
          if you observe silence in the system track.
        - **Output device change mid-recording is undefined behavior**
          (R-3). `macrec` captures the submix of the default output device
          *at start time*; switching outputs during recording is unsupported
          and may produce silence in the system track.
        - **macOS 26.x (Tahoe) plain-binary TCC listing** (R-7). On macOS
          26+, plain CLI binaries can show as path-only entries in System
          Settings. Wrap the binary in a `.app` bundle for cleaner UX
          (out of scope for v1).
        - **Local toolchain without Xcode does not run XCTest** (R-17).
          The Apple CommandLineTools `swift test` driver is a stub that
          builds the test target but does not run assertions. Use Xcode or
          a CI image with Xcode for actual test runs.

        ## File locations

        - **Binary:**          `<repo>/.build/<config>/macrec` after `swift build`.
        - **User defaults:**   `~/.tool-agents/macrec/.env`           (mode `0600`, in folder mode `0700`).
        - **PID file:**        `~/.tool-agents/macrec/macrec.pid`     (mode `0600`, only present while a detached recording is running).
        - **Log file:**        `~/.tool-agents/macrec/macrec.log`     (mode `0600`, append-only, no rotation).
        - **Bootstrap folder:** `~/.tool-agents/macrec/`              (mode `0700`; auto-created on every subcommand invocation).

        ## Manual TCC test prerequisite for E2E scripts

        Because no CI runner can grant TCC permissions (R-5, NFR-10), the
        end-to-end shell scripts under `test_scripts/` skip their bodies
        when permissions are not yet granted. To run them locally:

        ```sh
        # 1. Build the binary once.
        swift build

        # 2. Trigger the prompts.
        swift run macrec check-permissions

        # 3. Approve in System Settings > Privacy & Security.

        # 4. Re-run the e2e script you want.
        bash test_scripts/e2e-30s-mixed.sh
        ```

        ## See also

        - `docs/design/refined-request-recording-tool.md` — full requirements
          and acceptance criteria.
        - `docs/design/project-design.md` — architecture, module interfaces,
          CLI surface, exit codes, permission flow, detach + stop.
        - `docs/design/project-functions.md` — registered functional
          requirements (FR-1 .. FR-29).
        - `docs/design/plan-001-recording-tool.md` — implementation plan
          (Phases A through L).
        - `docs/design/plan-003-live-transcription.md` — live-transcription
          implementation plan (Phases 0 through I).
        - `docs/design/refined-request-live-transcription.md` —
          live-transcription requirements brief (FR-45..FR-58, AC-LT-1..AC-LT-25).
        - `docs/design/plan-006-soniox-streaming.md` — Soniox streaming
          provider implementation plan (Phases A through I).
        - `docs/design/refined-request-soniox-streaming.md` — Soniox
          requirements brief (FR-SX-1..FR-SX-18, AC-SX-1..AC-SX-18).
        - `docs/design/configuration-guide.md` — per-variable configuration
          reference (includes the `MACREC_TRANSCRIBE*` family,
          `GOOGLE_API_KEY`, `SONIOX_API_KEY`, `MACREC_SONIOX_ENDPOINT`,
          and `MACREC_SONIOX_KEY_EXPIRES_AT`).
        - `Issues - Pending Items.md` — open risks (R-1 .. R-19) and
          completed items.
    </info>
</macrec>
