// test/budget-smoke.test.ts — smoke tests for U9 (token-budget guard).
//
// Run via `npx tsx --test test/budget-smoke.test.ts` from tools/convo-coach.

import { strict as assert } from 'node:assert';
import test from 'node:test';

import { ConvoCoachError, type NormalisedRecord } from '../src/types.js';
import { applyBudget, estimateTokens } from '../src/llm/budget.js';
import { getContextWindow } from '../src/llm/model-context-windows.js';

// ---------------------------------------------------------------------------
// estimateTokens
// ---------------------------------------------------------------------------

test('estimateTokens(openai) returns a positive integer for non-empty text', () => {
    const n = estimateTokens('hello world', 'openai');
    assert.equal(typeof n, 'number');
    assert.ok(Number.isInteger(n));
    assert.ok(n > 0, `expected > 0, got ${n}`);
});

test('estimateTokens(anthropic) uses 4-cpt heuristic', () => {
    // 'hello world' is 11 chars → ceil(11/4) = 3.
    assert.equal(estimateTokens('hello world', 'anthropic'), 3);
});

test('estimateTokens returns 0 for empty input regardless of provider', () => {
    assert.equal(estimateTokens('', 'openai'), 0);
    assert.equal(estimateTokens('', 'google'), 0);
});

// ---------------------------------------------------------------------------
// getContextWindow
// ---------------------------------------------------------------------------

test('getContextWindow(known) returns the table value', () => {
    assert.equal(getContextWindow('gpt-4o-mini'), 128_000);
    assert.equal(getContextWindow('claude-haiku-4-5'), 200_000);
    assert.equal(getContextWindow('gemini-2.5-flash'), 1_000_000);
});

test('getContextWindow(unknown) returns 8000 and warns', () => {
    // Capture console.warn for this single call.
    const original = console.warn;
    let warned = '';
    console.warn = (msg: unknown) => {
        warned = String(msg);
    };
    try {
        const value = getContextWindow('completely-unknown-model-xyz');
        assert.equal(value, 8_000);
        assert.match(warned, /Unknown model 'completely-unknown-model-xyz'/);
        assert.match(warned, /8000-token context window/);
    } finally {
        console.warn = original;
    }
});

// ---------------------------------------------------------------------------
// applyBudget — happy path
// ---------------------------------------------------------------------------

function mkRecord(text: string, secondsFromEpoch = 0): NormalisedRecord {
    return {
        timestamp: new Date(secondsFromEpoch * 1000),
        text,
    };
}

test('applyBudget — small input under budget → truncated=false', () => {
    const records: NormalisedRecord[] = [
        mkRecord('alpha', 1),
        mkRecord('beta', 2),
        mkRecord('gamma', 3),
    ];
    const result = applyBudget(
        records,
        'You are a helpful coach.',
        'gpt-4o-mini',
        'openai',
        'truncate-start',
    );
    assert.equal(result.truncated, false);
    assert.equal(result.records.length, 3);
    assert.equal(result.originalTokenCount, result.finalTokenCount);
    assert.ok(result.originalTokenCount > 0);
});

// ---------------------------------------------------------------------------
// applyBudget — overflow paths
//
// Strategy: feed 1000 records of ~100-char text against an unknown model
// (which falls back to 8000-token capacity → 6800-token usable budget).
// Each record costs ceil(100/4) + 10 = 35 tokens under the heuristic, so
// 1000 records ≈ 35 000 tokens — well over budget.
// ---------------------------------------------------------------------------

function makeBigCorpus(): NormalisedRecord[] {
    const records: NormalisedRecord[] = [];
    for (let i = 0; i < 1000; i++) {
        // Pad index so each line is ~100 chars and remains uniquely identifiable.
        const idx = String(i).padStart(4, '0');
        const text = `line-${idx} ${'x'.repeat(90)}`; // 100-ish chars
        records.push(mkRecord(text, i));
    }
    return records;
}

// Silence the "unknown model" warning that getContextWindow emits during
// these overflow tests so the test output stays clean.
function withSilencedWarn<T>(fn: () => T): T {
    const original = console.warn;
    console.warn = () => {};
    try {
        return fn();
    } finally {
        console.warn = original;
    }
}

test('applyBudget — truncate-start drops oldest records and keeps the latest', () => {
    const records = makeBigCorpus();
    const result = withSilencedWarn(() =>
        applyBudget(
            records,
            'You are a helpful coach.',
            'tiny-test-model',          // unknown → 8000 capacity, 6800 budget
            'anthropic',                // heuristic provider for predictable counts
            'truncate-start',
        ),
    );
    assert.equal(result.truncated, true);
    assert.ok(result.records.length < records.length);
    assert.ok(result.records.length > 0);
    assert.ok(
        result.finalTokenCount < result.originalTokenCount,
        'finalTokenCount should shrink after truncation',
    );

    // The LAST record of the input must survive a truncate-start.
    const lastInput = records[records.length - 1]!;
    const lastSurvivor = result.records[result.records.length - 1]!;
    assert.equal(lastSurvivor.text, lastInput.text);

    // The FIRST record of the input must NOT be present.
    const firstInput = records[0]!;
    assert.notEqual(result.records[0]!.text, firstInput.text);
});

test('applyBudget — truncate-end drops newest records and keeps the oldest', () => {
    const records = makeBigCorpus();
    const result = withSilencedWarn(() =>
        applyBudget(
            records,
            'You are a helpful coach.',
            'tiny-test-model',
            'anthropic',
            'truncate-end',
        ),
    );
    assert.equal(result.truncated, true);
    assert.ok(result.records.length > 0);
    assert.ok(result.records.length < records.length);

    // The FIRST record of the input must survive a truncate-end.
    const firstInput = records[0]!;
    assert.equal(result.records[0]!.text, firstInput.text);

    // The LAST record of the input must NOT be present.
    const lastInput = records[records.length - 1]!;
    assert.notEqual(
        result.records[result.records.length - 1]!.text,
        lastInput.text,
    );
});

test('applyBudget — strategy "error" throws ConvoCoachError(BAD_USAGE)', () => {
    const records = makeBigCorpus();
    assert.throws(
        () =>
            withSilencedWarn(() =>
                applyBudget(
                    records,
                    'You are a helpful coach.',
                    'tiny-test-model',
                    'anthropic',
                    'error',
                ),
            ),
        (err: unknown) => {
            assert.ok(err instanceof ConvoCoachError, 'expected ConvoCoachError');
            assert.equal((err as ConvoCoachError).code, 'BAD_USAGE');
            assert.match(
                (err as ConvoCoachError).message,
                /exceeds model 'tiny-test-model' budget/,
            );
            return true;
        },
    );
});

test('applyBudget — input is treated as immutable (returns fresh array)', () => {
    const records = makeBigCorpus();
    const lengthBefore = records.length;
    withSilencedWarn(() =>
        applyBudget(
            records,
            'sys',
            'tiny-test-model',
            'anthropic',
            'truncate-start',
        ),
    );
    assert.equal(
        records.length,
        lengthBefore,
        'applyBudget must not mutate the input array',
    );
});
