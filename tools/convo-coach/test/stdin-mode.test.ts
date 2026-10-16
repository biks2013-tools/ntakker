// test/stdin-mode.test.ts — regression for EVAL-2026-10-16 CC-1.
//
// Node leaves `process.stdin.isTTY` undefined (not false) for pipes, so a
// strict `=== false` check made stdin mode unreachable: piped input fell
// through to autodetect and exited NO_INPUT (66) on an empty recordings dir.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

import { isStdinPiped } from '../src/args.js';
import { EXIT_CODES } from '../src/types.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, '..');

test('isStdinPiped: undefined (pipe/file) and false are piped; true (TTY) is not', () => {
    assert.equal(isStdinPiped(undefined), true);
    assert.equal(isStdinPiped(false), true);
    assert.equal(isStdinPiped(true), false);
});

test('piped input selects stdin mode instead of autodetect', () => {
    const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-stdin-home-'));
    const emptyRecordings = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-stdin-rec-'));

    // Empty piped input: stdin mode reaches EOF with no records and exits 0
    // without calling a provider. Autodetect (the pre-fix behaviour) finds no
    // sidecar in the empty recordings dir and exits NO_INPUT (66).
    const result = spawnSync(
        process.execPath,
        ['--import', 'tsx', 'src/cli.ts', '--provider', 'mlx', '--model', 'test-model'],
        {
            cwd: projectRoot,
            input: '',
            encoding: 'utf8',
            timeout: 30_000,
            env: {
                PATH: process.env.PATH ?? '',
                HOME: tmpHome,
                OPENAI_BASE_URL: 'http://127.0.0.1:9/v1',
                NTAKKER_RECORDINGS_DIR: emptyRecordings,
            },
        },
    );

    assert.equal(
        result.status,
        EXIT_CODES.SUCCESS,
        `expected stdin mode to exit cleanly on empty EOF; got ${result.status}. stderr:\n${result.stderr}`,
    );
});
