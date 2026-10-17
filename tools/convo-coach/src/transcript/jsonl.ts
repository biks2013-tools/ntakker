// src/transcript/jsonl.ts — ntakker-cli sidecar JSONL parser + plain-text parser.
//
// Owned by U4 (plan-011 Phase 6b). Pure functions; zero I/O.
//
// The ntakker-cli wire schema (see docs/tools/ntakker-cli.md and CC-DSGN-7) is one JSON
// object per line. Required field is `text`. Timestamp comes preferentially
// from `ts` (epoch ms), falling back to `t` then `timestamp` (ISO-8601 string).
// Channel/language/final/speaker are all optional. ntakker writes
// `source: "mic" | "system" | "mixed"` instead of `channel`; `mic` maps to
// channel A (the user) and `system` to channel B (the remote side), the
// convention the default system prompt uses (EVAL-2026-10-16 CC-2).
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
//   * ntakker rewrites a segment by `id` as it grows: in place when the new
//     line fits, otherwise as a tombstone plus an appended line. When the
//     same `id` appears more than once the LATER line wins
//     (EVAL-2026-10-16 CC-3) — e.g. a `tail -f` stream that already
//     delivered the old version and then sees the appended one. A `tail -f`
//     stream cannot see in-place rewrites at all; read the file
//     (`--transcript`) for an exact transcript.

import { TranscriptError, type NormalisedRecord } from '../types.js';

/**
 * Incremental JSONL parser: feed lines one at a time with `push`, read the
 * current records with `records()`. `parseJsonl` uses it for whole files;
 * stdin mode keeps one for the whole session so every trigger costs only
 * the lines that arrived since the last one (EVAL-2026-06-12 B1). Each
 * malformed line is warned about once, when it arrives.
 */
export class JsonlAccumulator {
    private readonly list: NormalisedRecord[] = [];
    private readonly indexById = new Map<string, number>();
    private lineNumber = 0;
    private sorted = true;
    private readonly counts = { considered: 0, malformed: 0, tombstones: 0 };

    /** Lines seen that were neither blank nor comments. */
    get considered(): number { return this.counts.considered; }
    get malformed(): number { return this.counts.malformed; }
    get tombstones(): number { return this.counts.tombstones; }
    /** Records currently held (after id de-duplication). */
    get size(): number { return this.list.length; }

    /** Parse one line (without its newline) into the accumulator. */
    push(raw: string): void {
        this.lineNumber += 1;
        const lineNo = this.lineNumber;
        const trimmed = raw.trim();
        if (trimmed.length === 0) return;
        if (trimmed.startsWith('#')) return;
        this.counts.considered += 1;

        let obj: unknown;
        try {
            obj = JSON.parse(trimmed);
        } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            console.warn(
                `[convo-coach/jsonl] line ${lineNo}: malformed JSON, skipped (${msg})`,
            );
            this.counts.malformed += 1;
            return;
        }

        if (!isPlainObject(obj)) {
            console.warn(
                `[convo-coach/jsonl] line ${lineNo}: expected JSON object, skipped`,
            );
            this.counts.malformed += 1;
            return;
        }

        // Tombstone marker per CC-DSGN-7.
        if (obj['_tombstone'] === true) {
            this.counts.tombstones += 1;
            return;
        }

        const text = obj['text'];
        if (typeof text !== 'string') {
            console.warn(
                `[convo-coach/jsonl] line ${lineNo}: missing/non-string 'text', skipped`,
            );
            this.counts.malformed += 1;
            return;
        }
        if (text.trim().length === 0) {
            // Tombstone-by-empty-text per task spec.
            this.counts.tombstones += 1;
            return;
        }

        const timestamp = extractTimestamp(obj);
        if (timestamp === null) {
            console.warn(
                `[convo-coach/jsonl] line ${lineNo}: no parseable timestamp (ts/t/timestamp), skipped`,
            );
            this.counts.malformed += 1;
            return;
        }

        const channel = extractChannel(obj['channel']) ?? channelFromSource(obj['source']);
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
        const id = typeof obj['id'] === 'string' ? (obj['id'] as string) : undefined;
        const existing = id !== undefined ? this.indexById.get(id) : undefined;
        if (existing !== undefined) {
            this.list[existing] = rec;
            this.sorted = false;
        } else {
            const last = this.list[this.list.length - 1];
            if (last !== undefined && last.timestamp.getTime() > timestamp.getTime()) {
                this.sorted = false;
            }
            if (id !== undefined) this.indexById.set(id, this.list.length);
            this.list.push(rec);
        }
    }

    /**
     * The records so far, sorted by ascending timestamp, as a fresh array.
     * Record objects are shared between calls (immutable), which lets the
     * token budget cache their counts.
     */
    records(): NormalisedRecord[] {
        if (!this.sorted) {
            // Sort in place once and rebuild the id index to match.
            const ids = new Map<NormalisedRecord, string>();
            for (const [id, i] of this.indexById) {
                const r = this.list[i];
                if (r !== undefined) ids.set(r, id);
            }
            this.list.sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
            this.indexById.clear();
            this.list.forEach((r, i) => {
                const id = ids.get(r);
                if (id !== undefined) this.indexById.set(id, i);
            });
            this.sorted = true;
        }
        return [...this.list];
    }
}

/**
 * Parse a ntakker-cli sidecar JSONL payload (the entire file content as a string).
 *
 * Returns the parsed records sorted by ascending `timestamp`. Tombstones and
 * comments are excluded. Malformed individual lines are warned-about and
 * skipped. Throws `TranscriptError` if every non-comment, non-blank line is
 * unparseable (no usable records produced from a non-empty payload).
 */
export function parseJsonl(content: string): NormalisedRecord[] {
    const acc = new JsonlAccumulator();
    for (const line of content.split(/\r?\n/)) acc.push(line);

    if (acc.considered > 0 && acc.size === 0) {
        throw new TranscriptError(
            `transcript JSONL: every line failed to parse (considered=${acc.considered}, malformed=${acc.malformed}, tombstones=${acc.tombstones}). Verify the file is a ntakker-cli sidecar (.jsonl).`,
        );
    }

    if (acc.malformed > 0) {
        console.warn(
            `[convo-coach/jsonl] parse summary: ${acc.malformed} malformed line(s) skipped, ${acc.size} record(s) kept.`,
        );
    }

    return acc.records();
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

/**
 * Map ntakker's `source` field to a channel: the microphone is the user
 * (A), system audio is the remote side (B). `mixed` (and anything else)
 * carries no channel.
 */
export function channelFromSource(v: unknown): 'A' | 'B' | undefined {
    if (v === 'mic' || v === 'microphone') return 'A';
    if (v === 'system') return 'B';
    return undefined;
}
