// test/config.test.ts — Unit tests for the four-tier config resolver.
//
// Scope:
//   - loadConfig() — tier ordering, alias resolution, CLI overrides, provenance.
//   - __test.parseDotEnv() — edge cases for the hand-rolled .env parser.
//   - Bootstrap: ~/.tool-agents/convo-coach/ directory creation (mode 0o700).
//
// Isolation strategy:
//   - process.env is mutated per-test and ALWAYS restored in after()/finally.
//   - The real HOME directory is NEVER touched. Tests that need to exercise
//     the tool-env tier redirect process.env.HOME to a tmp directory so that
//     ~/.tool-agents/convo-coach/.env resolves to a writable temp location.
//   - The cwd .env tier is exercised by passing opts.cwd pointing at a
//     tmp directory containing a synthetic .env file.
//   - After every test the env is restored and tmp dirs are removed.
//
// Node test runner naming: every top-level test starts with "config" so
// the scope-only filter `--test-name-pattern '^config'` picks them all up.

import { test, describe, beforeEach, afterEach, after } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { loadConfig, __test } from '../src/config.js';
import type { CliArgs, ConfigKey } from '../src/types.js';

const { parseDotEnv, ALIAS_MAP, RECOGNISED_KEYS } = __test;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Creates a temporary directory and returns its path. */
function makeTmp(prefix: string): string {
    return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

/** Writes a .env file in dir with the given content and returns the dir path. */
function writeDotEnv(dir: string, content: string): string {
    fs.writeFileSync(path.join(dir, '.env'), content, 'utf8');
    return dir;
}

/** Snapshots every recognised ConfigKey from process.env, and returns a
 *  restore function that puts them back exactly as they were. */
function snapshotEnv(): () => void {
    const saved: Record<string, string | undefined> = {};
    // Save all recognised keys plus HOME which we redirect for tool-env tests.
    const keysToSave: string[] = ['HOME', ...Array.from(RECOGNISED_KEYS)];
    for (const k of keysToSave) {
        saved[k] = process.env[k];
    }
    return () => {
        for (const [k, v] of Object.entries(saved)) {
            if (v === undefined) {
                delete process.env[k];
            } else {
                process.env[k] = v;
            }
        }
    };
}

/** Clears every recognised key from process.env (so a clean slate exists). */
function clearRecognisedEnv(): void {
    for (const k of RECOGNISED_KEYS) {
        delete process.env[k];
    }
}

/** Empty CliArgs — no flags set. */
const NO_CLI: CliArgs = Object.freeze({});

// ---------------------------------------------------------------------------
// 1. parseDotEnv — edge cases
// ---------------------------------------------------------------------------

describe('config: parseDotEnv edge cases', () => {
    test('config: comment lines starting with # are skipped', () => {
        const result = parseDotEnv('# This is a comment\nKEY=value\n');
        assert.equal(result['KEY'], 'value');
        assert.equal(Object.keys(result).length, 1);
    });

    test('config: blank lines are skipped without error', () => {
        const result = parseDotEnv('\n\n\nKEY=value\n\n');
        assert.equal(result['KEY'], 'value');
        assert.equal(Object.keys(result).length, 1);
    });

    test('config: double-quoted values have quotes stripped', () => {
        const result = parseDotEnv('KEY="value with spaces"\n');
        assert.equal(result['KEY'], 'value with spaces');
    });

    test('config: single-quoted values have quotes stripped', () => {
        const result = parseDotEnv("KEY='single quoted'\n");
        assert.equal(result['KEY'], 'single quoted');
    });

    test('config: mismatched quotes are left intact', () => {
        // "value' — first char is " but last is ' — no stripping should occur.
        const result = parseDotEnv('KEY="value\'\n');
        assert.equal(result['KEY'], '"value\'');
    });

    test('config: lines without = are ignored (no crash)', () => {
        const result = parseDotEnv('INVALID_NO_EQUALS\nKEY=value\n');
        assert.equal(result['KEY'], 'value');
        assert.ok(!('INVALID_NO_EQUALS' in result));
    });

    test('config: key-only line followed by equals (KEY=) yields empty string value', () => {
        const result = parseDotEnv('KEY=\n');
        // The parser trims the value; an empty value after trim stays ''.
        assert.equal(result['KEY'], '');
    });

    test('config: trailing comment after value is NOT stripped (parser is simple)', () => {
        // Per the design comment: "Trailing comments after value are NOT stripped".
        const result = parseDotEnv('KEY=value # this is NOT a comment\n');
        // After trim the value is "value # this is NOT a comment"
        // (no inline-comment stripping — simple parser behaviour).
        assert.equal(result['KEY'], 'value # this is NOT a comment');
    });

    test('config: KEY with surrounding whitespace around = is trimmed', () => {
        const result = parseDotEnv('KEY  =  spaced value  \n');
        assert.equal(result['KEY'], 'spaced value');
    });

    test('config: Windows CRLF line endings are handled', () => {
        const result = parseDotEnv('KEY=value\r\nSECOND=two\r\n');
        assert.equal(result['KEY'], 'value');
        assert.equal(result['SECOND'], 'two');
    });

    test('config: multiple key=value pairs are all parsed', () => {
        const content = [
            '# comment',
            '',
            'OPENAI_API_KEY=sk-test',
            'GOOGLE_API_KEY=goog-test',
            '',
        ].join('\n');
        const result = parseDotEnv(content);
        assert.equal(result['OPENAI_API_KEY'], 'sk-test');
        assert.equal(result['GOOGLE_API_KEY'], 'goog-test');
        assert.equal(Object.keys(result).length, 2);
    });
});

// ---------------------------------------------------------------------------
// 2. Alias resolution
// ---------------------------------------------------------------------------

describe('config: alias resolution', () => {
    let restore: () => void;
    let tmpHome: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        // Use a tmp HOME with no .env files so tool-env and cwd tiers are empty.
        tmpHome = makeTmp('convo-coach-alias-home-');
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
    });

    test('config: ANTHROPIC_FOUNDRY_API_KEY alias fills AZURE_AI_INFERENCE_KEY when canonical is unset', () => {
        process.env['ANTHROPIC_FOUNDRY_API_KEY'] = 'alias-key';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('AZURE_AI_INFERENCE_KEY'), 'alias-key');
    });

    test('config: canonical AZURE_AI_INFERENCE_KEY wins over ANTHROPIC_FOUNDRY_API_KEY alias', () => {
        process.env['AZURE_AI_INFERENCE_KEY'] = 'canonical-key';
        process.env['ANTHROPIC_FOUNDRY_API_KEY'] = 'alias-key';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('AZURE_AI_INFERENCE_KEY'), 'canonical-key');
    });

    test('config: ANTHROPIC_FOUNDRY_ENDPOINT alias fills AZURE_AI_INFERENCE_ENDPOINT when canonical is unset', () => {
        process.env['ANTHROPIC_FOUNDRY_ENDPOINT'] = 'https://alias-endpoint.example.com';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('AZURE_AI_INFERENCE_ENDPOINT'), 'https://alias-endpoint.example.com');
    });

    test('config: canonical AZURE_AI_INFERENCE_ENDPOINT wins over ANTHROPIC_FOUNDRY_ENDPOINT alias', () => {
        process.env['AZURE_AI_INFERENCE_ENDPOINT'] = 'https://canonical.example.com';
        process.env['ANTHROPIC_FOUNDRY_ENDPOINT'] = 'https://alias.example.com';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('AZURE_AI_INFERENCE_ENDPOINT'), 'https://canonical.example.com');
    });

    test('config: LITELLM_API_BASE alias fills LITELLM_PROXY_URL when canonical is unset', () => {
        process.env['LITELLM_API_BASE'] = 'http://litellm.local:4000';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('LITELLM_PROXY_URL'), 'http://litellm.local:4000');
    });

    test('config: canonical LITELLM_PROXY_URL wins over LITELLM_API_BASE alias', () => {
        process.env['LITELLM_PROXY_URL'] = 'http://canonical.local:4000';
        process.env['LITELLM_API_BASE'] = 'http://alias.local:4000';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('LITELLM_PROXY_URL'), 'http://canonical.local:4000');
    });

    test('config: LITELLM_API_KEY alias fills LITELLM_MASTER_KEY when canonical is unset', () => {
        process.env['LITELLM_API_KEY'] = 'api-key-alias';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('LITELLM_MASTER_KEY'), 'api-key-alias');
    });

    test('config: canonical LITELLM_MASTER_KEY wins over LITELLM_API_KEY alias', () => {
        process.env['LITELLM_MASTER_KEY'] = 'master-key';
        process.env['LITELLM_API_KEY'] = 'api-key-alias';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('LITELLM_MASTER_KEY'), 'master-key');
    });

    test('config: GEMINI_API_KEY alias fills GOOGLE_API_KEY when canonical is unset', () => {
        process.env['GEMINI_API_KEY'] = 'gemini-alias';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('GOOGLE_API_KEY'), 'gemini-alias');
    });

    test('config: canonical GOOGLE_API_KEY wins over GEMINI_API_KEY alias', () => {
        process.env['GOOGLE_API_KEY'] = 'google-canonical';
        process.env['GEMINI_API_KEY'] = 'gemini-alias';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('GOOGLE_API_KEY'), 'google-canonical');
    });

    test('config: requesting an alias key directly (ANTHROPIC_FOUNDRY_API_KEY) returns its own value', () => {
        // ANTHROPIC_FOUNDRY_API_KEY is itself a ConfigKey (it is in RECOGNISED_KEYS).
        // When set, config.get('ANTHROPIC_FOUNDRY_API_KEY') must return it directly.
        process.env['ANTHROPIC_FOUNDRY_API_KEY'] = 'direct-alias-value';
        const config = loadConfig(NO_CLI, { cwd: tmpHome });
        assert.equal(config.get('ANTHROPIC_FOUNDRY_API_KEY'), 'direct-alias-value');
    });

    test('config: ALIAS_MAP canonical-to-alias mapping is correct for all five alias pairs', () => {
        // Verify the static ALIAS_MAP matches the documented spec.
        assert.equal(ALIAS_MAP['AZURE_AI_INFERENCE_KEY'], 'ANTHROPIC_FOUNDRY_API_KEY');
        assert.equal(ALIAS_MAP['AZURE_AI_INFERENCE_ENDPOINT'], 'ANTHROPIC_FOUNDRY_ENDPOINT');
        assert.equal(ALIAS_MAP['LITELLM_PROXY_URL'], 'LITELLM_API_BASE');
        assert.equal(ALIAS_MAP['LITELLM_MASTER_KEY'], 'LITELLM_API_KEY');
        assert.equal(ALIAS_MAP['GOOGLE_API_KEY'], 'GEMINI_API_KEY');
    });
});

