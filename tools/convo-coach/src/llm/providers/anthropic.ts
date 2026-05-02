// src/llm/providers/anthropic.ts — Anthropic provider module.
//
// Required env: ANTHROPIC_API_KEY
// Optional env: ANTHROPIC_BASE_URL
// Default model: claude-haiku-4-5-20251001  (versioned id per sdk research §4)

import { createAnthropic } from '@ai-sdk/anthropic';

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

        const provider = createAnthropic({
            apiKey,
            ...(baseURL !== undefined && baseURL.length > 0 ? { baseURL } : {}),
        });

        const modelId = resolveModel('anthropic', modelOverride, config);
        return provider(modelId);
    },
};

export default anthropicProvider;
