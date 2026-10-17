// src/transcript/stdin.ts — line-by-line stdin reader with /dev/tty Enter
// trigger and a debounce-on-silence fallback.
//
// Owned by U5 (plan-011 Phase 6c). Implements CC-ADR-7:
//   * Default trigger: hit Enter on `/dev/tty`. This works for `tail -f`
//     pipelines that never close stdin.
//   * Fallback: when `/dev/tty` is unavailable (ENXIO/ENOENT — detached
//     shell, container, nohup), arm a debounce timer that fires after
//     `debounceMs` of stdin silence.
//   * EOF always emits one final yield with whatever is buffered.
//
// The generator keeps the conversation between yields, so each yield
// contains the full history. Callers (the orchestrator) apply the windowing
// layer to slice down to the requested time range.
//
// EVAL-2026-06-12 B1 (plan-023 T5): lines are parsed once, as they arrive,
// into a `StdinTranscript`. Before, every trigger re-split and re-parsed
// the whole accumulated buffer (O(n²) over a session) and re-warned about
// every malformed line each time.
//
// Defensive: every resource (timer, readline interface, /dev/tty fd) is
// disposed inside a `try/finally` if the generator is closed early.

import * as fs from 'node:fs';
import * as readline from 'node:readline';

import { JsonlAccumulator, parsePlainText } from './jsonl.js';
import type { NormalisedRecord } from '../types.js';

export interface StdinDriverOptions {
    readonly debounceMs: number;
}

export type TriggerReason = 'tty-enter' | 'debounce' | 'eof';

export interface StdinTrigger {
    readonly records: NormalisedRecord[];
    readonly transcriptEnd: Date;
    readonly reason: TriggerReason;
}

/**
 * The stdin conversation so far, built one line at a time.
 *
 * The format is decided by the first non-blank, non-comment line: a JSON
 * object means JSONL, anything else plain text. JSONL lines go through a
 * `JsonlAccumulator`. Until the first JSONL record parses, the raw lines
 * are kept too, so a stream whose every line fails as JSONL still degrades
 * to plain text (the old whole-buffer behaviour) instead of yielding
 * nothing.
 */
export class StdinTranscript {
    private format: 'unknown' | 'jsonl' | 'text' = 'unknown';
    private readonly jsonl = new JsonlAccumulator();
    private pendingRaw: string[] | undefined = [];
    private readonly textLines: string[] = [];

    push(line: string): void {
        if (this.format === 'unknown') {
            const trimmed = line.trim();
            if (trimmed.length > 0 && !trimmed.startsWith('#')) {
                this.format = looksLikeJsonObject(trimmed) ? 'jsonl' : 'text';
            }
        }
        if (this.format === 'text') {
            const trimmed = line.trim();
            if (trimmed.length > 0) this.textLines.push(trimmed);
            return;
        }
        this.jsonl.push(line);
        if (this.pendingRaw !== undefined) {
            if (this.jsonl.size > 0) {
                this.pendingRaw = undefined;
            } else {
                this.pendingRaw.push(line);
            }
        }
    }

    /** Records at trigger time `now`. Plain-text records all carry `now`. */
    records(now: Date): NormalisedRecord[] {
        if (this.format === 'text') {
            return this.textLines.map((text) => ({ timestamp: now, text }));
        }
        if (this.jsonl.size === 0 && this.pendingRaw !== undefined && this.jsonl.considered > 0) {
            // Every line so far failed as JSONL — degrade to plain text
            // rather than aborting the long-lived loop.
            return parsePlainText(this.pendingRaw.join('\n'), now);
        }
        return this.jsonl.records();
    }
}

/** Whether `line` (trimmed, non-empty) parses as a JSON object. */
function looksLikeJsonObject(line: string): boolean {
    if (!line.startsWith('{')) return false;
    try {
        const parsed = JSON.parse(line);
        return typeof parsed === 'object' && parsed !== null;
    } catch {
        return false;
    }
}