// ---------------------------------------------------------------------------
// 3. Tier ordering — shell → tool-env → cwd-env → CLI
// ---------------------------------------------------------------------------

describe('config: four-tier ordering', () => {
    let restore: () => void;
    let tmpHome: string;
    let tmpCwd: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        tmpHome = makeTmp('convo-coach-tier-home-');
        tmpCwd = makeTmp('convo-coach-tier-cwd-');
        // Default: redirect HOME to tmp so real ~/.tool-agents is untouched.
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
        try { fs.rmSync(tmpCwd, { recursive: true, force: true }); } catch { /* noop */ }
    });

    // -----------------------------------------------------------------------
    // 3a. Shell env (tier 1) is the baseline
    // -----------------------------------------------------------------------

    test('config: tier-1 shell env value is used when no higher tier sets the key', () => {
        process.env['OPENAI_API_KEY'] = 'shell-value';
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), 'shell-value');
        assert.equal(config.provenance('OPENAI_API_KEY'), 'shell');
    });

    test('config: empty string in shell env is treated as unset (tier contributes nothing)', () => {
        process.env['OPENAI_API_KEY'] = '';
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), undefined);
    });

    test('config: empty string at tier-2 wipes the shell value (delete-on-empty override)', () => {
        // Real-world scenario: shell exports AZURE_OPENAI_API_VERSION=<old>, and
        // ~/.tool-agents/convo-coach/.env contains `AZURE_OPENAI_API_VERSION=`
        // (uncommented, empty). The empty value should override and clear the
        // shell, not be ignored. The provider then sees undefined and routes
        // through Azure's v1 GA endpoint.
        process.env['AZURE_OPENAI_API_VERSION'] = '2024-12-01-preview';
        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(
            path.join(toolAgentsDir, '.env'),
            'AZURE_OPENAI_API_VERSION=\n',
            'utf8',
        );
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('AZURE_OPENAI_API_VERSION'), undefined);
        assert.equal(config.provenance('AZURE_OPENAI_API_VERSION'), undefined);
    });

    // -----------------------------------------------------------------------
    // 3b. Tool-env (tier 2) overrides shell env
    // -----------------------------------------------------------------------

    test('config: tier-2 tool-env overrides tier-1 shell env', () => {
        // Shell value (lower priority)
        process.env['OPENAI_API_KEY'] = 'shell-value';

        // Write tool-env .env in the fake ~/.tool-agents/convo-coach/
        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(toolAgentsDir, '.env'), 'OPENAI_API_KEY=tool-env-value\n', 'utf8');

        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), 'tool-env-value');
        assert.equal(config.provenance('OPENAI_API_KEY'), 'tool-env');
    });

    // -----------------------------------------------------------------------
    // 3c. cwd-env (tier 3) overrides tier 2
    // -----------------------------------------------------------------------

    test('config: tier-3 cwd-env overrides tier-2 tool-env', () => {
        // Tier 1: shell
        process.env['OPENAI_API_KEY'] = 'shell-value';

        // Tier 2: tool-env
        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(toolAgentsDir, '.env'), 'OPENAI_API_KEY=tool-env-value\n', 'utf8');

        // Tier 3: cwd-env (highest env-file priority)
        writeDotEnv(tmpCwd, 'OPENAI_API_KEY=cwd-env-value\n');

        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), 'cwd-env-value');
        assert.equal(config.provenance('OPENAI_API_KEY'), 'cwd-env');
    });

    test('config: tier-3 cwd-env without tool-env overrides tier-1 shell', () => {
        process.env['OPENAI_API_KEY'] = 'shell-value';
        writeDotEnv(tmpCwd, 'OPENAI_API_KEY=cwd-env-value\n');

        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), 'cwd-env-value');
        assert.equal(config.provenance('OPENAI_API_KEY'), 'cwd-env');
    });

    // -----------------------------------------------------------------------
    // 3d. CLI (tier 4) overrides everything
    // -----------------------------------------------------------------------

    test('config: tier-4 CLI flag overrides all lower tiers for COACH_PROVIDER', () => {
        // All three lower tiers set a value.
        process.env['COACH_PROVIDER'] = 'openai'; // shell (but COACH_PROVIDER is not a CLI-mappable ConfigKey in shell directly)

        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(toolAgentsDir, '.env'), 'COACH_PROVIDER=anthropic\n', 'utf8');

        writeDotEnv(tmpCwd, 'COACH_PROVIDER=google\n');

        const cliArgs: CliArgs = { provider: 'azure-openai' };
        const config = loadConfig(cliArgs, { cwd: tmpCwd });
        assert.equal(config.get('COACH_PROVIDER'), 'azure-openai');
        assert.equal(config.provenance('COACH_PROVIDER'), 'cli');
    });

    test('config: no CLI flag for OPENAI_API_KEY — cwd-env wins when all three env tiers are set', () => {
        process.env['OPENAI_API_KEY'] = 'shell-value';

        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(toolAgentsDir, '.env'), 'OPENAI_API_KEY=tool-env-value\n', 'utf8');

        writeDotEnv(tmpCwd, 'OPENAI_API_KEY=cwd-env-value\n');

        // No CLI flag for API keys — CLI only covers the six COACH_* / MACREC_* args.
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), 'cwd-env-value');
    });
});

