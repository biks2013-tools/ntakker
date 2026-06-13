// src/llm/default-models.ts — per-provider default model IDs and resolver.
//
// The defaults below are verified against
// docs/research/vercel-ai-sdk-v5-multiprovider.md §4 (Default Model IDs,
// 2026-05). Providers whose effective model is determined by user
// configuration (azure-openai's deployment) or by proxy-side routing
// (litellm, mlx) intentionally have no default and require an explicit
// `--model` / `COACH_MODEL` value.

import { ConfigError, type ProviderName, type ResolvedConfig } from '../types.js';

/**
 * Default model id per provider. `null` means "no default; user must
 * supply --model (or COACH_MODEL)". For `azure-openai` the default is
 * also `null` here; `resolveModel` substitutes `AZURE_OPENAI_DEPLOYMENT`
 * at runtime.
 */
export const DEFAULT_MODELS: Readonly<Record<ProviderName, string | null>> = Object.freeze({
    'openai':              'gpt-4o-mini',
    'anthropic':           'claude-haiku-4-5-20251001',
    'google':              'gemini-2.5-flash',
    'azure-openai':        null,
    'azure-ai-inference':  null,
    'ollama':              'llama3.1:8b',
    'litellm':             null,
    'mlx':                 null,
});

/**
 * Resolve the effective model id for a provider, in priority order:
 *   1. explicit `modelOverride` (CLI `--model`).
 *   2. `COACH_MODEL` from the resolved config.
 *   3. for `azure-openai`: `AZURE_OPENAI_DEPLOYMENT`.
 *   4. the provider's static default model id.
 *
 * Throws `ConfigError` (exit 78) if no value is found.
 */
export function resolveModel(
    provider: ProviderName,
    modelOverride: string | undefined,
    config: ResolvedConfig,
): string {
    if (modelOverride !== undefined && modelOverride.length > 0) {
        return modelOverride;
    }

    const coachModel = config.get('COACH_MODEL');
    if (coachModel !== undefined && coachModel.length > 0) {
        return coachModel;
    }

    if (provider === 'azure-openai') {
        const deployment = config.get('AZURE_OPENAI_DEPLOYMENT');
        if (deployment !== undefined && deployment.length > 0) {
            return deployment;
        }
        throw new ConfigError(
            "Provider 'azure-openai' requires a model. Pass --model <deployment>, " +
            'set COACH_MODEL, or set AZURE_OPENAI_DEPLOYMENT in the environment, ' +
            '~/.tool-agents/convo-coach/.env, or ./.env.',
        );
    }

    const fallback = DEFAULT_MODELS[provider];
    if (fallback !== null) {
        return fallback;
    }

    throw new ConfigError(
        `Provider '${provider}' has no default model. Pass --model <id> or set ` +
        'COACH_MODEL in the environment, ~/.tool-agents/convo-coach/.env, or ./.env.',
    );
}
