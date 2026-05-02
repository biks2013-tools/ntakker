// src/config.ts — four-tier configuration resolver.
//
// Resolution chain (lowest → highest priority):
//   1. process.env                              ('shell')
//   2. ~/.tool-agents/convo-coach/.env          ('tool-env')
//   3. <cwd>/.env                               ('cwd-env')
//   4. CLI flag overrides                       ('cli')
//
// Each tier writes into an internal map keyed by ConfigKey; later tiers
// overwrite earlier tiers and update the provenance record. Per the
// project no-fallback rule, no tier substitutes a default value when a
// key is unset — the resolver returns `undefined` and downstream code
// must raise the appropriate exception.
//
// Bootstrap: `~/.tool-agents/convo-coach/` is created with mode 0700 if
// it does not already exist. The `.env` file inside is NEVER created
// by this code; it is seeded out-of-band by `/tool-conventions scaffold`.
//
// Aliases (read-only — they only fill the canonical slot when the
// canonical key is unset):
//   AZURE_AI_INFERENCE_KEY      ← ANTHROPIC_FOUNDRY_API_KEY
//   AZURE_AI_INFERENCE_ENDPOINT ← ANTHROPIC_FOUNDRY_ENDPOINT
//   LITELLM_PROXY_URL           ← LITELLM_API_BASE
//   LITELLM_MASTER_KEY          ← LITELLM_API_KEY
//   GOOGLE_API_KEY              ← GEMINI_API_KEY

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

import type {
    CliArgs,
    ConfigKey,
    ProvenanceTier,
    ResolvedConfig,
} from './types.js';

const TOOL_NAME = 'convo-coach';

/** Aliases: canonical key → alias key. The alias is consulted only when
 *  no tier has set the canonical key. */
const ALIAS_MAP: Readonly<Partial<Record<ConfigKey, ConfigKey>>> = Object.freeze({
    AZURE_AI_INFERENCE_KEY: 'ANTHROPIC_FOUNDRY_API_KEY',
    AZURE_AI_INFERENCE_ENDPOINT: 'ANTHROPIC_FOUNDRY_ENDPOINT',
    LITELLM_PROXY_URL: 'LITELLM_API_BASE',
    LITELLM_MASTER_KEY: 'LITELLM_API_KEY',
    GOOGLE_API_KEY: 'GEMINI_API_KEY',
});

/** Map CLI args → ConfigKey slots they override. */
const CLI_OVERRIDES: ReadonlyArray<readonly [keyof CliArgs, ConfigKey]> = Object.freeze([
    ['provider', 'COACH_PROVIDER'],
    ['model', 'COACH_MODEL'],
    ['recordingsDir', 'MACREC_RECORDINGS_DIR'],
    ['debounce', 'COACH_DEBOUNCE'],
    ['onOverflow', 'COACH_ON_OVERFLOW'],
    ['systemPrompt', 'COACH_SYSTEM_PROMPT_PATH'],
] as const);

/**
 * Recognised env keys (every member of the ConfigKey union). Used to
 * filter shell env / .env files down to keys this tool actually reads.
 */
const RECOGNISED_KEYS: ReadonlySet<ConfigKey> = new Set<ConfigKey>([
    'COACH_PROVIDER',
    'COACH_MODEL',
    'MACREC_RECORDINGS_DIR',
    'COACH_DEBOUNCE',
    'COACH_ON_OVERFLOW',
    'COACH_SYSTEM_PROMPT_PATH',
    'OPENAI_API_KEY',
    'OPENAI_BASE_URL',
    'OPENAI_ORG_ID',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_BASE_URL',
    'GOOGLE_API_KEY',
    'GEMINI_API_KEY',
    'AZURE_OPENAI_API_KEY',
    'AZURE_OPENAI_ENDPOINT',
    'AZURE_OPENAI_DEPLOYMENT',
    'AZURE_OPENAI_API_VERSION',
    'AZURE_AI_INFERENCE_KEY',
    'AZURE_AI_INFERENCE_ENDPOINT',
    'ANTHROPIC_FOUNDRY_API_KEY',
    'ANTHROPIC_FOUNDRY_ENDPOINT',
    'OLLAMA_HOST',
    'LITELLM_PROXY_URL',
    'LITELLM_MASTER_KEY',
    'LITELLM_API_BASE',
    'LITELLM_API_KEY',
]);

/**
 * Hand-rolled `.env` parser — handles `KEY=value` lines, optional
 * surrounding whitespace, optional surrounding single or double quotes,
 * full-line `#` comments, and blank lines. Variable-reference expansion
 * (`$FOO`) is NOT supported.
 */
