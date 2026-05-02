// src/llm/providers/mlx.ts — MLX-LM via @ai-sdk/openai-compatible.
//
// Required env: OPENAI_BASE_URL (MLX-LM reuses this var per sdk research §3.4).
//
// No static default model — MLX-LM serves whatever the user started the
// server with (`mlx_lm.server --model …`). The user must pass --model
// matching that exact id.

import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

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

        const provider = createOpenAICompatible({
            name: 'mlx',
            baseURL,
            // MLX-LM ignores the api key but the SDK requires a non-empty
            // string; documented placeholder is 'mlx'.
            apiKey: 'mlx',
            includeUsage: true,
        });

        const modelId = resolveModel('mlx', modelOverride, config);
        return provider.languageModel(modelId);
    },
};

export default mlxProvider;
