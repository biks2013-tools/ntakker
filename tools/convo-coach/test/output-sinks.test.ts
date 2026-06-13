// test/output-sinks.test.ts — unit tests for the sidecar writer and stream-to-sinks plumbing.
//
// Scope: src/output/sidecar.ts (buildSidecarPath, SidecarWriter)
//        src/output/stream.ts (StdoutWriter, streamToSinks, runOneAdvice)
//
// Run via:  npx tsx --test test/output-sinks.test.ts
// from the tools/convo-coach directory.

import { strict as assert } from 'node:assert';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import test from 'node:test';

import { ConvoCoachError, type SidecarFrontMatter, type StreamSink } from '../src/types.js';
import { buildSidecarPath, SidecarWriter } from '../src/output/sidecar.js';
import { StdoutWriter, streamToSinks } from '../src/output/stream.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Build a local-time timestamp string exactly as formatTimestamp() does
 * (local time, not UTC). Using new Date(y, m-1, d, H, M, S) avoids any
 * timezone-to-UTC conversion that new Date(isoString) would apply.
 */
function localTs(d: Date): string {
    const yyyy = String(d.getFullYear()).padStart(4, '0');
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    const hh = String(d.getHours()).padStart(2, '0');
    const mi = String(d.getMinutes()).padStart(2, '0');
    const ss = String(d.getSeconds()).padStart(2, '0');
    return `${yyyy}${mm}${dd}-${hh}${mi}${ss}`;
}

/**
 * Minimal SidecarFrontMatter fixture for SidecarWriter tests.
 */
function makeFrontMatter(overrides: Partial<SidecarFrontMatter> = {}): SidecarFrontMatter {
    return {
        provider: 'anthropic',
        model: 'claude-haiku-4-5',
        transcript: '/tmp/test.jsonl',
        window: { last: '5m', since: undefined },
        createdAt: '2026-05-02T14:32:10Z',
        ...overrides,
    };
}

// ---------------------------------------------------------------------------
// buildSidecarPath — timestamp uses local time
// ---------------------------------------------------------------------------

test('buildSidecarPath: with transcriptPath — uses transcript dir and strips extension', (t) => {
    // Use a temp dir that definitely exists so existsSync returns false for our candidate.
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const now = new Date(2026, 4, 2, 14, 32, 10); // May = month 4 (0-based); local time
    const ts = localTs(now);

    const result = buildSidecarPath({
        transcriptPath: path.join(tmpDir, 'foo.jsonl'),
        fallbackDir: '/elsewhere',
        now,
    });

    assert.equal(result, path.join(tmpDir, `foo.advice-${ts}.md`));
});

test('buildSidecarPath: without transcriptPath — uses fallbackDir and convo-coach-stdin stem', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const now = new Date(2026, 4, 2, 14, 32, 10);
    const ts = localTs(now);

    const result = buildSidecarPath({
        fallbackDir: tmpDir,
        now,
    });

    assert.equal(result, path.join(tmpDir, `convo-coach-stdin.advice-${ts}.md`));
});

test('buildSidecarPath: collision — returns -2, -3, -4 suffixes before finding free slot', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const now = new Date(2026, 4, 2, 14, 32, 10);
    const ts = localTs(now);
    const baseName = `foo.advice-${ts}`;

    // Pre-create the primary and -2, -3, -4 candidates.
    fs.writeFileSync(path.join(tmpDir, `${baseName}.md`), '');
    fs.writeFileSync(path.join(tmpDir, `${baseName}-2.md`), '');
    fs.writeFileSync(path.join(tmpDir, `${baseName}-3.md`), '');
    fs.writeFileSync(path.join(tmpDir, `${baseName}-4.md`), '');

    const result = buildSidecarPath({
        transcriptPath: path.join(tmpDir, 'foo.jsonl'),
        fallbackDir: '/elsewhere',
        now,
    });

    assert.equal(result, path.join(tmpDir, `${baseName}-5.md`));
});

