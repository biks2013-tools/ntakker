// src/llm/providers/litellm.ts — LiteLLM proxy via @ai-sdk/openai-compatible.
//
// Required env: LITELLM_PROXY_URL (alias: LITELLM_API_BASE).
// Optional env: LITELLM_MASTER_KEY (alias: LITELLM_API_KEY) — some
//               LiteLLM proxies are deployed without auth; pass empty
//               string in that case.
//
// No static default model — LiteLLM's whole point is multi-provider
// routing, so the user must pass --model. See sdk research §3.3.

import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

export const litellmProvider: LlmProviderModule = {
    name: 'litellm',
    defaultModel: null,
    create({ config, modelOverride }): LanguageModel {
        const proxyUrlRaw = config.get('LITELLM_PROXY_URL');
        if (proxyUrlRaw === undefined || proxyUrlRaw.length === 0) {
            throw new ConfigError(
                "Provider 'litellm' requires LITELLM_PROXY_URL " +
                '(or its LITELLM_API_BASE alias). Set it in the environment, ' +
                '~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }
        const baseURL = proxyUrlRaw.trim().replace(/\/+$/, '');

        // Master key is optional; some LiteLLM proxies tolerate an empty
        // bearer (no-auth deployments). The SDK requires the field; pass
        // '' if absent.
        const masterKey = config.get('LITELLM_MASTER_KEY') ?? '';

        const provider = createOpenAICompatible({
            name: 'litellm',
            baseURL,
            apiKey: masterKey,
            includeUsage: true,
        });

        const modelId = resolveModel('litellm', modelOverride, config);
        return provider.languageModel(modelId);
    },
};

export default litellmProvider;
