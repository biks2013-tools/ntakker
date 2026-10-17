// test/incremental-perf.test.ts — plan-023 T5 (EVAL-2026-06-12 B1 / B5 /
// B10, EVAL-2026-10-16 CC-10 / CC-11).

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseJsonl, JsonlAccumulator } from '../src/transcript/jsonl.js';
import { StdinTranscript } from '../src/transcript/stdin.js';
import { applyBudget, encodingForModel, estimateTokens } from '../src/llm/budget.js';

function line(id: string, ms: number, text: string, source = 'mic'): string {
    return JSON.stringify({ id, timestamp: new Date(ms).toISOString(), source, text });
}

const LINES = [
    line('a', 1_000, 'hello'),
    line('b', 2_000, 'how are you', 'system'),
    '{"_tombstone":true,"id":"a"}',
    line('a', 1_000, 'hello there, a longer rewrite'),
    '# comment',
    '',
    line('c', 1_500, 'out of order'),
];

test('JsonlAccumulator fed line by line equals parseJsonl on the whole file', () => {
    const acc = new JsonlAccumulator();
    for (const l of LINES) acc.push(l);
    assert.deepEqual(acc.records(), parseJsonl(LINES.join('\n')));
    assert.deepEqual(acc.records().map((r) => r.text), ['hello there, a longer rewrite', 'out of order', 'how are you']);
});

test('StdinTranscript: snapshots between pushes match a full re-parse (B1)', () => {
    const t = new StdinTranscript();
    const now = new Date(10_000);
    for (let i = 0; i < LINES.length; i += 1) {
        t.push(LINES[i]!);
        const sofar = LINES.slice(0, i + 1).join('\n');
        let expected: unknown[];
        try {
            expected = parseJsonl(sofar);
        } catch {
            expected = [];
        }
        assert.deepEqual(t.records(now), expected, `after line ${i + 1}`);
    }
});

test('StdinTranscript: records are the same objects across triggers (lets B5 cache them)', () => {
    const t = new StdinTranscript();
    t.push(LINES[0]!);
    const first = t.records(new Date());
    t.push(LINES[1]!);
    const second = t.records(new Date());
    assert.equal(second[0], first[0]);
});

test('StdinTranscript: a malformed line warns once, not on every trigger (B1)', () => {
    const warnings: string[] = [];
    const original = console.warn;
    console.warn = (msg: unknown) => { warnings.push(String(msg)); };
    try {
        const t = new StdinTranscript();
        t.push(LINES[0]!);
        t.push('{not json');
        for (let i = 0; i < 5; i += 1) t.records(new Date());
    } finally {
        console.warn = original;
    }
    assert.equal(warnings.filter((w) => w.includes('malformed JSON')).length, 1);
});

test('StdinTranscript: plain text is detected from the first line and stamped at trigger time', () => {
    const t = new StdinTranscript();
    t.push('just words');
    t.push('more words');
    const now = new Date(42_000);
    assert.deepEqual(t.records(now), [
        { timestamp: now, text: 'just words' },
        { timestamp: now, text: 'more words' },
    ]);
});

test('StdinTranscript: a JSONL-looking stream whose lines all fail degrades to plain text', () => {
    const original = console.warn;
    console.warn = () => {};
    try {
        const t = new StdinTranscript();
        t.push('{"no_text_field": 1}');
        t.push('{"also": "bad"}');
        assert.equal(t.records(new Date(0)).length, 2);
    } finally {
        console.warn = original;
    }
});

test('encodingForModel picks o200k for current OpenAI models, cl100k for old ones (B10)', () => {
    for (const m of ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1', 'gpt-5.1', 'o3-mini', undefined]) {
        assert.equal(encodingForModel(m), 'o200k_base', String(m));
    }
    for (const m of ['gpt-4', 'gpt-4-turbo', 'gpt-3.5-turbo']) {
        assert.equal(encodingForModel(m), 'cl100k_base', m);
    }
    // The two encodings really differ on non-Latin text (Greek).
    const greek = 'Καλημέρα σας, τι κάνετε σήμερα;';
    assert.notEqual(estimateTokens(greek, 'openai', 'gpt-4o'), estimateTokens(greek, 'openai', 'gpt-4'));
});

test('applyBudget gives the same counts on repeat calls (cached) and caches per tokenizer', () => {
    const records = parseJsonl(LINES.join('\n'));
    const a = applyBudget(records, 'system prompt', 'gpt-4o', 'openai', 'error');
    const b = applyBudget(records, 'system prompt', 'gpt-4o', 'openai', 'error');
    assert.equal(a.originalTokenCount, b.originalTokenCount);
    const legacy = applyBudget(records, 'system prompt', 'gpt-4', 'openai', 'error');
    assert.ok(legacy.originalTokenCount > 0);
    const heuristic = applyBudget(records, 'system prompt', 'claude-x', 'anthropic', 'error');
    assert.ok(heuristic.originalTokenCount > 0);
});
