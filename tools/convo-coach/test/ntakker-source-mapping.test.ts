// test/ntakker-source-mapping.test.ts — EVAL-2026-10-16 CC-2.
//
// ntakker sidecars carry `source` ("mic" | "system" | "mixed") and an
// optional diarization `speaker`, not `channel`. The parser must map
// them so the prompt can tell the user from the remote side.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseJsonl, channelFromSource } from '../src/transcript/jsonl.js';
import { buildPrompt } from '../src/prompt/build.js';
import { DEFAULT_SYSTEM_PROMPT } from '../src/prompt/default-system-prompt.js';

const line = (o: Record<string, unknown>): string => JSON.stringify(o);

test('source mic → A, system → B, mixed → no channel', () => {
    assert.equal(channelFromSource('mic'), 'A');
    assert.equal(channelFromSource('microphone'), 'A');
    assert.equal(channelFromSource('system'), 'B');
    assert.equal(channelFromSource('mixed'), undefined);
    assert.equal(channelFromSource(undefined), undefined);
});

test('parseJsonl maps ntakker source and keeps speaker', () => {
    const content = [
        line({ id: '1', timestamp: '2026-10-16T10:00:00Z', source: 'mic', text: 'Can you share the numbers?' }),
        line({ id: '2', timestamp: '2026-10-16T10:00:05Z', source: 'system', text: 'Sure, after the call.', speaker: 'Speaker 2' }),
        line({ id: '3', timestamp: '2026-10-16T10:00:09Z', source: 'mixed', text: 'Mixed line.' }),
    ].join('\n');
    const recs = parseJsonl(content);
    assert.deepEqual(recs.map((r) => r.channel), ['A', 'B', undefined]);
    assert.equal(recs[1]?.speaker, 'Speaker 2');
});

test('an explicit channel field still wins over source', () => {
    const recs = parseJsonl(line({ ts: 1_000, channel: 'B', source: 'mic', text: 'x' }));
    assert.equal(recs[0]?.channel, 'B');
});

test('prompt lines carry the channel and speaker tags', () => {
    const recs = parseJsonl(
        line({ id: '2', timestamp: '2026-10-16T10:00:05Z', source: 'system', text: 'Sure.', speaker: 'Speaker 2', language: 'en' }),
    );
    const built = buildPrompt({ records: recs, systemPrompt: DEFAULT_SYSTEM_PROMPT });
    assert.match(built.user, /\[B\] \[Speaker 2\] \(en\): Sure\./);
});
