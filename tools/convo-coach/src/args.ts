// src/args.ts — hand-rolled CLI argument parser.
//
// Mirrors the style of tools/dual-transcript-merger/src/cli.ts:84-157.
// Recognised flags (all optional, all string-valued unless marked):
//
//   --transcript <path>
//   --last <duration>
//   --since <timestamp>
//   --provider <name>          (validated against ProviderName union)
//   --model <id>
//   --system-prompt <path>
//   --debounce <duration>
//   --on-overflow <strategy>   (validated against OverflowStrategy union)
//   --recordings-dir <dir>
//   --help, -h                 (boolean)
//   --version, -V              (boolean)
//
// Unknown flags or invalid enum values throw `UsageError` (exit 64).

import {
    OVERFLOW_STRATEGIES,
    PROVIDER_NAMES,
    UsageError,
    type CliArgs,
    type OverflowStrategy,
    type ProviderName,
} from './types.js';

interface MutableCliArgs {
    transcript?: string;
    last?: string;
    since?: string;
    provider?: ProviderName;
    model?: string;
    systemPrompt?: string;
    debounce?: string;
    onOverflow?: OverflowStrategy;
    recordingsDir?: string;
    help?: boolean;
    version?: boolean;
}

function isProviderName(v: string): v is ProviderName {
    return (PROVIDER_NAMES as readonly string[]).includes(v);
}

function isOverflowStrategy(v: string): v is OverflowStrategy {
    return (OVERFLOW_STRATEGIES as readonly string[]).includes(v);
}

export function parseCliArgs(argv: readonly string[]): CliArgs {
    const out: MutableCliArgs = {};
    let i = 0;
    while (i < argv.length) {
        const arg = argv[i] ?? '';
        const consumeValue = (): string => {
            const v = argv[i + 1];
            if (v === undefined) {
                throw new UsageError(`${arg} requires a value`);
            }
            i += 1;
            return v;
        };

        switch (arg) {
            case '-h':
            case '--help':
                out.help = true;
                break;
            case '-V':
            case '--version':
                out.version = true;
                break;
            case '--transcript':
                out.transcript = consumeValue();
                break;
            case '--last':
                out.last = consumeValue();
                break;
            case '--since':
                out.since = consumeValue();
                break;
            case '--provider': {
                const v = consumeValue();
                if (!isProviderName(v)) {
                    throw new UsageError(
                        `--provider='${v}' is invalid (allowed: ${PROVIDER_NAMES.join(', ')})`,
                    );
                }
                out.provider = v;
                break;
            }
            case '--model':
                out.model = consumeValue();
                break;
            case '--system-prompt':
                out.systemPrompt = consumeValue();
                break;
            case '--debounce':
                out.debounce = consumeValue();
                break;
            case '--on-overflow': {
                const v = consumeValue();
                if (!isOverflowStrategy(v)) {
                    throw new UsageError(
                        `--on-overflow='${v}' is invalid (allowed: ${OVERFLOW_STRATEGIES.join(', ')})`,
                    );
                }
                out.onOverflow = v;
                break;
            }
            case '--recordings-dir':
                out.recordingsDir = consumeValue();
                break;
            default:
                if (arg.startsWith('-')) {
                    throw new UsageError(`unknown option '${arg}' (try --help)`);
                }
                throw new UsageError(
                    `unexpected positional argument '${arg}' (convo-coach takes no positional args; try --help)`,
                );
        }
        i += 1;
    }

    return out as CliArgs;
}

/**
 * True when stdin is piped / redirected (not an interactive terminal).
 *
 * Node sets `process.stdin.isTTY` to `true` only for a TTY; for pipes and
 * files the property is `undefined` (never `false`), so a strict
 * `=== false` check never matches and stdin mode was unreachable
 * (EVAL-2026-10-16 CC-1).
 */
export function isStdinPiped(stdinIsTTY: boolean | undefined): boolean {
    return stdinIsTTY !== true;
}

/**
 * Help text — mirrors the `<command>` block + parameter table of
 * docs/tools/convo-coach.md. Single source of truth for end-user usage.
 */
export function helpText(): string {
    return `convo-coach — LLM-powered conversational coach for ntakker-cli transcripts

USAGE
  convo-coach [--transcript <path>] [--last <duration>] [--since <timestamp>]
              [--provider <name>] [--model <id>] [--system-prompt <path>]
              [--debounce <duration>] [--on-overflow <strategy>]
              [--recordings-dir <dir>] [--help] [--version]

INPUT MODE (auto-detected, in priority order)
  1. stdin               When something is piped on stdin (no TTY).
  2. --transcript <path> Explicit file path to a ntakker-cli transcript sidecar.
  3. autodetect          Newest *.transcript.* file in --recordings-dir
                         (or NTAKKER_RECORDINGS_DIR, default ~/Recordings).

OPTIONS
  --transcript <path>           Path to a ntakker-cli sidecar (.jsonl, .txt,
                                .srt, .vtt). Single- or dual-channel.
  --last <duration>             Slice the transcript to only the last N
                                of conversation. Format: 30s, 5m, 1h.
  --since <timestamp>           Slice the transcript to only segments
                                after this timestamp. Accepts ISO-8601,
                                Unix epoch (seconds), or relative (e.g.
                                5m). When combined with --last, the later
                                boundary (more recent) wins.
  --provider <name>             LLM provider. One of:
                                  ${PROVIDER_NAMES.join(', ')}
                                Overrides COACH_PROVIDER. Defaults to
                                azure-openai when neither is set
                                (Project Memory Exception 003).
  --model <id>                  Model identifier for the selected
                                provider. Overrides COACH_MODEL.
  --system-prompt <path>        Path to a markdown file used as the LLM
                                system message. Overrides
                                COACH_SYSTEM_PROMPT_PATH.
  --debounce <duration>         Stdin-mode debounce window. Default 15s.
                                Overrides COACH_DEBOUNCE.
  --on-overflow <strategy>      Token-budget overflow strategy. One of:
                                  ${OVERFLOW_STRATEGIES.join(', ')}
                                Overrides COACH_ON_OVERFLOW.
  --recordings-dir <dir>        Folder scanned in autodetect mode.
                                Overrides NTAKKER_RECORDINGS_DIR.
  -h, --help                    Print this help text and exit.
  -V, --version                 Print the version and exit.

ENVIRONMENT
  Configuration is resolved through four tiers (lowest → highest):
    1. shell environment
    2. ~/.tool-agents/convo-coach/.env
    3. <cwd>/.env
    4. CLI flags

  See docs/tools/convo-coach.md for the full env-var reference,
  per-provider credential requirements, and worked examples.

EXIT CODES
  0   success
  1   unexpected error
  64  bad usage / invalid CLI argument
  66  no transcript input available
  70  LLM provider failure
  78  missing required configuration
`;
}
