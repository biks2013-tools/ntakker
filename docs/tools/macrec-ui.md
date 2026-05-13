<macrecUi>
    <objective>
        `macrec-ui` is a macOS-only menu-bar status item application that
        provides a graphical front-end for the `macrec` audio recording
        engine. It runs alongside (not in place of) the `macrec` CLI: the
        UI drives the same `MacrecCore` library in-process, exposing a
        compact popover toolbar from which users can start, pause, resume,
        stop, and split recordings without typing any CLI command. The
        toolbar surfaces an elapsed-time read-out, the current output file
        name (editable), format / layout / output-folder / microphone
        pickers, a permission-status indicator, and per-source level
        meters for the system-audio submix and the microphone. The popover
        also exposes opt-in live transcription (Google Gemini in v1,
        with `None` as the default) including a transcription source picker,
        a sidecar-format picker, an inline live-transcript panel, a one-time
        privacy-disclosure dialog, and a per-recording cost / latency
        summary. Targets macOS 14 (Sonoma) or later and ships as a separate
        SwiftPM
        executable target (`macrec-ui`) under its own bundle id
        `com.local.macrec-ui` so its TCC grants are independent of the
        CLI's. There are no CLI arguments in v1 — the binary launches the
        menu-bar app directly.
    </objective>
    <command>
        macrec-ui
    </command>
    <info>
        ## Overview

        `macrec-ui` is the second first-party tool in this project, a
        native macOS menu-bar companion to the `macrec` CLI (see
        [docs/tools/macrec.md](macrec.md)). It is intended for
        developers and power users on macOS 14 (Sonoma) or later who
        want one-click access to the recording engine without
        memorising CLI flags. The UI does **not** shell out to the
        `macrec` binary — it links the shared `MacrecCore` SwiftPM
        library directly and drives `RecordingSession` in-process
        (FR-42), so the on-disk output of a UI-driven recording is
        bit-for-bit identical to a `macrec start` invocation with the
        same settings.

        Pipeline (shared with the CLI, see [docs/tools/macrec.md](macrec.md)):

        ```
        ScreenCaptureKit (system audio)  ─┐
                                          ├─► HostClockAligner ─► BufferSummer ─► Recorder ─► .m4a / .wav / .caf
        AVFoundation     (microphone)    ─┘                          (mixed / split / stereo-split)
        ```

        Surface added on top of the CLI engine: an `NSStatusItem` with a
        state-driven icon (FR-41), an `NSPopover` containing an
        `NSHostingController<RootView>` (FR-30) with the four lifecycle
        controls (Start / Pause / Resume / Stop) plus manual Split
        (FR-31, FR-32), an editable filename field (FR-35), format /
        layout / output-folder / microphone pickers (FR-36, FR-38,
        FR-39), a live permission-status indicator (FR-37), an
        elapsed-time read-out (FR-40), and per-source peak/RMS level
        meters at 30 Hz (FR-43). Configuration follows the same
        four-tier resolution chain as the CLI.

        ## System requirements

        - **macOS 14 (Sonoma) or later.** `ScreenCaptureKit` audio
          capture requires macOS 13+; the codebase targets 14 to use
          the latest `AsyncSequence` APIs and SwiftUI `@Observable`.
        - **Apple silicon or Intel.** The `macrec-ui` target ships as
          a universal binary (arm64 + x86_64) matching the CLI
          (NFR-15).
        - **Screen Recording TCC grant.** Required by
          `ScreenCaptureKit` for the system-audio submix.
        - **Microphone TCC grant.** Required by `AVFoundation` for
          input capture.
        - **~50 MB of disk** for a release build of the binary plus
          its embedded Info.plist section.
        - **Swift 5.9+ toolchain** (Xcode 15.0+ recommended; Apple
          CommandLineTools is sufficient for `swift build` / `swift
          run`, but its `swift test` driver is a stub on CLT — see
          R-22).

        ## First-run setup

        `macrec-ui` is shipped as a SwiftPM `executableTarget` (no
        `.app` bundle wrapper in v1). Launch it directly from the
        build cache or run a release build:

        ```sh
        # Development (one-shot, debug build).
        swift run macrec-ui

        # Production-flavoured release build.
        swift build -c release
        .build/release/macrec-ui
        ```

        On the very first launch you will see **two separate macOS TCC
        prompts**:

        1. **Microphone access** (raised by `AVFoundation` the first
           time the mic picker enumerates devices or Start is clicked).
        2. **Screen Recording access** (raised by `ScreenCaptureKit`
           the first time `SCStream` is configured for system-audio
           capture).

        A **third prompt — Speech Recognition access** — appears the
        first time the user opts into the Apple provider via the Live
        transcription picker (which is the v1.5+ default), or on first
        Start with the picker still set to Apple. The
        `NSSpeechRecognitionUsageDescription` string is embedded in
        the UI's Info.plist. Denying this prompt — or revoking the
        grant later in System Settings → Privacy & Security → Speech
        Recognition — surfaces inline as
        `MacrecError.speechRecognitionPermissionDenied` (exit 77,
        `EX_NOPERM`) when Start is pressed; the recording itself is
        not started so no audio file is created.

        All three prompts are bound to the `com.local.macrec-ui`
        bundle id (the UI's identity), which is **separate** from the
        CLI's `com.local.macrec` bundle id. Granting any permission
        to the CLI does **not** carry over to the UI (R-23) — this
        isolation is intentional, lets each tool be revoked
        independently, and is a deliberate consequence of FR-42's
        in-process design.

        After both prompts have been answered, look for the small
        microphone-with-soundwave glyph in the system menu-bar tray
        (right-hand side of the menu bar). Clicking it opens the
        popover toolbar. The status item is retained as a strong
        property on `AppDelegate` so it does not silently deallocate
        (R-26).

        ## UI surface walkthrough

        The popover lays out top-to-bottom in a fixed-width column.
        Every control surfaced below is part of v1; nothing on this
        list is deferred.

        ### Permission status indicators (FR-37)

        Two coloured chips at the top of the popover labelled
        **"Screen Recording"** and **"Microphone"**. Each chip shows
        one of three live states refreshed at 2 Hz while the popover
        is visible (and on
        `NSApplication.didBecomeActiveNotification`):

        - **Green** — granted; ready to record.
        - **Amber** — not-determined; clicking opens the relevant
          System Settings pane and triggers the prompt.
        - **Red** — denied or restricted; clicking opens System
          Settings deep-linked to the offending pane.

        Start is disabled unless both chips are green.

        ### Filename field (FR-35)

        Single text field pre-populated on Start with
        `recording-YYYY-MM-DD-HH-mm-ss.<ext>` where `<ext>` mirrors
        the current Format picker. Editable before Start; **locked
        (read-only)** while recording is active. The resolved
        absolute path (folder + filename + extension) is rendered in
        a smaller secondary label below the field for confirmation.

        ### Format picker (FR-38)

        Dropdown with `m4a` / `wav` / `caf` (mirrors `macrec start
        --format`). Changing the format updates the filename's
        extension live. Disabled while recording. Persisted across
        launches in `UserDefaults` under
        `macrec.ui.lastFormat`.

        ### Layout picker (FR-38)

        Dropdown with `mixed` / `split` / `stereo-split` (mirrors
        `macrec start --layout`). Disabled while recording.
        Persisted across launches in `UserDefaults` under
        `macrec.ui.lastLayout`.

        ### Output folder picker (FR-36)

        "Choose Folder…" button that opens an `NSOpenPanel` (folder-
        only, single selection). Selection persists across launches
        in `UserDefaults` under `macrec.ui.outputFolder` (security-
        scoped bookmark). Default `~/Recordings/`; created on first
        use if missing. The popover temporarily switches behaviour to
        `.semitransient` for the duration of the panel and restores
        `.transient` on close, so the popover does not dismiss
        underneath the open dialog (R-27).

        ### Microphone device picker (FR-39)

        Dropdown populated from `AudioDeviceEnumerator.listInputs()`
        — exactly the data source `macrec list-devices` uses.
        Defaults to the system default input. Persists by stable
        device UID in `UserDefaults` under
        `macrec.ui.micDeviceUID`. Refreshes on
        `AVCaptureDeviceWasConnectedNotification` /
        `AVCaptureDeviceWasDisconnectedNotification`. Disabled while
        recording.

        ### Mic echo cancellation toggle (plan-013, revised; plan-014)

        Sits directly under the microphone device picker. SwiftUI
        `Toggle` bound to the `@AppStorage("com.macrec.ui.micAEC")`
        slot — **defaults to off (plan-014)**. When on, the popover
        composes `RecordingOptions(micAEC: true)` at start-time,
        which causes `RecordingSession.run()` to construct a
        `SoftwareAECProcessor` (v5) wired between the existing capture
        sources and the aligner. When off, the processor is not
        constructed and the mic and system buffers go directly to the
        aligner exactly as they did pre-plan-013. The mic source is
        always `AVMicrophoneSource` (the `AVCaptureSession`-backed
        path) regardless of the toggle's state. Persistence is
        automatic — the toggle remembers its last state across
        popover dismissals and process relaunches.

        The custom software AEC, when enabled, eliminates the
        system-audio bleed that the built-in mic would otherwise pick
        up from the speakers (the long-standing "I can hear my
        Spotify on the mic channel" problem in `--layout split` /
        `stereo-split` recordings) by running an NLMS adaptive filter
        against the captured system-audio reference signal. Unlike
        Apple's voice-processing AEC (which the original plan-013
        attempt used and which turned out to be incompatible with
        this project's `SCStream` capture), the software path:

          - Preserves the native mic frequency response (no band
            narrowing).
          - Does not apply AGC or noise suppression — quiet voice
            stays quiet, ambient room tone is captured as-is.
          - Needs 3–10 s (speech / music) to converge from cold start
            with v5's calmer μ=0.01 step. After convergence the
            residual bleed stabilises 15–25 dB below the uncancelled
            level.
          - Self-guards via PTS-aligned reference windowing, a
            reference-activity gate (no adapt during system silence),
            a double-talk detector (no adapt while mic dominates
            ref), a 50 ms windowed divergence reset, and a soft-knee
            output limiter (see plan-014 §2 for the full layer
            description).

        For music capture or any workflow where the convergence
        delay matters, turn the toggle off; that records the raw
        mic verbatim. The toggle's help text carries the same
        guidance.

        Locked while recording. Flipping the toggle mid-session has
        no effect on the in-flight recording — the AEC processor is
        constructed from the immutable `RecordingOptions` snapshot
        at `run()` — so the control is disabled until `state`
        returns to `.idle` / `.stopped` / `.failed`. Stop, flip,
        click Start to apply.

        ### Level meters (FR-43)

        Two horizontal bars side by side (system-audio submix and
        microphone), each rendering both **peak** (faster fall-off,
        higher saturation) and **RMS** (slower fall-off, lower
        saturation). Updated at ~30 Hz coalesced via a non-blocking
        `AsyncStream<LevelSample>` with `.bufferingNewest(2)`; the
        underlying vDSP measurements run on a pre-allocated
        `AVAudioPCMBuffer` so they never block the audio capture
        queues (NFR-11). Active any time at least one capture source
        is delivering buffers.

        ### Live transcription picker (FR-49)

        Dropdown labelled **"Live transcription"** with one entry per
        registered provider. The picker order (top to bottom) is:
        **Apple / WhisperKit / Gemini / Soniox / Azure OpenAI (cloud, batch)
        / Azure OpenAI Realtime (cloud, streaming) / ElevenLabs Scribe v2
        (cloud) / None** — locked by plan-007 §C.1 (extends plan-006 D-SX-1).

        - **Apple Speech (on-device)** *(default on first launch as of
          v1.5 / plan-005)* — Apple SpeechAnalyzer running on-device.
          Requires macOS 26+ and the **Speech Recognition** TCC grant
          (see Permissions section below); no API key, no network. This
          replaces `None` as the default; users who prefer the
          true-no-op behaviour can still select **None**.
        - **Apple Cloud (cloud, streaming, Greek + 57 locales)**
          *(2026-05-01)* — Apple's cloud Speech-to-Text path via
          `SFSpeechRecognizer` with `requiresOnDeviceRecognition =
          false`. No API key, no third-party billing — audio is
          tunnelled through the system framework to Apple's private
          ASR servers. Supports `el-GR` and ~57 other locales the
          on-device `SpeechAnalyzer` doesn't ship assets for.
          Quotas: 1,000 requests / hour / device, ~60 s of audio per
          recognition task — provider auto-rotates the underlying
          task at 55 s. Requires `NSSpeechRecognitionUsageDescription`
          (already in the bundle plist) and the user to approve the
          system Speech Recognition prompt the first time the API is
          called from a Developer-ID-signed `.app`. (See
          `docs/reference/apple-cloud-stt-investigation-2026-05.md`
          for the full investigation; see PLAN-007-DONE-14 in
          `Issues - Pending Items.md` for the run-mode caveat with
          ad-hoc CLI binaries.)
        - **WhisperKit (on-device)** — WhisperKit running on Apple
          silicon CoreML.  No API key, no network.
        - **Gemini** — Google Gemini REST batch API (plan-004). Requires
          `GOOGLE_API_KEY` (see "Configuration" below). The picker label
          was `Gemini Live` in plan-003; it was renamed to **Gemini**
          in plan-004 when the WebSocket architecture was replaced by
          REST batch. Existing `~/Library/Preferences/com.local.macrec-ui.plist`
          values of `gemini-live` continue to work — the
          `ConfigResolver` accepts them as a deprecated alias and logs a
          one-time deprecation notice.
        - **Soniox** *(plan-006)* — Soniox cloud streaming
          (WebSocket; default model `stt-rt-v4`). Requires
          `SONIOX_API_KEY` (obtain at
          <https://console.soniox.com>). Default language hints are
          `el,en` (Greek + English bilingual). Cloud-streamed audio
          is documented in the privacy-disclosure sheet (see below).
        - **Azure OpenAI (cloud, batch)** *(plan-007 Phase A1)* — Azure
          OpenAI `gpt-4o-mini-transcribe` REST batch. Requires
          `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`, and
          `AZURE_OPENAI_DEPLOYMENT`; the api-version is optional with
          a documented starter `2025-04-01-preview`. Microsoft
          contractually commits no model training on user audio (see
          the Azure-batch privacy-disclosure variant below).
        - **Azure OpenAI Realtime (cloud, streaming)** *(plan-007 Phase A2)* —
          Azure OpenAI realtime WebSocket with `intent=transcription`.
          Same env vars as the batch variant (`AZURE_OPENAI_*`); adds
          optional VAD / noise-reduction tuning knobs documented under
          **§LT-Az-RT** in `configuration-guide.md`. Sessions cap at
          60 min; the provider transparently reconnects at 58 min with
          a 5 s audio replay so long recordings continue without user
          intervention. The disclosure copy is distinct from the batch
          variant (real-time stream vs. file upload).
        - **ElevenLabs Scribe v2 (cloud)** *(plan-007 Phase B)* —
          ElevenLabs batch REST. Requires `ELEVENLABS_API_KEY` (obtain
          at <https://elevenlabs.io/app/settings/api-keys>). Optional
          `ELEVENLABS_DIARIZE`, `ELEVENLABS_NUM_SPEAKERS`,
          `ELEVENLABS_TAG_AUDIO_EVENTS`, `ELEVENLABS_LANGUAGE_CODE`,
          `ELEVENLABS_ENTITY_DETECTION` (off by default — +30%
          surcharge per `configuration-guide.md` §LT-EL.8).
        - **None** — no transcription work happens, no permissions are
          requested, no network connections are opened (AC-LT-1).

        Persisted across launches in `UserDefaults` under
        `com.macrec.ui.transcribeProvider` (FR-54). Disabled while
        recording (AC-LT-19). When set to a provider whose API key is
        missing from the resolved config chain, the dropdown displays a
        red **"Key not configured"** badge (red dot); clicking the badge
        opens an inline help popover that names the env var
        (`GOOGLE_API_KEY` for Gemini, `SONIOX_API_KEY` for Soniox,
        `AZURE_OPENAI_API_KEY` for both Azure providers,
        `ELEVENLABS_API_KEY` for ElevenLabs) and the recommended path
        (`~/.tool-agents/macrec-ui/.env`). The Start button remains
        enabled — pressing Start in this state surfaces
        `MacrecError.transcriptionApiKeyMissing(provider:)` inline
        without crashing the recording (AC-LT-8 / AC-SX-8).

        ### Provider-specific key-entry sections (plan-007 Task 0.4)

        The picker is followed by a generic `ProviderKeyField` row
        rendered conditionally based on the active provider. The
        helper view writes to `~/.tool-agents/macrec-ui/.env` (mode
        `0600`) and `setenv`s the new value into the running process so
        the next Start picks it up without an app restart. When the
        active provider is `azure` or `azure-openai-realtime`, three
        read-only summary lines render below the field showing the
        currently-resolved `AZURE_OPENAI_ENDPOINT`,
        `AZURE_OPENAI_DEPLOYMENT`, and `AZURE_OPENAI_API_VERSION`. When
        the active provider is `azure-openai-realtime`, three
        additional read-only lines render the resolved VAD threshold,
        VAD silence (ms), and noise-reduction profile (defaults shown
        when the env vars are unset).

        Live transcription is also supported in the CLI's `--detach`
        background mode (parity with the foreground UI path). The
        plan-003-era `transcriptionDetachUnsupported` cross-check was
        removed by plan-004 Phase G.1; see
        [docs/tools/macrec.md](macrec.md) → "Detach mode is compatible
        with `--transcribe`" for details.

        ### Transcription source picker (FR-47)

        Dropdown labelled **"Source"** that selects which audio feeds
        the transcription provider:

        - **system** — system audio submix only.
        - **mic** — microphone only.
        - **mixed** *(default)* — post-`BufferSummer` summed signal.
        - **both** — two parallel streams labelled by source. v1
          falls back to `mixed` for non-split layouts (see
          [docs/tools/macrec.md](macrec.md) → "Live transcription").

        Persisted under `com.macrec.ui.transcribeSource`. Independent of
        the recording's Layout picker. Disabled while recording. Hidden
        when the Live-transcription picker is set to `None`.

        ### Transcript format picker (FR-51)

        Dropdown labelled **"Format"** for the sidecar transcript file.
        Allowed values: `jsonl` *(default)*, `txt`, `srt`, `vtt`.
        Persisted under `com.macrec.ui.transcriptFormat`. Hidden when
        the Live-transcription picker is `None`.

        ### Live transcript panel (FR-52)

        A scrollable panel rendered between the level meters and the
        elapsed-time indicator. Fixed maximum height ~120 pt
        (locked by OQ-LT-3 — separate-window mode is a v2 follow-up).

        - **Partial events** appear in *italic-secondary* style and are
          replaced in place as the provider emits revisions.
        - **Final / settled events** commit in *plain-primary* style
          (italic dropped, full-opacity foreground colour) so users can
          visually distinguish settled text from in-flight partials at a
          glance.
        - **Language chip.** When a settled segment carries a
          non-`nil` `language` field (Apple SpeechAnalyzer emits one
          per recognised locale; Gemini does not), a small uppercase
          BCP-47 chip is rendered next to the segment (e.g. `EN`,
          `EL`). Useful for confirming dual-locale parallel
          recognition is splitting languages correctly.
        - The panel **auto-scrolls** to the bottom on each event unless
          the user has scrolled away, in which case a **"Jump to live"**
          affordance appears at the bottom-right.
        - Closing the popover does **not** stop transcription, only its
          rendering. On reopen, the most-recent finals (last ~50 entries
          retained, drop-oldest beyond) are visible.
        - The panel is hidden when the Live-transcription picker is
          `None` (no panel space wasted in the no-transcription
          configuration).

        ### Privacy disclosure dialog (FR-53)

        The first time the user picks any non-`None` provider on a
        given app install, a modal sheet appears explaining:

        > *"The audio captured during this recording will be sent to a
        > third-party API (`<provider name>`) for transcription. The
        > raw PCM audio leaves this Mac while the provider is active.
        > No PII metadata (filename, microphone name, host name) is
        > transmitted."*

        The sheet has **Continue** and **Cancel** buttons plus a
        **"Don't show again on this Mac"** checkbox. Confirming
        suppresses the dialog for subsequent launches; the disclosure
        text remains discoverable as a tooltip on the Live-transcription
        picker. Cancelling reverts the picker to `None` (AC-LT-9).

        #### Soniox-specific disclosure copy (plan-006)

        Soniox carries an additional one-time disclosure on top of the
        shared cloud-provider sheet, because it streams audio over a
        long-lived WebSocket rather than per-chunk REST POSTs. Picking
        **Soniox** for the first time on a fresh install presents:

        > *"Live transcription via Soniox sends your captured audio
        > over a continuous WebSocket connection to Soniox's cloud
        > (`wss://stt-rt.soniox.com` by default; EU/JP endpoints
        > configurable). Soniox does NOT store audio by default;
        > org-level retention is configurable in the Soniox console
        > (<https://soniox.com/console>). No per-recording opt-out is
        > offered in v1. See <https://soniox.com/privacy> for the
        > vendor's privacy notice."*

        The **Continue** button persists the acknowledgement under
        the AppStorage key
        `com.local.macrec-ui.transcription.hasAcceptedSonioxDisclosure`
        (Boolean; default `false`). The disclosure does NOT reappear on
        subsequent launches once accepted. Reset for a fresh demo via:

        ```sh
        defaults delete com.local.macrec-ui com.local.macrec-ui.transcription.hasAcceptedSonioxDisclosure
        ```

        Cancelling reverts the picker to its previous selection
        (typically `Apple` per the v1.5 default). Note that **a
        SONIOX_API_KEY must be configured before this disclosure can be
        accepted** — users who have not yet visited
        <https://console.soniox.com> to obtain a key see the missing-key
        red-dot badge first and only reach the disclosure after
        populating `~/.tool-agents/macrec-ui/.env`.

        #### Per-provider acknowledgement keys (plan-007 Task 0.3)

        Plan-007 reshapes the disclosure model from a single shared
        boolean into **one acknowledgement flag per provider id** so
        users opt in once per data-residency posture rather than once
        forever. Switching from Gemini to Azure (or Azure to
        ElevenLabs, or batch Azure to realtime Azure) re-shows the
        sheet with provider-specific copy. The persistence keys are:

        | Provider id              | UserDefaults key                                                                |
        |--------------------------|--------------------------------------------------------------------------------|
        | `gemini`                  | `com.local.macrec-ui.transcription.privacy.gemini.acknowledged`                |
        | `soniox`                  | `com.local.macrec-ui.transcription.privacy.soniox.acknowledged`                |
        | `azure`                   | `com.local.macrec-ui.transcription.privacy.azure.acknowledged`                 |
        | `azure-openai-realtime`   | `com.local.macrec-ui.transcription.privacy.azure-openai-realtime.acknowledged` |
        | `elevenlabs`              | `com.local.macrec-ui.transcription.privacy.elevenlabs.acknowledged`            |

        On first run after upgrade, the legacy single boolean
        (`com.local.macrec-ui.transcription.privacyDisclosureAcknowledged`)
        and the plan-006 Soniox-specific key
        (`com.local.macrec-ui.transcription.hasAcceptedSonioxDisclosure`)
        are migrated forward to the corresponding per-provider keys
        and removed, so existing users do not see the dialog twice
        for Gemini or Soniox.

        #### Azure OpenAI batch disclosure copy (plan-007 §7.1)

        > *"Audio will be sent to Microsoft Azure OpenAI Service for
        > transcription. Microsoft contractually commits that your audio
        > and transcripts are never used to train AI models and are
        > never shared with OpenAI or other parties. Data is processed
        > in the Azure region associated with your resource (currently
        > Global Standard, which may route through East US 2). A Data
        > Processing Agreement covers this transfer. For full details,
        > see Microsoft's Azure OpenAI data privacy documentation at
        > https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy
        > and the Microsoft Online Services DPA at https://aka.ms/DPA."*

        #### Azure OpenAI Realtime disclosure copy (plan-007 §A2.9)

        > *"Audio will be streamed live to Microsoft Azure OpenAI
        > Service for transcription over a secure WebSocket. Microsoft
        > contractually commits that your audio and transcripts are
        > never used to train AI models and are never shared with
        > OpenAI or other parties. Audio is processed in real time and
        > is NOT retained per Azure data privacy policy. The session
        > is capped at 60 minutes — recordings longer than that will
        > reconnect transparently. Data is processed in the Azure
        > region associated with your resource (currently Global
        > Standard, which may route through East US 2). For full
        > details, see Microsoft's Azure OpenAI data privacy
        > documentation at
        > https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/data-privacy
        > and the Microsoft Online Services DPA at https://aka.ms/DPA."*

        #### ElevenLabs disclosure copy (plan-007 §7.2)

        > *"Audio will be sent to ElevenLabs (US-based, SOC 2 Type II
        > certified, ISO 27001, GDPR-compliant). By default ElevenLabs
        > retains audio and transcripts for service operation;
        > Enterprise customers can enable Zero Retention mode
        > (`enable_logging=false`). Audio is not used to train models
        > without explicit opt-in. EU data residency is available on
        > Enterprise tier through account settings. For full details,
        > see ElevenLabs' privacy policy at https://elevenlabs.io/privacy
        > and the Data Processing Addendum at https://elevenlabs.io/dpa."*

        ### Cost / latency display

        Below the transcript panel, a single-line read-out shows the
        running session metrics from `TranscriptionManager` (plan-004
        REST-batch architecture):

        ```
        17 chunks · 42 s billable · 0 errors · 410 ms last RTT
        ```

        - `chunks`        — number of 2.5 s WAV chunks POSTed so far.
        - `billable`      — cumulative seconds of audio sent (drives
                            cost estimates).
        - `errors`        — non-fatal request failures (HTTP 5xx,
                            transient network errors). Recording
                            continuity is **never** affected.
        - `last RTT`      — round-trip time of the most recent successful
                            chunk POST.

        Updated at 1 Hz while a recording is active. The same numbers
        are emitted on the events stream at session end and printed to
        the post-stop log (FR-58). The plan-003 JSONL sidecar header
        line is no longer written — metrics surface via the
        `TranscriptionMetrics` value type instead. After Stop, the
        post-stop saved-files disclosure also lists the transcript
        sidecar path alongside each `.partNN` audio file (FR-57).

        ### Elapsed-time indicator (FR-40)

        `HH:MM:SS` read-out, updated at 1 Hz only while the popover
        is visible. Tracks **segment-elapsed** (time since the
        current `partNN` file opened) and **cumulative-elapsed** (sum
        across all segments of the current logical recording).
        **Freezes during pause** because no audio is captured under
        the stop-and-stitch model.

        ### Control bar

        State-driven button row at the bottom of the popover. Visible
        buttons depend on the observed `SessionState` (FR-33):

        - **Start** — visible in `idle`. Begins a new recording.
        - **Pause** — visible in `recording`. Engages stop-and-stitch:
          finalises the current segment file and parks the engine.
        - **Resume** — visible in `paused`. Opens the next segment
          file (`partNN+1`) and resumes capture; cold-start latency
          on `SCStream` warmup is typically 200–500 ms (R-29).
        - **Stop** — visible in `recording`, `paused`, and
          `splitting`. Finalises the current file and returns to
          `idle`.
        - **Split** — visible in `recording`. Triggers the manual
          atomic-swap split path on `RecordingSession` (FR-32).

        While in the transient `starting` / `pausing` / `resuming` /
        `splitting` / `stopping` states, the relevant button is
        disabled (greyed) and the icon's tint pulses to indicate the
        in-flight transition.

        ### Saved-files disclosure (post-stop)

        After Stop returns to `idle`, the popover briefly displays a
        disclosure block listing every file written by the most-
        recent recording (one row per `partNN`, plus per-channel
        rows under `--layout split`). Each row has a "Reveal in
        Finder" affordance.

        ## Behavior summary

        ### Stop-and-stitch pause produces multiple files

        Pause/Resume is implemented as **stop-and-stitch** (locked
        decision OQ-CORE-1; A-UI-2). Pressing Pause finalises the
        current segment file as a complete, playable artefact;
        pressing Resume opens a new segment with an incremented
        `partNN` suffix per FR-34. A recording that was paused once
        therefore produces two files on disk:

        ```
        recording-2026-04-26-18-30-00.part01.m4a
        recording-2026-04-26-18-30-00.part02.m4a
        ```

        A recording that was paused twice produces three files
        (`part01`, `part02`, `part03`), and so on. Single-segment
        recordings — never paused, never split — keep the
        unadorned name `recording-2026-04-26-18-30-00.m4a` (no
        `.partNN` suffix) per FR-34.

        Under `--layout split`, both per-source files share the same
        `.partNN` infix, before the `.mic` / `.system` token, so a
        sort-by-filename groups the segments naturally:

        ```
        recording-….part01.mic.m4a
        recording-….part01.system.m4a
        recording-….part02.mic.m4a
        recording-….part02.system.m4a
        ```

        ### Manual split rotates to a new file with no audible gap

        Pressing **Split** triggers `RecordingSession.split(nextOutput:)`
        (FR-32) — a single-recorder atomic swap on the session's
        `serialQueue`, guarded by `OSAllocatedUnfairLock<Recorder?>`.
        The new `Recorder` is pre-warmed before the swap and the old
        one is finalised after; the capture pipeline
        (`SCStream`/`AVCaptureSession`) **stays alive** across the
        rotation. Measured seam in the field is up to ~52 ms (10 ms
        swap latency + 42 ms AAC priming for `m4a`; ~10 ms for
        `wav`/`caf`), comfortably under the **AC-UI-7 ceiling of
        250 ms** at the seam (R-25).

        ### Quit while recording

        Selecting **Quit** (or `⌘Q`) while a recording is active does
        **not** terminate immediately. The UI presents a modal
        confirmation dialog ("Stop the current recording and quit?
        / Cancel"). Confirming routes through the standard Stop
        path: the current segment file is finalised, the
        `SessionState` transitions to `stopped`, and the process
        exits 0. Cancelling dismisses the dialog and leaves the
        recording running. Force-quit (Activity Monitor / `kill -9`)
        cannot be intercepted but leaves any already-finalised
        `partNN` files on disk; only the in-flight segment is at
        risk (AC-UI-13).

        ## Privacy & cost

        Live transcription sends the captured audio over the network to
        a third-party provider. The UI exposes three controls to make
        this explicit:

        ### What data leaves the machine

        When the Live-transcription picker is set to anything other than
        `None`, the **raw PCM audio** corresponding to the selected
        Source picker (`mic`, `system`, `mixed`, or both) is downsampled
        to 16 kHz mono PCM16, packaged as 2.5 s WAV chunks, and POSTed
        over HTTPS to the provider's REST endpoint (plan-004 architecture;
        see `docs/tools/macrec.md` → "Bandwidth"). Per NFR-20, **no PII
        metadata is sent** — filename, mic device name, host name, and
        user name are stripped from the wire payload. The default
        `None` setting keeps every byte local; the engine never opens a
        network connection in that configuration.

        ### How costs are estimated

        Each provider charges per minute (or per token) of audio sent.
        The popover's cost / latency display surfaces the live
        `billableSeconds` counter (cumulative seconds of audio POSTed);
        multiply by the provider's published per-second rate (Gemini:
        see Google AI Studio pricing) for an approximate per-recording
        cost. v1 ships a per-recording counter only — a multi-recording
        aggregator dashboard is a v2 follow-up.

        ### How the disclosure works

        The first time a user picks a non-`None` provider on a fresh
        `~/Library/Preferences/com.local.macrec-ui.plist`, the modal
        privacy sheet (FR-53, AC-LT-9) appears. Confirming records the
        acknowledgement under
        `com.macrec.ui.transcribePrivacyAcknowledged`; the sheet does
        not appear on subsequent launches. The disclosure text remains
        accessible at any time as a tooltip on the Live-transcription
        picker. Resetting acknowledgement (e.g. for a fresh demo) is
        done by deleting that one defaults key:

        ```sh
        defaults delete com.local.macrec-ui com.macrec.ui.transcribePrivacyAcknowledged
        ```

        ## Configuration

        `macrec-ui` reads transcription configuration through the same
        four-tier chain the CLI uses (see "Resolution chain" below).
        Recording-engine UI state (selected format, layout, mic UID,
        output folder bookmark) is stored in `UserDefaults` under the
        `com.local.macrec-ui` bundle id and is **not** part of the
        env-var configuration chain — it is UI state, not
        configuration.

        ### Resolution chain (lowest → highest priority)

        Same four-tier chain `macrec` uses, with the CLI tier empty
        in v1:

        1. **Shell environment** — `ProcessInfo.processInfo.environment`.
        2. **User `.env`** — `~/.tool-agents/macrec-ui/.env` (mode `0600`).
        3. **Local `.env`** — `./.env` in the current working directory.
        4. **CLI flags** — *n/a in v1* (`macrec-ui` accepts no command-line arguments).

        ### Environment variables

        | Variable                            | Purpose                                                                                                                                                                                                       | Allowed values                          | Default               |
        |-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------|-----------------------|
        | `MACREC_UI_LOG_LEVEL`               | Diagnostic log verbosity (NFR-16). Controls only logging — not behaviour. Treating an unset value as `info` is a logging-only convenience and is **not** a runtime-config fallback in the no-fallback-rule sense. | `info`, `debug`, `trace`               | `info` (when unset)   |
        | `MACREC_TRANSCRIBE`                 | Default live-transcription provider (FR-49). Read at launch to pre-select the picker; the picker still wins per-session. | `none`, `apple`, `whisperkit`, `gemini` (canonical), `gemini-live` (deprecated alias; lowered to `gemini`), `soniox` | `apple` (post plan-005) |
        | `MACREC_TRANSCRIBE_SOURCE`          | Default audio source for transcription (FR-47).                                                                  | `system`, `mic`, `mixed`, `both`        | `mixed`               |
        | `MACREC_TRANSCRIBE_FORMAT`          | Default sidecar transcript format (FR-51).                                                                       | `jsonl`, `txt`, `srt`, `vtt`            | `jsonl`               |
        | `MACREC_TRANSCRIBE_MODEL`           | Provider-specific model id override (project-design §LT-5.2).                                                    | provider-specific (e.g. `gemini-3-flash-preview`, `stt-rt-v4`) | provider's pinned default |
        | `MACREC_TRANSCRIBE_LANGUAGE`        | BCP-47 spoken-language hint passed to the provider. Comma-separated values activate dual-locale recognition (Apple / Soniox). | BCP-47 string (e.g. `en-US` or `el,en`) | provider auto-detect (Soniox: `el,en`) |
        | `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`  | Optional ISO-8601 date marking when `GOOGLE_API_KEY` (or other provider key) expires. If past, a warning is logged at start; recording is NOT blocked. Shared fallback when `MACREC_SONIOX_KEY_EXPIRES_AT` is unset. | ISO-8601 date string                    | unset                 |
        | `GOOGLE_API_KEY`                    | Vendor-canonical API key for Gemini. Required when `MACREC_TRANSCRIBE=gemini` (or its deprecated alias `gemini-live`, or the picker is set to Gemini). Resolved BEFORE the recording opens; missing key fails fast with `transcriptionApiKeyMissing`. Obtain at <https://aistudio.google.com/app/apikey>. | API key string | unset (recording uses `None` fallback) |
        | `SONIOX_API_KEY`                    | Vendor-canonical API key for Soniox cloud streaming (plan-006). Required when `MACREC_TRANSCRIBE=soniox` or the picker is set to Soniox. Resolved BEFORE the recording opens; missing key fails fast with `transcriptionApiKeyMissing(provider:"soniox")`. Obtain at <https://console.soniox.com>. The user MUST sign up at console.soniox.com to get a key — the UI cannot proceed without one. | API key string | unset (recording falls back to picker default) |
        | `MACREC_SONIOX_ENDPOINT`            | Soniox WebSocket endpoint override (for EU/JP data residency). Validated as `ws://` or `wss://` URL. | URL string (`wss://stt-rt.soniox.com/transcribe-websocket` (US, default), `wss://stt-rt.eu.soniox.com/transcribe-websocket` (EU), `wss://stt-rt.jp.soniox.com/transcribe-websocket` (JP)) | `wss://stt-rt.soniox.com/transcribe-websocket` |
        | `MACREC_SONIOX_KEY_EXPIRES_AT`      | Per-provider expiry override for `SONIOX_API_KEY`. Takes precedence over `MACREC_TRANSCRIBE_KEY_EXPIRES_AT` (plan-006 D-SX-3). | ISO-8601 date string | unset (falls back to shared `MACREC_TRANSCRIBE_KEY_EXPIRES_AT`) |

        Notes:

        - Per the project's "no fallback values" rule (CLAUDE.md →
          Structure & Conventions), missing **runtime** configuration
          must raise an exception. `MACREC_UI_LOG_LEVEL` is an
          explicitly carved-out exception because it does not affect
          recording behaviour. This is documented in the seeded
          `~/.tool-agents/macrec-ui/.env`.
        - The transcription env vars listed above are the same keys
          documented for the CLI in
          [docs/design/configuration-guide.md](../design/configuration-guide.md)
          §2.16–§2.22; both tools share the four-tier resolution chain
          (with the user-`.env` tier scoped to
          `~/.tool-agents/macrec-ui/.env` for the UI).
        - Recommended location for `GOOGLE_API_KEY` and
          `SONIOX_API_KEY` is `~/.tool-agents/macrec-ui/.env` (mode
          `0600`). Do **not** paste API keys into shell history or
          `.zshrc`. Soniox keys are obtained from
          <https://console.soniox.com> (Account → API keys); the user
          MUST sign up there to get a key — there is no in-app key
          provisioning flow.

        ### `@AppStorage` UserDefaults keys

        Persisted UI state (FR-35, FR-36, FR-38, FR-39) is keyed under
        the `com.local.macrec-ui` bundle id at
        `~/Library/Preferences/com.local.macrec-ui.plist`. All five keys
        share the reverse-DNS prefix `com.macrec.ui.*` (matching the
        bundle id family without the `local.` infix):

        | Key                          | Purpose                                                                                          |
        |------------------------------|--------------------------------------------------------------------------------------------------|
        | `com.macrec.ui.outputFolder` | Last-chosen output folder (absolute path string). Empty on first launch → resolves to `~/Recordings/`. |
        | `com.macrec.ui.basename`     | Pre-record filename (without extension). Empty → `FilenameGenerator.default(now:)` is used at Start. |
        | `com.macrec.ui.format`       | Last-selected output format raw value (`m4a` / `wav` / `caf`).                                   |
        | `com.macrec.ui.layout`       | Last-selected track layout raw value (`mixed` / `split` / `stereo-split`).                       |
        | `com.macrec.ui.micUID`       | Stable UID of the last-selected microphone device. Empty (or sentinel `__default__`) → system default input. |
        | `com.macrec.ui.transcribeProvider`           | Last-selected live-transcription provider raw value (`none` / `apple` / `whisperkit` / `gemini` / `soniox`; legacy `gemini-live` values from plan-003 installs continue to work — the resolver lowers them to `gemini`). Default `apple` post plan-005 (FR-54). |
        | `com.macrec.ui.transcribeSource`             | Last-selected transcription source raw value (`system` / `mic` / `mixed` / `both`). Default `mixed` (FR-54). |
        | `com.macrec.ui.transcriptFormat`             | Last-selected sidecar transcript format raw value (`jsonl` / `txt` / `srt` / `vtt`). Default `jsonl` (FR-54). |
        | `com.macrec.ui.transcribePrivacyAcknowledged` | One-time acknowledgement flag for the shared cloud-provider privacy disclosure dialog (FR-53). Boolean. Default `false`. |
        | `com.local.macrec-ui.transcription.hasAcceptedSonioxDisclosure` | One-time acknowledgement flag for the Soniox-specific privacy disclosure sheet (plan-006). Set to `true` after the user clicks **Continue** on the Soniox disclosure. Boolean. Default `false`. |
        | `com.macrec.ui.appearance`                  | User-chosen appearance mode raw value (`system` / `light` / `dark`). Default `system` (added by plan-008 — see "Theming" below). Read by `AppearanceHostingRoot`, `AppearanceSwitcher`, and `GeneralSettingsView`. |
        | `com.macrec.ui.transcriptionEnabled`        | Master gate for the live-transcription pipeline. `Bool`, default `true`. When `false`, `ControlBar.startTapped()` overrides the engine to `"none"` for the duration of the recording WITHOUT mutating `com.macrec.ui.transcribeProvider` — re-enabling restores the user's last engine (added by plan-008, UR-ADR-7). |
        | `com.macrec.ui.popoverHeight`               | Persisted vertical popover height (Double, default `600`). Driven by `ResizeHandle` drag gesture; `PopoverController.heightObserver` pushes the value onto `NSPopover.contentSize`. |

        These keys are managed via SwiftUI's `@AppStorage` property
        wrapper inside the popover views; they are written
        synchronously on every change and read at app launch. **They
        are UI persistence, NOT runtime configuration** — the
        no-fallback rule (CLAUDE.md → Structure & Conventions) does
        **not** apply here. UI state is allowed to default to a
        sensible empty/zero value at first launch, and the views
        bootstrap reasonable defaults (e.g. `outputFolder` →
        `~/Recordings/`, `basename` → timestamped name) on demand.

        ## Theming (Light / Dark / Follow System)

        Plan-008 introduced a 3-mode appearance picker. Two surfaces:

        1. **Popover metadata strip** — a tiny SF-symbol icon-menu
           (`AppearanceSwitcher`, `Sources/macrec-ui/Views/Header/`)
           inline with the permission pill / folder chip / state label.
           One-click access from any popover open.
        2. **Settings → General tab** — a 3-row inline `Picker`
           (`GeneralSettingsView`, `Sources/macrec-ui/Settings/Sections/`)
           rendered first in the Settings sidebar.

        Both surfaces bind to the same `@AppStorage("com.macrec.ui.appearance")`
        key (raw `"system"` / `"light"` / `"dark"`, default `"system"`).
        Persistence is automatic via SwiftUI's property-wrapper reactivity
        and survives app restarts. Read it manually with:

        ```bash
        defaults read com.local.macrec-ui com.macrec.ui.appearance
        ```

        **Propagation chain.** Both the popover (hosted via
        `NSHostingController` inside `PopoverController`) and the
        `Settings { }` scene wrap their root in `AppearanceHostingRoot`
        (`Sources/macrec-ui/Theme/AppearanceHostingRoot.swift`), which:

        - Reads the persisted raw via `@AppStorage`
        - Maps to `AppearanceMode` (`Sources/MacrecUIKit/Theme/AppearanceMode.swift`)
        - Applies `.preferredColorScheme(_:)` (passing `nil` for `system`
          so the OS / parent scope's choice applies)
        - Injects the appropriate `\.palette` env value (`Palette.light`
          or `Palette.dark`) so descendant views pick up theme tokens

        Per `docs/reference/research-nshostingcontroller-appearance.md`
        no `NotificationCenter` / KVO observer is needed on macOS 26 —
        `@AppStorage` reactivity propagates through the
        `NSHostingController` boundary natively, and OS appearance
        flips trigger re-evaluation through `@Environment(\.colorScheme)`.

        **Color tokens.** The theme exposes 17 semantic tokens defined
        in `Sources/macrec-ui/Theme/Palette.swift` (label / value /
        secondary / tertiary text colors, group + control + field
        backgrounds, separator + stroke colors, accent, success
        background / foreground / dot, and red record-button gradient
        start/end). Both `Palette.light` and `Palette.dark` instances
        are pinned to the CSS custom-property values in the design
        mockup at `docs/design/mockups/popover-redesign.html` (see
        `Tests/MacrecUITests/Theme/PaletteTests.swift` for the
        contract pin).

        **Out of scope (deferred).** A user-visible appearance
        preview, automatic-following of macOS Auto theme schedule,
        and per-window appearance overrides are not implemented in
        plan-008 — `.system` mode already follows whatever
        `NSApplication.effectiveAppearance` resolves to (which honors
        the macOS Auto schedule), so most of these come "for free".

        ## Logging

        `macrec-ui` logs through the same `LoggerFactory` /
        `swift-log` pipeline the CLI uses (NFR-16). When running
        outside an Xcode debugger session, log output is written to:

        ```
        ~/.tool-agents/macrec-ui/macrec-ui.log
        ```

        The file is `0600` mode, append-only, and **not** rotated by
        the app (manage it manually if it grows large — same
        convention as the CLI's detached-mode log file). Default
        level is `.info`.

        ### Viewing logs in Console.app

        The UI registers its log subsystem as
        `com.local.macrec-ui`. To stream logs live in macOS
        Console.app:

        1. Open **Console** (`/System/Applications/Utilities/Console.app`).
        2. Pick your Mac in the left sidebar.
        3. Click **Start Streaming**.
        4. In the search bar, filter by `subsystem:com.local.macrec-ui`.

        You can also tail the file directly:

        ```sh
        tail -f ~/.tool-agents/macrec-ui/macrec-ui.log
        ```

        ### Bumping verbosity

        Two complementary mechanisms:

        - **Persistent (one run)**: prefix the launch with the env
          var. e.g. `MACREC_UI_LOG_LEVEL=debug swift run macrec-ui`.
        - **Live (during a session)**: **option-click** the menu-bar
          status icon to open a hidden diagnostic submenu. The
          submenu exposes a "Show debug log" toggle that flips the
          live logger from `.info` to `.debug` (or back) without
          relaunching.

        ## Examples

        ### Example 1 — Record a 5-minute Zoom call into a single m4a

        Click sequence:

        1. Join the Zoom call as you normally would.
        2. Click the menu-bar mic-with-soundwave icon → popover
           opens.
        3. Verify both permission chips are green.
        4. Pick the desired output folder via "Choose Folder…" (or
           accept the previously-saved one).
        5. Confirm Format = `m4a`, Layout = `mixed`, Mic = built-in
           microphone (or your podcasting mic).
        6. Optionally rename the suggested filename
           (`recording-2026-04-26-14-05-00.m4a` →
           `zoom-quarterly-review.m4a`).
        7. Click **Start**. The status icon turns red, the elapsed-
           time read-out begins ticking, level meters animate.
        8. After ~5 minutes, click **Stop**.

        Result: a single file at the chosen folder containing both
        sides of the conversation mixed into one stereo m4a. The
        post-stop disclosure panel offers "Reveal in Finder".

        ### Example 2 — Record a podcast with separate guest/host tracks (`--layout split`)

        Click sequence:

        1. Open the popover.
        2. Output folder = `~/Recordings/Podcast/`.
        3. Format = `wav` (lossless source for post-production),
           Layout = `split`.
        4. Mic = your USB podcasting mic (selected from the dropdown).
        5. Filename = `episode-042`.
        6. **Start** → record the conversation.
        7. **Stop** when finished.

        Result: two files written side by side under
        `~/Recordings/Podcast/`:

        ```
        episode-042.mic.wav      ← your microphone (host)
        episode-042.system.wav   ← system audio (guest, browser, music bed, etc.)
        ```

        Each file is independently editable in your DAW, with
        sample-accurate alignment between them.

        ### Example 3 — Pause during a phone call mid-recording, resume after

        Click sequence:

        1. **Start** a recording with Format = `m4a`, Layout =
           `mixed`. Filename auto-fills to e.g.
           `recording-2026-04-26-18-30-00.m4a`.
        2. After 12 minutes the phone rings. Click **Pause**.
           - Status icon turns yellow.
           - The current segment file is finalised on disk as
             `recording-2026-04-26-18-30-00.part01.m4a`.
           - Elapsed-time read-out freezes.
        3. Take the call. The recording is parked — no audio is
           being captured during pause (stop-and-stitch).
        4. After the call, click **Resume**.
           - Status icon goes red again (after a typical 200–500 ms
             SCStream warmup, R-29).
           - A new segment file opens at
             `recording-2026-04-26-18-30-00.part02.m4a`.
           - Elapsed-time read-out continues from where it froze.
        5. Click **Stop** when done.

        Result: two files on disk:

        ```
        recording-2026-04-26-18-30-00.part01.m4a   ← pre-pause segment
        recording-2026-04-26-18-30-00.part02.m4a   ← post-resume segment
        ```

        Both are individually playable. Concatenate them losslessly
        with `ffmpeg -f concat -i list.txt -c copy joined.m4a` if a
        single-file artefact is needed.

        ## Known issues / risks

        Authoritative tracker: [Issues - Pending Items.md](../../Issues%20-%20Pending%20Items.md).
        Highlights specific to `macrec-ui`:

        - **R-22 — `swift test` is a stub on Apple CommandLineTools.**
          Tests authored for `MacrecUITests` and `MacrecCoreTests`
          compile but cannot be trusted on a CLT-only host. Run them
          on a CI image with full Xcode (or install Xcode locally)
          before declaring plan-002 Phase I complete.
        - **R-23 — Separate TCC grants on every UI rebuild.** The
          UI's `com.local.macrec-ui` bundle id is distinct from the
          CLI's `com.local.macrec`. Granting Screen Recording /
          Microphone to one does **not** grant it to the other; both
          must be approved independently. Furthermore, ad-hoc-signed
          SPM builds (continuation of R-2) re-prompt on every
          rebuild because the on-disk path/signature changes.
          Mitigation: keep launching the same release binary across
          a long QA session; deferred to v2 `.app` packaging with a
          stable Developer-ID signature for production.
        - **R-29 — SCStream cold-start latency on Resume.** Each
          Resume incurs a typical 200–500 ms SCStream warmup on
          Apple silicon before the first buffer arrives in the new
          segment. v1 does not impose a Resume-latency SLO; if
          observed cold-start consistently exceeds 1 s, file a
          v1.1 follow-up to pre-warm a parked SCStream during pause.

        Same caveats as the CLI apply (R-2 ad-hoc-signing
        instability, R-7 macOS 26.x plain-binary TCC listing, R-13
        sleep-during-record, R-9 Bluetooth output route, R-3 output
        device change mid-recording — see
        [docs/tools/macrec.md](macrec.md) → "Limitations / known
        issues" for the canonical list, since both tools share the
        capture stack and therefore share its limitations).

        ## Building from source

        Requirements:

        - macOS 14 (Sonoma) or later.
        - Swift 5.9+ toolchain (Xcode 15.0+ recommended; Apple
          CommandLineTools is sufficient for `swift build` / `swift
          run` but cannot run XCTest — see R-22 / R-17).

        Commands:

        ```sh
        swift build                         # debug build at .build/debug/macrec-ui
        swift build -c release              # release build at .build/release/macrec-ui
        swift run macrec-ui                 # one-shot run from the build cache
        swift test                          # unit tests (Xcode required for the test runner)
        ```

        The target is declared as an `executableTarget` in
        `Package.swift` with the `-Xlinker -sectcreate __TEXT
        __info_plist Resources/MacrecUI-Info.plist` flag so the UI's
        Info.plist (with `LSUIElement=true`,
        `NSMicrophoneUsageDescription`, `NSScreenCaptureUsageDescription`,
        `CFBundleIdentifier=com.local.macrec-ui`) is embedded into
        the binary's `__TEXT,__info_plist` section. There is no
        `.app` bundle wrapper in v1; the binary is launched
        directly. As with the CLI, this means TCC grants are tied to
        the on-disk binary path and may be reset on rebuild (R-2 /
        R-23). For long QA sessions, build a release binary once and
        keep launching the same path.

        ## File locations

        - **Binary:**           `<repo>/.build/<config>/macrec-ui` after `swift build`.
        - **User defaults:**    `~/.tool-agents/macrec-ui/.env`            (mode `0600`, in folder mode `0700`).
        - **App preferences:**  `~/Library/Preferences/com.local.macrec-ui.plist`
          (managed by `UserDefaults` / `@AppStorage`; selected
          format / layout / mic UID / output-folder bookmark live
          here, per FR-36 / FR-38 / FR-39).
        - **Log file:**         `~/.tool-agents/macrec-ui/macrec-ui.log`   (mode `0600`, append-only, no rotation; see "Logging" above).
        - **Bootstrap folder:** `~/.tool-agents/macrec-ui/`               (mode `0700`; auto-created on launch).

        Note: unlike the CLI, `macrec-ui` does **not** use a PID
        file. PID files are an artefact of the CLI's `--detach`
        background mode; the UI is always foreground (the popover
        IS the user interface).

        ## Cross-references

        - [docs/design/refined-request-toolbar-ui.md](../design/refined-request-toolbar-ui.md)
          — the original refined-request brief that drove FR-30 ..
          FR-44 and NFR-11 .. NFR-16 (Decisions Locked table +
          AC-UI-1 .. AC-UI-18 acceptance criteria).
        - [docs/design/plan-002-toolbar-ui.md](../design/plan-002-toolbar-ui.md)
          — phased implementation plan for the menu-bar app
          (Phases 0 / A / B / C / D / E / F / G / H / I / J / K).
        - [docs/design/plan-003-live-transcription.md](../design/plan-003-live-transcription.md)
          — phased implementation plan for the live-transcription
          subsystem (Phases 0 / A / B / C / D / E / F / G / H / I).
        - [docs/design/refined-request-live-transcription.md](../design/refined-request-live-transcription.md)
          — live-transcription requirements (FR-45..FR-58, NFR-17..NFR-21).
        - [docs/design/plan-006-soniox-streaming.md](../design/plan-006-soniox-streaming.md)
          — phased implementation plan for the Soniox streaming provider
          (Phases A through I).
        - [docs/design/refined-request-soniox-streaming.md](../design/refined-request-soniox-streaming.md)
          — Soniox requirements (FR-SX-1..FR-SX-18, NFR-SX-1..NFR-SX-7,
          AC-SX-1..AC-SX-18).
        - [docs/design/project-design.md](../design/project-design.md)
          §15 — full UI architecture (state machine, popover
          layout, permission gating, level metering, settings
          persistence).
        - [docs/design/project-functions.md](../design/project-functions.md)
          — registered FRs (FR-30 .. FR-44) and NFRs (NFR-11 ..
          NFR-16).
        - [docs/tools/macrec.md](macrec.md) — companion CLI tool
          that shares the `MacrecCore` engine.
        - [docs/design/configuration-guide.md](../design/configuration-guide.md)
          — per-variable configuration reference (shared with the
          CLI).
        - [Issues - Pending Items.md](../../Issues%20-%20Pending%20Items.md)
          — risk register; **R-22**, **R-23**, **R-29** in
          particular.
    </info>
</macrecUi>
