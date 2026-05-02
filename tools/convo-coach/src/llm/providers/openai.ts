// src/llm/providers/openai.ts — OpenAI provider module.
//
// Required env: OPENAI_API_KEY
// Optional env: OPENAI_BASE_URL, OPENAI_ORG_ID
// Default model: gpt-4o-mini  (per docs/research/vercel-ai-sdk-v5-multiprovider.md §4)

import { createOpenAI } from '@ai-sdk/openai';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

export const openaiProvider: LlmProviderModule = {
    name: 'openai',
    defaultModel: 'gpt-4o-mini',
    create({ config, modelOverride }): LanguageModel {
        const apiKey = config.get('OPENAI_API_KEY');
        if (apiKey === undefined || apiKey.length === 0) {
            throw new ConfigError(
                "Provider 'openai' requires OPENAI_API_KEY. Set it in the environment, " +
                '~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const baseURL = config.get('OPENAI_BASE_URL');
        const organization = config.get('OPENAI_ORG_ID');

        const provider = createOpenAI({
            apiKey,
            ...(baseURL !== undefined && baseURL.length > 0 ? { baseURL } : {}),
            ...(organization !== undefined && organization.length > 0 ? { organization } : {}),
        });

        const modelId = resolveModel('openai', modelOverride, config);
        return provider(modelId);
    },
};

export default openaiProvider;
