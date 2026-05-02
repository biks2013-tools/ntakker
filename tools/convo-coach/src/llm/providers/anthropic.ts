// src/llm/providers/anthropic.ts — Direct Anthropic provider module (LangChain).
//
// Required env: ANTHROPIC_API_KEY
// Optional env: ANTHROPIC_BASE_URL
// Default model: claude-haiku-4-5-20251001

import { ChatAnthropic } from '@langchain/anthropic';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

export const anthropicProvider: LlmProviderModule = {
    name: 'anthropic',
    defaultModel: 'claude-haiku-4-5-20251001',
    create({ config, modelOverride }): LanguageModel {
        const apiKey = config.get('ANTHROPIC_API_KEY');
        if (apiKey === undefined || apiKey.length === 0) {
            throw new ConfigError(
                "Provider 'anthropic' requires ANTHROPIC_API_KEY. Set it in the environment, " +
                '~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const baseURL = config.get('ANTHROPIC_BASE_URL');
        const modelId = resolveModel('anthropic', modelOverride, config);

        return new ChatAnthropic({
            apiKey,
            model: modelId,
            ...(baseURL && baseURL.length > 0
                ? { clientOptions: { baseURL } }
                : {}),
        });
    },
};

export default anthropicProvider;
