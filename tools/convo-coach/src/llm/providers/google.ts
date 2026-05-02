// src/llm/providers/google.ts — Google Gemini provider module.
//
// Required env: GOOGLE_API_KEY (GEMINI_API_KEY alias is resolved by config layer).
// Default model: gemini-2.5-flash  (per sdk research §4)

import { createGoogleGenerativeAI } from '@ai-sdk/google';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

export const googleProvider: LlmProviderModule = {
    name: 'google',
    defaultModel: 'gemini-2.5-flash',
    create({ config, modelOverride }): LanguageModel {
        const apiKey = config.get('GOOGLE_API_KEY');
        if (apiKey === undefined || apiKey.length === 0) {
            throw new ConfigError(
                "Provider 'google' requires GOOGLE_API_KEY (or its GEMINI_API_KEY alias). " +
                'Set it in the environment, ~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const provider = createGoogleGenerativeAI({ apiKey });

        const modelId = resolveModel('google', modelOverride, config);
        return provider(modelId);
    },
};

export default googleProvider;