// ---------------------------------------------------------------------------
// 4. CLI arg → ConfigKey mapping
// ---------------------------------------------------------------------------

describe('config: CLI arg to ConfigKey mapping', () => {
    let restore: () => void;
    let tmpHome: string;
    let tmpCwd: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        tmpHome = makeTmp('convo-coach-cli-home-');
        tmpCwd = makeTmp('convo-coach-cli-cwd-');
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
        try { fs.rmSync(tmpCwd, { recursive: true, force: true }); } catch { /* noop */ }
    });

    test('config: cliArgs.provider maps to COACH_PROVIDER with cli provenance', () => {
        const config = loadConfig({ provider: 'anthropic' }, { cwd: tmpCwd });
        assert.equal(config.get('COACH_PROVIDER'), 'anthropic');
        assert.equal(config.provenance('COACH_PROVIDER'), 'cli');
    });

    test('config: cliArgs.model maps to COACH_MODEL with cli provenance', () => {
        const config = loadConfig({ model: 'gpt-4o-mini' }, { cwd: tmpCwd });
        assert.equal(config.get('COACH_MODEL'), 'gpt-4o-mini');
        assert.equal(config.provenance('COACH_MODEL'), 'cli');
    });

    test('config: cliArgs.recordingsDir maps to MACREC_RECORDINGS_DIR with cli provenance', () => {
        const config = loadConfig({ recordingsDir: '/tmp/recordings' }, { cwd: tmpCwd });
        assert.equal(config.get('MACREC_RECORDINGS_DIR'), '/tmp/recordings');
        assert.equal(config.provenance('MACREC_RECORDINGS_DIR'), 'cli');
    });

    test('config: cliArgs.debounce maps to COACH_DEBOUNCE with cli provenance', () => {
        const config = loadConfig({ debounce: '30s' }, { cwd: tmpCwd });
        assert.equal(config.get('COACH_DEBOUNCE'), '30s');
        assert.equal(config.provenance('COACH_DEBOUNCE'), 'cli');
    });

    test('config: cliArgs.onOverflow maps to COACH_ON_OVERFLOW with cli provenance', () => {
        const config = loadConfig({ onOverflow: 'truncate-end' }, { cwd: tmpCwd });
        assert.equal(config.get('COACH_ON_OVERFLOW'), 'truncate-end');
        assert.equal(config.provenance('COACH_ON_OVERFLOW'), 'cli');
    });

    test('config: cliArgs.systemPrompt maps to COACH_SYSTEM_PROMPT_PATH with cli provenance', () => {
        const config = loadConfig({ systemPrompt: '/etc/prompt.md' }, { cwd: tmpCwd });
        assert.equal(config.get('COACH_SYSTEM_PROMPT_PATH'), '/etc/prompt.md');
        assert.equal(config.provenance('COACH_SYSTEM_PROMPT_PATH'), 'cli');
    });

    test('config: empty string cliArgs are treated as absent (not overriding lower tiers)', () => {
        // The implementation checks `typeof raw === 'string' && raw.length > 0`.
        process.env['COACH_PROVIDER'] = 'openai';
        // Pass an undefined provider (omitted from CliArgs)
        const config = loadConfig({} as CliArgs, { cwd: tmpCwd });
        assert.equal(config.get('COACH_PROVIDER'), 'openai');
        assert.equal(config.provenance('COACH_PROVIDER'), 'shell');
    });

    test('config: all six CLI override keys are present in CLI_OVERRIDES (verify via observable behaviour)', () => {
        const allMapped: CliArgs = {
            provider: 'ollama',
            model: 'llama3:8b',
            recordingsDir: '/tmp/rec',
            debounce: '15s',
            onOverflow: 'error',
            systemPrompt: '/tmp/sys.md',
        };
        const config = loadConfig(allMapped, { cwd: tmpCwd });

        const expectations: Array<[ConfigKey, string]> = [
            ['COACH_PROVIDER', 'ollama'],
            ['COACH_MODEL', 'llama3:8b'],
            ['MACREC_RECORDINGS_DIR', '/tmp/rec'],
            ['COACH_DEBOUNCE', '15s'],
            ['COACH_ON_OVERFLOW', 'error'],
            ['COACH_SYSTEM_PROMPT_PATH', '/tmp/sys.md'],
        ];
        for (const [key, expected] of expectations) {
            assert.equal(config.get(key), expected, `expected ${key}=${expected}`);
            assert.equal(config.provenance(key), 'cli', `expected ${key} provenance=cli`);
        }
    });
});

