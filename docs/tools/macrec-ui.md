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
        meters for the system-audio submix and the microphone. Targets
        macOS 14 (Sonoma) or later and ships as a separate SwiftPM
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

        Both prompts are bound to the `com.local.macrec-ui` bundle id
        (the UI's identity), which is **separate** from the CLI's
        `com.local.macrec` bundle id. Granting either permission to
        the CLI does **not** carry over to the UI (R-23) — this
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

        ## Configuration

        `macrec-ui` reads exactly **one** environment variable. UI
        state (selected format, layout, mic UID, output folder
        bookmark) is stored in `UserDefaults` under the
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

        ### Environment variable

        | Variable               | Purpose                                                                                                                                                                                                       | Allowed values            | Default              |
        |------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------|----------------------|
        | `MACREC_UI_LOG_LEVEL`  | Diagnostic log verbosity (NFR-16). Controls only logging — not behaviour. Treating an unset value as `info` is a logging-only convenience and is **not** a runtime-config fallback in the no-fallback-rule sense. | `info`, `debug`, `trace` | `info` (when unset)  |

        Note: per the project's "no fallback values" rule (CLAUDE.md
        → Structure & Conventions), missing **runtime** configuration
        must raise an exception. `MACREC_UI_LOG_LEVEL` is an
        explicitly carved-out exception because it does not affect
        recording behaviour. This is documented in the seeded
        `~/.tool-agents/macrec-ui/.env`.

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

        These keys are managed via SwiftUI's `@AppStorage` property
        wrapper inside the popover views; they are written
        synchronously on every change and read at app launch. **They
        are UI persistence, NOT runtime configuration** — the
        no-fallback rule (CLAUDE.md → Structure & Conventions) does
        **not** apply here. UI state is allowed to default to a
        sensible empty/zero value at first launch, and the views
        bootstrap reasonable defaults (e.g. `outputFolder` →
        `~/Recordings/`, `basename` → timestamped name) on demand.

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
