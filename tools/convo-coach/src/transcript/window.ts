// src/transcript/window.ts — record windowing for --last / --since.
//
// Owned by U4 (plan-011 Phase 6b). Pure functions; zero I/O.
//
// Implements FR-CC-5 / AC-CC-5: "later boundary wins" when both `--last` and
// `--since` are supplied. The cut-off is computed against `transcriptEnd`,
// which is "now" for stdin mode and the timestamp of the latest record (or
// file mtime, for empty files) in finite-file mode.

import { WindowError, type NormalisedRecord, type WindowFilter } from '../types.js';
import { parseDuration } from './duration.js';

/**
 * Filter `records` so only those whose `timestamp >= cutOff` remain.
 *
 * Cut-off rules:
 *   * both `last` and `since`: cutOff = MAX(transcriptEnd - last.ms, since)
 *   * only `last`:             cutOff = transcriptEnd - last.ms
 *   * only `since`:            cutOff = since
 *   * neither:                 returns records unchanged
 *
 * `since` is validated against `transcriptEnd`; a `since` strictly later than
 * `transcriptEnd` raises `WindowError` because there is no possible record to
 * keep.
 *
 * Pure function — does not mutate `records`. Returns a new array (or the
 * same reference when no filter is active).
 */
export function applyWindow(
    records: readonly NormalisedRecord[],
    filter: WindowFilter,
    transcriptEnd: Date,
): NormalisedRecord[] {
    const hasLast = filter.last !== undefined;
    const hasSince = filter.since !== undefined;

    if (!hasLast && !hasSince) {
        return records.slice();
    }

    const endMs = transcriptEnd.getTime();
    let cutOffMs = Number.NEGATIVE_INFINITY;

    if (hasSince) {
        const sinceMs = (filter.since as Date).getTime();
        if (sinceMs > endMs) {
            throw new WindowError(
                `--since (${(filter.since as Date).toISOString()}) is after the end of the transcript (${transcriptEnd.toISOString()}); no records would match.`,
            );
        }
        cutOffMs = sinceMs;
    }

    if (hasLast) {
        const last = filter.last as { value: number; unitMs: number };
        const lastMs = last.value * last.unitMs;
        const lastCutOff = endMs - lastMs;
        // "Later boundary wins" when both are set.
        cutOffMs = Math.max(cutOffMs, lastCutOff);
    }

    return records.filter((r) => r.timestamp.getTime() >= cutOffMs);
}

/**
 * Parse the raw `--since` CLI argument into a concrete `Date`.
 *
 * Accepts:
 *   * ISO-8601 — `2026-05-02T14:32:10`, `2026-05-02T14:32:10.123Z`, …
 *     (anything `Date.parse` understands, basically).
 *   * Unix epoch seconds — bare integers like `1714657930`. Numbers that look
 *     like milliseconds (i.e. >= 10^12, year 2001+ in ms) are interpreted as
 *     milliseconds; otherwise as seconds. The boundary is 1e12: if you pass a
 *     value >= 1e12 we treat it as ms (this catches the unambiguous ms case
 *     while keeping current-era seconds in the seconds branch).
 *   * Relative duration — `5m`, `1h`, `30s` (parsed via `parseDuration`).
 *     Interpreted as "X ago from `transcriptEnd`".
 *
 * Throws `WindowError` (BAD_USAGE) on inputs that match none of the above.
 */
export function parseSinceArg(input: string, transcriptEnd: Date): Date {
    if (typeof input !== 'string' || input.length === 0) {
        throw new WindowError(
            `--since: expected non-empty string, got ${typeof input === 'string' ? `''` : typeof input}.`,
        );
    }

    // 1. Relative duration first — cheap regex-pre-check matches `parseDuration`.
    if (/^\d+(s|m|h)$/.test(input)) {
        const parsed = parseDuration(input);
        return new Date(transcriptEnd.getTime() - parsed.ms);
    }

    // 2. Bare integer → epoch seconds (or ms when obviously ms-sized).
    if (/^\d+$/.test(input)) {
        const n = Number.parseInt(input, 10);
        if (!Number.isFinite(n)) {
            throw new WindowError(
                `--since: '${input}' is not a finite epoch value.`,
            );
        }
        const ms = n >= 1_000_000_000_000 ? n : n * 1000;
        return new Date(ms);
    }

    // 3. ISO-8601 (or anything else Date.parse understands).
    const ms = Date.parse(input);
    if (Number.isNaN(ms)) {
        throw new WindowError(
            `--since: '${input}' is not a recognised timestamp. Accepted formats: ISO-8601 (e.g. '2026-05-02T14:32:10'), Unix epoch seconds (e.g. '1714657930'), or a relative duration (e.g. '5m', '1h', '30s').`,
        );
    }
    return new Date(ms);
}