// ---------------------------------------------------------------------------
// 5. Provenance reporting — per tier
// ---------------------------------------------------------------------------

describe('config: provenance reporting', () => {
    let restore: () => void;
    let tmpHome: string;
    let tmpCwd: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        tmpHome = makeTmp('convo-coach-prov-home-');
        tmpCwd = makeTmp('convo-coach-prov-cwd-');
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
        try { fs.rmSync(tmpCwd, { recursive: true, force: true }); } catch { /* noop */ }
    });

    test('config: provenance is undefined when key is not set in any tier', () => {
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.provenance('OPENAI_API_KEY'), undefined);
    });

    test('config: provenance is shell when key is only in process.env', () => {
        process.env['OPENAI_API_KEY'] = 'shell-only';
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.provenance('OPENAI_API_KEY'), 'shell');
    });

    test('config: provenance is tool-env when set in ~/.tool-agents/convo-coach/.env (overrides shell)', () => {
        process.env['OPENAI_API_KEY'] = 'shell-value';

        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(toolAgentsDir, '.env'), 'OPENAI_API_KEY=tool-env-value\n', 'utf8');

        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.provenance('OPENAI_API_KEY'), 'tool-env');
    });

    test('config: provenance is cwd-env when set in local .env (overrides tool-env)', () => {
        process.env['OPENAI_API_KEY'] = 'shell-value';

        const toolAgentsDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        fs.mkdirSync(toolAgentsDir, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(toolAgentsDir, '.env'), 'OPENAI_API_KEY=tool-env-value\n', 'utf8');
        writeDotEnv(tmpCwd, 'OPENAI_API_KEY=cwd-env-value\n');

        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.provenance('OPENAI_API_KEY'), 'cwd-env');
    });

    test('config: provenance is cli when a CLI flag is passed (overrides cwd-env)', () => {
        process.env['COACH_PROVIDER'] = 'openai';
        writeDotEnv(tmpCwd, 'COACH_PROVIDER=anthropic\n');

        const config = loadConfig({ provider: 'google' }, { cwd: tmpCwd });
        assert.equal(config.provenance('COACH_PROVIDER'), 'cli');
        assert.equal(config.get('COACH_PROVIDER'), 'google');
    });

    test('config: alias provenance reflects the tier that set the alias key', () => {
        // Only the alias is set, via shell.
        process.env['GEMINI_API_KEY'] = 'gemini-shell';
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });

        // get('GOOGLE_API_KEY') returns alias value; provenance should be 'shell'
        // (tier that supplied GEMINI_API_KEY).
        assert.equal(config.get('GOOGLE_API_KEY'), 'gemini-shell');
        assert.equal(config.provenance('GOOGLE_API_KEY'), 'shell');
    });

    test('config: alias provenance upgrades to cwd-env when alias is in local .env', () => {
        writeDotEnv(tmpCwd, 'GEMINI_API_KEY=gemini-cwd\n');
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });

        assert.equal(config.get('GOOGLE_API_KEY'), 'gemini-cwd');
        assert.equal(config.provenance('GOOGLE_API_KEY'), 'cwd-env');
    });
});

