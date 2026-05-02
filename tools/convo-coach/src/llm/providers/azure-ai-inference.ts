// src/llm/providers/azure-ai-inference.ts — Azure AI Inference (Foundry).
//
// Required env:
//   AZURE_AI_INFERENCE_KEY        (alias: ANTHROPIC_FOUNDRY_API_KEY)
//   AZURE_AI_INFERENCE_ENDPOINT   (alias: ANTHROPIC_FOUNDRY_ENDPOINT)
//
// Routed through LangChain's ChatOpenAI against Foundry's `/openai/v1`
// OpenAI-compatible endpoint (GA since Aug 2025).
//
// No static default model — the user must pass --model.

import { ChatOpenAI } from '@langchain/openai';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

/**
 * Append the Foundry OpenAI-compatible suffix `/openai/v1` if the
 * endpoint does not already end with it (or with a bare `/v1`). Trailing
 * slashes are stripped.
 */
export function normaliseFoundryBaseUrl(endpoint: string): string {
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
        const modelId = resolveModel('azure-ai-inference', modelOverride, config);

        return new ChatOpenAI({
            apiKey,
            model: modelId,
            configuration: { baseURL },
            streamUsage: true,
        });
    },
};

export default azureAiInferenceProvider;
