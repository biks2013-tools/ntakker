// src/llm/providers/ollama.ts — Ollama via @ai-sdk/openai-compatible.
//
// Optional env: OLLAMA_HOST (default: http://127.0.0.1:11434).
//
// This is the ONE documented exception to the no-fallback config rule:
// Ollama's local default host is so universally `127.0.0.1:11434` that
// the `.env` template documents it as the default. See sdk research
// §3.2 and the macrec project's CLAUDE.md.
//
// Default model: llama3.1:8b.

import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

import { type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

const DEFAULT_OLLAMA_HOST = 'http://127.0.0.1:11434';

/** Strip trailing slashes and ensure the URL ends with `/v1`. */
function normaliseOllamaBaseUrl(host: string): string {
    const trimmed = host.trim().replace(/\/+$/, '');
    if (/\/v1$/.test(trimmed)) return trimmed;
    return `${trimmed}/v1`;
}

export const ollamaProvider: LlmProviderModule = {
    name: 'ollama',
    defaultModel: 'llama3.1:8b',
    create({ config, modelOverride }): LanguageModel {
        const hostRaw = config.get('OLLAMA_HOST');
        const host = hostRaw !== undefined && hostRaw.length > 0 ? hostRaw : DEFAULT_OLLAMA_HOST;

        const baseURL = normaliseOllamaBaseUrl(host);

        const provider = createOpenAICompatible({
            name: 'ollama',
            baseURL,
            // Ollama ignores apiKey but the SDK requires a non-empty
            // string; documented placeholder is 'ollama'.
            apiKey: 'ollama',
            includeUsage: true,
        });

        const modelId = resolveModel('ollama', modelOverride, config);
        return provider.languageModel(modelId);
    },
};

export default ollamaProvider;
