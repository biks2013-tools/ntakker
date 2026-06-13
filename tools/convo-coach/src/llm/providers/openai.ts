// src/llm/providers/openai.ts — Direct OpenAI provider module (LangChain).
//
// Required env: OPENAI_API_KEY
// Optional env: OPENAI_BASE_URL, OPENAI_ORG_ID
// Default model: gpt-4o-mini

import { ChatOpenAI } from '@langchain/openai';

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
        const modelId = resolveModel('openai', modelOverride, config);

        const configuration: { baseURL?: string; organization?: string } = {};
        if (baseURL && baseURL.length > 0) configuration.baseURL = baseURL;
        if (organization && organization.length > 0) configuration.organization = organization;

        return new ChatOpenAI({
            apiKey,
            model: modelId,
            ...(Object.keys(configuration).length > 0 ? { configuration } : {}),
            streamUsage: true,
        });
    },
};

export default openaiProvider;