test('buildSidecarPath: 99 collisions — throws ConvoCoachError mentioning collision exhaustion', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const now = new Date(2026, 4, 2, 14, 32, 10);
    const ts = localTs(now);
    const baseName = `foo.advice-${ts}`;

    // Create primary + -2 through -99 (total 99 files).
    fs.writeFileSync(path.join(tmpDir, `${baseName}.md`), '');
    for (let i = 2; i <= 99; i++) {
        fs.writeFileSync(path.join(tmpDir, `${baseName}-${i}.md`), '');
    }

    assert.throws(
        () =>
            buildSidecarPath({
                transcriptPath: path.join(tmpDir, 'foo.jsonl'),
                fallbackDir: '/elsewhere',
                now,
            }),
        (err: unknown) => {
            assert.ok(err instanceof ConvoCoachError, `expected ConvoCoachError, got ${err}`);
            assert.match((err as ConvoCoachError).message, /99 collisions/);
            return true;
        },
    );
});

test('buildSidecarPath: various transcript extensions are stripped correctly', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const now = new Date(2026, 4, 2, 14, 32, 10);
    const ts = localTs(now);

    const cases: Array<[string, string]> = [
        ['bar.jsonl', 'bar'],
        ['bar.txt', 'bar'],
        ['bar.something.weird', 'bar.something'],
    ];

    for (const [filename, expectedStem] of cases) {
        const result = buildSidecarPath({
            transcriptPath: path.join(tmpDir, filename),
            fallbackDir: '/elsewhere',
            now,
        });
        const expectedBase = `${expectedStem}.advice-${ts}.md`;
        assert.equal(
            result,
            path.join(tmpDir, expectedBase),
            `for transcript '${filename}' expected stem '${expectedStem}'`,
        );
    }
});

// ---------------------------------------------------------------------------
// SidecarWriter — construction writes frontmatter immediately
// ---------------------------------------------------------------------------

test('SidecarWriter: construction writes YAML frontmatter to .tmp file', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.advice-20260502-143210.md');
    const fm = makeFrontMatter();
    new SidecarWriter(targetPath, fm);

    const tmpFile = `${targetPath}.tmp`;
    assert.ok(fs.existsSync(tmpFile), '.tmp file must exist after construction');

    const content = fs.readFileSync(tmpFile, 'utf8');
    // Should contain YAML frontmatter delimiters
    assert.ok(content.includes('---'), 'frontmatter opening delimiter missing');
    assert.ok(content.includes('provider: anthropic'), 'provider field missing');
    assert.ok(content.includes('model: claude-haiku-4-5'), 'model field missing');
    assert.ok(content.includes('createdAt:'), 'createdAt field missing');
});

test('SidecarWriter: write() appends chunks synchronously in order', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const writer = new SidecarWriter(targetPath, makeFrontMatter());

    writer.write('chunk-one ');
    writer.write('chunk-two ');
    writer.write('chunk-three');

    const content = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    assert.ok(content.includes('chunk-one chunk-two chunk-three'), 'all chunks must appear in order');
});

test('SidecarWriter: appendMetricsBlock appends ## Metrics section with correct values', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const writer = new SidecarWriter(targetPath, makeFrontMatter());

    writer.appendMetricsBlock({
        promptTokens: 100,
        completionTokens: 50,
        totalTokens: 150,
        ttftMs: 320,
        latencyMs: 1200,
    });

    const content = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    assert.ok(content.includes('## Metrics'), 'Metrics heading must appear');
    assert.ok(content.includes('- promptTokens: 100'), 'promptTokens missing');
    assert.ok(content.includes('- completionTokens: 50'), 'completionTokens missing');
    assert.ok(content.includes('- totalTokens: 150'), 'totalTokens missing');
    assert.ok(content.includes('- ttftMs: 320'), 'ttftMs missing');
    assert.ok(content.includes('- latencyMs: 1200'), 'latencyMs missing');
});

test('SidecarWriter: appendMetricsBlock renders N/A for undefined values', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const writer = new SidecarWriter(targetPath, makeFrontMatter());
    writer.appendMetricsBlock({});

    const content = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    const naCount = (content.match(/N\/A/g) ?? []).length;
    assert.equal(naCount, 5, 'all 5 metric fields should show N/A when undefined');
});

