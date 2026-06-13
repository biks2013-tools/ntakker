// test/prompt-smoke.test.ts — smoke tests for prompt/build.ts and
// prompt/default-system-prompt.ts (U8 of plan-011).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { buildPrompt, loadSystemPrompt } from '../src/prompt/build.js';
import { DEFAULT_SYSTEM_PROMPT } from '../src/prompt/default-system-prompt.js';
import {
    type NormalisedRecord,
    type WindowFilter,
    TranscriptError,
    UsageError,
} from '../src/types.js';

const SECOND = 1000;
const MINUTE = 60 * SECOND;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeRecords(): NormalisedRecord[] {
    // Five chronological records, mix of channels A/B and absent channel.
    return [
        {
            timestamp: new Date(2026, 4, 2, 14, 30, 0),
            text: 'Hi, thanks for joining the call.',
            channel: 'A',
            language: 'en-US',
        },
        {
            timestamp: new Date(2026, 4, 2, 14, 30, 12),
            text: 'Happy to be here.',
            channel: 'B',
        },
        {
            timestamp: new Date(2026, 4, 2, 14, 30, 25),
            text: 'Let me share the agenda.',
            channel: 'A',
        },
        {
            timestamp: new Date(2026, 4, 2, 14, 31, 5),
            text: 'Sounds good — go ahead.',
            channel: 'B',
            language: 'en-US',
        },
        {
            timestamp: new Date(2026, 4, 2, 14, 32, 10),
            text: 'First topic is the migration timeline.',
        },
    ];
}

// ---------------------------------------------------------------------------
// buildPrompt: chronological order + timestamp format
// ---------------------------------------------------------------------------

test('buildPrompt formats all records chronologically with HH:MM:SS timestamps', () => {
    const records = makeRecords();
    const built = buildPrompt({
        records,
        systemPrompt: DEFAULT_SYSTEM_PROMPT,
    });

    // Each record's text appears in the user message.
    for (const r of records) {
        assert.ok(
            built.user.includes(r.text),
            `expected user message to include "${r.text}"`,
        );
    }

    // Timestamps appear in HH:MM:SS form.
    assert.ok(built.user.includes('[14:30:00]'));
    assert.ok(built.user.includes('[14:30:12]'));
    assert.ok(built.user.includes('[14:30:25]'));
    assert.ok(built.user.includes('[14:31:05]'));
    assert.ok(built.user.includes('[14:32:10]'));

    // Chronological order: each timestamp appears before the next.
    const order = ['[14:30:00]', '[14:30:12]', '[14:30:25]', '[14:31:05]', '[14:32:10]'];
    let cursor = 0;
    for (const stamp of order) {
        const idx = built.user.indexOf(stamp, cursor);
        assert.ok(idx >= 0, `missing ${stamp}`);
        cursor = idx + stamp.length;
    }

    // Channel labels rendered when present.
    assert.ok(built.user.includes('[14:30:00] [A] (en-US): Hi, thanks for joining the call.'));
    assert.ok(built.user.includes('[14:30:12] [B]: Happy to be here.'));
    // Record without channel must not have a channel tag.
    assert.ok(built.user.includes('[14:32:10]: First topic is the migration timeline.'));

    // BuiltPrompt shape sanity.
    assert.equal(built.system, DEFAULT_SYSTEM_PROMPT);
    assert.ok(built.estimatedTokens > 0);
});

// ---------------------------------------------------------------------------
// buildPrompt: transcriptPath set vs unset → metadata Source line
// ---------------------------------------------------------------------------

test('buildPrompt metadata Source line reflects transcriptPath presence', () => {
    const records = makeRecords();

    const withPath = buildPrompt({
        records,
        systemPrompt: 'sys',
        transcriptPath: '/tmp/foo.jsonl',
    });
    assert.ok(withPath.user.includes('Source: /tmp/foo.jsonl'));

    const withoutPath = buildPrompt({
        records,
        systemPrompt: 'sys',
    });
    assert.ok(withoutPath.user.includes('Source: stdin'));
});

// ---------------------------------------------------------------------------
// buildPrompt: window rendering
// ---------------------------------------------------------------------------

test('buildPrompt renders Window line for each window combination', () => {
    const records = makeRecords();

    // (a) last only
    const lastOnly: WindowFilter = { last: { value: 5, unitMs: MINUTE } };
    const builtLast = buildPrompt({
        records,
        systemPrompt: 'sys',
        window: lastOnly,
    });
    assert.ok(
        builtLast.user.includes('Window: last 5m'),
        `expected "Window: last 5m" in:\n${builtLast.user}`,
    );

    // (b) since only
    const sinceDate = new Date(2026, 4, 2, 14, 32, 10);
    const sinceOnly: WindowFilter = { since: sinceDate };
    const builtSince = buildPrompt({
        records,
        systemPrompt: 'sys',
        window: sinceOnly,
    });
    assert.ok(
        builtSince.user.includes('Window: since 14:32:10'),
        `expected "Window: since 14:32:10" in:\n${builtSince.user}`,
    );

    // (c) both
    const both: WindowFilter = {
        last: { value: 5, unitMs: MINUTE },
        since: sinceDate,
    };
    const builtBoth = buildPrompt({
        records,
        systemPrompt: 'sys',
        window: both,
    });
    assert.ok(
        builtBoth.user.includes('Window: last 5m AND since 14:32:10'),
        `expected combined window line in:\n${builtBoth.user}`,
    );

    // (d) neither (window omitted entirely)
    const builtNone = buildPrompt({
        records,
        systemPrompt: 'sys',
    });
    assert.ok(
        builtNone.user.includes('Window: full transcript'),
        `expected "Window: full transcript" in:\n${builtNone.user}`,
    );

    // (e) explicit empty WindowFilter object also collapses to "full transcript"
    const builtEmpty = buildPrompt({
        records,
        systemPrompt: 'sys',
        window: {},
    });
    assert.ok(builtEmpty.user.includes('Window: full transcript'));
});

// ---------------------------------------------------------------------------
// buildPrompt: empty records throws TranscriptError
// ---------------------------------------------------------------------------

test('buildPrompt throws TranscriptError when records is empty', () => {
    assert.throws(
        () => buildPrompt({ records: [], systemPrompt: 'sys' }),
        (err: unknown) => {
            assert.ok(err instanceof TranscriptError);
            assert.match((err as Error).message, /No transcript records/);
            return true;
        },
    );
});

// ---------------------------------------------------------------------------
// loadSystemPrompt
// ---------------------------------------------------------------------------

test('loadSystemPrompt(undefined) returns the bundled default prompt', () => {
    assert.equal(loadSystemPrompt(undefined), DEFAULT_SYSTEM_PROMPT);
});

test('loadSystemPrompt with nonexistent path throws a helpful UsageError', () => {
    assert.throws(
        () => loadSystemPrompt('/nonexistent/definitely-not-here-zzz.md'),
        (err: unknown) => {
            assert.ok(err instanceof UsageError);
            assert.match(
                (err as Error).message,
                /Could not read --system-prompt file/,
            );
            assert.match(
                (err as Error).message,
                /\/nonexistent\/definitely-not-here-zzz\.md/,
            );
            return true;
        },
    );
});

test('loadSystemPrompt reads a real file and returns its contents', () => {
    const dir = mkdtempSync(join(tmpdir(), 'convo-coach-prompt-'));
    const path = join(dir, 'custom.md');
    const content = '# Custom prompt\nYou are a friendly tutor.\n';
    writeFileSync(path, content, 'utf8');
    try {
        assert.equal(loadSystemPrompt(path), content);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});
