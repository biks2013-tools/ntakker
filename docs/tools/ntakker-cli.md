<ntakker-cli>
    <objective>
        `ntakker-cli` is a macOS-only command-line audio recording tool that captures
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
        ntakker-cli <subcommand> [options]
    </command>
    <info>
        ## What changed in v1.5

        > Default `--transcribe` value flipped from `none` to `apple`. Plain
        > `ntakker-cli start` now produces an on-device transcript sidecar by
        > default (Apple SpeechAnalyzer; no API key, no network). To restore
        > the old behaviour, set `NTAKKER_TRANSCRIBE=none` in your `.env` (or
        > pass `--transcribe none` on the CLI).
        >
        > A new provider id `apple` is now accepted alongside `gemini`
        > (and the deprecated `gemini-live` alias for `gemini`). Apple is
        > the only provider that supports comma-separated locale lists in
        > `--transcribe-language` for parallel dual-locale recognition.

        ## Overview

        `ntakker-cli` is the only first-party tool in this project so far. It
        compiles as a standalone Swift Package Manager executable (target
        `ntakker-cli`, library target `NtakkerCore`) and runs on macOS 14 (Sonoma)
        and later. The command surface mirrors classic Unix audio tools: a
        small set of subcommands, a single required output flag, and a
        four-source configuration precedence chain (shell env → user `.env`
        → local `.env` → CLI flags, lowest to highest priority).

        Subcommands at a glance:

        - `ntakker-cli start`             — begin a recording (foreground or detached).
        - `ntakker-cli stop`              — stop a recording started with `start --detach`.
        - `ntakker-cli list-devices`      — list available audio input devices.
        - `ntakker-cli check-permissions` — print Screen Recording and Microphone TCC state.

        Pipeline:

        ```
        ScreenCaptureKit (system audio)  ─┐
                                          ├─► HostClockAligner ─► BufferSummer ─► Recorder ─► .m4a / .wav / .caf
        AVFoundation     (microphone)    ─┘                          (mixed / split / stereo-split)
        ```

        ## Subcommands

        ### `start`

        Begins a recording. Stop with Ctrl-C (SIGINT) or SIGTERM in foreground
        mode, or with `ntakker-cli stop` when started with `--detach`.

        Verbatim help (from `swift run ntakker-cli start --help`):

        ```
        OVERVIEW: Begin a recording. Stop with Ctrl-C (SIGINT) or SIGTERM (foreground),
        or with 'ntakker-cli stop' (when started with --detach).

        USAGE: ntakker-cli start <options>

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
          --mic-aec <on|off>      Microphone echo cancellation. Default: off
                                  (opt-in as of plan-014). When on, runs a
                                  custom software NLMS adaptive filter
                                  (`SoftwareAECProcessor` v5) using the
                                  captured system-audio buffers as the
                                  reference signal to subtract speaker-to-
                                  mic acoustic bleed from the mic. Native
                                  mic bandwidth is preserved (no AGC, no
                                  noise suppression, no band narrowing).
                                  v5 self-guards via PTS-aligned ref
                                  windowing, a reference-activity gate,
                                  a double-talk detector, a 50 ms windowed
                                  divergence reset, and a soft-knee
                                  output limiter. Filter converges over
                                  the first 3–10 s of audio. Off (default)
                                  bypasses the processor (raw mic). Env:
                                  NTAKKER_MIC_AEC. (plan-013 / plan-014)
          --detach                Run the recording in the background (double-fork
                                  daemon). The shell prompt returns immediately; PID is
                                  written to --pid-file. Stop with 'ntakker-cli stop'.
                                  (FR-25)
          --pid-file <pid-file>   PID file path for --detach mode. Default:
                                  ~/.tool-agents/ntakker-cli/ntakker-cli.pid. Env:
                                  NTAKKER_PID_FILE. (FR-25/FR-27/FR-28)
          --log-file <log-file>   Log file path for --detach mode (mode 0600, append).
                                  Default: ~/.tool-agents/ntakker-cli/ntakker-cli.log. Env:
                                  NTAKKER_LOG_FILE. (FR-29)
          --transcribe <provider>
                                  Live transcription provider. Default: apple
                                  (changed from `none` in v1.5 / plan-005).
                                  Allowed: none | apple | apple-cloud | gemini
                                  | soniox | whisperkit | azure |
                                  azure-openai-realtime | elevenlabs.
                                  (`gemini-live` is accepted as a deprecated
                                  alias for one release; the resolver lowers
                                  it to `gemini` and logs a deprecation
                                  notice.) Env: NTAKKER_TRANSCRIBE.
                                  (FR-48 / plan-003 / plan-004 / plan-005 /
                                  plan-006 / plan-007)
          --soniox-endpoint <url>
                                  Soniox WebSocket endpoint override (for
                                  EU/JP data residency). Default:
                                  wss://stt-rt.soniox.com/transcribe-websocket.
                                  Env: NTAKKER_SONIOX_ENDPOINT. (plan-006)
          --transcribe-source <source>
                                  Audio source for transcription. Default: mixed.
                                  Allowed: system | mic | mixed | both. Env:
                                  NTAKKER_TRANSCRIBE_SOURCE. (FR-47)
          --transcribe-format <format>
                                  Sidecar transcript format. Default: jsonl.
                                  Allowed: jsonl | txt | srt | vtt. Env:
                                  NTAKKER_TRANSCRIBE_FORMAT. (FR-51)
          --transcribe-model <model-id>
                                  Provider-specific model id override. Default:
                                  provider's pinned default (currently
                                  `gemini-3-flash-preview` for the
                                  `gemini` provider). Env:
                                  NTAKKER_TRANSCRIBE_MODEL. See "Model id"
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
                                  auto-detect. Env: NTAKKER_TRANSCRIBE_LANGUAGE.
          --transcribe-key-expires-at <iso-8601>
                                  Optional ISO-8601 date marking when the
                                  configured API key expires. If past, a warning
                                  is logged at start; recording is NOT blocked.
                                  Env: NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT.
                                  (plan-003 §LT-5.2)
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
        > `~/.tool-agents/ntakker-cli/.env` (mode `0600`). See
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
        ntakker-cli start --output ~/recordings/test.m4a

        # 2. Record for exactly 30 s, overwriting any existing file.
        ntakker-cli start --output /tmp/sample.m4a --max-duration 30 --overwrite

        # 3. Detached background recording (returns the prompt immediately).
        #    Stop later with `ntakker-cli stop`.
        ntakker-cli start --detach --output ~/recordings/meeting.m4a --overwrite

        # 4. Two-file split layout (mic + system as separate files).
        #    Output naming is derived from --output: writes
        #    `~/recordings/podcast.mic.m4a` and `~/recordings/podcast.system.m4a`.
        ntakker-cli start --layout split --output ~/recordings/podcast.m4a

        # 5. Stereo-split with system on the left, mic on the right;
        #    use a specific mic device (find its UID with `ntakker-cli list-devices`).
        ntakker-cli start \
            --layout stereo-split --mic-channel right \
            --mic-device "BuiltInMicrophoneDevice" \
            --output ~/recordings/interview.m4a

        # 6. Recording with no transcription (default behaviour — identical
        #    to pre-plan-003 builds; no network connections, no sidecar files).
        ntakker-cli start --output ~/recordings/talk.m4a

        # 7. Recording with Gemini transcription writing a JSONL sidecar.
        #    GOOGLE_API_KEY must be exported (or in ~/.tool-agents/ntakker-cli/.env).
        #    Produces ~/recordings/talk.m4a + ~/recordings/talk.transcript.jsonl.
        export GOOGLE_API_KEY=...   # from https://aistudio.google.com/app/apikey
        ntakker-cli start \
            --transcribe gemini \
            --transcribe-source mixed \
            --transcribe-format jsonl \
            --output ~/recordings/talk.m4a

        # 8. Mic-only Gemini transcription with an SRT sidecar
        #    (final-only cues, suitable for video-editor import).
        ntakker-cli start \
            --transcribe gemini \
            --transcribe-source mic \
            --transcribe-format srt \
            --output ~/recordings/lecture.m4a

        # 9. Detached background recording WITH transcription (plan-004
        #    lifted the v1 detach-incompatible restriction; the REST
        #    batch architecture has no terminal-output dependency).
        #    Stop later with `ntakker-cli stop`.
        ntakker-cli start \
            --detach \
            --transcribe gemini \
            --transcribe-format jsonl \
            --output ~/recordings/meeting.m4a --overwrite

        # 10. Soniox cloud streaming with bilingual Greek + English hints
        #     and a JSONL sidecar.  SONIOX_API_KEY must be exported (or in
        #     ~/.tool-agents/ntakker-cli/.env). Produces ~/talk.m4a +
        #     ~/talk.transcript.jsonl. Default model: stt-rt-v4.
        export SONIOX_API_KEY=sk_...   # from https://console.soniox.com
        ntakker-cli start --transcribe soniox --transcribe-language el,en \
            --output ./talk.m4a --transcribe-format jsonl

        # 11. Azure OpenAI batch (REST) transcription using
        #     gpt-4o-mini-transcribe. Requires AZURE_OPENAI_API_KEY,
        #     AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT (find
        #     the deployment name in Azure Foundry → Models + endpoints).
        export AZURE_OPENAI_API_KEY=...
        export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
        export AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini-transcribe
        ntakker-cli start --transcribe azure --transcribe-format jsonl \
            --output ~/recordings/meeting.m4a

        # 12. Azure OpenAI realtime (WebSocket) transcription with
        #     `intent=transcription`. Same env vars as #11; produces
        #     volatile partials + stable finals on the JSONL sidecar.
        ntakker-cli start --transcribe azure-openai-realtime \
            --transcribe-format jsonl \
            --output ~/recordings/standup.m4a

        # 13. ElevenLabs Scribe v2 batch transcription with diarization
        #     and per-word speaker labels. ELEVENLABS_API_KEY must be
        #     exported (or in ~/.tool-agents/ntakker-cli/.env).
        export ELEVENLABS_API_KEY=sk_...   # from https://elevenlabs.io/app/settings/api-keys
        export ELEVENLABS_DIARIZE=true
        export ELEVENLABS_NUM_SPEAKERS=2
        ntakker-cli start --transcribe elevenlabs \
            --transcribe-format jsonl \
            --output ~/recordings/interview.m4a
        ```

        ### `stop`

        Stops a detached recording started with `ntakker-cli start --detach`. Reads
        the PID file (default `~/.tool-agents/ntakker-cli/ntakker-cli.pid`), sends
        `SIGTERM`, and polls every 100 ms for clean exit, up to
        `--stop-timeout` seconds.

        Verbatim help:

        ```
        OVERVIEW: Stop a detached recording started with 'ntakker-cli start --detach'.

        USAGE: ntakker-cli stop [--pid-file <pid-file>] [--stop-timeout <stop-timeout>]

        OPTIONS:
          --pid-file <pid-file>   PID file path of the detached recording. Default:
                                  ~/.tool-agents/ntakker-cli/ntakker-cli.pid. Env:
                                  NTAKKER_PID_FILE.
          --stop-timeout <stop-timeout>
                                  Seconds to wait for the recording process to exit
                                  cleanly after SIGTERM. Default: 35. Env:
                                  NTAKKER_STOP_TIMEOUT.
          --version               Show the version.
          -h, --help              Show help information.
        ```

        Decision tree (project-design.md §14.3):

        - PID file missing               → `NtakkerError.noActiveRecording`,    exit 78.
        - PID file present but stale     → remove file, `NtakkerError.staleRecording`, exit 75.
        - PID file malformed             → remove file, treated as stale,      exit 75.
        - PID file live, exits in time   →                                     exit 0.
        - PID file live, timeout fires   → `NtakkerError.stopTimeout`,          exit 70.

        Examples:

        ```sh
        # 1. Stop the default detached recording.
        ntakker-cli stop

        # 2. Stop a recording that used a custom --pid-file.
        ntakker-cli stop --pid-file /tmp/ntakker-cli.session1.pid

        # 3. Wait up to 60 s instead of the default 35 s for finalization.
        ntakker-cli stop --stop-timeout 60
        ```

        ### `list-devices`

        Prints one record per available input audio device, in a parseable
        single-record-per-line format. Always exits 0 if at least one device
        is found; throws `NtakkerError.noInputDevicesAvailable` (exit 70) if
        the system reports zero inputs.

        Verbatim help:

        ```
        OVERVIEW: Print available audio input devices.

        USAGE: ntakker-cli list-devices

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
        $ ntakker-cli list-devices
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

        USAGE: ntakker-cli check-permissions

        OPTIONS:
          --version               Show the version.
          -h, --help              Show help information.
        ```

        Example:

        ```sh
        if ntakker-cli check-permissions; then
            ntakker-cli start --output ~/recordings/now.m4a --max-duration 60
        else
            echo "Grant Screen Recording + Microphone in System Settings, then re-run."
        fi
        ```

        ## Configuration precedence

        Every configuration value is resolved in this order, from lowest
        priority to highest:

        1. Shell environment       (`process.env` equivalent — `ProcessInfo.processInfo.environment`).
        2. User `.env`             (`~/.tool-agents/ntakker-cli/.env`, mode 0600).
        3. Local `.env`            (`./.env` in the current working directory).
        4. CLI flags               (always win).

        Higher-priority sources override lower ones on a per-key basis. The
        canonical env-var names use the `NTAKKER_*` prefix, with the
        intentional exception of `OUTPUT_PATH` (which is unprefixed because
        the configuration design predates the prefix convention).

        See `docs/design/configuration-guide.md` for the full per-variable
        table (allowed values, defaults, recommended storage tier).

        ## Permissions

        `ntakker-cli` requires two macOS TCC permissions:

        - **Screen Recording** — required by `ScreenCaptureKit` to capture
          the system audio submix. macOS attaches audio capture authorization
          to the Screen Recording namespace; there is no separate "system
          audio" entitlement.
        - **Microphone** — required by `AVFoundation` to capture the input
          device.

        On first run, `ntakker-cli` triggers the standard system prompts. After
        the user approves, the same-process state cannot be re-read (a known
        macOS TCC limitation), so `ntakker-cli start` exits with
        `NtakkerError.screenRecordingPermissionNotDetermined` (exit 75) or
        `NtakkerError.microphonePermissionNotDetermined` (also 75); re-run the
        command to pick up the granted state.

        Subsequent denials surface as
        `NtakkerError.screenRecordingPermissionDenied` /
        `NtakkerError.microphonePermissionDenied` (exit 77, `EX_NOPERM`) with
        an explicit System Settings path printed to stderr (see
        project-design.md §8 for the locked strings).

        ### Speech Recognition (for `--transcribe apple`)

        When `--transcribe apple` is selected (the v1.5 default),
        `ntakker-cli` also needs the **Speech Recognition** TCC grant. The
        `Info.plist` carries `NSSpeechRecognitionUsageDescription`; the
        first run that opts into the Apple provider triggers a system
        prompt. Denying the prompt — or revoking the grant later in
        System Settings → Privacy & Security → Speech Recognition —
        causes `ntakker-cli start` to exit 77 (`EX_NOPERM`) via
        `NtakkerError.speechRecognitionPermissionDenied` before any
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
        `.build/<config>/ntakker-cli`, every rebuild can change the TCC identity
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

        ## Microphone acoustic echo cancellation (AEC)

        AEC is **opt-in** as of plan-014. Pass `--mic-aec on` (or set
        `NTAKKER_MIC_AEC=on` / flip the popover toggle) to route the
        mic through the custom software AEC (`SoftwareAECProcessor`
        v5). The processor sits between the existing mic and
        system-audio capture sources and the aligner: it takes the
        captured system-audio buffers as the reference signal for an
        NLMS (Normalized Least Mean Squares) adaptive filter,
        estimates the speaker→air→mic echo path on each channel, and
        subtracts the estimate from the raw mic samples before they
        are written to disk. With AEC on, the long-standing "I can
        hear Spotify / Zoom / browser audio on the mic channel"
        problem in `--layout split` / `stereo-split` recordings goes
        away.

        > **Fixed 2026-10-17 (EVAL-2026-10-16, plan-022 T4).** Until
        > this fix the filter's reference window started one sample
        > *after* the mic sample. Depending on how far the system
        > audio led the mic, it read either future reference audio or
        > audio 85–170 ms old, so it could not learn a real echo path,
        > and on a synthetic echo it left more echo than it removed.
        > The window now ends at the mic sample's own time. The same
        > change made the processor about 3.3× cheaper (about 1.6 % of
        > one core per second of audio, against 5.3 %): it keeps a
        > running window energy, fuses leakage and update into one
        > vector pass, runs one filter against a mono reference when
        > the mic is an upmixed mono device (the usual built-in mic),
        > and no longer holds the system-audio thread's lock during
        > the filter loop. If you tried AEC before and it did nothing,
        > try it again.

        > **Why opt-in?** The default-on shipping of v3/v4 produced
        > "filtering distortion" on setups where there was no actual
        > speaker bleed (headphones, low speaker volume, etc.) — see
        > plan-014 §0 and the v5 stability layers below for the fix.
        > With v5 the processor is safe to leave on whenever there
        > is real bleed to cancel, but for headphone users it costs
        > CPU doing nothing useful. Opt-in matches behaviour to user
        > intent.

        > **History.** The first plan-013 attempt used Apple's
        > built-in `AVAudioEngine.inputNode.setVoiceProcessingEnabled`
        > path. That approach turned out to be incompatible with this
        > project's `SCStream` system-audio capture: the underlying
        > `AUVoiceProcessingIO` audio unit needs unobstructed access
        > to the system OUTPUT device for its AEC reference, and
        > `SCStream` taps the same OS audio mix. The `AVMicrophoneSource`
        > path therefore stays the proven `AVCaptureSession` capture;
        > the AEC is implemented in software downstream, where there
        > is no HAL-level conflict. See `docs/design/plan-013-microphone-aec.md` §0
        > for the full story.

        ### Trade-offs

        Compared to Apple's voice processing, the software AEC has a
        very different trade-off envelope:

        - **No AGC.** The captured mic gain is unchanged — quiet
          speakers stay quiet; loud peaks are not compressed. If you
          need automatic levelling, apply it as a post-processing
          step.
        - **No noise suppression.** Constant noise (fans, HVAC,
          street rumble) is captured as-is. NLMS only cancels what
          appears in the reference signal — i.e. system audio
          playing through the speakers — not the mic's ambient room
          tone.
        - **Native bandwidth.** The mic frequency response is
          unchanged. Music / wide-band capture works; this is the
          biggest improvement vs. the old voice-processing path.
        - **Convergence delay.** The filter starts with all weights
          at zero and adapts conservatively (μ=0.01 in v5, an order
          of magnitude slower than v3/v4). It needs 3–10 s of speech
          / music reference to converge. During convergence the
          residual bleed drops gradually; after convergence it is
          typically 15–25 dB below the uncancelled level.

        ### v5 stability layers (plan-014)

        v5 adds five safeguards against the divergence that plagued
        v3 and v4:

        - **Reference-activity gate.** Adaptation is frozen whenever
          the reference RMS is below `~ -50 dBFS` (system silence).
        - **Double-talk detector.** Adaptation is frozen whenever the
          mic short-term power exceeds the reference short-term
          power × 4 (user is talking; no real echo to learn).
        - **Divergence reset.** A 50 ms sustained-violation window
          on `residualEnergy > micEnergy` triggers a weight reset to
          zero — the filter recovers from any momentary instability
          rather than locking it in.
        - **Calmer NLMS step + leakage.** μ is 0.01 (10× v3/v4),
          regularization is 1e-2, the per-sample weight delta is
          clamped at ±1e-3, and a slow leakage of `1e-5` per sample
          bleeds off any stray growth.
        - **Soft-knee output limiter.** A tanh-style limiter at
          knee=0.7 / ceiling=0.95 replaces v4's hard clip, so the
          residual signal stays band-limited and AAC can never
          overshoot 0 dBFS on the encoded output.

        v5 also indexes the reference ring buffer by **PTS-derived
        logical position** (Layer F), so the ref window for any mic
        sample at host time *t* covers the corresponding system
        samples at host time *t*, regardless of whether the two
        capture stacks happen to deliver buffers in lockstep.
        - **No tracking of fast environmental changes.** If you
          move the laptop or cover the mic mid-recording, the echo
          path changes; the filter takes another 1–3 s to re-adapt
          and the residual briefly rises during that window.
        - **CPU cost ≈ 5–8 % of one Apple Silicon P-core** for
          stereo at 48 kHz with the default 4096-tap filter.

        AEC is off by default. Turn it on per session with
        `--mic-aec on` (CLI), `NTAKKER_MIC_AEC=on` (env or
        `~/.tool-agents/ntakker-cli/.env`), or the popover toggle in
        `ntakker`. With AEC off the mic is recorded verbatim and
        the system source feeds the aligner directly, exactly as in
        pre-plan-013 builds.

        ### What you'll see in the logs

        At session start, `ntakker-cli` prints one of these two lines on
        `stderr` (or to the detach log file) so it is easy to verify
        which path is active:

        ```
        … mic source = AVMicrophoneSource (AEC processor=on)
        … mic source = AVMicrophoneSource (AEC processor=off)
        ```

        When the processor is active, you will additionally see (on
        the `ntakker-cli.aec` logger):

        ```
        … SoftwareAECProcessor v5 (plan-014: PTS-aligned NLMS + ref-activity gate + double-talk detector + divergence reset + soft limiter) initialised: filterLength=4096 (~85 ms) μ=0.01 reg=0.01 stepMax=0.001 leak=1e-05 …
        … SoftwareAECProcessor first reference: frames=… channels=2 bufferStartPTS=…
        … SoftwareAECProcessor first mic processed: frames=… channels=2 micFirstPTS=…
        ```

        If v5's divergence reset ever fires, you will also see:

        ```
        … AEC divergence reset fired N time(s) — weights re-zeroed (cumulative resets=…)
        ```

        On a healthy long-form recording the cumulative count should
        stay ≤ 1–2 over the entire session. Sustained reset activity
        (multiple per minute) usually means the reference signal is
        genuinely uncorrelated with what the mic is hearing — turn
        AEC off, or reduce the speaker-to-mic distance / volume.

        The pre-existing 1 Hz `mic_health: …` heartbeat from
        `AVMicrophoneSource` continues to fire unchanged — a healthy
        run shows non-zero `recentPeakAmp` while you speak. (The
        cleaned mic feeds the aligner, but the heartbeat is a
        diagnostic on the raw mic source itself, so it always
        reflects the unprocessed signal.)

        ### Limitations

        - **The reference signal is the system audio that `SCStream`
          captures.** If the user is playing audio through a route
          `SCStream` does not see (e.g. an external audio interface
          set as the default output without screen-recording
          permission on it), the bleed will not be cancelled because
          the reference is silent.
        - **Cross-channel echo is not modelled.** Each channel runs
          an independent NLMS filter; if the L speaker's echo
          dominantly shows up on the R mic capsule (or vice versa),
          a single-channel filter cannot fully cancel it. In
          practice the residual is still substantially reduced
          because the L→mic and R→mic acoustic paths are similar
          enough on a laptop chassis that per-channel cancellation
          recovers most of the gain.
        - **No adaptive resampling.** The processor assumes mic and
          reference are both at the same sample rate (48 kHz, the
          pipeline canonical rate). Other rates would require the
          processor to handle resampling — not a v1 concern because
          the canonical pipeline normalises everything before this
          point.
        - **Filter weights are not persisted across sessions.** Each
          recording converges from scratch. Persisting per-device
          weights would shave the first 1–3 s of residual but is
          not a v1 priority.

        ## Exit codes

        Locked by project-design.md §9.5. The mapping below is sourced
        directly from `Sources/NtakkerCore/Errors/NtakkerError.swift`.

        | Code | Symbolic         | `NtakkerError` cases                                                                                                                | Meaning                                  |
        |------|------------------|------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------|
        | 0    | success          | normal completion or SIGINT-finalized recording or clean `stop`                                                                    | success                                  |
        | 1    | generic          | `unknown`, `ioError`, `finishWritingFailed`                                                                                        | generic / unexpected runtime failure     |
        | 2    | partial output   | `writerFinalizationTimeout`                                                                                                        | finalization timed out (file may be partial) |
        | 64   | `EX_USAGE`       | `invalidConfigValue`, `dotEnvParseError`                                                                                           | usage error / invalid argument           |
        | 66   | `EX_NOINPUT`     | `outputParentMissing`, `outputAlreadyExists`, `pidFileWriteFailed`                                                                  | output / PID file path error             |
        | 70   | `EX_SOFTWARE`    | `noInputDevicesAvailable`, `scStreamFailedToStart`, `scStreamSilentStopExceeded`, `avCaptureFailedToStart`, `micAECUnavailable`, `writerFailedToStart`, `stopTimeout` | runtime failure                          |
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
        > `NtakkerError.transcriptionDetachUnsupported` case has been deleted
        > from `NtakkerError`.

        ## Live transcription

        `ntakker-cli` can stream the captured audio to a streaming speech-to-text
        provider in parallel with the on-disk recording, producing a sidecar
        transcript file alongside the audio file. The feature is **opt-in**;
        with no `--transcribe` flag and no `NTAKKER_TRANSCRIBE` env var, the
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
        | `apple-cloud`  | Apple Cloud Speech Recognition (`SFSpeechRecognizer` with `requiresOnDeviceRecognition=false`). Requires the bundled `ntakker.app` — the raw CLI cannot present the TCC Speech Recognition prompt. No extra API key beyond the Apple ID on the device. | _(none)_ |
        | `soniox`       | **Soniox cloud streaming** (WebSocket; PCM16 16 kHz mono frames; plan-006). Default model `stt-rt-v4`. Supports language identification across multiple BCP-47 hints (e.g. `el,en`); endpoint detection is enabled; speaker diarization is **on by default** (overridable via `NTAKKER_SONIOX_DIARIZE`, plan-012). ~$0.12/hour at list price. | `SONIOX_API_KEY`   |
        | `azure`        | Azure OpenAI batch transcription (REST) via `gpt-4o-mini-transcribe`. | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` |
        | `azure-openai-realtime` | Azure OpenAI Realtime (WebSocket, `intent=transcription`). Session auto-reconnects at the 58-minute mark. | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT` |
        | `elevenlabs`   | ElevenLabs Scribe v2 batch. Supports diarization. Free/Starter tiers cap at 8 concurrent requests. | `ELEVENLABS_API_KEY` |

        Additional providers (OpenAI Realtime, Deepgram Streaming,
        AssemblyAI Streaming) are admitted by the `TranscriptionProvider`
        protocol (NFR-21) and tracked as v2 follow-ups.

        ### Two-tier requirement

        Two configuration values must be present together when transcription
        is enabled:

        1. **`NTAKKER_TRANSCRIBE` (or `--transcribe`)** picks the provider.
           Resolved through the four-tier chain (shell env → user `.env` →
           local `.env` → CLI flag). Default `none`.
        2. **The provider's required API key** must be resolvable by the
           same chain at recording start. For `gemini` (and its deprecated
           alias `gemini-live`) this is `GOOGLE_API_KEY`; for `soniox` it
           is `SONIOX_API_KEY`. If the chosen provider needs a key and
           none is found, `ConfigResolver` raises
           `NtakkerError.transcriptionApiKeyMissing(provider:)` (exit `78`)
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
        transcription, `ntakker-cli` runs **two** transcription drivers in
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
        | `elevenlabs`              | Two parallel POSTs. Free/Starter tiers cap concurrent requests at 8 — `ntakker-cli` logs a warning at session start. |

        **UI:** the live transcript panel renders TWO stacked auto-
        scrolling lanes labelled `System audio` and `Microphone`.

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
        (ntakker) and on the events stream consumed by
        `SessionCoordinator`. Use `billableSeconds` × the provider's
        published per-second rate to estimate cost per recording. (The
        plan-003 §LT-7.2 / §LT-9.1 512-byte JSONL header line was
        dropped by plan-004 — JSONL sidecars now carry one record per
        coalesced segment with id-keyed in-place rewrite, and metrics
        are surfaced via `TranscriptionMetrics` rather than a file
        header.)

        ### Model id

        The `--transcribe-model` flag (env `NTAKKER_TRANSCRIBE_MODEL`)
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
        | Speaker diarization    | **ON** by default since plan-012 (overridable via `NTAKKER_SONIOX_DIARIZE` / `--soniox-diarize`; UI toggle at Settings → Soniox → "Diarize speakers") |

        #### Endpoint regions

        For data-residency requirements, override the endpoint via
        `--soniox-endpoint <url>` or `NTAKKER_SONIOX_ENDPOINT`:

        | Region | Endpoint URL                                          |
        |--------|--------------------------------------------------------|
        | US     | `wss://stt-rt.soniox.com/transcribe-websocket` (default) |
        | EU     | `wss://stt-rt.eu.soniox.com/transcribe-websocket`     |
        | JP     | `wss://stt-rt.jp.soniox.com/transcribe-websocket`     |

        See <https://soniox.com/docs/stt/data-residency> for the
        authoritative list. The resolver validates the URL is `ws://`
        or `wss://` and raises `NtakkerError.invalidConfigValue`
        (exit 64) otherwise.

        #### API key

        `SONIOX_API_KEY` is the only accepted source for the credential
        — there is no `--soniox-api-key` CLI flag (avoids leakage into
        shell history). Obtain a key at <https://console.soniox.com>
        (Account → API keys), then add it to
        `~/.tool-agents/ntakker-cli/.env` (mode `0600`):

        ```sh
        chmod 0700 ~/.tool-agents/ntakker-cli
        echo 'SONIOX_API_KEY=sk_...' >> ~/.tool-agents/ntakker-cli/.env
        chmod 0600 ~/.tool-agents/ntakker-cli/.env
        ```

        Pair the key with `NTAKKER_SONIOX_KEY_EXPIRES_AT` (ISO-8601 date)
        if your team rotates keys on a fixed cadence; the resolver emits
        a soft renewal reminder in the 7 days before expiry. The
        per-provider variable takes precedence over the shared
        `NTAKKER_TRANSCRIBE_KEY_EXPIRES_AT`.

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

        **Override:** set `NTAKKER_SONIOX_DIARIZE=false` (or pass
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
        | Language hint    | _(auto-detect — `NTAKKER_PARAKEET_LANGUAGE` is informational only because FluidAudio v0.8.x has no per-call language API)_ |
        | Streaming        | NOT supported (batch-only, mirrors WhisperKit)            |
        | API key          | Not required                                              |
        | First-launch DL  | ~600 MB to Application Support (cached after)             |

        **Examples:**

        ```sh
        # Parakeet — defaults to v3 multilingual.
        ntakker-cli start --transcribe parakeet \
            --output ~/recordings/greek-meeting.m4a

        # Override the model id (forward-compat — currently
        # informational, FluidAudio v0.8.x clamps to v3 internally).
        ntakker-cli start --transcribe parakeet \
            --parakeet-model parakeet-tdt-0.6b-v3 \
            --parakeet-language el \
            --output ~/recordings/heavy.m4a
        ```

        **Model-resolution precedence** (mirrors WhisperKit):

        1. `--parakeet-model` / `NTAKKER_PARAKEET_MODEL` (Parakeet-specific override).
        2. `--transcribe-model` / `NTAKKER_TRANSCRIBE_MODEL` (shared).
        3. Provider default (`parakeet-tdt-0.6b-v3`).

        **Why the version pin (FluidAudio v0.8.2):** v0.9.x bumped the
        package's swift-tools-version to 6.0 and the new
        `StreamingAsrManager.swift` triggers Swift 6 strict-concurrency
        errors when built. v0.8.x uses tools 5.10 and exposes the same
        batch ASR surface (`AsrManager` / `AsrModels.downloadAndLoad
        (version: .v3)`). Because we're batch-only by design, the
        absence of the streaming manager is irrelevant. Bump the pin
        once upstream resolves the strict-concurrency issue.

        ## Building from source

        Requires:

        - macOS 14 (Sonoma) or later — `ScreenCaptureKit` audio capture
          requires macOS 13+; the codebase targets 14 to use the latest
          AsyncSequence APIs.
        - Swift 5.9+ toolchain (Xcode 15.0+, or Apple CommandLineTools with
          Swift 5.9; CommandLineTools cannot run XCTest — see R-17).

        Commands:

        ```sh
        swift build              # debug build at .build/debug/ntakker-cli
        swift build -c release   # release build at .build/release/ntakker-cli
        swift test               # unit tests (requires Xcode for the test runner — see R-17)
        swift run ntakker-cli --help  # one-shot run from the build cache
        ```

        ### Installing system-wide on `PATH`

        To use `ntakker-cli` as a normal CLI from any shell:

        ```sh
        swift build -c release --product ntakker-cli
        sudo cp .build/release/ntakker-cli /usr/local/bin/ntakker-cli
        ntakker-cli --help
        ```

        `/usr/local/bin` is on the default `zsh` `PATH`. If you
        prefer a non-`sudo` location, copy to `~/.local/bin` (or any
        directory on your `PATH`) instead.

        ### TCC notes

        The CLI inherits Microphone + Screen Recording grants
        attached to the parent terminal binary (Terminal.app, iTerm,
        etc.). On first run macOS will pop the two prompts; click
        Allow. Apple Cloud Speech Recognition (`--transcribe
        apple-cloud`) does **not** work from the raw CLI — it only
        works from the bundled `ntakker.app` (see
        [docs/tools/ntakker.md](ntakker.md) → "Packaging as a
        typical macOS `.app` bundle").

        Provider API keys (Gemini, Soniox, Azure, ElevenLabs) are
        read from environment variables, then
        `~/.tool-agents/ntakker-cli/.env`, then the local `.env`, then CLI
        flags. See the "Configuration precedence" section above for
        the full resolution chain.

        ## Limitations / known issues

        - **macOS only.** Linux and Windows are out of scope; the entire
          capture stack is `ScreenCaptureKit` + `AVFoundation`.
        - **System audio capture requires Screen Recording permission.**
          This is a hard macOS TCC requirement, not a project decision.
        - **No log rotation in detach mode** (FR-29 v1 limitation). The log
          file at `~/.tool-agents/ntakker-cli/ntakker-cli.log` grows monotonically;
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
          (R-3). `ntakker-cli` captures the submix of the default output device
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

        - **Binary:**          `<repo>/.build/<config>/ntakker-cli` after `swift build`.
        - **User defaults:**   `~/.tool-agents/ntakker-cli/.env`           (mode `0600`, in folder mode `0700`).
        - **PID file:**        `~/.tool-agents/ntakker-cli/ntakker-cli.pid`     (mode `0600`, only present while a detached recording is running).
        - **Log file:**        `~/.tool-agents/ntakker-cli/ntakker-cli.log`     (mode `0600`, append-only, no rotation).
        - **Bootstrap folder:** `~/.tool-agents/ntakker-cli/`              (mode `0700`; auto-created on every subcommand invocation).

        ## Manual TCC test prerequisite for E2E scripts

        Because no CI runner can grant TCC permissions (R-5, NFR-10), the
        end-to-end shell scripts under `test_scripts/` skip their bodies
        when permissions are not yet granted. To run them locally:

        ```sh
        # 1. Build the binary once.
        swift build

        # 2. Trigger the prompts.
        swift run ntakker-cli check-permissions

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
          reference (includes the `NTAKKER_TRANSCRIBE*` family,
          `GOOGLE_API_KEY`, `SONIOX_API_KEY`, `NTAKKER_SONIOX_ENDPOINT`,
          and `NTAKKER_SONIOX_KEY_EXPIRES_AT`).
        - `Issues - Pending Items.md` — open risks (R-1 .. R-19) and
          completed items.
    </info>
</ntakker-cli>