function parseDotEnv(text: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (line.length === 0 || line.startsWith('#')) continue;
        const eq = line.indexOf('=');
        if (eq === -1) continue;
        const key = line.slice(0, eq).trim();
        let value = line.slice(eq + 1).trim();
        // Strip a single matching pair of surrounding quotes.
        if (value.length >= 2) {
            const first = value[0];
            const last = value[value.length - 1];
            if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
                value = value.slice(1, -1);
            }
        }
        if (key.length > 0) out[key] = value;
    }
    return out;
}

function tryReadDotEnv(path: string): Record<string, string> {
    if (!existsSync(path)) return {};
    try {
        return parseDotEnv(readFileSync(path, 'utf8'));
    } catch {
        // Best effort — an unreadable .env file is treated as "tier
        // contributes nothing".
        return {};
    }
}

/**
 * Best-effort: ensure `~/.tool-agents/convo-coach/` exists with mode
 * 0700. The .env file inside is NOT created by this code — its absence
 * just means tier 2 contributes nothing to the resolved config. Failure
 * is silently ignored (a permissions error here just disables tier 2).
 */
function bootstrapToolAgentsDir(): void {
    const dir = join(homedir(), '.tool-agents', TOOL_NAME);
    try {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
    } catch {
        // intentionally swallowed
    }
}

interface LoadConfigOptions {
    /** Working directory used to resolve `<cwd>/.env`. Defaults to
     *  `process.cwd()`. Exposed for testing. */
    readonly cwd?: string;
}

/**
 * Walk the four-tier chain and return a `ResolvedConfig` whose `get()`
 * method transparently resolves documented aliases.
 */
export function loadConfig(cliArgs: CliArgs, opts: LoadConfigOptions = {}): ResolvedConfig {
    bootstrapToolAgentsDir();

    const cwd = opts.cwd ?? process.cwd();

    const values = new Map<ConfigKey, string>();
    const provenance = new Map<ConfigKey, ProvenanceTier>();

    const applyTier = (
        source: Readonly<Record<string, string | undefined>>,
        tier: ProvenanceTier,
    ): void => {
        for (const key of RECOGNISED_KEYS) {
            const raw = source[key];
            if (raw === undefined) continue;
            if (raw === '') {
                // Explicit empty value at this tier acts as an "unset"
                // override — it clears anything contributed by a lower
                // tier (e.g. uncommenting `KEY=` in ~/.tool-agents/<tool>/.env
                // wipes the shell's exported value) but does NOT itself
                // contribute a value, so a tier-1 empty alone leaves the
                // key undefined.
                values.delete(key);
                provenance.delete(key);
                continue;
            }
            values.set(key, raw);
            provenance.set(key, tier);
        }
    };

    // Tier 1 — shell environment.
    applyTier(process.env as Readonly<Record<string, string | undefined>>, 'shell');

    // Tier 2 — ~/.tool-agents/convo-coach/.env
    const toolEnvPath = join(homedir(), '.tool-agents', TOOL_NAME, '.env');
    applyTier(tryReadDotEnv(toolEnvPath), 'tool-env');

    // Tier 3 — <cwd>/.env
    const cwdEnvPath = resolve(cwd, '.env');
    applyTier(tryReadDotEnv(cwdEnvPath), 'cwd-env');

    // Tier 4 — CLI flag overrides.
    for (const [argKey, configKey] of CLI_OVERRIDES) {
        const raw = cliArgs[argKey];
        if (typeof raw === 'string' && raw.length > 0) {
            values.set(configKey, raw);
            provenance.set(configKey, 'cli');
        }
    }

    const get = (key: ConfigKey): string | undefined => {
        const direct = values.get(key);
        if (direct !== undefined) return direct;
        const aliasKey = ALIAS_MAP[key];
        if (aliasKey === undefined) return undefined;
        return values.get(aliasKey);
    };

    const provenanceOf = (key: ConfigKey): ProvenanceTier | undefined => {
        const direct = provenance.get(key);
        if (direct !== undefined) return direct;
        const aliasKey = ALIAS_MAP[key];
        if (aliasKey === undefined) return undefined;
        return provenance.get(aliasKey);
    };

    return {
        get,
        provenance: provenanceOf,
    };
}

// Test-only export — internal helpers exposed so unit tests can verify
// the dotenv parser without touching disk.
export const __test = Object.freeze({
    parseDotEnv,
    ALIAS_MAP,
    RECOGNISED_KEYS,
});
