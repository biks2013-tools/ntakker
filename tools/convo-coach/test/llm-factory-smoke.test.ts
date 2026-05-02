// test/llm-factory-smoke.test.ts — smoke tests for U6 (LLM provider factory).
//
// Run via `npx tsx --test test/llm-factory-smoke.test.ts` from tools/convo-coach.
//
// These tests use a hand-rolled ResolvedConfig stub backed by a Map. No real
// network calls are made — each provider's `create()` is exercised with the
// minimum credentials required to satisfy its ConfigError guards. The
// returned LanguageModel is asserted to be a non-null value (the SDK
// returns either a function or an object with a .doStream method depending
// on the provider; we only assert it is defined).

import { strict as assert } from 'node:assert';
import test from 'node:test';

import {
    ConfigError,
    PROVIDER_NAMES,
    type ConfigKey,
    type ProvenanceTier,
    type ProviderName,
    type ResolvedConfig,
} from '../src/types.js';

import { resolveModel, DEFAULT_MODELS } from '../src/llm/default-models.js';
import {
    PROVIDERS,
    buildLanguageModel,
    resolveProviderName,
} from '../src/llm/factory.js';

// ---------------------------------------------------------------------------
// Stub ResolvedConfig
// ---------------------------------------------------------------------------

function makeConfig(values: Partial<Record<ConfigKey, string>>): ResolvedConfig {
    const map = new Map<ConfigKey, string>(
        Object.entries(values).filter(([, v]) => v !== undefined) as [ConfigKey, string][],
    );
    return {
        get(key: ConfigKey): string | undefined {
            return map.get(key);
        },
        provenance(key: ConfigKey): ProvenanceTier | undefined {
            return map.has(key) ? 'shell' : undefined;
        },
    };
}

// ---------------------------------------------------------------------------
// resolveProviderName
// ---------------------------------------------------------------------------

test('resolveProviderName: explicit CLI arg wins over env and default', () => {
    const cfg = makeConfig({ COACH_PROVIDER: 'openai' });
    assert.equal(resolveProviderName(cfg, 'anthropic'), 'anthropic');
});

test('resolveProviderName: COACH_PROVIDER used when no CLI arg', () => {
    const cfg = makeConfig({ COACH_PROVIDER: 'google' });
    assert.equal(resolveProviderName(cfg, undefined), 'google');
});

test('resolveProviderName: defaults to azure-openai when nothing set (Exception 003)', () => {
    const cfg = makeConfig({});
    assert.equal(resolveProviderName(cfg, undefined), 'azure-openai');
});

test('resolveProviderName: throws ConfigError for unknown COACH_PROVIDER', () => {
    const cfg = makeConfig({ COACH_PROVIDER: 'gpt-9-turbo' });
    assert.throws(
        () => resolveProviderName(cfg, undefined),
        (err: unknown) => err instanceof ConfigError && /not a recognised provider/.test((err as Error).message),
    );
});

// ---------------------------------------------------------------------------
// resolveModel
// ---------------------------------------------------------------------------

test('resolveModel: modelOverride wins over everything', () => {
    const cfg = makeConfig({ COACH_MODEL: 'env-model' });
    assert.equal(resolveModel('openai', 'cli-model', cfg), 'cli-model');
});

test('resolveModel: COACH_MODEL used when no override', () => {
    const cfg = makeConfig({ COACH_MODEL: 'env-model' });
    assert.equal(resolveModel('openai', undefined, cfg), 'env-model');
});

test('resolveModel: provider default used when nothing else set', () => {
    const cfg = makeConfig({});
    assert.equal(resolveModel('openai', undefined, cfg), 'gpt-4o-mini');
    assert.equal(resolveModel('anthropic', undefined, cfg), 'claude-haiku-4-5-20251001');
    assert.equal(resolveModel('google', undefined, cfg), 'gemini-2.5-flash');
    assert.equal(resolveModel('ollama', undefined, cfg), 'llama3.1:8b');
});

test('resolveModel: azure-openai falls back to AZURE_OPENAI_DEPLOYMENT', () => {
    const cfg = makeConfig({ AZURE_OPENAI_DEPLOYMENT: 'my-gpt4o-deployment' });
    assert.equal(resolveModel('azure-openai', undefined, cfg), 'my-gpt4o-deployment');
});

test('resolveModel: azure-openai with no deployment throws ConfigError', () => {
    const cfg = makeConfig({});
    assert.throws(
        () => resolveModel('azure-openai', undefined, cfg),
        (err: unknown) => err instanceof ConfigError,
    );
});

test('resolveModel: providers with null default throw ConfigError when nothing set', () => {
    const cfg = makeConfig({});
    for (const p of ['litellm', 'mlx', 'azure-ai-inference'] as const) {
        assert.throws(
            () => resolveModel(p, undefined, cfg),
            (err: unknown) => err instanceof ConfigError,
            `expected ConfigError for ${p}`,
        );
    }
});

// ---------------------------------------------------------------------------
// DEFAULT_MODELS table sanity
// ---------------------------------------------------------------------------

test('DEFAULT_MODELS covers every ProviderName exactly once', () => {
    const keys = Object.keys(DEFAULT_MODELS).sort();
    const expected = [...PROVIDER_NAMES].sort();
    assert.deepEqual(keys, expected);
});

// ---------------------------------------------------------------------------
// PROVIDERS registry sanity
// ---------------------------------------------------------------------------

