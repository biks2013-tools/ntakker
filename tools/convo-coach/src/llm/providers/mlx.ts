// src/llm/providers/mlx.ts — Local MLX-LM provider module (LangChain).
// MLX-LM exposes an OpenAI-compatible server; convo-coach reuses
// OPENAI_BASE_URL pointed at the MLX-LM server endpoint.
//
// Required env: OPENAI_BASE_URL

import { ChatOpenAI } from '@langchain/openai';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

export const mlxProvider: LlmProviderModule = {
    name: 'mlx',
    defaultModel: null,
    create({ config, modelOverride }): LanguageModel {
        const baseUrlRaw = config.get('OPENAI_BASE_URL');
        if (baseUrlRaw === undefined || baseUrlRaw.length === 0) {
            throw new ConfigError(
                "Provider 'mlx' requires OPENAI_BASE_URL pointing at the local MLX-LM server " +
                '(e.g. http://127.0.0.1:8080/v1). Set it in the environment, ' +
                '~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }
        const baseURL = baseUrlRaw.trim().replace(/\/+$/, '');
        const modelId = resolveModel('mlx', modelOverride, config);

        return new ChatOpenAI({
            apiKey: 'mlx',
            model: modelId,
            configuration: { baseURL },
            streamUsage: true,
        });
    },
};

export default mlxProvider;
