// src/llm/providers/litellm.ts — LiteLLM proxy provider module (LangChain).
//
// Required env: LITELLM_PROXY_URL (alias: LITELLM_API_BASE).
// Optional env: LITELLM_MASTER_KEY (alias: LITELLM_API_KEY).

import { ChatOpenAI } from '@langchain/openai';

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
        // bearer (no-auth deployments). LangChain's ChatOpenAI requires a
        // non-empty apiKey, so we substitute a documented placeholder.
        const masterKey = config.get('LITELLM_MASTER_KEY');
        const apiKey = masterKey && masterKey.length > 0 ? masterKey : 'dummy';

        const modelId = resolveModel('litellm', modelOverride, config);

        return new ChatOpenAI({
            apiKey,
            model: modelId,
            configuration: { baseURL },
            streamUsage: true,
        });
    },
};

export default litellmProvider;