// ---------------------------------------------------------------------------
// 6. Bootstrap — ~/.tool-agents/convo-coach/ directory creation
// ---------------------------------------------------------------------------

describe('config: bootstrap directory creation', () => {
    let restore: () => void;
    let tmpHome: string;
    let tmpCwd: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        tmpHome = makeTmp('convo-coach-boot-home-');
        tmpCwd = makeTmp('convo-coach-boot-cwd-');
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
        try { fs.rmSync(tmpCwd, { recursive: true, force: true }); } catch { /* noop */ }
    });

    test('config: calling loadConfig creates ~/.tool-agents/convo-coach/ when it does not exist', () => {
        const expectedDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        assert.ok(!fs.existsSync(expectedDir), 'precondition: dir should not exist yet');

        loadConfig(NO_CLI, { cwd: tmpCwd });

        assert.ok(fs.existsSync(expectedDir), 'bootstrap should have created the directory');
        assert.ok(fs.statSync(expectedDir).isDirectory(), 'should be a directory');
    });

    test('config: the bootstrapped directory has mode 0o700', () => {
        loadConfig(NO_CLI, { cwd: tmpCwd });

        const expectedDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        const stat = fs.statSync(expectedDir);
        // stat.mode includes file type bits. Mask to permission bits only.
        const permBits = stat.mode & 0o777;
        assert.equal(
            permBits,
            0o700,
            `expected directory mode 0700, got ${permBits.toString(8)}`,
        );
    });

    test('config: loadConfig is idempotent — calling it twice does not fail or lose the directory', () => {
        loadConfig(NO_CLI, { cwd: tmpCwd });
        loadConfig(NO_CLI, { cwd: tmpCwd }); // second call must not throw

        const expectedDir = path.join(tmpHome, '.tool-agents', 'convo-coach');
        assert.ok(fs.existsSync(expectedDir));
    });

    test('config: the bootstrap does NOT create the .env file (that is seeded out-of-band)', () => {
        loadConfig(NO_CLI, { cwd: tmpCwd });

        const dotEnvPath = path.join(tmpHome, '.tool-agents', 'convo-coach', '.env');
        // Per the design comment: "The .env file inside is NEVER created by this code".
        assert.ok(!fs.existsSync(dotEnvPath), '.env file must NOT be created by loadConfig');
    });
});

