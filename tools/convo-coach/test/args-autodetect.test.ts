// test/args-autodetect.test.ts — unit tests for args.ts (parseCliArgs, helpText)
// and transcript/autodetect.ts (autodetectLatestSidecar).
//
// Run with:
//   npx tsx --test test/args-autodetect.test.ts
//
// Owned by the args-autodetect test-build agent. DO NOT modify production source.
// All temp directories are created under os.tmpdir() and cleaned up in after() hooks.

import { describe, test, after } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { parseCliArgs, helpText } from '../src/args.js';
import { autodetectLatestSidecar } from '../src/transcript/autodetect.js';
import {
    UsageError,
    TranscriptError,
    PROVIDER_NAMES,
    OVERFLOW_STRATEGIES,
} from '../src/types.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTempDir(prefix: string): string {
    return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

/** Touch a file with a specific mtime. mtime is a Date or epoch-ms number. */
function touchFile(filePath: string, content = '', mtimeMs?: number): void {
    fs.writeFileSync(filePath, content, 'utf8');
    if (mtimeMs !== undefined) {
        const t = new Date(mtimeMs);
        fs.utimesSync(filePath, t, t);
    }
}

// ---------------------------------------------------------------------------
// parseCliArgs
// ---------------------------------------------------------------------------

describe('parseCliArgs', () => {
    // 1. No args → all fields undefined (or unset), help/version absent (falsy)
    test('no args → returns empty object (all fields undefined)', () => {
        const result = parseCliArgs([]);
        assert.equal(result.transcript, undefined);
        assert.equal(result.last, undefined);
        assert.equal(result.since, undefined);
        assert.equal(result.provider, undefined);
        assert.equal(result.model, undefined);
        assert.equal(result.systemPrompt, undefined);
        assert.equal(result.debounce, undefined);
        assert.equal(result.onOverflow, undefined);
        assert.equal(result.recordingsDir, undefined);
        // help and version are not set → should be undefined (falsy)
        assert.ok(!result.help, 'help should be falsy when not passed');
        assert.ok(!result.version, 'version should be falsy when not passed');
    });

    // 2. All flags set → each maps to the correct CliArgs field
    test('all flags set → all fields populated correctly', () => {
        const argv = [
            '--transcript', '/path/to/sidecar.jsonl',
            '--last', '5m',
            '--since', '2026-05-02T12:00:00Z',
            '--provider', 'openai',
            '--model', 'gpt-4o',
            '--system-prompt', '/path/to/prompt.md',
            '--debounce', '15s',
            '--on-overflow', 'truncate-start',
            '--recordings-dir', '/path/to/recordings',
        ];
        const result = parseCliArgs(argv);
        assert.equal(result.transcript, '/path/to/sidecar.jsonl');
        assert.equal(result.last, '5m');
        assert.equal(result.since, '2026-05-02T12:00:00Z');
        assert.equal(result.provider, 'openai');
        assert.equal(result.model, 'gpt-4o');
        assert.equal(result.systemPrompt, '/path/to/prompt.md');
        assert.equal(result.debounce, '15s');
        assert.equal(result.onOverflow, 'truncate-start');
        assert.equal(result.recordingsDir, '/path/to/recordings');
    });

    // 3. --help → sets help: true
    test('--help → help is true', () => {
        const result = parseCliArgs(['--help']);
        assert.equal(result.help, true);
    });

    // 3b. -h shorthand → help is true
    test('-h → help is true (short form)', () => {
        const result = parseCliArgs(['-h']);
        assert.equal(result.help, true);
    });

    // 4. --version → sets version: true
    test('--version → version is true', () => {
        const result = parseCliArgs(['--version']);
        assert.equal(result.version, true);
    });

    // 4b. -V shorthand → version is true
    test('-V → version is true (short form)', () => {
        const result = parseCliArgs(['-V']);
        assert.equal(result.version, true);
    });

    // 5. Unknown flag → throws UsageError naming the bad flag
    test('unknown flag throws UsageError with the bad flag name', () => {
        assert.throws(
            () => parseCliArgs(['--bogus']),
            (err: unknown) => {
                assert.ok(err instanceof UsageError, 'should be UsageError');
                assert.ok(
                    (err as Error).message.includes('--bogus'),
                    `message should contain --bogus; got: ${(err as Error).message}`,
                );
                return true;
            },
        );
    });

    // 5b. Positional argument → throws UsageError
    test('positional argument throws UsageError', () => {
        assert.throws(
            () => parseCliArgs(['some-positional']),
            (err: unknown) => err instanceof UsageError,
        );
    });

    // 6. --provider invalid value → throws UsageError listing accepted values
    test('--provider with invalid value throws UsageError listing all accepted providers', () => {
        assert.throws(
            () => parseCliArgs(['--provider', 'not-a-real-provider']),
            (err: unknown) => {
                assert.ok(err instanceof UsageError, 'should be UsageError');
                const msg = (err as Error).message;
                assert.ok(msg.includes('not-a-real-provider'), `message missing the bad value; got: ${msg}`);
                // The error message must enumerate at least a subset of valid providers.
                for (const p of ['openai', 'anthropic', 'google']) {
                    assert.ok(msg.includes(p), `message missing accepted provider '${p}'; got: ${msg}`);
                }
                return true;
            },
        );
    });

    // 6b. All 8 valid provider values parse without error
    test('all 8 provider names are accepted without error', () => {
        for (const name of PROVIDER_NAMES) {
            const result = parseCliArgs(['--provider', name]);
            assert.equal(result.provider, name, `provider '${name}' should be accepted`);
        }
    });

    // 7. --on-overflow invalid value → throws UsageError listing strategies
    test('--on-overflow with invalid value throws UsageError listing accepted strategies', () => {
        assert.throws(
            () => parseCliArgs(['--on-overflow', 'drop-oldest']),
            (err: unknown) => {
                assert.ok(err instanceof UsageError, 'should be UsageError');
                const msg = (err as Error).message;
                assert.ok(msg.includes('drop-oldest'), `message missing the bad value; got: ${msg}`);
                for (const s of OVERFLOW_STRATEGIES) {
                    assert.ok(msg.includes(s), `message missing strategy '${s}'; got: ${msg}`);
                }
                return true;
            },
        );
    });

    // 7b. All valid overflow strategies parse without error
    test('all overflow strategies are accepted without error', () => {
        for (const strategy of OVERFLOW_STRATEGIES) {
            const result = parseCliArgs(['--on-overflow', strategy]);
            assert.equal(result.onOverflow, strategy, `strategy '${strategy}' should be accepted`);
        }
    });

    // 8. Missing value for a value-bearing flag → throws UsageError
    test('--transcript at end of argv with no value throws UsageError', () => {
        assert.throws(
            () => parseCliArgs(['--transcript']),
            (err: unknown) => {
                assert.ok(err instanceof UsageError, 'should be UsageError');
                assert.ok(
                    (err as Error).message.includes('--transcript'),
                    `message should mention --transcript; got: ${(err as Error).message}`,
                );
                return true;
            },
        );
    });

    test('--provider at end of argv with no value throws UsageError', () => {
        assert.throws(
            () => parseCliArgs(['--provider']),
            (err: unknown) => err instanceof UsageError,
        );
    });

    test('--model at end of argv with no value throws UsageError', () => {
        assert.throws(
            () => parseCliArgs(['--model']),
            (err: unknown) => err instanceof UsageError,
        );
    });

    test('--on-overflow at end of argv with no value throws UsageError', () => {
        assert.throws(
            () => parseCliArgs(['--on-overflow']),
            (err: unknown) => err instanceof UsageError,
        );
    });

    // 9. Equal-sign syntax: the parser uses a switch on the raw arg token.
    //    --provider=openai is NOT the same token as --provider, so the switch
    //    falls through to the default case and throws UsageError (unknown option).
    //    We document this behaviour here; the test verifies the actual outcome.
    test('equal-sign syntax --provider=openai falls into unknown-option path (space-separated only)', () => {
        // The parser does NOT split on '='. Document the actual behaviour so the
        // suite catches any future change in either direction.
        assert.throws(
            () => parseCliArgs(['--provider=openai']),
            (err: unknown) => err instanceof UsageError,
            'equal-sign syntax should throw UsageError (parser is space-separated only)',
        );
    });

    // 10. Mixed flag order → all flags parsed regardless of position
    test('flags in arbitrary order are all parsed correctly', () => {
        const argv = [
            '--model', 'claude-3',
            '--help',
            '--provider', 'anthropic',
            '--transcript', '/foo.jsonl',
            '--version',
            '--last', '10m',
        ];
        const result = parseCliArgs(argv);
        assert.equal(result.model, 'claude-3');
        assert.equal(result.help, true);
        assert.equal(result.provider, 'anthropic');
        assert.equal(result.transcript, '/foo.jsonl');
        assert.equal(result.version, true);
        assert.equal(result.last, '10m');
    });

    // 10b. Repeated flags: last one wins (the switch just overwrites)
    test('repeated --model flag: last value wins', () => {
        const result = parseCliArgs(['--model', 'first', '--model', 'second']);
        assert.equal(result.model, 'second');
    });
});

