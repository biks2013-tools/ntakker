// src/llm/providers/azure-openai.ts — Azure OpenAI provider module (LangChain).
//
// Required env:
//   AZURE_OPENAI_API_KEY      → apiKey
//   AZURE_OPENAI_ENDPOINT     → resourceName (derived) or v1 baseURL
//   AZURE_OPENAI_DEPLOYMENT   → consumed by resolveModel as the modelId
//
// Optional env:
//   AZURE_OPENAI_API_VERSION  → apiVersion override.
//                               * UNSET (recommended for current models like
//                                 gpt-5.x): the provider uses ChatOpenAI
//                                 against the v1 GA endpoint
//                                 https://<resource>.openai.azure.com/openai/v1/...
//                                 No dated api-version is needed; the
//                                 deployment name is the model id.
//                               * SET to a dated preview value (e.g.
//                                 '2025-04-01-preview'): falls back to the
//                                 LangChain `AzureChatOpenAI` integration
//                                 which uses the legacy deployment-based URL
//                                 https://<resource>.openai.azure.com/openai/deployments/<deployment>/<path>?api-version=<x>.
//                                 Useful only for older deployments that
//                                 still require a dated api-version.

import { AzureChatOpenAI, ChatOpenAI } from '@langchain/openai';

import { ConfigError, type LanguageModel, type LlmProviderModule } from '../../types.js';
import { resolveModel } from '../default-models.js';

/**
 * Extract the resource name from a full Azure OpenAI endpoint URL.
 *
 * Examples:
 *   https://my-res.openai.azure.com         → my-res
 *   https://my-res.openai.azure.com/        → my-res
 *   my-res.openai.azure.com                  → my-res
 *   my-res                                   → my-res   (already a bare name)
 */
export function deriveResourceName(endpoint: string): string {
    let host = endpoint.trim();
    host = host.replace(/^https?:\/\//i, '');
    host = host.replace(/\/.*$/, '');
    const firstLabel = host.split('.')[0] ?? '';
    if (firstLabel.length === 0) {
        throw new ConfigError(
            `Could not derive Azure resource name from AZURE_OPENAI_ENDPOINT='${endpoint}'. ` +
            'Expected something like https://<resource-name>.openai.azure.com.',
        );
    }
    return firstLabel;
}

function trimTrailingSlash(s: string): string {
    let v = s;
    while (v.endsWith('/')) v = v.slice(0, -1);
    return v;
}

export const azureOpenaiProvider: LlmProviderModule = {
    name: 'azure-openai',
    defaultModel: null,
    create({ config, modelOverride }): LanguageModel {
        const apiKey = config.get('AZURE_OPENAI_API_KEY');
        if (apiKey === undefined || apiKey.length === 0) {
            throw new ConfigError(
                "Provider 'azure-openai' requires AZURE_OPENAI_API_KEY. " +
                'Set it in the environment, ~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const endpoint = config.get('AZURE_OPENAI_ENDPOINT');
        if (endpoint === undefined || endpoint.length === 0) {
            throw new ConfigError(
                "Provider 'azure-openai' requires AZURE_OPENAI_ENDPOINT. " +
                'Set it in the environment, ~/.tool-agents/convo-coach/.env, or ./.env.',
            );
        }

        const apiVersionRaw = config.get('AZURE_OPENAI_API_VERSION');
        const apiVersion = apiVersionRaw && apiVersionRaw.length > 0
            ? apiVersionRaw
            : undefined;

        const modelId = resolveModel('azure-openai', modelOverride, config);

        if (apiVersion === undefined) {
            // v1 GA mode — use ChatOpenAI pointed at the /openai/v1 endpoint.
            // The deployment name is sent as the `model` field in the
            // request body, exactly how OpenAI's GA contract works.
            // (LangChain 1.x cleanly separated ChatOpenAI from
            // AzureChatOpenAI — `ChatOpenAI` no longer auto-reads
            // AZURE_OPENAI_* env vars, so no suppression is needed.)
            const baseURL = trimTrailingSlash(endpoint) + '/openai/v1';
            return new ChatOpenAI({
                apiKey,
                model: modelId,
                configuration: { baseURL },
                streamUsage: true,
            });
        }

        // Legacy mode — AzureChatOpenAI builds the deployment-based URL
        // pattern automatically using azureOpenAIApiInstanceName +
        // azureOpenAIApiDeploymentName + azureOpenAIApiVersion.
        const azureOpenAIApiInstanceName = deriveResourceName(endpoint);
        return new AzureChatOpenAI({
            azureOpenAIApiKey: apiKey,
            azureOpenAIApiInstanceName,
            azureOpenAIApiDeploymentName: modelId,
            azureOpenAIApiVersion: apiVersion,
            streamUsage: true,
        });
    },
};

export default azureOpenaiProvider;
