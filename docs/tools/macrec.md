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
        subcommand for clean finalization.
    </objective>
    <command>
        macrec <subcommand> [options]
    </command>
    <info>
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
          --version               Show the version.
          -h, --help              Show help information.
        ```

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
        | 78   | `EX_CONFIG`      | `missingRequiredConfig`, `micDeviceNotFound`, `alreadyRecording`, `noActiveRecording`                                              | configuration / workflow error           |

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
        - `docs/design/configuration-guide.md` — per-variable configuration
          reference.
        - `Issues - Pending Items.md` — open risks (R-1 .. R-19) and
          completed items.
    </info>
</macrec>