test('PROVIDERS registry: every provider module declares its own name', () => {
    for (const name of PROVIDER_NAMES) {
        const mod = PROVIDERS[name];
        assert.ok(mod, `missing provider module for ${name}`);
        assert.equal(mod.name, name, `provider module name mismatch for ${name}`);
    }
});

// ---------------------------------------------------------------------------
// buildLanguageModel — per-provider construction
// ---------------------------------------------------------------------------

interface ProviderFixture {
    readonly provider: ProviderName;
    readonly cfg: Partial<Record<ConfigKey, string>>;
    readonly modelOverride?: string;
    readonly expectedModelId: string;
}

const FIXTURES: readonly ProviderFixture[] = [
    {
        provider: 'openai',
        cfg: { OPENAI_API_KEY: 'sk-test-openai' },
        expectedModelId: 'gpt-4o-mini',
    },
    {
        provider: 'anthropic',
        cfg: { ANTHROPIC_API_KEY: 'sk-test-anthropic' },
        expectedModelId: 'claude-haiku-4-5-20251001',
    },
    {
        provider: 'google',
        cfg: { GOOGLE_API_KEY: 'sk-test-google' },
        expectedModelId: 'gemini-2.5-flash',
    },
    {
        provider: 'azure-openai',
        cfg: {
            AZURE_OPENAI_API_KEY: 'sk-test-azure',
            AZURE_OPENAI_ENDPOINT: 'https://my-res.openai.azure.com',
            AZURE_OPENAI_API_VERSION: '2024-10-21',
            AZURE_OPENAI_DEPLOYMENT: 'gpt-4o-deploy',
        },
        expectedModelId: 'gpt-4o-deploy',
    },
    {
        provider: 'azure-ai-inference',
        cfg: {
            AZURE_AI_INFERENCE_KEY: 'sk-test-foundry',
            AZURE_AI_INFERENCE_ENDPOINT: 'https://my-res.services.ai.azure.com',
        },
        modelOverride: 'claude-haiku-4-5',
        expectedModelId: 'claude-haiku-4-5',
    },
    {
        provider: 'ollama',
        // No env at all → should still build via the documented default host.
        cfg: {},
        expectedModelId: 'llama3.1:8b',
    },
    {
        provider: 'litellm',
        cfg: {
            LITELLM_PROXY_URL: 'http://localhost:4000',
            LITELLM_MASTER_KEY: 'sk-litellm',
        },
        modelOverride: 'gpt-4o',
        expectedModelId: 'gpt-4o',
    },
    {
        provider: 'mlx',
        cfg: {
            OPENAI_BASE_URL: 'http://127.0.0.1:8080/v1',
        },
        modelOverride: 'mlx-community/Llama-3.2-3B-Instruct-4bit',
        expectedModelId: 'mlx-community/Llama-3.2-3B-Instruct-4bit',
    },
];

for (const fx of FIXTURES) {
    test(`buildLanguageModel(${fx.provider}) returns a model + correct labels`, () => {
        const cfg = makeConfig(fx.cfg);
        const result = buildLanguageModel(cfg, fx.provider, fx.modelOverride);
        assert.equal(result.provider, fx.provider, 'provider label');
        assert.equal(result.modelId, fx.expectedModelId, 'modelId label');
        assert.ok(result.model !== undefined && result.model !== null, 'model defined');
        // SDK returns either a callable function or an object — both
        // are valid LanguageModel shapes.
        const t = typeof result.model;
        assert.ok(t === 'function' || t === 'object', `unexpected model typeof: ${t}`);
    });
}

// ---------------------------------------------------------------------------
// buildLanguageModel — error mapping
// ---------------------------------------------------------------------------

test('buildLanguageModel: ConfigError from a provider passes through (exit 78)', () => {
    // openai with no API key → provider raises ConfigError → factory re-throws.
    const cfg = makeConfig({});
    assert.throws(
        () => buildLanguageModel(cfg, 'openai', undefined),
        (err: unknown) => err instanceof ConfigError && /OPENAI_API_KEY/.test((err as Error).message),
    );
});

test('buildLanguageModel: azure-openai missing endpoint raises ConfigError', () => {
    const cfg = makeConfig({
        AZURE_OPENAI_API_KEY: 'sk-test',
        AZURE_OPENAI_API_VERSION: '2024-10-21',
        AZURE_OPENAI_DEPLOYMENT: 'depl',
    });
    assert.throws(
        () => buildLanguageModel(cfg, 'azure-openai', undefined),
        (err: unknown) => err instanceof ConfigError && /AZURE_OPENAI_ENDPOINT/.test((err as Error).message),
    );
});

test('buildLanguageModel: azure-openai builds without AZURE_OPENAI_API_VERSION (v1 GA default)', () => {
    // The v1 GA endpoint /openai/v1/... does not require a dated api-version.
    // Confirm the provider builds cleanly when AZURE_OPENAI_API_VERSION is unset
    // (the SDK falls back to its built-in 'v1' default). See provider source for
    // the rationale.
    const cfg = makeConfig({
        AZURE_OPENAI_API_KEY: 'sk-test',
        AZURE_OPENAI_ENDPOINT: 'https://my-res.openai.azure.com',
        AZURE_OPENAI_DEPLOYMENT: 'gpt-5.1',
        // AZURE_OPENAI_API_VERSION intentionally omitted.
    });
    const result = buildLanguageModel(cfg, 'azure-openai', undefined);
    assert.equal(result.provider, 'azure-openai');
    assert.equal(result.modelId, 'gpt-5.1');
    assert.ok(result.model !== undefined && result.model !== null);
});