test('SidecarWriter: close() is atomic — .tmp gone, final .md exists with full content', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const writer = new SidecarWriter(targetPath, makeFrontMatter());
    writer.write('body content here');
    writer.close();

    assert.ok(!fs.existsSync(`${targetPath}.tmp`), '.tmp file must be gone after close()');
    assert.ok(fs.existsSync(targetPath), 'final .md file must exist after close()');
    const content = fs.readFileSync(targetPath, 'utf8');
    assert.ok(content.includes('body content here'), 'body content must survive the rename');
    assert.ok(content.includes('provider: anthropic'), 'frontmatter must survive the rename');
});

test('SidecarWriter: YAML frontmatter has each expected key on its own line as "key: value"', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    new SidecarWriter(targetPath, makeFrontMatter());

    const raw = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    const lines = raw.split('\n');

    // Extract frontmatter between the two '---' delimiters
    const fmStart = lines.indexOf('---');
    const fmEnd = lines.indexOf('---', fmStart + 1);
    assert.ok(fmStart !== -1 && fmEnd !== -1 && fmEnd > fmStart, 'frontmatter delimiters missing');

    const fmLines = lines.slice(fmStart + 1, fmEnd);

    // Each top-level key must appear in "key: value" form
    const requiredKeys = ['provider', 'model', 'transcript', 'window', 'createdAt'];
    for (const key of requiredKeys) {
        const hasLine = fmLines.some((line) => line.startsWith(`${key}:`));
        assert.ok(hasLine, `frontmatter must have a line starting with '${key}:'`);
    }
});

test('SidecarWriter: window rendering — last: 5m renders correctly', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    new SidecarWriter(targetPath, makeFrontMatter({ window: { last: '5m', since: undefined } }));

    const content = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    assert.ok(content.includes('  last: 5m'), 'window.last must render as "  last: 5m"');
    assert.ok(content.includes('  since: null'), 'window.since must render as "  since: null" when absent');
});

test('SidecarWriter: window rendering — since ISO string renders correctly', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    new SidecarWriter(targetPath, makeFrontMatter({ window: { last: undefined, since: '2026-05-02T14:32:10' } }));

    const content = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    // 'since' value contains a colon, so yamlScalar will quote it
    assert.ok(content.includes('  since:'), 'window.since line must be present');
    assert.ok(content.includes('2026-05-02T14:32:10'), 'since timestamp value must appear in the file');
    assert.ok(content.includes('  last: null'), 'window.last must render as "  last: null" when absent');
});

test('SidecarWriter: transcript path with spaces does not break frontmatter structure', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const spacePath = '/tmp/my recordings/foo bar.jsonl';
    new SidecarWriter(targetPath, makeFrontMatter({ transcript: spacePath }));

    const raw = fs.readFileSync(`${targetPath}.tmp`, 'utf8');
    const lines = raw.split('\n');
    const fmStart = lines.indexOf('---');
    const fmEnd = lines.indexOf('---', fmStart + 1);
    const fmBlock = lines.slice(fmStart + 1, fmEnd).join('\n');

    // transcript line must exist and contain the path text
    assert.ok(fmBlock.includes('transcript:'), 'transcript key must be present');
    assert.ok(fmBlock.includes('my recordings'), 'path text must survive in frontmatter');
});

test('SidecarWriter: write() after close() throws an Error', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const writer = new SidecarWriter(targetPath, makeFrontMatter());
    writer.close();

    // Implementation note (PLAN-011-CC-PENDING-4): post-close throws `Error`,
    // not `ConvoCoachError`. This is an acknowledged cosmetic implementation gap.
    assert.throws(
        () => writer.write('late chunk'),
        (err: unknown) => {
            assert.ok(err instanceof Error, 'expected an Error to be thrown');
            assert.match(
                (err as Error).message,
                /close/i,
                'error message should mention close()',
            );
            return true;
        },
    );
});

