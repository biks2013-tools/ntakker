<dualTranscriptMerger>
    <objective>
        Merges dual-channel JSONL sidecar transcripts produced by `macrec --transcribe dual`
        (Channel A = Apple on-device English / Greek primary; Channel B = Apple Cloud secondary)
        into a single chronologically-ordered transcript. The two providers have very different
        emission cadences — Channel A streams short utterances (~0 s duration each) while
        Channel B emits one long ~55 s consolidated transcript per task-rotation window — and
        Channel B also tends to hallucinate when fed audio in the other channel's language.
        The tool interleaves both channels by timestamp and applies a configurable
        cross-language hallucination filter (conservative default; aggressive opt-in; or off
        for raw merge).
    </objective>
    <command>
        dual-transcript-merger &lt;input.jsonl&gt; [--filter conservative|aggressive|off] [--out &lt;path&gt;] [--format jsonl|txt]
    </command>
    <info>
        ## Overview

        `dual-transcript-merger` is a TypeScript CLI tool that post-processes the dual-channel
        JSONL sidecar files written by `macrec --transcribe dual`. Each line in the sidecar is
        a JSON object tagged with a `channel` field (`A` or `B`) plus standard transcript
        fields (`startTime`, `endTime`, `text`, `locale`, etc.).

        The tool reads the input file, sorts all utterances by `startTime`, optionally removes
        hallucinated entries via a cross-language filter, and writes the merged result either
        back to a JSONL file (all metadata preserved) or to a human-readable plain-text file
        with inline channel tags.

        ---

        ## Configuration

        Configuration is resolved in the following priority order (lowest → highest):

        1. Shell environment variables (`process.env`)
        2. `~/.tool-agents/dual-transcript-merger/.env`
        3. Local `.env` in the current working directory
        4. CLI flags (always win)

        ### Environment variables

        #### DUAL_TRANSCRIPT_MERGER_DEFAULT_FILTER
        Sets the default value for `--filter` when the flag is omitted on the CLI.
        Accepted values: `conservative` | `aggressive` | `off`.
        - `conservative` (documented default): removes Channel B utterances whose detected
          locale does not match the locale the B-provider was configured for, using a
          low-sensitivity language-ID heuristic. Catches the most common cross-language
          hallucinations without discarding ambiguous short segments.
        - `aggressive`: removes any Channel B utterance where language-ID confidence falls
          below a higher threshold. Useful when Channel A already provides reliable coverage
          of the primary language and you want the cleanest possible merged output.
        - `off`: disables all hallucination filtering. Both channels are interleaved as-is.
          Use this for raw diagnostic merges or when building downstream tooling that applies
          its own filtering logic.
        If this variable is not set AND `--filter` is not passed, the tool defaults to
        `conservative`.

        #### DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT
        Sets the default value for `--format` when the flag is omitted on the CLI.
        Accepted values: `jsonl` | `txt`.
        - `jsonl` (documented default): writes one JSON object per merged utterance, preserving
          all metadata fields from the original sidecar (channel, locale, confidence, timing,
          provider, etc.). Suitable for downstream programmatic processing.
        - `txt`: writes a human-readable plain-text transcript, one utterance per line,
          prefixed with a channel tag and timestamp, e.g.:
            `[A 00:01:03.420] Hello, good morning everyone.`
            `[B 00:01:04.001] And good afternoon to all participants.`
        If this variable is not set AND `--format` is not passed, the tool defaults to `jsonl`.

        ---

        ## Command-line parameters

        | Parameter                        | Required | Description |
        |----------------------------------|----------|-------------|
        | `<input.jsonl>`                  | Yes      | Path to the dual-channel JSONL sidecar file produced by `macrec --transcribe dual`. |
        | `--filter conservative\|aggressive\|off` | No | Cross-language hallucination filter level. Overrides `DUAL_TRANSCRIPT_MERGER_DEFAULT_FILTER`. Default: `conservative`. |
        | `--out <path>`                   | No       | Output file path. If omitted, the merged file is written alongside the input file with a `.merged` infix, e.g. `recording.dual.jsonl` → `recording.merged.jsonl` (or `.merged.txt`). |
        | `--format jsonl\|txt`            | No       | Output format. Overrides `DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT`. Default: `jsonl`. |

        ---

        ## Exit codes

        | Code | Meaning |
        |------|---------|
        | 0    | Success — merged file written. |
        | 1    | Input file not found or unreadable. |
        | 2    | Input file is not valid dual-channel JSONL (missing required fields). |
        | 3    | Output path is not writable. |
        | 4    | Invalid value supplied for `--filter` or `--format`. |

        ---

        ## Examples

        ### Basic merge with default settings
        Uses `conservative` filter and `jsonl` output format. Output is written next to the
        input file.

        ```sh
        dual-transcript-merger ~/Recordings/2026-05-02.dual.jsonl
        # writes: ~/Recordings/2026-05-02.merged.jsonl
        ```

        ### Merge with aggressive hallucination filtering, plain-text output
        ```sh
        dual-transcript-merger ~/Recordings/meeting.dual.jsonl \
            --filter aggressive \
            --format txt \
            --out ~/Transcripts/meeting-clean.txt
        ```

        ### Raw merge (no filtering) for diagnostic inspection
        ```sh
        dual-transcript-merger ~/Recordings/meeting.dual.jsonl \
            --filter off \
            --out ~/Transcripts/meeting-raw.jsonl
        ```

        ### Override default format via environment variable, then use CLI flag to override again
        ```sh
        export DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT=txt
        dual-transcript-merger ~/Recordings/meeting.dual.jsonl
        # writes .merged.txt because env var says txt

        dual-transcript-merger ~/Recordings/meeting.dual.jsonl --format jsonl
        # writes .merged.jsonl because CLI flag overrides env var
        ```

        ### Pin project-wide defaults in ~/.tool-agents config
        ```sh
        # Edit ~/.tool-agents/dual-transcript-merger/.env and set:
        # DUAL_TRANSCRIPT_MERGER_DEFAULT_FILTER=aggressive
        # DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT=txt
        #
        # From that point on, any invocation without --filter or --format
        # will use aggressive filtering and txt output.
        dual-transcript-merger ~/Recordings/lecture.dual.jsonl
        ```

        ---

        ## Input JSONL format

        Each line in the input file is expected to be a JSON object with at minimum:

        ```jsonc
        {
          "channel": "A" | "B",
          "startTime": <number>,   // seconds since recording start, fractional
          "endTime": <number>,     // seconds since recording start, fractional
          "text": "<string>",
          "locale": "<BCP-47>",   // e.g. "en-US", "el-GR"
          "provider": "<string>", // e.g. "apple-ondevice", "apple-cloud"
          "confidence": <number>  // optional, 0.0–1.0
        }
        ```

        Lines that cannot be parsed as JSON, or that are missing `channel`, `startTime`, or
        `text`, are skipped with a warning printed to stderr.

        ---

        ## Output JSONL format

        Each merged output line extends the input object with a `mergedAt` timestamp (ISO-8601
        wall-clock) and a `filterAction` field:

        ```jsonc
        {
          // ... all original fields ...
          "mergedAt": "2026-05-02T09:14:37.000Z",
          "filterAction": "kept" | "removed-hallucination"
          // filterAction is "removed-hallucination" only when --filter off is used
          // and you want to inspect what would have been removed; in normal mode
          // removed lines are simply omitted from the output.
        }
        ```

        ---

        ## Installation

        The tool lives under `tools/dual-transcript-merger/` inside the project repository
        as a Node/TypeScript workspace package. Once implemented:

        ```sh
        cd tools/dual-transcript-merger
        npm install
        npm run build
        npm link          # makes `dual-transcript-merger` available on PATH
        ```
    </info>
</dualTranscriptMerger>
