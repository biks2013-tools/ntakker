// src/prompt/build.ts — assembles the system + user message pair sent to
// the LLM. Pure functions where possible; only `loadSystemPrompt` does I/O.
//
// See §CC-DSGN-6 of docs/design/project-design.md for the signature, and
// §CC-DSGN-12 CC-ADR-8 for the rationale behind the bundled default prompt.

import { readFileSync, statSync } from 'node:fs';
import {
    type BuildPromptOptions,
    type BuiltPrompt,
    type NormalisedRecord,
    type WindowFilter,
    TranscriptError,
    UsageError,
} from '../types.js';
import { DEFAULT_SYSTEM_PROMPT } from './default-system-prompt.js';

// ---------------------------------------------------------------------------
// loadSystemPrompt
// ---------------------------------------------------------------------------

/**
 * Resolve the system prompt to use. If `systemPromptPath` is provided, read
 * the file synchronously and return its contents (UTF-8). Otherwise return
 * the bundled DEFAULT_SYSTEM_PROMPT.
 *
 * Throws `UsageError` (exit 64 — bad usage) if the path was provided but
 * does not exist or is not readable, since the user supplied an invalid
 * path on the CLI / env-var.
 */
export function loadSystemPrompt(systemPromptPath: string | undefined): string {
    if (systemPromptPath === undefined || systemPromptPath === '') {
        return DEFAULT_SYSTEM_PROMPT;
    }
    try {
        const stat = statSync(systemPromptPath);
        if (!stat.isFile()) {
            throw new UsageError(
                `--system-prompt path is not a regular file: ${systemPromptPath}`,
            );
        }
        return readFileSync(systemPromptPath, 'utf8');
    } catch (err) {
        if (err instanceof UsageError) {
            throw err;
        }
        const reason = err instanceof Error ? err.message : String(err);
        throw new UsageError(
            `Could not read --system-prompt file at ${systemPromptPath}: ${reason}`,
        );
    }
}

// ---------------------------------------------------------------------------
// buildPrompt
// ---------------------------------------------------------------------------

/**
 * Render a `WindowFilter` as the human-readable string used in the
 * `Window:` metadata line. Returns "full transcript" when neither bound
 * is set (or when `window` is undefined).
 */
function renderWindow(window: WindowFilter | undefined): string {
    if (window === undefined) {
        return 'full transcript';
    }
    const parts: string[] = [];
    if (window.last !== undefined) {
        parts.push(`last ${renderLast(window.last.value, window.last.unitMs)}`);
    }
    if (window.since !== undefined) {
        parts.push(`since ${formatTimestamp(window.since)}`);
    }
    if (parts.length === 0) {
        return 'full transcript';
    }
    return parts.join(' AND ');
}

/** Render the `last` window component as e.g. "5m", "30s", "2h", "1d". */
function renderLast(value: number, unitMs: number): string {
    const SECOND = 1000;
    const MINUTE = 60 * SECOND;
    const HOUR = 60 * MINUTE;
    const DAY = 24 * HOUR;
    if (unitMs === DAY) return `${value}d`;
    if (unitMs === HOUR) return `${value}h`;
    if (unitMs === MINUTE) return `${value}m`;
    if (unitMs === SECOND) return `${value}s`;
    // Fallback: render the total duration in seconds.
    const totalSeconds = Math.round((value * unitMs) / SECOND);
    return `${totalSeconds}s`;
}

/** Format a Date as `HH:MM:SS` in local time, zero-padded. */
function formatTimestamp(date: Date): string {
    const hh = String(date.getHours()).padStart(2, '0');
    const mm = String(date.getMinutes()).padStart(2, '0');
    const ss = String(date.getSeconds()).padStart(2, '0');
    return `${hh}:${mm}:${ss}`;
}

/**
 * Format a single transcript record as one line of the `[Transcript]`
 * block: `[HH:MM:SS] [<channel>](<lang>): <text>` — the channel and
 * language tags are only emitted when present.
 */
function formatRecord(record: NormalisedRecord): string {
    const ts = `[${formatTimestamp(record.timestamp)}]`;
    const channel = record.channel !== undefined ? ` [${record.channel}]` : '';
    const lang = record.language !== undefined ? ` (${record.language})` : '';
    return `${ts}${channel}${lang}: ${record.text}`;
}

/**
 * Assemble the final `BuiltPrompt` (system + user + estimated token count)
 * from the supplied options. Records are emitted in the order received —
 * the slicer (U4) is responsible for chronological ordering.
 *
 * Throws `TranscriptError` (exit 66 — no input) when `records` is empty,
 * since we have nothing to coach the user about.
 */
export function buildPrompt(opts: BuildPromptOptions): BuiltPrompt {
    if (opts.records.length === 0) {
        throw new TranscriptError(
            'No transcript records to build prompt from (window may have excluded everything; check --last/--since).',
        );
    }

    const sourceLine = opts.transcriptPath ?? 'stdin';
    const windowLine = renderWindow(opts.window);
    const transcriptBlock = opts.records.map(formatRecord).join('\n');

    const user = [
        'Below is the recent conversation transcript. Please provide live coaching advice.',
        '',
        '[Transcript metadata]',
        `Source: ${sourceLine}`,
        `Window: ${windowLine}`,
        `Records: ${opts.records.length}`,
        '',
        '[Transcript]',
        transcriptBlock,
        '',
        '[Coaching request]',
        'Advise me on what I could ask, suggest, request, or answer right now.',
    ].join('\n');

    // rough estimate; U9 budget.ts refines this with model-aware tokenization
    const estimatedTokens = Math.ceil((opts.systemPrompt.length + user.length) / 4);

    return {
        system: opts.systemPrompt,
        user,
        estimatedTokens,
    };
}