/**
 * Async generator yielding one trigger event per coaching request. Each
 * event carries a snapshot of the parsed records seen so far plus a
 * `reason` flag describing what fired the trigger.
 *
 * Lifecycle:
 *   * Generator iteration starts → wire up stdin readline + try /dev/tty.
 *   * Each accumulated stdin line refreshes the debounce timer (when
 *     /dev/tty is not in use).
 *   * Each Enter on /dev/tty (or each debounce fire) resolves the
 *     "next-trigger" promise.
 *   * Stdin EOF resolves the promise with `eof` and ends the loop.
 *   * Generator close (caller `break`s out of the for-await) tears down
 *     readline, the /dev/tty fd, and any pending timer.
 */
export async function* readFromStdin(
    opts: StdinDriverOptions,
): AsyncGenerator<StdinTrigger> {
    const debounceMs = opts.debounceMs;

    const transcript = new StdinTranscript();
    let resolveNext: ((value: TriggerReason | null) => void) | undefined;
    let pendingValue: TriggerReason | null | undefined;
    let debounceTimer: NodeJS.Timeout | undefined;

    const fireTrigger = (reason: TriggerReason): void => {
        if (resolveNext !== undefined) {
            const r = resolveNext;
            resolveNext = undefined;
            r(reason);
        } else {
            pendingValue = reason;
        }
    };

    const fireEof = (): void => {
        if (resolveNext !== undefined) {
            const r = resolveNext;
            resolveNext = undefined;
            r(null);
        } else {
            pendingValue = null;
        }
    };

    const armDebounce = (): void => {
        if (debounceMs <= 0) return;
        if (debounceTimer !== undefined) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
            debounceTimer = undefined;
            fireTrigger('debounce');
        }, debounceMs);
    };

    // ---- Main stdin reader (always active) ----------------------------
    const stdinRl = readline.createInterface({ input: process.stdin });
    let useTtyTrigger = false;
    let ttyFd: number | undefined;
    let ttyRl: readline.Interface | undefined;

    stdinRl.on('line', (line: string) => {
        transcript.push(line);
        if (!useTtyTrigger) {
            armDebounce();
        }
    });
    stdinRl.on('close', () => {
        fireEof();
    });

    // ---- Optional /dev/tty Enter trigger -------------------------------
    try {
        ttyFd = fs.openSync('/dev/tty', 'r');
        const ttyStream = fs.createReadStream('', { fd: ttyFd, autoClose: false });
        ttyRl = readline.createInterface({ input: ttyStream });
        useTtyTrigger = true;
        ttyRl.on('line', () => {
            fireTrigger('tty-enter');
        });
        ttyRl.on('error', () => {
            // /dev/tty died mid-flight (e.g. terminal closed). Fall back
            // to debounce for the remainder of the session.
            useTtyTrigger = false;
        });
    } catch {
        // ENXIO / ENOENT — /dev/tty unavailable. Stay in debounce mode.
        useTtyTrigger = false;
        ttyFd = undefined;
        ttyRl = undefined;
    }

    const cleanup = (): void => {
        if (debounceTimer !== undefined) {
            clearTimeout(debounceTimer);
            debounceTimer = undefined;
        }
        try {
            stdinRl.close();
        } catch {
            /* noop */
        }
        if (ttyRl !== undefined) {
            try { ttyRl.close(); } catch { /* noop */ }
            ttyRl = undefined;
        }
        if (ttyFd !== undefined) {
            try { fs.closeSync(ttyFd); } catch { /* noop */ }
            ttyFd = undefined;
        }
    };

    try {
        while (true) {
            // Wait for either a trigger or EOF.
            const reason: TriggerReason | null = await new Promise<TriggerReason | null>((resolve) => {
                if (pendingValue !== undefined) {
                    const v = pendingValue;
                    pendingValue = undefined;
                    resolve(v);
                    return;
                }
                resolveNext = resolve;
            });

            if (reason === null) {
                // EOF: emit one last batch with whatever is buffered.
                const now = new Date();
                const records = transcript.records(now);
                yield { records, transcriptEnd: now, reason: 'eof' };
                return;
            }

            const now = new Date();
            const records = transcript.records(now);
            yield { records, transcriptEnd: now, reason };
            // The transcript is intentionally NOT reset — each yield
            // contains the accumulated history; the orchestrator's window
            // slicer trims it down to the requested range.
        }
    } finally {
        cleanup();
    }
}
