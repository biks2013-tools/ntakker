// src/transcript/jsonl.ts — macrec sidecar JSONL parser + plain-text parser.
//
// Owned by U4 (plan-011 Phase 6b). Pure functions; zero I/O.
//
// The macrec wire schema (see docs/tools/macrec.md and CC-DSGN-7) is one JSON
// object per line. Required field is `text`. Timestamp comes preferentially
// from `ts` (epoch ms), falling back to `t` then `timestamp` (ISO-8601 string).
// Channel/language/final/speaker are all optional.
//
// Tolerance policy (per task spec + plan-011 §U4):
//   * Blank lines are skipped silently.
//   * Lines starting with `#` are treated as comments and skipped silently.
//   * Lines whose `text` is empty/whitespace-only are tombstones — dropped.
//   * Lines with `_tombstone === true` (per CC-DSGN-7) are dropped.
//   * Malformed JSON or records missing `text` produce a `console.warn` with
//     the 1-based line number and are skipped. We DO NOT throw on a per-line
//     basis. We throw `TranscriptError` only when 100 % of non-empty,
//     non-comment lines fail to parse — that signals a wholesale wrong format.
//   * Records are sorted by ascending timestamp before being returned;
//     callers must NOT assume the file was chronological.

import { TranscriptError, type NormalisedRecord } from '../types.js';

interface ParseStats {
    readonly considered: number;     // non-empty, non-comment lines
    readonly produced: number;       // records returned to the caller
    readonly malformed: number;      // JSON/missing-field failures
    readonly tombstones: number;     // dropped tombstones (text === '' or _tombstone)
}

/**
 * Parse a macrec sidecar JSONL payload (the entire file content as a string).
 *
 * Returns the parsed records sorted by ascending `timestamp`. Tombstones and
 * comments are excluded. Malformed individual lines are warned-about and
 * skipped. Throws `TranscriptError` if every non-comment, non-blank line is
 * unparseable (no usable records produced from a non-empty payload).
 */
export function parseJsonl(content: string): NormalisedRecord[] {
    const lines = content.split(/\r?\n/);
    const records: NormalisedRecord[] = [];
    const stats = { considered: 0, malformed: 0, tombstones: 0 };

    for (let i = 0; i < lines.length; i += 1) {
        const raw = lines[i] ?? '';
        const trimmed = raw.trim();
        if (trimmed.length === 0) continue;
        if (trimmed.startsWith('#')) continue;
        stats.considered += 1;

        let obj: unknown;
        try {
            obj = JSON.parse(trimmed);
        } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            console.warn(
                `[convo-coach/jsonl] line ${i + 1}: malformed JSON, skipped (${msg})`,
            );
            stats.malformed += 1;
            continue;
        }

        if (!isPlainObject(obj)) {
            console.warn(
                `[convo-coach/jsonl] line ${i + 1}: expected JSON object, skipped`,
            );
            stats.malformed += 1;
            continue;
        }

        // Tombstone marker per CC-DSGN-7.
        if (obj['_tombstone'] === true) {
            stats.tombstones += 1;
            continue;
        }

        const text = obj['text'];
        if (typeof text !== 'string') {
            console.warn(
                `[convo-coach/jsonl] line ${i + 1}: missing/non-string 'text', skipped`,
            );
            stats.malformed += 1;
            continue;
        }
        if (text.trim().length === 0) {
            // Tombstone-by-empty-text per task spec.
            stats.tombstones += 1;
            continue;
        }

        const timestamp = extractTimestamp(obj);
        if (timestamp === null) {
            console.warn(
                `[convo-coach/jsonl] line ${i + 1}: no parseable timestamp (ts/t/timestamp), skipped`,
            );
            stats.malformed += 1;
            continue;
        }

        const channel = extractChannel(obj['channel']);
        const language = typeof obj['lang'] === 'string'
            ? (obj['lang'] as string)
            : (typeof obj['language'] === 'string' ? (obj['language'] as string) : undefined);
        const isFinal = typeof obj['final'] === 'boolean'
            ? (obj['final'] as boolean)
            : (typeof obj['isFinal'] === 'boolean' ? (obj['isFinal'] as boolean) : undefined);
        const speaker = typeof obj['speaker'] === 'string'
            ? (obj['speaker'] as string)
            : undefined;

        const rec: NormalisedRecord = {
            timestamp,
            text,
            ...(channel !== undefined && { channel }),
            ...(language !== undefined && { language }),
            ...(isFinal !== undefined && { isFinal }),
            ...(speaker !== undefined && { speaker }),
        };
        records.push(rec);
    }

    if (stats.considered > 0 && records.length === 0) {
        throw new TranscriptError(
            `transcript JSONL: every line failed to parse (considered=${stats.considered}, malformed=${stats.malformed}, tombstones=${stats.tombstones}). Verify the file is a macrec sidecar (.jsonl).`,
        );
    }

    if (stats.malformed > 0) {
        console.warn(
            `[convo-coach/jsonl] parse summary: ${stats.malformed} malformed line(s) skipped, ${records.length} record(s) kept.`,
        );
    }

    records.sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
    return records;
}

/**
 * Parse a `.txt` transcript: each non-empty line becomes one record. No
 * channel/language assignment is attempted (txt has no schema). All records
 * inherit the same `baseTime` as their `timestamp` — the caller passes the
 * file's mtime so `applyWindow` still has something to compare against. If
 * `baseTime` is omitted, the current wall-clock is used.
 */
export function parsePlainText(content: string, baseTime?: Date): NormalisedRecord[] {
    const ts = baseTime ?? new Date();
    const lines = content.split(/\r?\n/);
    const out: NormalisedRecord[] = [];
    for (const raw of lines) {
        const trimmed = raw.trim();
        if (trimmed.length === 0) continue;
        out.push({ timestamp: ts, text: trimmed });
    }
    return out;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function isPlainObject(v: unknown): v is Record<string, unknown> {
    return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function extractTimestamp(obj: Record<string, unknown>): Date | null {
    // Preference order per task spec: `ts` (epoch ms) → `t` → `timestamp`.
    const tsRaw = obj['ts'];
    if (typeof tsRaw === 'number' && Number.isFinite(tsRaw)) {
        return new Date(tsRaw);
    }

    const candidates: readonly unknown[] = [obj['t'], obj['timestamp']];
    for (const cand of candidates) {
        if (typeof cand === 'string' && cand.length > 0) {
            const ms = Date.parse(cand);
            if (!Number.isNaN(ms)) return new Date(ms);
        }
        if (typeof cand === 'number' && Number.isFinite(cand)) {
            return new Date(cand);
        }
    }
    return null;
}

function extractChannel(v: unknown): 'A' | 'B' | undefined {
    if (v === 'A' || v === 'B') return v;
    return undefined;
}
