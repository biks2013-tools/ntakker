// src/llm/providers/azure-openai.ts — Azure OpenAI provider module.
//
// Required env:
//   AZURE_OPENAI_API_KEY      → apiKey
//   AZURE_OPENAI_ENDPOINT     → resourceName (derived; see deriveResourceName)
//   AZURE_OPENAI_DEPLOYMENT   → consumed by resolveModel as the modelId
//
// Optional env:
//   AZURE_OPENAI_API_VERSION  → apiVersion override.
//                               * When UNSET (recommended for current models
//                                 such as gpt-5.x): the SDK uses its 'v1'
//                                 default and routes to Azure's GA endpoint
//                                 https://<resource>.openai.azure.com/openai/v1/...
//                                 No dated api-version is needed.
//                               * When SET to a dated preview value (e.g.
//                                 '2025-04-01-preview'): the provider also
//                                 enables `useDeploymentBasedUrls: true`,
//                                 switching to the legacy URL pattern
//                                 https://<resource>.openai.azure.com/openai/deployments/<deployment>/<path>?api-version=<x>.
//                                 Use this only for older deployments that
//                                 require the legacy route. Setting a dated
//                                 api-version against the v1 URL pattern
//                                 would yield "API version not supported".
//
// No static default model — the deployment name IS the model id.
//
// See docs/research/vercel-ai-sdk-v5-multiprovider.md §2.1 and §6 gotcha 11.

import { createAzure } from '@ai-sdk/azure';

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
 *
 * Throws `ConfigError` if the input cannot be reduced to a non-empty
 * resource name.
 */
export function deriveResourceName(endpoint: string): string {
    let host = endpoint.trim();
    // Strip URL scheme.
    host = host.replace(/^https?:\/\//i, '');
    // Strip trailing slash and any path.
    host = host.replace(/\/.*$/, '');
    // Strip the .openai.azure.com (and any other) suffix → first label only.
    const firstLabel = host.split('.')[0] ?? '';
    if (firstLabel.length === 0) {
        throw new ConfigError(
            `Could not derive Azure resource name from AZURE_OPENAI_ENDPOINT='${endpoint}'. ` +
            'Expected something like https://<resource-name>.openai.azure.com.',
        );
    }
    return firstLabel;
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

        // AZURE_OPENAI_API_VERSION is optional and chooses the URL pattern:
        //   - unset / empty → v1 GA mode (apiVersion defaults to 'v1' inside
        //     the SDK; URL is /openai/v1/... ; no dated api-version query).
        //   - explicitly set → legacy deployment-based mode (URL becomes
        //     /openai/deployments/<id>/...?api-version=<x>). Setting a dated
        //     api-version without enabling useDeploymentBasedUrls would route
        //     it against the v1 URL and Azure would reject it with "API
        //     version not supported", so we pair the two automatically.
        const apiVersionRaw = config.get('AZURE_OPENAI_API_VERSION');
        const apiVersion = apiVersionRaw && apiVersionRaw.length > 0
            ? apiVersionRaw
            : undefined;
        const useDeploymentBasedUrls = apiVersion !== undefined;

        const resourceName = deriveResourceName(endpoint);

        // Pass apiKey + resourceName explicitly so the SDK does not auto-read
        // AZURE_API_KEY / AZURE_RESOURCE_NAME from the shell. This preserves
        // the four-tier precedence chain. apiVersion + useDeploymentBasedUrls
        // are only forwarded together, so the SDK's 'v1' GA default takes
        // effect when no api-version is configured.
        const provider = createAzure({
            apiKey,
            resourceName,
            ...(apiVersion !== undefined
                ? { apiVersion, useDeploymentBasedUrls }
                : {}),
        });

        const modelId = resolveModel('azure-openai', modelOverride, config);
        return provider(modelId);
    },
};

export default azureOpenaiProvider;
