// src/llm/factory.ts — provider selection + LanguageModel construction.
//
// Owns:
//   * the static map ProviderName → LlmProviderModule (PROVIDERS).
//   * resolveProviderName: CLI arg → COACH_PROVIDER → 'azure-openai' default
//     (per Project Memory Exception 003 in CLAUDE.md).
//   * buildLanguageModel: full pipeline producing the value the
//     orchestrator hands to streamText, plus the provider/model labels
//     for the sidecar metrics block.
//
// Per CC-ADR-13: ONE agent owns this file plus the eight provider files.

import {
    ConfigError,
    PROVIDER_NAMES,
    ProviderError,
    type LanguageModel,
    type ProviderName,
    type ResolvedConfig,
    type LlmProviderModule,
} from '../types.js';

import { resolveModel } from './default-models.js';

/**
 * Provider registry: one lazy loader per canonical ProviderName.
 *
 * EVAL-2026-10-16 CC-11 (plan-023 T5): the registry used to import all
 * eight provider modules — and with them every LangChain SDK — at
 * startup, which made even `--help` pay ~100 ms. Each module is now
 * imported only when its provider is selected.
 */
export const PROVIDER_LOADERS: Readonly<Record<ProviderName, () => Promise<LlmProviderModule>>> = Object.freeze({
    'openai':              async () => (await import('./providers/openai.js')).openaiProvider,
    'anthropic':           async () => (await import('./providers/anthropic.js')).anthropicProvider,
    'google':              async () => (await import('./providers/google.js')).googleProvider,
    'azure-openai':        async () => (await import('./providers/azure-openai.js')).azureOpenaiProvider,
    'azure-ai-inference':  async () => (await import('./providers/azure-ai-inference.js')).azureAiInferenceProvider,
    'ollama':              async () => (await import('./providers/ollama.js')).ollamaProvider,
    'litellm':             async () => (await import('./providers/litellm.js')).litellmProvider,
    'mlx':                 async () => (await import('./providers/mlx.js')).mlxProvider,
});

/** Load the provider module for `name`. */
export function loadProvider(name: ProviderName): Promise<LlmProviderModule> {
    return PROVIDER_LOADERS[name]();
}

/** Type-narrowing helper: is this string one of the known providers? */
function isProviderName(value: string): value is ProviderName {
    return (PROVIDER_NAMES as readonly string[]).includes(value);
}

/**
 * Resolve which provider to use, in priority order:
 *   1. explicit CLI `--provider <name>` (already typed).
 *   2. `COACH_PROVIDER` env var (validated against the 8 known names;
 *      throws `ConfigError` if set to an unknown value).
 *   3. fallback to `'azure-openai'` per Exception 003. NOT a silent
 *      default — the exception is documented in CLAUDE.md.
 */
export function resolveProviderName(
    config: ResolvedConfig,
    cliProvider: ProviderName | undefined,
): ProviderName {
    if (cliProvider !== undefined) {
        return cliProvider;
    }

    const envValue = config.get('COACH_PROVIDER');
    if (envValue !== undefined && envValue.length > 0) {
        if (!isProviderName(envValue)) {
            throw new ConfigError(
                `COACH_PROVIDER='${envValue}' is not a recognised provider. ` +
                `Expected one of: ${PROVIDER_NAMES.join(', ')}.`,
            );
        }
        return envValue;
    }

    // Project Memory Exception 003 — convo-coach defaults to azure-openai.
    return 'azure-openai';
}

export interface BuildLanguageModelResult {
    readonly model: LanguageModel;
    readonly provider: ProviderName;
    readonly modelId: string;
}

/**
 * End-to-end: pick a provider, instantiate its LanguageModel, return both
 * the model and the labels needed for the sidecar metrics block.
 *
 * Errors thrown by a provider's `create()` (network setup, missing
 * credentials surfaced via ConfigError, malformed URLs, etc.) are
 * re-wrapped in `ProviderError` (exit 70) UNLESS they are themselves
 * `ConfigError`s (exit 78), which we re-throw verbatim.
 */
export async function buildLanguageModel(
    config: ResolvedConfig,
    cliProvider: ProviderName | undefined,
    modelOverride: string | undefined,
): Promise<BuildLanguageModelResult> {
    const providerName = resolveProviderName(config, cliProvider);
    const providerModule = await loadProvider(providerName);

    let model: LanguageModel;
    try {
        model = providerModule.create({ config, modelOverride });
    } catch (err) {
        // Preserve typed ConfigError exit-code mapping.
        if (err instanceof ConfigError) throw err;
        const message = err instanceof Error ? err.message : String(err);
        throw new ProviderError(
            `Failed to initialize provider '${providerName}': ${message}`,
        );
    }

    // Re-resolve the model id so the sidecar's metrics block records the
    // exact same string that the SDK is using. resolveModel is pure.
    const modelId = resolveModel(providerName, modelOverride, config);

    return { model, provider: providerName, modelId };
}