// ---------------------------------------------------------------------------
// 7. get() returns undefined for completely unset keys (no-fallback rule)
// ---------------------------------------------------------------------------

describe('config: no-fallback — unset keys return undefined', () => {
    let restore: () => void;
    let tmpHome: string;
    let tmpCwd: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        tmpHome = makeTmp('convo-coach-nf-home-');
        tmpCwd = makeTmp('convo-coach-nf-cwd-');
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
        try { fs.rmSync(tmpCwd, { recursive: true, force: true }); } catch { /* noop */ }
    });

    test('config: get() returns undefined for an unset key — no default is substituted', () => {
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        // These are required for many providers — must NOT have a default.
        assert.equal(config.get('OPENAI_API_KEY'), undefined);
        assert.equal(config.get('ANTHROPIC_API_KEY'), undefined);
        assert.equal(config.get('AZURE_AI_INFERENCE_KEY'), undefined);
        assert.equal(config.get('LITELLM_PROXY_URL'), undefined);
    });

    test('config: get() returns undefined for an unset aliased key when both canonical and alias are absent', () => {
        // Neither GOOGLE_API_KEY nor GEMINI_API_KEY is set.
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('GOOGLE_API_KEY'), undefined);
    });

    test('config: get() returns undefined for COACH_PROVIDER when no CLI and no env set it', () => {
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('COACH_PROVIDER'), undefined);
    });
});

