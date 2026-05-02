// test/integration-smoke.test.ts — end-to-end smoke for the orchestrator.
//
// Strategy: drive the full pipeline (config → CLI args → reader → window →
// budget → prompt → factory → stream) with a fake OpenAI key so the
// upstream stages run for real, but the actual provider call fails. A
// PROVIDER_FAILURE exit (70) proves the pipeline is wired end to end.
//
// We capture stderr/stdout to keep the test runner output clean.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { main } from '../src/index.js';
import { EXIT_CODES } from '../src/types.js';

function makeTempDir(prefix: string): string {
    return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function writeSampleJsonl(dir: string): string {
    const filePath = path.join(dir, 'sample.jsonl');
    const baseMs = Date.parse('2026-05-02T12:00:00Z');
    const lines = [
        { ts: baseMs, text: 'Hello, can you tell me about your project?', channel: 'A', lang: 'en' },
        { ts: baseMs + 5_000, text: 'Sure — it is a CLI for live conversation coaching.', channel: 'B', lang: 'en' },
        { ts: baseMs + 12_000, text: 'How do you handle the LLM streaming?', channel: 'A', lang: 'en' },
        { ts: baseMs + 18_000, text: 'We use the Vercel AI SDK with the textStream API.', channel: 'B', lang: 'en' },
    ];
    fs.writeFileSync(filePath, lines.map((l) => JSON.stringify(l)).join('\n') + '\n', 'utf8');
    return filePath;
}

interface CapturedStreams {
    stdout: string;
    stderr: string;
    restore: () => void;
}

function captureStreams(): CapturedStreams {
    const captured: CapturedStreams = {
        stdout: '',
        stderr: '',
        restore: () => {
            process.stdout.write = origStdout as typeof process.stdout.write;
            process.stderr.write = origStderr as typeof process.stderr.write;
        },
    };
    const origStdout = process.stdout.write.bind(process.stdout);
    const origStderr = process.stderr.write.bind(process.stderr);

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    process.stdout.write = ((chunk: any): boolean => {
        captured.stdout += typeof chunk === 'string' ? chunk : String(chunk);
        return true;
    }) as typeof process.stdout.write;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    process.stderr.write = ((chunk: any): boolean => {
        captured.stderr += typeof chunk === 'string' ? chunk : String(chunk);
        return true;
    }) as typeof process.stderr.write;

    return captured;
}

test('integration smoke: full pipeline reaches the OpenAI provider with a fake key (exit 70)', async () => {
    const tempDir = makeTempDir('convo-coach-smoke-');
    const transcriptPath = writeSampleJsonl(tempDir);

    // Inject a fake API key. process.env mutation persists for this Node
    // process; we restore in the finally.
    const originalKey = process.env['OPENAI_API_KEY'];
    process.env['OPENAI_API_KEY'] = 'fake-key-for-test';

    const captured = captureStreams();
    let exitCode = -1;
    let entries: string[] = [];
    try {
        // runCli wraps main() in the top-level catch; we want a real exit
        // code so we use runCli through the public surface.
        const { runCli } = await import('../src/index.js');
        exitCode = await runCli([
            '--transcript', transcriptPath,
            '--provider', 'openai',
            '--model', 'gpt-4o-mini',
        ]);
        // Snapshot the sidecar artefacts BEFORE cleanup runs.
        try { entries = fs.readdirSync(tempDir); } catch { /* dir gone */ }
    } finally {
        captured.restore();
        if (originalKey === undefined) {
            delete process.env['OPENAI_API_KEY'];
        } else {
            process.env['OPENAI_API_KEY'] = originalKey;
        }
        // Best-effort cleanup — ignore errors.
        try { fs.rmSync(tempDir, { recursive: true, force: true }); } catch { /* noop */ }
    }

    // We expect exit 70 (PROVIDER_FAILURE) — the fake key is rejected by
    // OpenAI. Any other code (esp. 78/MISSING_CONFIG, 64/BAD_USAGE,
    // 66/NO_INPUT) means an upstream stage broke.
    //
    // If we are running in a sandbox without network access, the SDK might
    // fail with a network error that still surfaces as PROVIDER_FAILURE,
    // which is fine — anything that reaches the provider call counts.
    //
    // Allow exit 1 (GENERIC) ONLY when it's clearly a sandbox-network
    // problem — the message will mention DNS/ENOTFOUND/EAI_AGAIN. In that
    // case, skip the assertion gracefully.
    if (
        exitCode === EXIT_CODES.GENERIC &&
        /ENOTFOUND|EAI_AGAIN|getaddrinfo|network/i.test(captured.stderr)
    ) {
        // Sandbox without network — pipeline is wired, but we can't reach
        // the SDK. Treat as pass.
        return;
    }

    assert.equal(
        exitCode,
        EXIT_CODES.PROVIDER_FAILURE,
        `expected exit ${EXIT_CODES.PROVIDER_FAILURE} (PROVIDER_FAILURE), got ${exitCode}.\n` +
        `stderr:\n${captured.stderr}\nstdout:\n${captured.stdout}`,
    );

    // Sidecar artefact: either the .tmp (if rename hasn't happened — we
    // failed before metrics-append) or the final .md.
    const hasSidecar = entries.some((e) => /\.advice-\d{8}-\d{6}.*\.md(\.tmp)?$/.test(e));
    assert.ok(
        hasSidecar,
        `expected a sidecar (.md or .md.tmp) in '${tempDir}', got: ${entries.join(', ')}`,
    );
});

test('main(): --help short-circuits and returns SUCCESS', async () => {
    const captured = captureStreams();
    let exitCode = -1;
    try {
        exitCode = await main(['--help']);
    } finally {
        captured.restore();
    }
    assert.equal(exitCode, EXIT_CODES.SUCCESS);
    assert.match(captured.stdout, /USAGE/);
});

test('main(): --version short-circuits and returns SUCCESS', async () => {
    const captured = captureStreams();
    let exitCode = -1;
    try {
        exitCode = await main(['--version']);
    } finally {
        captured.restore();
    }
    assert.equal(exitCode, EXIT_CODES.SUCCESS);
    assert.match(captured.stdout, /^convo-coach \d/);
});