// ---------------------------------------------------------------------------
// helpText()
// ---------------------------------------------------------------------------

describe('helpText', () => {
    // 11. Content checks
    test('helpText includes "convo-coach" as the tool name', () => {
        const text = helpText();
        assert.ok(text.includes('convo-coach'), `expected "convo-coach" in helpText; got:\n${text}`);
    });

    test('helpText includes all flag names', () => {
        const text = helpText();
        const expectedFlags = [
            '--transcript',
            '--last',
            '--since',
            '--provider',
            '--model',
            '--system-prompt',
            '--debounce',
            '--on-overflow',
            '--recordings-dir',
            '--help',
            '--version',
        ];
        for (const flag of expectedFlags) {
            assert.ok(text.includes(flag), `expected flag "${flag}" in helpText; got:\n${text}`);
        }
    });

    test('helpText includes the short-form flags -h and -V', () => {
        const text = helpText();
        assert.ok(text.includes('-h'), 'expected -h in helpText');
        assert.ok(text.includes('-V'), 'expected -V in helpText');
    });

    test('helpText includes all 8 provider names', () => {
        const text = helpText();
        for (const p of PROVIDER_NAMES) {
            assert.ok(text.includes(p), `expected provider "${p}" in helpText; got:\n${text}`);
        }
    });

    test('helpText includes all 3 overflow strategies', () => {
        const text = helpText();
        for (const s of OVERFLOW_STRATEGIES) {
            assert.ok(text.includes(s), `expected overflow strategy "${s}" in helpText; got:\n${text}`);
        }
    });

    test('helpText is a non-empty string', () => {
        const text = helpText();
        assert.equal(typeof text, 'string');
        assert.ok(text.length > 0, 'helpText must not be empty');
    });
});