// ---------------------------------------------------------------------------
// 8. cwd opts — cwd defaults to process.cwd() when not supplied
// ---------------------------------------------------------------------------

describe('config: cwd option', () => {
    let restore: () => void;
    let tmpHome: string;
    let tmpCwd: string;
    let origCwd: string;

    beforeEach(() => {
        restore = snapshotEnv();
        clearRecognisedEnv();
        tmpHome = makeTmp('convo-coach-cwdopt-home-');
        tmpCwd = makeTmp('convo-coach-cwdopt-cwd-');
        origCwd = process.cwd();
        process.env['HOME'] = tmpHome;
    });

    afterEach(() => {
        // Restore cwd if it was changed.
        try { process.chdir(origCwd); } catch { /* noop */ }
        restore();
        try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch { /* noop */ }
        try { fs.rmSync(tmpCwd, { recursive: true, force: true }); } catch { /* noop */ }
    });

    test('config: when opts.cwd is provided it is used instead of process.cwd()', () => {
        writeDotEnv(tmpCwd, 'OPENAI_API_KEY=cwd-explicit\n');
        // Ensure process.cwd() does NOT have a .env with this key.
        const config = loadConfig(NO_CLI, { cwd: tmpCwd });
        assert.equal(config.get('OPENAI_API_KEY'), 'cwd-explicit');
        assert.equal(config.provenance('OPENAI_API_KEY'), 'cwd-env');
    });

    test('config: when opts.cwd is omitted, process.cwd() is used to find local .env', () => {
        // Change into tmpCwd and write a .env there.
        writeDotEnv(tmpCwd, 'OPENAI_API_KEY=cwd-implicit\n');
        process.chdir(tmpCwd);

        // Call loadConfig WITHOUT opts.cwd so it falls back to process.cwd().
        const config = loadConfig(NO_CLI);
        assert.equal(config.get('OPENAI_API_KEY'), 'cwd-implicit');
    });
});

