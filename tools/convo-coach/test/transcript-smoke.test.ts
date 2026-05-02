// test/transcript-smoke.test.ts — smoke coverage for the U4 transcript stack.
//
// Run with:  npx tsx --test test/transcript-smoke.test.ts
//
// Asserts:
//   * `readTranscriptFile` ingests a 5-record JSONL (with one malformed line
//     in the middle), returns 5 records sorted ascending by timestamp.
//   * `applyWindow` with `last: 5m` against a 10-minute span keeps only the
//     latter half.
//   * `applyWindow` with a future `since` raises `WindowError`.
//   * `parseDuration('30s').ms === 30_000`.
//   * `parseDuration('not-a-duration')` throws `WindowError`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { parseDuration } from '../src/transcript/duration.js';
import { applyWindow } from '../src/transcript/window.js';
import { readTranscriptFile } from '../src/transcript/reader.js';
import { WindowError } from '../src/types.js';

function makeTempDir(prefix: string): string {
    return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

test('parseDuration: 30s → 30_000 ms', () => {
    const d = parseDuration('30s');
    assert.equal(d.ms, 30_000);
    assert.equal(d.value, 30);
    assert.equal(d.unitMs, 1_000);
});

test('parseDuration: bad input throws WindowError', () => {
    assert.throws(
        () => parseDuration('not-a-duration'),
        (err: unknown) => err instanceof WindowError && /not-a-duration/.test((err as Error).message),
    );
    assert.throws(
        () => parseDuration('1h30m'),
        (err: unknown) => err instanceof WindowError,
    );
    assert.throws(
        () => parseDuration(''),
        (err: unknown) => err instanceof WindowError,
    );
});

test('readTranscriptFile + applyWindow: 5 sorted records, last 5m keeps the tail', () => {
    const dir = makeTempDir('convo-coach-u4-');
    const file = path.join(dir, 'sample.transcript.jsonl');

    // Span 10 minutes. 5 records at t=0,2,4,6,8 minutes after epoch-anchor.
    const anchor = Date.UTC(2026, 4, 2, 12, 0, 0); // 2026-05-02T12:00:00Z
    const recs = [
        { ts: anchor + 0 * 60_000, text: 'r0', channel: 'A' },
        // Order is intentionally shuffled to verify sorting.
        { ts: anchor + 4 * 60_000, text: 'r2', channel: 'B' },
        { ts: anchor + 2 * 60_000, text: 'r1', channel: 'A' },
        { ts: anchor + 8 * 60_000, text: 'r4', channel: 'B' },
        { ts: anchor + 6 * 60_000, text: 'r3', channel: 'A' },
    ];

    const lines: string[] = [];
    lines.push('# comment line — should be ignored');
    lines.push(JSON.stringify(recs[0]));
    lines.push(JSON.stringify(recs[1]));
    lines.push('this is not json {{{');             // malformed; warns + skips
    lines.push(JSON.stringify(recs[2]));
    lines.push(JSON.stringify(recs[3]));
    lines.push(JSON.stringify(recs[4]));
    lines.push('');                                  // blank line tolerated
    fs.writeFileSync(file, lines.join('\n'), 'utf8');

    const { records, transcriptEnd } = readTranscriptFile(file);

    // 5 records survive (malformed + comment + blank are skipped).
    assert.equal(records.length, 5, 'expected 5 records after parse');

    // Sorted ascending by timestamp.
    for (let i = 1; i < records.length; i += 1) {
        assert.ok(
            records[i]!.timestamp.getTime() >= records[i - 1]!.timestamp.getTime(),
            `records not sorted at index ${i}`,
        );
    }
    assert.equal(records[0]!.text, 'r0');
    assert.equal(records[4]!.text, 'r4');

    // transcriptEnd is the latest record's timestamp.
    assert.equal(transcriptEnd.getTime(), anchor + 8 * 60_000);

    // applyWindow last=5m → cut-off at (anchor + 8m) - 5m = anchor + 3m.
    // → keeps records at t=4m, 6m, 8m → r2, r3, r4 (in chronological order).
    const last5m = parseDuration('5m');
    const kept = applyWindow(
        records,
        { last: { value: last5m.value, unitMs: last5m.unitMs } },
        transcriptEnd,
    );
    assert.equal(kept.length, 3, 'expected last-5m to keep 3 records');
    assert.deepEqual(kept.map((r) => r.text), ['r2', 'r3', 'r4']);

    // applyWindow with future `since` → WindowError.
    const future = new Date(transcriptEnd.getTime() + 60_000);
    assert.throws(
        () => applyWindow(records, { since: future }, transcriptEnd),
        (err: unknown) => err instanceof WindowError && /after the end/.test((err as Error).message),
    );

    // Cleanup.
    fs.rmSync(dir, { recursive: true, force: true });
});

test('readTranscriptFile: unsupported extension → TranscriptError', async () => {
    const dir = makeTempDir('convo-coach-u4-ext-');
    const file = path.join(dir, 'whatever.bin');
    fs.writeFileSync(file, 'data', 'utf8');
    assert.throws(
        () => readTranscriptFile(file),
        (err: unknown) => err instanceof Error && /unsupported transcript extension/.test((err as Error).message),
    );
    fs.rmSync(dir, { recursive: true, force: true });
});