test('SidecarWriter: close() is idempotent — second call does nothing', (t) => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-writer-test-'));
    t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

    const targetPath = path.join(tmpDir, 'out.md');
    const writer = new SidecarWriter(targetPath, makeFrontMatter());
    writer.close();
    // Second close should not throw — the internal guard `if (this.closed) return` handles it.
    assert.doesNotThrow(() => writer.close());
});

// ---------------------------------------------------------------------------
// StdoutWriter — write() forwards to process.stdout
// ---------------------------------------------------------------------------

test('StdoutWriter: write() calls process.stdout.write with the chunk', () => {
    const writer = new StdoutWriter();
    const captured: string[] = [];
    const original = process.stdout.write.bind(process.stdout);

    // Monkey-patch with a spy — cast through unknown to sidestep the overloaded signature.
    (process.stdout as unknown as { write: (c: unknown) => boolean }).write = (chunk: unknown): boolean => {
        if (typeof chunk === 'string') captured.push(chunk);
        return true;
    };

    try {
        writer.write('hello from stdout writer');
        assert.deepEqual(captured, ['hello from stdout writer']);
    } finally {
        process.stdout.write = original;
    }
});

test('StdoutWriter: write() with empty string does not call process.stdout.write', () => {
    const writer = new StdoutWriter();
    let callCount = 0;
    const original = process.stdout.write.bind(process.stdout);

    // Cast through unknown to sidestep the overloaded write signature.
    (process.stdout as unknown as { write: () => boolean }).write = (): boolean => {
        callCount++;
        return true;
    };

    try {
        writer.write('');
        assert.equal(callCount, 0, 'process.stdout.write must not be called for empty chunk');
    } finally {
        process.stdout.write = original;
    }
});

// ---------------------------------------------------------------------------
// streamToSinks — fan-out helper
// ---------------------------------------------------------------------------

/** Simple array-backed sink for testing fan-out. */
class CollectorSink implements StreamSink {
    public readonly received: string[] = [];
    public closeCalled = false;

    write(chunk: string): void {
        this.received.push(chunk);
    }

    close(): void {
        this.closeCalled = true;
    }
}

async function* makeStream(chunks: string[]): AsyncGenerator<string> {
    for (const chunk of chunks) {
        yield chunk;
    }
}

async function* throwingStream(chunks: string[], throwAfter: number): AsyncGenerator<string> {
    for (let i = 0; i < chunks.length; i++) {
        if (i === throwAfter) {
            throw new Error(`stream error after chunk ${throwAfter}`);
        }
        yield chunks[i]!;
    }
}

test('streamToSinks: delivers all chunks to all sinks in order', async () => {
    const sinkA = new CollectorSink();
    const sinkB = new CollectorSink();
    const chunks = ['alpha', 'beta', 'gamma'];

    await streamToSinks(makeStream(chunks), [sinkA, sinkB]);

    assert.deepEqual(sinkA.received, chunks, 'sink A must receive all chunks in order');
    assert.deepEqual(sinkB.received, chunks, 'sink B must receive all chunks in order');
});

test('streamToSinks: returns ttftMs > 0 after at least one chunk', async () => {
    const sink = new CollectorSink();
    const result = await streamToSinks(makeStream(['hello']), [sink]);
    assert.ok(typeof result.ttftMs === 'number', 'ttftMs must be a number');
    assert.ok(result.ttftMs >= 0, `ttftMs must be non-negative, got ${result.ttftMs}`);
});

test('streamToSinks: empty stream — no chunks delivered, ttftMs is undefined', async () => {
    const sinkA = new CollectorSink();
    const sinkB = new CollectorSink();

    const result = await streamToSinks(makeStream([]), [sinkA, sinkB]);

    assert.deepEqual(sinkA.received, [], 'sink A must receive nothing on empty stream');
    assert.deepEqual(sinkB.received, [], 'sink B must receive nothing on empty stream');
    assert.equal(result.ttftMs, undefined, 'ttftMs must be undefined when no chunks were produced');
});

