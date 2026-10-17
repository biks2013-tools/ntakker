<ntakkerStudio>
    <objective>
        `ntakker-studio` is a macOS-only SwiftUI Dock application for
        exploring and studying recordings made by `ntakker` /
        `ntakker-cli`. It scans a library folder, plays a recording (a
        split `.mic` + `.system` pair plays together), shows its
        transcripts beside a waveform, jumps the audio to the moment any
        transcript line was spoken, cuts parts out of a recording into a
        new copy while re-timing the transcripts, answers questions about
        the whole transcript, writes meeting minutes, renames speakers,
        edits transcript text, re-transcribes a recording with a batch
        provider, and searches the text of every recording in the
        library. It does not record (that stays in `ntakker`). Built from
        the same Swift package as `ntakker` and `ntakker-cli`, under its
        own bundle id `com.giorgosmarinos.ntakker-studio`. Swift rather than
        TypeScript: covered by Project Memory Exception 001 in
        CLAUDE.md.
    </objective>
    <command>
        open /Applications/ntakker-studio.app
    </command>
    <info>
        ## Overview

        `ntakker-studio` is the third first-party tool in this project,
        a normal (Dock, Cmd-Tab) companion to the menu-bar `ntakker`
        app (see [ntakker.md](ntakker.md)) and the `ntakker-cli` CLI
        (see [ntakker-cli.md](ntakker-cli.md)). Logic that can be
        unit-tested lives in the `NtakkerStudioKit` library target; the
        `ntakker-studio` executable target is the SwiftUI shell. Both
        link `NtakkerCore` for the transcript types, the JSONL writer,
        the Ask client, the configuration resolver and the transcription
        providers. Requirements and decisions: `docs/plans/plan-024-ntakker-studio.md`
        and `docs/refined_requests/refined-request-001-ntakker-studio.md`.

        The command line takes no arguments: launching the app opens the
        main window. The app quits when its last window is closed.

        ## System requirements

        - macOS 26 (Tahoe) or later (`LSMinimumSystemVersion` 26.0; the
          package platform is `.macOS(.v26)`, Project Memory Exception 002).
        - No Screen Recording or Microphone permission is needed: the
          studio only plays and reads files. Audio playback and waveform
          decoding use `AVFoundation` on files the user already owns.
        - Cloud AI features (Ask, Minutes, cloud re-transcription) need
          the network and the provider keys described under
          "Configuration".

        ## Build, package, install

        ```sh
        swift build --product ntakker-studio          # debug build
        bash scripts/package-ntakker-studio-app.sh    # -> dist/ntakker-studio.app (ad-hoc signed)
        bash scripts/redeploy-ntakker-studio.sh       # stop, rebuild, install to /Applications/ntakker-studio.app, launch
        ```

        - Bundle id: `com.giorgosmarinos.ntakker-studio`. Info.plist:
          `Resources/NtakkerStudio-Info.plist` (embedded into the
          binary by the target's linker settings and copied into the
          `.app` by the packaging script). Version: `0.1.0`.
        - Tests: `swift test --filter NtakkerStudioTests` (Swift Testing
          suites for the kit; Xcode toolchain required).
        - Packaging scripts honour the same overrides as the ntakker
          ones: `SWIFT_CONFIG=debug`, `CODESIGN_IDENTITY="Developer ID
          Application: ..."`.

        ## Library

        - **Library folder.** The studio keeps its own setting in
          `UserDefaults` (suite `com.giorgosmarinos.ntakker-studio`) under
          `studio.libraryFolder`. On the very first launch, if that key
          is unset, the studio adopts ntakker's output folder
          (`com.ntakker-cli.ui.outputFolder` in the `com.giorgosmarinos.ntakker`
          suite). If neither is set the user must choose a folder
          (File > Choose Library Folder..., Cmd-Shift-O, or Settings);
          there is no default folder. Cmd-R rescans.
        - **Scan depth.** The scanner walks up to 4 folder levels below
          the library folder.
        - **Grouping.** The sidebar groups recordings by month, newest
          first.

        ### What counts as a recording

        A recording is the set of audio files and transcript sidecars in
        one folder that share a stem:

        - Audio: `<stem>.m4a|wav|caf` (mixed or stereo-split layouts) or
          the pair `<stem>.mic.<ext>` + `<stem>.system.<ext>` (split
          layout) - the pair is one recording with two tracks.
        - **Parts.** Every `.partNN` segment (from pause or split, for
          example `recording-....part02.m4a`) is its own recording.
        - **Transcripts.** `<stem>.transcript.jsonl` and every
          `<stem>.<label>.transcript.jsonl` (per-source transcripts such
          as `.mic` / `.system`, and re-transcriptions) are attached to
          the recording.
        - `*.orig` backups are ignored.
        - Session notes `transcript.md` and `qa.md` found in the
          recording's session folder are attached to it.
        - JSONL is the source of truth. SRT, VTT and TXT sidecars are not
          read.

        ## Features

        ### Search across all recordings

        Full-text search over every transcript in the library. Matching
        is case- and diacritic-insensitive and all typed words must
        occur in the line. A result opens its recording at that moment.

        ### Player

        - Plays the mic and system tracks of a split recording mixed
          together, through `AVAudioEngine` (blocks of 8192 frames, about
          0.7 s scheduled ahead).
        - Speeds 0.75x to 2x.
        - **Remove echo** (split recordings only): subtracts the system
          audio that leaked into the microphone, while you listen. It is
          ntakker's NLMS echo canceller (`SoftwareAECProcessor.processAligned`,
          playback tuning) with the system track as the reference. When a
          recording opens, its echo delay is measured
          (`EchoDelayEstimator`, 1 ms envelopes over two minutes; 110–145 ms
          on the recordings tried) and the reference is delayed by that
          minus 20 ms, so the echo falls inside the filter's 85 ms window.
          The filter keeps learning while off, so switching it on is
          immediate; after a jump it settles again within a second or two.
          The choice is remembered. Files are never changed. Measured on
          three real recordings: the mic is 15–16 dB quieter while the
          system side talks on two of them, about 3 dB on the third, which
          is mostly speech in the room (kept, as it should be).
        - Space plays / pauses and Left / Right skip 5 s, but only while
          no text field has keyboard focus. The Playback menu offers the
          same actions as Option-Space, Option-Left, Option-Right, which
          work even while typing.

        ### Waveform

        Click to seek; drag to select a range (the selection feeds Cut).

        ### Transcript pane

        Shows every transcript of the recording with time, speaker and
        source. Follow mode highlights and scrolls to the line being
        played; a text filter and a speaker filter narrow the lines;
        clicking a line seeks the audio to where it was spoken;
        double-clicking a line edits its text. An edit rewrites the JSONL
        sidecar atomically (temp file, then replace); the first edit of a
        file keeps a one-time backup `<transcript>.orig`.

        ### Inspector tabs

        - **Ask** - questions about the recording. The whole transcript
          is sent to the model as `[mm:ss] Speaker: text` lines (the
          studio does not truncate to a context window). `[mm:ss]`
          citations in answers are clickable and seek the player. The
          last 6 exchanges are kept as conversation history. Saved to
          `<stem>.studio-qa.md`.
        - **Minutes** - generates meeting minutes in sections, with an
          optional output language. Saved to `<stem>.minutes.md`.
        - **Speakers** - rename speakers; names are saved per recording
          (in `<stem>.studio.json`) and used in the transcript view, Ask
          and Minutes.
        - **Cut** - mark ranges on the waveform; preview mode skips them
          during playback; Export writes a cut copy (see "Cut export").
        - **Re-transcribe** - see below.
        - **Info** - the recording's files, the audio-start/sync
          information, and a sync offset stepper (+/- 30 s).

        ### Cut export

        A cut never modifies the original files. Every audio track is cut
        (same format), every transcript is re-timed (lines inside a cut
        are dropped, later lines shift earlier), and a `.studio.json` is
        written for the copy. The output goes to:

        - `<folder>-cut-<yyyy-MM-dd-HH-mm-ss>/`, a sibling of the
          original folder, when the recording lives in its own session
          folder; or
        - a `<stem>-cut-<yyyy-MM-dd-HH-mm-ss>/` subfolder when the folder
          is shared with other recordings.

        **Remove echo from the microphone** (split recordings): the same
        export can also clean the mic track of the system track's echo,
        with or without cuts. `EchoCleaner` runs the playback echo filter
        over the whole mic file at the measured echo delay, after a
        one-minute warm-up pass so the opening is clean too, writing the
        mic file's own format; the cut, if any, is applied afterwards. The
        folder is then named `…-clean-…` (echo only) or `…-cut-clean-…`
        (both). Re-transcribing the cleaned copy gives a mic transcript
        without the other side's words in it.

        ### Re-transcribe

        Produces a new transcript from the audio with one of ntakker's
        **batch** providers: `parakeet`, `whisperkit`, `gemini`, `azure`,
        `elevenlabs`. Provider settings are resolved through
        `ConfigResolver(toolName: "ntakker")`, i.e. ntakker's
        configuration, and the provider is built with
        `TranscriptionProviderFactory`. The audio is decoded to 16 kHz
        and chunked on silence: cloud providers get a 20 s target / 30 s
        maximum chunk; on-device providers use their own chunking
        policy. Streaming-only providers (`apple`, `apple-cloud`,
        `soniox`, `azure-openai-realtime`, `gemini-live`) are refused.
        The result is written as
        `<stem>[.<track>].<provider>-<yyyyMMdd-HHmm>.transcript.jsonl`
        with exact timestamps and attached to the recording. The
        language list typed in the panel is passed to the provider as
        `NTAKKER_TRANSCRIBE_LANGUAGE` (process environment).

        ## Timing model (`SegmentTiming`)

        Transcript segments carry wall-clock timestamps. To place a
        segment on the audio timeline:

        - **Audio start** = the creation date of the first audio file,
          unless `<stem>.studio.json` holds an `audioStart` override.
        - **Offset** = segment timestamp - audio start.
        - **Batch providers** stamp a segment when the result arrives, so
          the segment's `durationSec` is also subtracted.
        - **Streaming providers** (ids `soniox`, `apple`, `apple-cloud`,
          `azure-openai-realtime`, `gemini-live`) stamp the segment when
          it is spoken; no duration is subtracted.
        - **Per-recording sync nudge** (`syncOffsetSec`, Info tab,
          +/- 30 s) corrects whatever error remains.
        - Transcripts written by the studio itself (re-transcriptions,
          cuts) carry exact timing and are listed in
          `exactTimingTranscripts`, so no estimation or nudge applies.

        ## Files the studio writes

        Only next to the recording, never anywhere else:

        | File | Written when | Content |
        |---|---|---|
        | `<stem>.studio.json` | only when the user changes something | `audioStart`, `speakerNames`, `syncOffsetSec`, `exactTimingTranscripts` |
        | `<stem>.minutes.md` | Minutes generated | meeting minutes |
        | `<stem>.studio-qa.md` | Ask used | question and answer log |
        | `<transcript>.orig` | first text edit of a transcript | backup of the unedited JSONL |
        | `<stem>[.<track>].<provider>-<yyyyMMdd-HHmm>.transcript.jsonl` | Re-transcribe | new exact-timing transcript |
        | `<folder>-cut-<yyyy-MM-dd-HH-mm-ss>/` or `<stem>-cut-<yyyy-MM-dd-HH-mm-ss>/` | Cut export | cut audio, re-timed transcripts, studio metadata |

        Original audio files are never modified. Edited transcript text
        is the only in-place change to an original sidecar, and it keeps
        the `.orig` backup.

        ## Configuration

        **`ntakker-studio` has no configuration folder of its own.** There
        is no `~/.tool-agents/ntakker-studio/` and none must be created.
        At launch (`applicationWillFinishLaunching`) the app loads
        ntakker's file `~/.tool-agents/ntakker/.env` into its process
        (`EnvFileStore.loadIntoProcess(toolName: "ntakker")`) and reuses
        ntakker's settings; a load failure is logged and the app
        continues, with Ask and re-transcription then failing on their
        own missing-configuration errors. Edit those settings in
        ntakker's Settings (or the file itself, mode `0600`); the studio
        never writes the file. As in ntakker, missing required
        configuration raises an error - there are no fallback values.

        Variable names consumed (values are never documented here):

        | Variable | Used for |
        |---|---|
        | `NTAKKER_ASK_PROVIDER` | Provider for Ask and Minutes, resolved by `AskConfigResolver` |
        | `NTAKKER_ASK_MODEL` | Model for Ask and Minutes |
        | `NTAKKER_ASK_CONTEXT_MINUTES` | Part of ntakker's Ask settings, but **not used** by the studio: it sends the whole transcript |
        | Provider keys and endpoints (`OPENAI_*`, `ANTHROPIC_*`, `GOOGLE_API_KEY`, `AZURE_OPENAI_*`, `AZURE_AI_INFERENCE_*`, `OLLAMA_HOST`, `LITELLM_*`, `SONIOX_API_KEY`, `ELEVENLABS_*`, ... ) | Exactly as in ntakker: whatever the chosen Ask or re-transcription provider requires |
        | `NTAKKER_TRANSCRIBE_LANGUAGE` | Set in the process from the Re-transcribe panel's languages field |

        The resolution chain for these values is the one documented for
        ntakker ([ntakker.md](ntakker.md) -> "Resolution chain"): shell
        environment, then `~/.tool-agents/ntakker/.env`, then a local
        `.env`; the studio has no CLI flags.

        UI state is stored in `UserDefaults` under `com.giorgosmarinos.ntakker-studio`
        (for example `studio.libraryFolder`). It is UI persistence, not
        runtime configuration.

        ## Logging

        Uses `swift-log`; the app logs under the label
        `ntakker-studio.app`. It does not create a log file under
        `~/.tool-agents`.

        ## Known limitations

        - Streaming-only providers cannot be used to re-transcribe.
        - The audio start is estimated from the file creation date, which
          is accurate to about +/- 1 s plus the provider's batch latency
          for transcripts not written by the studio. Use the Info tab's
          sync offset stepper to correct it per recording.
        - SRT, VTT and TXT sidecars are not read; only JSONL.
        - Ad-hoc-signed builds may be treated as a new app by macOS after
          each rebuild (same caveat as ntakker, R-2 / R-23).
        - No recording; use `ntakker` or `ntakker-cli`.

        ## File locations

        - **App:** `/Applications/ntakker-studio.app` (installed), `dist/ntakker-studio.app` (packaged).
        - **Preferences:** `~/Library/Preferences/com.giorgosmarinos.ntakker-studio.plist`.
        - **Configuration:** none of its own; reads `~/.tool-agents/ntakker/.env`.
        - **Sources:** `Sources/ntakker-studio/` (app), `Sources/NtakkerStudioKit/` (kit), `Tests/NtakkerStudioTests/`.

        ## Releasing

        A public release is Developer ID signed with the hardened runtime and notarized by Apple.

        1. Set the version in `Resources/NtakkerStudio-Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`).
        2. Build, sign, notarize and package (both variables are required; there are no defaults):
           ```sh
           NTAKKER_SIGN_IDENTITY=<Developer ID Application SHA-1> \
           NOTARY_PROFILE=<notarytool keychain profile> \
             bash scripts/release.sh ntakker-studio
           ```
           Two identities share the name "Developer ID Application: GEORGIOS MARINOS", so pass the SHA-1 (`security find-identity -v -p codesigning`). The script runs the tests (only the failures listed in `scripts/release-known-failures.txt` are tolerated), verifies the Developer ID signature and hardened runtime, notarizes, and writes `ntakker-studio-<version>.zip`, a stapled `.dmg` and `SHA256SUMS` to `dist/release/ntakker-studio/`, plus `homebrew-tap/Casks/ntakker-studio.rb`.
        3. Tag `ntakker-studio-v<version>` and create the GitHub release on `biks2013-tools/ntakker` with those files.
        4. Copy `homebrew-tap/Casks/ntakker-studio.rb` into `biks2013-tools/homebrew-ntakker` (`Casks/`) and push. Users install with `brew install --cask biks2013-tools/ntakker/ntakker-studio`.

        ## Cross-references

        - [docs/plans/plan-024-ntakker-studio.md](../plans/plan-024-ntakker-studio.md) - architecture and task list.
        - [docs/refined_requests/refined-request-001-ntakker-studio.md](../refined_requests/refined-request-001-ntakker-studio.md) - request, decisions and scope.
        - [ntakker.md](ntakker.md) - the menu-bar app whose configuration and output folder the studio reuses.
        - [ntakker-cli.md](ntakker-cli.md) - the recording engine and transcript sidecar format.
    </info>
</ntakkerStudio>
