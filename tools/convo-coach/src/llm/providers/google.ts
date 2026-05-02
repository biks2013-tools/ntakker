// src/llm/providers/google.ts — Google Gemini provider module (LangChain).
//
// Required env: GOOGLE_API_KEY (GEMINI_API_KEY alias resolved by config layer).
// Default model: gemini-2.5-flash

import { ChatGoogleGenerativeAI } from '@langchain/google-genai';

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

        const modelId = resolveModel('google', modelOverride, config);

        return new ChatGoogleGenerativeAI({
            apiKey,
            model: modelId,
        });
    },
};

export default googleProvider;
