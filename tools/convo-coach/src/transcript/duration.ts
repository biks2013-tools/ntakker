// src/transcript/duration.ts — duration parsing for --last and friends.
//
// Owned by U4 (plan-011 Phase 6b). Pure functions; zero I/O.
//
// Accepted input: `30s`, `5m`, `1h`. The strict regex `^(\d+)(s|m|h)$` rejects
// everything else (compound forms, decimals, negative values, whitespace,
// units other than s/m/h) with a `WindowError` whose message includes the
// offending input and the accepted shapes.
//
// `formatDuration(ms)` is the inverse used by sidecar metadata writers
// (`SidecarFrontMatter.window.last`); it picks the largest unit that yields
// an integer to keep the metadata human-readable.

import { WindowError } from '../types.js';

/** Result of parsing a duration string. */
export interface ParsedDuration {
    /** Numeric component (e.g. `5` from `5m`). */
    readonly value: number;
    /** Milliseconds-per-unit (e.g. `60_000` for `m`). */
    readonly unitMs: number;
    /** Total milliseconds — equals `value * unitMs`. */
    readonly ms: number;
}

const DURATION_REGEX = /^(\d+)(s|m|h)$/;

const UNIT_MS: Readonly<Record<'s' | 'm' | 'h', number>> = Object.freeze({
    s: 1_000,
    m: 60_000,
    h: 3_600_000,
});

const ACCEPTED_FORMATS = '`30s`, `5m`, `1h` (positive integer + unit s|m|h)';

/**
 * Parse a duration like `30s`, `5m`, `1h`. Returns `{ value, unitMs, ms }`.
 *
 * Throws `WindowError` (BAD_USAGE) on any input that does not match the strict
 * regex — including compound forms (`1h30m`), decimals (`1.5m`), negatives,
 * whitespace, or unknown units. The error message echoes the offending input
 * and the list of accepted formats.
 */
export function parseDuration(input: string): ParsedDuration {
    if (typeof input !== 'string') {
        throw new WindowError(
            `invalid duration: expected string, got ${typeof input}. Accepted formats: ${ACCEPTED_FORMATS}.`,
        );
    }
    const match = DURATION_REGEX.exec(input);
    if (match === null) {
        throw new WindowError(
            `invalid duration '${input}'. Accepted formats: ${ACCEPTED_FORMATS}.`,
        );
    }
    const valueStr = match[1] as string;
    const unit = match[2] as 's' | 'm' | 'h';
    const value = Number.parseInt(valueStr, 10);
    if (!Number.isFinite(value) || value < 0) {
        throw new WindowError(
            `invalid duration '${input}': numeric component out of range. Accepted formats: ${ACCEPTED_FORMATS}.`,
        );
    }
    const unitMs = UNIT_MS[unit];
    return {
        value,
        unitMs,
        ms: value * unitMs,
    };
}

/**
 * Format a millisecond count back to a duration string. Picks the largest
 * unit (h > m > s) for which the value divides evenly; falls back to seconds
 * (rounded) for non-integer second counts. Used by the sidecar writer to
 * round-trip `--last` into front-matter.
 *
 * Examples:
 *   formatDuration(30_000)      === '30s'
 *   formatDuration(300_000)     === '5m'
 *   formatDuration(3_600_000)   === '1h'
 *   formatDuration(90_000)      === '90s'   // doesn't divide into minutes
 */
export function formatDuration(ms: number): string {
    if (!Number.isFinite(ms) || ms < 0) {
        throw new WindowError(
            `cannot format duration: value must be a non-negative finite number (got ${ms}).`,
        );
    }
    const intMs = Math.round(ms);
    if (intMs % UNIT_MS.h === 0) {
        return `${intMs / UNIT_MS.h}h`;
    }
    if (intMs % UNIT_MS.m === 0) {
        return `${intMs / UNIT_MS.m}m`;
    }
    // Always representable as seconds (rounded to nearest 1s).
    return `${Math.round(intMs / UNIT_MS.s)}s`;
}
