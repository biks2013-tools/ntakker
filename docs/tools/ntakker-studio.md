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
          `.app` by the packaging script).
        - Icon ("Listen & Read", 2026-10-18): a frosted panel with a
          waveform — the played part in ntakker's mint, a red playhead —
          over three transcript lines with speaker dots, the current one
          highlighted, on the squircle of ntakker's icon in a midnight →
          teal gradient. At 16 / 32 px only a thick waveform and the
          playhead are drawn. Source: `scripts/generate-studio-appicon.swift`
          (Core Graphics, no external tools) →
          `Resources/StudioAppIcon.iconset/` → `iconutil -c icns
          Resources/StudioAppIcon.iconset -o Resources/StudioAppIcon.icns`.
          The packaging script copies it into the bundle as `AppIcon.icns`
          and regenerates it when the `.icns` is missing.
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
        - **Rename and Move to Trash (added 2026-10-27).** Right-click a
          recording in the sidebar for *Rename…*, *Show in Finder* and
          *Move to Trash* (also File > Rename Recording… and File > Move to
          Trash, Cmd-Delete, or the Delete key in the list; several
          selected recordings go to the Trash together).
          - *Rename* renames what the sidebar shows: a recording with its
            session folder to itself renames the **folder** (for a paused /
            split session the folder holds every part, so all parts take the
            new name, and the sheet says so); a recording that shares its
            folder, or lies loose in the library folder, renames its
            **files** — every `<stem>.…` file (audio, transcripts and their
            `.orig` backups, `studio.json`, minutes, Q&A, ntakker's
            `.questions.jsonl`), never another recording's longer stem
            (`x.part01.…` is not `x`'s). Names with `/` or `:`, or starting
            with a dot, and names already taken are refused; a failed file
            rename is undone.
          - *Move to Trash* asks first (name, size), then moves the whole
            session folder to the Trash when no other recording lives in
            it, otherwise only the recording's files. Finder's Put Back
            restores it.
          - The library folder itself is never renamed or trashed, and a
            recording whose audio was written in the last 10 s (ntakker is
            still recording it) is refused. An open recording is closed
            first and, after a rename, reopened under its new name.

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
        - **Echo filter settings** (the sliders button next to Remove
          echo; they also apply to Export Copy with echo removal):
          - *Strength* 0–100 %: out = (1 − s)·mic + s·filtered.
          - *Extra suppression* off / low / high: a second stage
            (`ResidualEchoSuppressor`, 512-sample frames, 10.7 ms of
            delay) that turns each frequency down by how much of it is the
            echo the canceller estimated, catching what the canceller
            cannot model (reverb, speaker distortion). Measured on two
            echo-heavy recordings (two minutes, system side talking):
            off 16 dB, low 23 dB, high 28 dB. Local speech over the echo
            loses at most 1.5 dB (low) / 3 dB (high) in tests.
          - *Adaptation* stable / fast: the canceller's learning speed
            (fast = μ 0.3; stable = μ 0.05, smaller steps). Changing it
            restarts the learning.
          - *Echo delay by hand* 0–400 ms: replaces the measured delay for
            this recording; saved as `echoDelayMs` in `<stem>.studio.json`.
          Strength, suppression and adaptation are app-wide
          (`studio.echo.*` preferences); unset means full strength, off,
          fast.
        - Space plays / pauses and Left / Right skip 5 s, but only while
          no text field has keyboard focus. The Playback menu offers the
          same actions as Option-Space, Option-Left, Option-Right, which
          work even while typing.

        ### Waveform

        Click to seek; drag to select a range (the selection feeds Cut).

        **The two channels apart (added 2026-10-21).** A split recording
        (separate mic and system files) shows two lanes, **System** above
        and **Mic** below, each with its own waveform on the same
        timeline:

        - The speaker button at a lane's left mutes that channel **while
          you listen** — mute one to hear the other alone. Listening only:
          the files and the export are not affected.
        - A range dragged on a lane is selected on that channel; in the
          Cut tab, **Silence on Mic / System** replaces it with silence on
          that channel only (to take out a cough, typing, a notification
          heard on one side). Silenced ranges show grey on their lane and
          are heard as silence at once.

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
          during playback; on a split recording, silence ranges on one
          channel (the **Silenced** box: per-range play / remove, *Silence
          Whole Mic* / *Silence Whole System*, Clear); Export writes a
          copy with all of it (see "Cut export").
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

        **Silenced ranges** (split recordings, 2026-10-21): the same export
        writes each silenced range of a channel as silence in that
        channel's file (ranges on the original timeline, then the cut), with
        a 10 ms fade at each edge so there is no click; the other channel
        is untouched. The folder name gets `-silenced` (e.g.
        `…-silenced-…`, `…-cut-silenced-…`). Transcript lines are kept — a
        silenced range is not removed from the timeline. Silences, like
        cuts, live in the open recording until exported; they are not
        saved with it.

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
        | `<stem>.studio.json` | only when the user changes something | `audioStart`, `speakerNames`, `syncOffsetSec`, `exactTimingTranscripts`, `echoDelayMs`, `meeting` (the linked calendar meeting: `id`, `subject`, `start`, `end`, `organizer`, `attendees`, `location`, `webLink`) |
        | `<stem>.minutes.md` | Minutes generated | meeting minutes |
        | `<stem>.studio-qa.md` | Ask used | question and answer log |
        | `<transcript>.orig` | first text edit of a transcript | backup of the unedited JSONL |
        | `<stem>[.<track>].<provider>-<yyyyMMdd-HHmm>.transcript.jsonl` | Re-transcribe | new exact-timing transcript |
        | `<folder>-cut-<yyyy-MM-dd-HH-mm-ss>/` or `<stem>-cut-<yyyy-MM-dd-HH-mm-ss>/` (also `-clean`, `-silenced` and combinations) | Cut export | cut / cleaned / silenced audio, re-timed transcripts, studio metadata |

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
        own missing-configuration errors. Edit those settings in either
        app's Settings window (plan-025: both write the file) or in the
        file itself (mode `0600`). As in ntakker, missing required
        configuration raises an error - there are no fallback values.

        Variable names consumed (values are never documented here):

        | Variable | Used for |
        |---|---|
        | `NTAKKER_ASK_PROVIDER` | Provider for Ask and Minutes, resolved by `AskConfigResolver` |
        | `NTAKKER_ASK_MODEL` | Model for Ask and Minutes |
        | `NTAKKER_ASK_CONTEXT_MINUTES` | Part of ntakker's Ask settings, but **not used** by the studio: it sends the whole transcript |
        | Provider keys and endpoints (`OPENAI_*`, `ANTHROPIC_*`, `GOOGLE_API_KEY`, `AZURE_OPENAI_*`, `AZURE_AI_INFERENCE_*`, `OLLAMA_HOST`, `LITELLM_*`, `SONIOX_API_KEY`, `ELEVENLABS_*`, ... ) | Exactly as in ntakker: whatever the chosen Ask or re-transcription provider requires |
        | `NTAKKER_TRANSCRIBE_LANGUAGE` | Set in the process from the Re-transcribe panel's languages field |
        | `NTAKKER_RECORDINGS_DIR` | The library folder (shared with ntakker) |
        | `NTAKKER_STUDIO_ECHO_STRENGTH` / `_SUPPRESSION` / `_ADAPTATION` | The echo filter |
        | `NTAKKER_CALENDAR_COMMAND` | The calendar command for meeting matching (below); no default — unset means the feature reports "not configured" |

        The resolution chain for these values is the one documented for
        ntakker ([ntakker.md](ntakker.md) -> "Resolution chain"): shell
        environment, then `~/.tool-agents/ntakker/.env`, then a local
        `.env`. The studio's only command-line options are those of
        `ntakker-studio match-meetings` and `ntakker-studio join` (below).

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

        ## Shared settings file (plan-025)

        The Settings window (⌘,) starts with the studio's own **General**
        pane (Appearance, below), then the same shared settings view as
        ntakker's: Recording, Transcription, Asking, each provider and Studio,
        all stored in `~/.tool-agents/ntakker/.env`. The library is the shared
        recordings folder `NTAKKER_RECORDINGS_DIR` (the one ntakker records
        into; a folder chosen in an earlier version is carried over once), and
        the echo filter's strength, suppression and adaptation are
        `NTAKKER_STUDIO_ECHO_*` there; the per-recording echo delay stays in
        `<stem>.studio.json`. Changes made in ntakker or in the file show up at
        once.

        ## Appearance

        System, Light or Dark for every studio window (main window, Settings,
        popovers, sheets, open/save panels). Choose it in **Settings ▸ General ▸
        Theme** or **View ▸ Appearance**; it applies at once and is restored
        before the first window opens on the next launch. *System* follows the
        macOS appearance. Stored per app in the studio's preferences
        (`studio.appearance` = `system` / `light` / `dark`; missing means
        `system`), not in the shared file. Implemented with `NSApp.appearance`
        (`Sources/ntakker-studio/Model/StudioAppearance.swift`).

        ## Meetings from the calendar

        The studio can tell which calendar meeting a recording is. It runs
        a configured command that prints the calendar as JSON and matches
        each recording's time span against the meetings in it.

        **Configure** `NTAKKER_CALENDAR_COMMAND` in
        `~/.tool-agents/ntakker/.env` (or Settings ▸ Studio ▸ Calendar):
        a shell command line with `{from}` and `{to}`, which are replaced by
        the first and last day (`YYYY-MM-DD`, local time, both included).
        It runs through `/bin/sh -c` with the app's environment; apps
        started from the Dock have a short PATH, so give the program's full
        path. It may take up to 120 s. With M365Mail
        (`m365mail calendar export`, Microsoft 365 via Graph):

        ```sh
        NTAKKER_CALENDAR_COMMAND="/Users/<you>/.local/bin/m365mail calendar export --from {from} --to {to} --no-description"
        ```

        `--no-description` keeps meeting bodies out (only a short preview
        is printed); the studio does not need them.

        **Calendar JSON accepted** (`CalendarDocument`): `{"events": [ … ]}`
        (m365mail's document) or a bare `[ … ]`. Each event needs
        `subject`, `start`, `end` — ISO 8601 with an offset, or a bare day
        for all-day events. Optional and used: `id`, `allDay`,
        `myResponse`, `organizer {name, address}`, `attendees [{name,
        address}]`, `location`, `webLink` / `onlineMeeting.joinUrl`. Any
        other tool printing this shape works.

        **Matching** (`MeetingMatcher`). A recording spans its start
        (`studio.json` `audioStart`, else the audio file's creation date)
        plus the length of its longest track. All-day and declined events
        are ignored. Every overlapping meeting is a candidate, ranked by
        *fit* — overlap ÷ the span both cover together — plus a bonus when
        a word of the recording's name is in the subject
        (`fireblocks-recording-…` → "NBG | FIREBLOCKS"; words of 3+
        letters, stems by the first five letters, generic words such as
        "recording", "meeting", "nbg" ignored); ties go to accepted or
        organised meetings. Confidence: **strong** (fit ≥ 0.5, or a name
        match with fit ≥ 0.25, and no close runner-up), **likely** (fit ≥
        0.2 or a name match), **weak** (only touches it — in practice
        clips of a few minutes). A recording left running across
        back-to-back meetings is reported as **spanning several meetings**
        (each ≥ 80 % recorded; clashing meetings counted once), listed in
        order.

        **In the app:** Info ▸ Meeting ▸ *Find in Calendar* lists the
        best match and up to four alternatives with their confidence and
        coverage; *Link* saves one in `<stem>.studio.json` (`meeting`),
        after which its subject shows under the recording's title and
        *Open in Calendar* / *Unlink* are offered.

        **From the command line:**

        ```sh
        /Applications/ntakker-studio.app/Contents/MacOS/ntakker-studio match-meetings \
            [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--name TEXT] [--library DIR]
        ```

        prints one JSON document: `library`, `recordings`, `matched`
        (counts per confidence, and `spansSeveralMeetings`), and `results`
        — per recording `recording`, `stem`, `folder`, `start`, `end`,
        `durationMinutes`, `confidence`, `meeting` (subject, times,
        organizer, attendees, `overlapMinutes`, `fitPercent`,
        `recordingCoveragePercent`, `meetingCoveragePercent`,
        `nameMatches`, `webLink`), `alternatives`, and `meetingsCovered`
        when it spans several. The calendar is fetched once per range of
        at most 31 days. Exit codes: 0, 64 usage, 78 missing
        configuration (no command / no library), 1 when the command or its
        JSON fails. Without a command word the binary opens the app.

        **Validated 2026-10-18** on the user's library (124 recordings,
        29 Apr – 17 Oct 2026, M365 calendar, 41 s): 51 strong, 18 likely,
        26 weak, 29 none; 10 spanning several meetings. Of the 63
        recordings the user had named after the meeting, 33 matched a
        subject sharing a word, and nearly all the others were right by
        content (bancassurance ↔ "NBG-Allianz Asphodel", 11labs ↔
        ElevenLabs, fidelity ↔ FIL, paloalto ↔ Unit42, Greek subjects);
        "none" and "weak" were test clips and recordings outside meetings.

        ## Joining recordings (added 2026-10-19)

        A session that was paused and resumed (or split) is saved as
        several `.partNN` recordings. Joining makes **one new recording**
        from them; the originals are not changed.

        **In the app:** select two or more recordings in the library
        (⌘-click / ⇧-click). The detail area shows the join: the parts
        in the order they were recorded, the pause before each (left
        out of the joined audio), where each part begins in the result,
        its length and lines, and the joined length. A part of a session
        also shows **Join the N Parts…** next to its title, which selects
        all the parts of that session. *Join* writes the recording,
        rescans the library and opens it.

        **What is written:**
        - audio: per track (mixed, or mic + system), the parts end to
          end in the first part's file format; a track shorter than its
          part is padded with silence so mic and system stay aligned; a
          part in another sample rate or channel count is converted;
        - a transcript for every label any part has (main, microphone,
          system, re-transcriptions), each part's lines placed as the
          studio shows them (sync nudge applied) and shifted to where the
          part begins, written with exact timing;
        - `<stem>.studio.json`: start = the first part's start, speaker
          names merged (an id named in an earlier part keeps that name),
          the first linked meeting. Minutes and Q&A notes are not carried
          over.
        - where: a sibling folder `<folder>-joined-<yyyy-MM-dd-HH-mm-ss>`
          when the first part's folder holds only the joined parts,
          otherwise a subfolder `<stem>-joined-<…>` of that folder. Files
          are named after the parts' stem without `.partNN`.

        Recordings with different tracks (e.g. one part without its mic
        file) are refused with a message naming both. Speaker ids are
        per part in live transcripts (Soniox's "1" in one part need not be
        the same person in the next); rename speakers in the joined
        recording when they differ.

        **From the command line:**

        ```sh
        ntakker-studio join --name TEXT [--library DIR] [--dry-run]
        ```

        joins every recording whose name contains TEXT (at least two) and
        prints JSON: `plan` (stem, start, `durationSeconds`, tracks,
        transcripts, and per part `recording`, `start`, `durationSeconds`,
        `offsetSeconds`, `pauseBeforeSeconds`, `lines`) and, unless
        `--dry-run`, `joined` (folder, stem, parts, duration, lines).
        Exit codes as for `match-meetings`.

        **Validated 2026-10-19** on a copy of the user's six-part
        "Daily-Projects" session (with part 1's mic file put back): 24:34
        of audio in 12 s, both tracks 1474.1 s (the sum of the parts),
        307 lines (the sum), in order; the audio of parts 5 and 6 sits at
        684.7 s and 1402.7 s of the joined track with zero shift
        (envelope correlation 1.0).

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