test('streamToSinks: does NOT call sink.close() — close is the orchestrator\'s responsibility', async () => {
    const sinkA = new CollectorSink();
    const sinkB = new CollectorSink();

    await streamToSinks(makeStream(['one', 'two']), [sinkA, sinkB]);

    assert.equal(sinkA.closeCalled, false, 'streamToSinks must not call sinkA.close()');
    assert.equal(sinkB.closeCalled, false, 'streamToSinks must not call sinkB.close()');
});

test('streamToSinks: generator throws after first chunk — error propagates', async () => {
    const sinkA = new CollectorSink();
    const sinkB = new CollectorSink();

    await assert.rejects(
        () => streamToSinks(throwingStream(['one', 'two'], 1), [sinkA, sinkB]),
        (err: unknown) => {
            assert.ok(err instanceof Error);
            assert.match((err as Error).message, /stream error after chunk 1/);
            return true;
        },
    );

    // Both sinks must have received chunk 0 before the throw on chunk 1
    assert.deepEqual(sinkA.received, ['one'], 'sink A must have received chunk before throw');
    assert.deepEqual(sinkB.received, ['one'], 'sink B must have received chunk before throw');
});

test('streamToSinks: sink write() throws — error propagates to caller', async () => {
    const goodSink = new CollectorSink();

    class ThrowOnSecondSink implements StreamSink {
        private callCount = 0;
        write(_chunk: string): void {
            this.callCount++;
            if (this.callCount === 2) {
                throw new Error('sink exploded on chunk 2');
            }
        }
    }

    const badSink = new ThrowOnSecondSink();

    await assert.rejects(
        () => streamToSinks(makeStream(['one', 'two', 'three']), [goodSink, badSink]),
        (err: unknown) => {
            assert.ok(err instanceof Error);
            assert.match((err as Error).message, /sink exploded on chunk 2/);
            return true;
        },
    );
});

// ---------------------------------------------------------------------------
// runOneAdvice — minimal contract test via a stubbed LanguageModel
// ---------------------------------------------------------------------------

// runOneAdvice now wraps LangChain's BaseChatModel.stream(messages) — much
// easier to stub than the ai SDK's doStream contract. Any object exposing
// an async `.stream()` method that returns an async-iterable of objects with
// a `content` string and an optional `usage_metadata` field on the final
// chunk satisfies the contract.

test('runOneAdvice: returns { usage, ttftMs, latencyMs } with correct shape from a stub model', async () => {
    const { runOneAdvice } = await import('../src/output/stream.js');

    async function* fakeStream(): AsyncIterable<{
        content: string;
        usage_metadata?: { input_tokens: number; output_tokens: number; total_tokens: number };
    }> {
        yield { content: 'stub ' };
        yield { content: 'advice' };
        yield {
            content: '',
            usage_metadata: { input_tokens: 10, output_tokens: 5, total_tokens: 15 },
        };
    }

    const stubModel = {
        stream: async () => fakeStream(),
    };

    const collector = new CollectorSink();
    const result = await runOneAdvice({
        model: stubModel as unknown as import('../src/types.js').LanguageModel,
        system: 'You are a coach.',
        user: 'What should I say?',
        sinks: [collector],
    });

    assert.ok(typeof result.ttftMs === 'number', `ttftMs must be a number, got ${typeof result.ttftMs}`);
    assert.ok(typeof result.latencyMs === 'number', `latencyMs must be a number, got ${typeof result.latencyMs}`);
    assert.ok(typeof result.usage === 'object', 'usage must be an object');
    assert.ok(result.latencyMs >= 0, 'latencyMs must be non-negative');
    // The stub yields aggregated `usage_metadata` only on the final chunk;
    // LangChain's `concat` carries it forward so runOneAdvice should surface
    // it on the result.
    assert.equal(result.usage.inputTokens, 10);
    assert.equal(result.usage.outputTokens, 5);
    assert.equal(result.usage.totalTokens, 15);
    assert.equal(collector.received.join(''), 'stub advice');
});
