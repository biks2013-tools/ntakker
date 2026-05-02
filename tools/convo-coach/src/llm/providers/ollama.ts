// src/llm/providers/ollama.ts — Local Ollama provider module (LangChain).
//
// Optional env: OLLAMA_HOST (default: http://127.0.0.1:11434).
// Default model: llama3.1:8b

import { ChatOllama } from '@langchain/ollama';

import { type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

const DEFAULT_OLLAMA_HOST = 'http://127.0.0.1:11434';

/**
 * Strip trailing slashes and any trailing `/v1` (legacy convo-coach
 * behaviour treated `/v1` as required for the OpenAI-compatible adapter).
 * LangChain's ChatOllama hits the native Ollama `/api/...` paths, so we
 * pass it the bare host URL.
 */
export function normaliseOllamaHost(host: string): string {
    let url = host.trim();
    while (url.endsWith('/')) url = url.slice(0, -1);
    if (url.endsWith('/v1')) url = url.slice(0, -3);
    while (url.endsWith('/')) url = url.slice(0, -1);
    return url;
}

export const ollamaProvider: LlmProviderModule = {
    name: 'ollama',
    defaultModel: 'llama3.1:8b',
    create({ config, modelOverride }): LanguageModel {
        const hostRaw = config.get('OLLAMA_HOST');
        const baseUrl = hostRaw && hostRaw.length > 0
            ? normaliseOllamaHost(hostRaw)
            : DEFAULT_OLLAMA_HOST;

        const modelId = resolveModel('ollama', modelOverride, config);

        return new ChatOllama({
            baseUrl,
            model: modelId,
        });
    },
};

export default ollamaProvider;