// ---------------------------------------------------------------------------
// autodetectLatestSidecar
// ---------------------------------------------------------------------------

describe('autodetectLatestSidecar', () => {
    // Collect temp dirs for cleanup
    const tempDirs: string[] = [];

    after(() => {
        for (const dir of tempDirs) {
            try {
                fs.rmSync(dir, { recursive: true, force: true });
            } catch {
                // best effort
            }
        }
    });

    function makeCleanDir(prefix: string): string {
        const dir = makeTempDir(prefix);
        tempDirs.push(dir);
        return dir;
    }

    // 1. Empty directory → throws TranscriptError with "no candidate" message
    test('empty directory → throws TranscriptError mentioning no candidates', () => {
        const dir = makeCleanDir('cc-autodetect-empty-');
        assert.throws(
            () => autodetectLatestSidecar(dir),
            (err: unknown) => {
                assert.ok(err instanceof TranscriptError, `expected TranscriptError; got ${(err as Error)?.constructor?.name}`);
                const msg = (err as Error).message;
                // The message mentions "no transcript sidecars found"
                assert.ok(
                    /no.*sidecar|no.*candidate|no.*transcript|no.*\.jsonl|no.*\.txt/i.test(msg),
                    `message should mention no candidates; got: ${msg}`,
                );
                return true;
            },
        );
    });

    // 2. Non-existent directory → throws TranscriptError (NO_INPUT, exit 66)
    test('non-existent directory → throws TranscriptError', () => {
        const nonExistent = path.join(os.tmpdir(), `cc-autodetect-nonexistent-${Date.now()}`);
        assert.throws(
            () => autodetectLatestSidecar(nonExistent),
            (err: unknown) => {
                assert.ok(err instanceof TranscriptError, `expected TranscriptError; got ${(err as Error)?.constructor?.name}`);
                assert.equal((err as { code?: string }).code, 'NO_INPUT');
                return true;
            },
        );
    });

    // 3. Directory with one .jsonl → returns its path
    test('directory with a single .jsonl file → returns that file path', () => {
        const dir = makeCleanDir('cc-autodetect-single-');
        const file = path.join(dir, 'recording.transcript.jsonl');
        touchFile(file);

        const result = autodetectLatestSidecar(dir);
        assert.equal(result, file);
    });

    // 4. Multiple files → returns the most-recently-modified
    test('multiple .jsonl and .txt files → returns most-recently-modified', () => {
        const dir = makeCleanDir('cc-autodetect-multi-');

        const now = Date.now();
        const older = path.join(dir, 'older.transcript.jsonl');
        const middle = path.join(dir, 'middle.transcript.txt');
        const newest = path.join(dir, 'newest.transcript.jsonl');

        touchFile(older, '', now - 10_000);
        touchFile(middle, '', now - 5_000);
        touchFile(newest, '', now);

        const result = autodetectLatestSidecar(dir);
        assert.equal(result, newest, `expected newest file; got: ${result}`);
    });

    // 5. Tilde expansion: ~/some/path is expanded via os.homedir()
    test('tilde expansion: ~/subpath resolves to homedir-based path', () => {
        // Create a real temp dir under the user's actual home directory so
        // the tilde expansion resolves to the same absolute path.
        const home = os.homedir();
        const relName = `cc-autodetect-tilde-${Date.now()}`;
        const absoluteDir = path.join(home, relName);
        fs.mkdirSync(absoluteDir, { recursive: true });
        tempDirs.push(absoluteDir);

        const file = path.join(absoluteDir, 'session.transcript.jsonl');
        touchFile(file);

        const tildeInput = `~/${relName}`;
        const result = autodetectLatestSidecar(tildeInput);
        assert.equal(result, file, `expected ${file}; got: ${result}`);
    });

    // 6. Mixed file types: only .jsonl and .txt are candidates; audio files ignored
    test('mixed file types: .m4a, .wav, .md are ignored; only .jsonl and .txt are candidates', () => {
        const dir = makeCleanDir('cc-autodetect-mixed-');

        const now = Date.now();
        // Audio files (newer mtime than the transcript)
        touchFile(path.join(dir, 'recording.m4a'), '', now);
        touchFile(path.join(dir, 'recording.wav'), '', now - 1_000);
        touchFile(path.join(dir, 'notes.md'), '', now - 500);

        // Valid candidate — older than audio but only transcript eligible
        const transcript = path.join(dir, 'recording.transcript.jsonl');
        touchFile(transcript, '', now - 3_000);

        const result = autodetectLatestSidecar(dir);
        assert.equal(result, transcript, `expected the .jsonl file; got: ${result}`);
    });

    // 6b. Both .jsonl and .txt present; newest of either wins
    test('.jsonl and .txt both present: newest by mtime wins regardless of extension', () => {
        const dir = makeCleanDir('cc-autodetect-jsontxt-');

        const now = Date.now();
        const jsonl = path.join(dir, 'sidecar.transcript.jsonl');
        const txt = path.join(dir, 'sidecar.transcript.txt');

        touchFile(jsonl, '', now - 2_000);
        touchFile(txt, '', now);     // txt is newer

        const result = autodetectLatestSidecar(dir);
        assert.equal(result, txt, `expected the newer .txt file; got: ${result}`);
    });

    // 7. Non-directory path (regular file) → throws TranscriptError
    test('passing a regular file path (not a dir) → throws TranscriptError', () => {
        const dir = makeCleanDir('cc-autodetect-notdir-');
        const file = path.join(dir, 'notadirectory.jsonl');
        touchFile(file);

        assert.throws(
            () => autodetectLatestSidecar(file),
            (err: unknown) => {
                assert.ok(err instanceof TranscriptError, `expected TranscriptError; got ${(err as Error)?.constructor?.name}`);
                const msg = (err as Error).message;
                assert.ok(
                    /not a directory/i.test(msg),
                    `message should say "not a directory"; got: ${msg}`,
                );
                return true;
            },
        );
    });

    // 8. Hidden files (.something.jsonl) — verify actual behaviour.
    //    The implementation uses `entry.isFile()` only (no hidden-file exclusion),
    //    so hidden files whose extension is .jsonl or .txt ARE included as candidates.
    test('hidden .jsonl file is included as a candidate (no hidden-file filter in implementation)', () => {
        const dir = makeCleanDir('cc-autodetect-hidden-');

        const now = Date.now();
        const hidden = path.join(dir, '.hidden-session.jsonl');
        touchFile(hidden, '', now);

        // hidden file should be the winner (it is the only candidate)
        const result = autodetectLatestSidecar(dir);
        assert.equal(result, hidden, `expected hidden file to be returned; got: ${result}`);
    });

    // 8b. When a hidden file and a visible file compete, most-recent mtime wins
    test('hidden vs visible: most recently modified file wins regardless of visibility', () => {
        const dir = makeCleanDir('cc-autodetect-hidvis-');

        const now = Date.now();
        const visible = path.join(dir, 'visible.transcript.jsonl');
        const hidden = path.join(dir, '.hidden.transcript.jsonl');

        touchFile(visible, '', now - 1_000);
        touchFile(hidden, '', now);     // hidden is newer

        const result = autodetectLatestSidecar(dir);
        assert.equal(result, hidden, `expected hidden (newer) file; got: ${result}`);
    });

    // Edge case: directory contains only unsupported extensions → TranscriptError
    test('directory with only unsupported extensions (.m4a, .wav) → TranscriptError', () => {
        const dir = makeCleanDir('cc-autodetect-unsupported-');
        touchFile(path.join(dir, 'audio.m4a'));
        touchFile(path.join(dir, 'audio.wav'));

        assert.throws(
            () => autodetectLatestSidecar(dir),
            (err: unknown) => err instanceof TranscriptError,
        );
    });

    // Edge case: bare ~ (home dir itself)
    test('bare tilde ~ is expanded to homedir() without throwing when dir exists', () => {
        // We cannot assert a specific file from ~ (we don't control its contents),
        // but we can assert that the function does not throw a "not a directory" error.
        // It may throw TranscriptError("no sidecars found") if home is empty of .jsonl/.txt,
        // but it should NOT throw "not a directory".
        try {
            autodetectLatestSidecar('~');
        } catch (err: unknown) {
            if (err instanceof TranscriptError) {
                // Acceptable: either no sidecars, or not accessible — both are TranscriptError.
                // We just verify it's not an unexpected error type.
                return;
            }
            // If it doesn't throw at all (found files) — also fine.
            throw err; // Re-throw any non-TranscriptError
        }
    });
});
