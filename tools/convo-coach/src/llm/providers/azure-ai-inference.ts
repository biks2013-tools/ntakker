// src/llm/providers/azure-ai-inference.ts — Azure AI Inference (Foundry).
//
// Required env:
//   AZURE_AI_INFERENCE_KEY        (alias: ANTHROPIC_FOUNDRY_API_KEY)
//   AZURE_AI_INFERENCE_ENDPOINT   (alias: ANTHROPIC_FOUNDRY_ENDPOINT)
//
// Routed through @ai-sdk/openai-compatible against Foundry's
// `/openai/v1` endpoint (GA since Aug 2025; the older `/models` endpoint
// retires Aug 26, 2026). See sdk research §2.2.
//
// No static default model — the user must pass --model.

import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

/**
 * Append the Foundry OpenAI-compatible suffix `/openai/v1` if the
 * endpoint does not already end with it (or with a bare `/v1`). Trailing
 * slashes are stripped.
 */
function normaliseFoundryBaseUrl(endpoint: string): string {
    let url = endpoint.trim().replace(/\/+$/, '');
    if (/\/openai\/v1$/.test(url)) return url;
    if (/\/v1$/.test(url)) return url;
    return `${url}/openai/v1`;
}

export const azureAiInferenceProvider: LlmProviderModule = {
    name: 'azure-ai-inference',
    defaultModel: null,
    create({ config, modelOverride }): LanguageModel {
        const apiKey = config.get('AZURE_AI_INFERENCE_KEY');
        if (apiKey === undefined || apiKey.length === 0) {
            throw new ConfigError(
                "Provider 'azure-ai-inference' requires AZURE_AI_INFERENCE_KEY " +
                '(or its ANTHROPIC_FOUNDRY_API_KEY alias). Set it in the environment, ' +
                '~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const endpoint = config.get('AZURE_AI_INFERENCE_ENDPOINT');
        if (endpoint === undefined || endpoint.length === 0) {
            throw new ConfigError(
                "Provider 'azure-ai-inference' requires AZURE_AI_INFERENCE_ENDPOINT " +
                '(or its ANTHROPIC_FOUNDRY_ENDPOINT alias). Set it in the environment, ' +
                '~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const baseURL = normaliseFoundryBaseUrl(endpoint);

        const provider = createOpenAICompatible({
            name: 'azure-ai-inference',
            baseURL,
            apiKey,
            includeUsage: true,
        });

        const modelId = resolveModel('azure-ai-inference', modelOverride, config);
        return provider.languageModel(modelId);
    },
};

export default azureAiInferenceProvider;