// ---------------------------------------------------------------------------
// 9. RECOGNISED_KEYS — meta-test: all alias keys are in the set
// ---------------------------------------------------------------------------

describe('config: RECOGNISED_KEYS completeness', () => {
    test('config: all alias keys (both canonical and alias) are members of RECOGNISED_KEYS', () => {
        // Every key that appears in ALIAS_MAP (both canonical and alias value) must
        // be in RECOGNISED_KEYS, otherwise they would be stripped from env/dotenv reads.
        const aliasEntries: Array<[ConfigKey, ConfigKey]> = Object.entries(ALIAS_MAP) as Array<[ConfigKey, ConfigKey]>;
        for (const [canonical, alias] of aliasEntries) {
            assert.ok(
                RECOGNISED_KEYS.has(canonical),
                `Canonical key '${canonical}' is missing from RECOGNISED_KEYS`,
            );
            assert.ok(
                RECOGNISED_KEYS.has(alias),
                `Alias key '${alias}' is missing from RECOGNISED_KEYS`,
            );
        }
    });

    test('config: RECOGNISED_KEYS contains at least the eight standard provider keys', () => {
        const required: ConfigKey[] = [
            'OPENAI_API_KEY',
            'ANTHROPIC_API_KEY',
            'GOOGLE_API_KEY',
            'AZURE_OPENAI_API_KEY',
            'AZURE_AI_INFERENCE_KEY',
            'OLLAMA_HOST',
            'LITELLM_PROXY_URL',
            'LITELLM_MASTER_KEY',
        ];
        for (const k of required) {
            assert.ok(RECOGNISED_KEYS.has(k), `Missing required provider key: ${k}`);
        }
    });
});
