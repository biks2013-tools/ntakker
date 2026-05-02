# Vercel AI SDK v5 — Multi-Provider Streaming Client Reference

> **Purpose**: Authoritative implementation reference for `convo-coach`'s provider abstraction layer.  
> **Audience**: Planner and parallel coders who will implement `src/providers/` without re-researching.  
> **Versions tested**: `ai@5.x` (stable; npm shows `6.0.173` as latest but `5.x` remains supported — see Versions section), `@ai-sdk/openai@3.0.55`, `@ai-sdk/anthropic@3.0.74`, `@ai-sdk/google@3.0.64`, `@ai-sdk/azure@3.0.59`, `@ai-sdk/openai-compatible@2.0.41`.

---

## Provider Matrix

| # | Provider | env var(s) required | SDK package | Constructor / factory | Default model | Notes |
|---|---|---|---|---|---|---|
| 1 | `openai` | `OPENAI_API_KEY` | `@ai-sdk/openai` | `openai('gpt-4o-mini')` | `gpt-4o-mini` | `OPENAI_BASE_URL` optional; `OPENAI_ORG_ID` optional. |
| 2 | `anthropic` | `ANTHROPIC_API_KEY` | `@ai-sdk/anthropic` | `anthropic('claude-haiku-4-5-20251001')` | `claude-haiku-4-5-20251001` | `ANTHROPIC_BASE_URL` optional. |
| 3 | `gemini` | `GOOGLE_API_KEY` | `@ai-sdk/google` | `google('gemini-2.5-flash')` | `gemini-2.5-flash` | Accept `GEMINI_API_KEY` as alias; both forward to the same package env var. |
| 4 | `azure-openai` | `AZURE_OPENAI_API_KEY`, `AZURE_RESOURCE_NAME`, `AZURE_OPENAI_DEPLOYMENT` | `@ai-sdk/azure` | `azure(deploymentName)` | uses `AZURE_OPENAI_DEPLOYMENT` | `AZURE_OPENAI_API_VERSION` optional (default: `v1`). Deployment name ≠ model name — see gotchas. |
| 5 | `azure-ai-inference` | `AZURE_AI_INFERENCE_KEY`, `AZURE_AI_INFERENCE_ENDPOINT` | `@ai-sdk/openai-compatible` | `createOpenAICompatible({ name:'azure-ai-inference', baseURL: ENDPOINT+'/openai/v1', apiKey: KEY }).languageModel(model)` | `claude-haiku-4-5` | Azure AI Inference (Foundry) exposes `/openai/v1` since Aug 2025 GA. No dedicated SDK package; route via openai-compatible. |
| 6 | `ollama` | `OLLAMA_HOST` | `@ai-sdk/openai-compatible` | `createOpenAICompatible({ name:'ollama', baseURL: OLLAMA_HOST+'/v1', apiKey:'ollama' }).languageModel(model)` | `llama3.1:8b` | `apiKey` is ignored by Ollama but SDK requires non-empty string. |
| 7 | `litellm` | `LITELLM_PROXY_URL`, `LITELLM_MASTER_KEY` | `@ai-sdk/openai-compatible` | `createOpenAICompatible({ name:'litellm', baseURL: LITELLM_PROXY_URL, apiKey: LITELLM_MASTER_KEY }).languageModel(model)` | none — required | Model name is whatever the proxy's `model_list` exposes. |
| 8 | `mlx` | `OPENAI_BASE_URL` (no dedicated key) | `@ai-sdk/openai-compatible` | `createOpenAICompatible({ name:'mlx', baseURL: OPENAI_BASE_URL, apiKey:'mlx' }).languageModel(model)` | none — required | MLX-LM serves the loaded model; `--model` is required. |

---

## 1. `streamText` API Surface

### 1.1 Return shape

`streamText` is a synchronous call — it returns immediately without awaiting. Results are exposed as promises or async iterables on the returned object.

```typescript
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

const result = streamText({           // NOT awaited — returns synchronously
  model: openai('gpt-4o-mini'),
  system: 'You are a helpful assistant.',
  prompt: 'Hello!',
});

// Three ways to consume:
result.textStream        // AsyncIterable<string> — plain text deltas only
result.fullStream        // AsyncIterable<TextStreamPart> — all event types
await result.usage       // Promise<LanguageModelUsage>
await result.text        // Promise<string> — full accumulated text
await result.finishReason  // Promise<'stop'|'length'|'content-filter'|'tool-calls'|'error'|'other'>
```

### 1.2 `textStream` — plain text async iterable

`textStream` yields **only plain string text deltas**, filtering out tool calls, reasoning tokens, and structural events. Each chunk is a raw string fragment (one or more characters). It is safe to pass each chunk directly to `process.stdout.write()`.

```typescript
for await (const delta of result.textStream) {
  process.stdout.write(delta);   // delta is a plain string, never undefined
}
```

**Confirmed**: `textStream` does NOT yield empty strings or structural events. Tool-call parts, reasoning parts, and stream lifecycle events are filtered out. Only `text-delta` events from `fullStream` are surfaced here.

### 1.3 `fullStream` — all event types

`fullStream` is an `AsyncIterable<TextStreamPart<TOOLS>>` that emits every event. Relevant event types for `convo-coach` (no tool calling):

| Event type | Fields | When emitted |
|---|---|---|
| `start` | — | Stream connection established |
| `start-step` | — | An LLM API call step starts |
| `text-start` | `id: string` | A text block begins |
| `text-delta` | `id: string`, `delta: string` | Each text chunk |
| `text-end` | `id: string` | Text block completes |
| `finish-step` | `finishReason`, `usage` (step-level) | Step complete |
| `finish` | `finishReason`, `usage` (total) | Full stream complete |
| `error` | `error: unknown` | Provider error mid-stream |
| `abort` | — | Stream aborted via AbortController |

Full event set also includes: `reasoning-start/delta/end`, `tool-input-start/delta/end/available`, `tool-call`, `tool-result`, `tool-error`, `file`. These are not emitted for plain text-only calls.

**v5 vs v6 naming note**: In AI SDK v5, the text delta field is `textDelta` inside `text-delta` parts when iterating `fullStream`. In v6, this was renamed to `delta`. Verify against the exact pinned version. The official v5 event type is `{ type: 'text-delta'; textDelta: string }`.

Minimal `fullStream` usage pattern for `convo-coach`:

```typescript
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

const result = streamText({
  model: openai('gpt-4o-mini'),
  system: systemPrompt,
  prompt: userMessage,
});

let firstTokenAt: number | undefined;
const started = Date.now();

for await (const part of result.fullStream) {
  switch (part.type) {
    case 'text-delta':
      if (firstTokenAt === undefined) firstTokenAt = Date.now();
      // In v5: part.textDelta  |  In v6: part.delta
      // Use textStream instead to avoid this ambiguity:
      break;
    case 'error':
      throw part.error;      // re-throw; caller maps to exit 70
    case 'finish':
      // part.usage is available here too (same as await result.usage)
      break;
  }
}
```

**Recommendation**: For `convo-coach`, iterate `result.textStream` for the streaming write loop (simpler, no version ambiguity). Use `await result.usage` for the Metrics block. Use `onError` callback or a try/catch around the iteration for error handling.

### 1.4 `usage` — token counts

`await result.usage` resolves to a `LanguageModelUsage` object **after the stream has fully consumed**:

```typescript
type LanguageModelUsage = {
  inputTokens:  number | undefined;
  outputTokens: number | undefined;
  totalTokens:  number | undefined;
  // Extended (v5+):
  reasoningTokens?:      number | undefined;
  cachedInputTokens?:    number | undefined;
  inputTokenDetails?: {
    noCacheTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
  };
  outputTokenDetails?: {
    textTokens?: number;
    reasoningTokens?: number;
  };
};
```

**Breaking change from v4**: In v4, the fields were `promptTokens` and `completionTokens`. In v5+, they are `inputTokens` and `outputTokens`. Never use the v4 names.

**Provider caveats**: Not all providers reliably report token counts in streaming mode. Azure OpenAI has a known NaN issue with some deployment configurations. Ollama may return `undefined` for all counts. Always guard:

```typescript
const usage = await result.usage;
const inputTokens  = usage.inputTokens  ?? 0;
const outputTokens = usage.outputTokens ?? 0;
```

`await result.totalUsage` is also available and includes accumulated counts across multi-step calls (not relevant for single-step `convo-coach` use).

### 1.5 Error handling

**Design**: `streamText` starts the HTTP request but does NOT throw synchronously (no `await`). Errors surface in two ways:

1. **Via `onError` callback** — recommended for cleanup tasks:
   ```typescript
   const result = streamText({
     model: ...,
     prompt: ...,
     onError({ error }) {
       console.error('Stream error:', error);
     },
   });
   ```

2. **Via `error` event in `fullStream`** — when iterating `fullStream`, an `{ type: 'error', error: unknown }` part is emitted. The iteration then ends; no exception is thrown by the iterator itself.

3. **Via try/catch around `textStream` iteration** — when iterating `textStream`, errors ARE thrown from the iterator (re-thrown from the underlying stream):
   ```typescript
   try {
     for await (const delta of result.textStream) {
       process.stdout.write(delta);
     }
   } catch (err) {
     // network drop, provider 5xx, auth failure, etc.
     // Map to exit 70 (EX_SOFTWARE)
   }
   ```

**For `convo-coach`**: use try/catch around the `textStream` for loop. This is the simplest pattern, gives one error-handling site, and the error object is the raw provider error (includes HTTP status, message, provider-specific codes).

### 1.6 Cancellation via AbortController

```typescript
import { streamText } from 'ai';

const controller = new AbortController();

// Cancel after 30 seconds:
const timeout = setTimeout(() => controller.abort(), 30_000);

const result = streamText({
  model: openai('gpt-4o-mini'),
  prompt: 'Write something long...',
  abortSignal: controller.signal,
  onAbort({ steps }) {
    // Called when aborted; steps contains partial results
    clearTimeout(timeout);
  },
});

try {
  for await (const delta of result.textStream) {
    process.stdout.write(delta);
  }
} catch (err) {
  if (controller.signal.aborted) {
    // Normal abort — not a provider error
  } else {
    throw err;
  }
} finally {
  clearTimeout(timeout);
}
```

You can also handle abort in-stream:
```typescript
for await (const part of result.fullStream) {
  if (part.type === 'abort') {
    // stream was aborted
    break;
  }
}
```

There is no `.cancel()` method on the result object. The only mechanism is `AbortController`.

### 1.7 Minimal, complete Node.js example (stream to stdout + print usage)

```typescript
#!/usr/bin/env node
// ESM — package.json must have "type": "module"
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

// OPENAI_API_KEY must be set in environment
const result = streamText({
  model: openai('gpt-4o-mini'),
  system: 'You are a helpful assistant.',
  prompt: 'List three tips for public speaking.',
  maxOutputTokens: 512,
  temperature: 0.7,
});

const started = Date.now();
let firstTokenMs: number | undefined;

try {
  for await (const delta of result.textStream) {
    if (firstTokenMs === undefined) firstTokenMs = Date.now() - started;
    process.stdout.write(delta);
  }
  process.stdout.write('\n');
} catch (err) {
  process.stderr.write(`\nStream error: ${String(err)}\n`);
  process.exit(70);  // EX_SOFTWARE
}

const usage = await result.usage;
const elapsed = Date.now() - started;

process.stderr.write([
  `\n--- Metrics ---`,
  `TTFT:          ${firstTokenMs ?? 'N/A'} ms`,
  `Total elapsed: ${elapsed} ms`,
  `Input tokens:  ${usage.inputTokens ?? 'N/A'}`,
  `Output tokens: ${usage.outputTokens ?? 'N/A'}`,
  `Total tokens:  ${usage.totalTokens ?? 'N/A'}`,
].join('\n') + '\n');
```

---

## 2. Azure Providers

### 2.1 Azure OpenAI — `@ai-sdk/azure`

Azure OpenAI deploys models under **deployment names** that you create in the Azure portal. The deployment name is what you pass to the SDK, NOT the underlying model name.

#### Constructor signature

```typescript
import { createAzure } from '@ai-sdk/azure';

const azure = createAzure({
  resourceName: 'my-resource',         // → https://my-resource.openai.azure.com/openai/v1{path}
  apiKey: 'sk-...',
  apiVersion: 'v1',                    // default; omit unless you need legacy
  // --- OR use baseURL instead of resourceName: ---
  // baseURL: 'https://my-resource.openai.azure.com',  // resolves to {baseURL}/v1{path}
});

const model = azure('my-gpt4o-deployment');   // deployment name, not model name
```

#### Env var → constructor mapping

| Env var | `createAzure` field | Notes |
|---|---|---|
| `AZURE_RESOURCE_NAME` | `resourceName` | Auto-read when `resourceName` omitted |
| `AZURE_API_KEY` | `apiKey` | Auto-read when `apiKey` omitted |
| `AZURE_OPENAI_DEPLOYMENT` | passed as `azure(deploymentName)` | Must be read by convo-coach, not auto-read |
| `AZURE_OPENAI_API_VERSION` | `apiVersion` | Optional; default `v1` |

**Clarification on env var naming**: The official SDK reads `AZURE_RESOURCE_NAME` and `AZURE_API_KEY` from the environment automatically. The refined request uses `AZURE_OPENAI_API_KEY` and `AZURE_OPENAI_ENDPOINT`. There is a mismatch. The recommended resolution is to read `AZURE_OPENAI_API_KEY` from the four-tier chain and pass it explicitly as `apiKey`, and to derive `resourceName` from `AZURE_OPENAI_ENDPOINT` by stripping the URL scheme and `.openai.azure.com` suffix — OR to accept `AZURE_RESOURCE_NAME` as an alias. Document the exact behavior in `docs/tools/convo-coach.md`.

#### Using the legacy deployment-based URL format

If the Azure deployment requires the older URL format:
```
https://{resourceName}.openai.azure.com/openai/deployments/{deploymentId}/chat/completions?api-version=...
```
Pass `useDeploymentBasedUrls: true` to `createAzure`:
```typescript
const azure = createAzure({
  resourceName: 'my-resource',
  apiKey: '...',
  useDeploymentBasedUrls: true,
  apiVersion: '2025-04-01-preview',  // required with legacy format
});
```

#### Full convo-coach factory example

```typescript
import { createAzure } from '@ai-sdk/azure';

export function createAzureOpenAIModel(
  apiKey: string,
  resourceName: string,
  deploymentName: string,
  apiVersion?: string,
) {
  const azure = createAzure({
    resourceName,
    apiKey,
    apiVersion: apiVersion ?? 'v1',
  });
  return azure(deploymentName);
}
```

#### Important limitations

- `@ai-sdk/azure` does NOT support Azure-hosted Anthropic models (the URL path for Anthropic models differs: `/anthropic/...` vs `/openai/...`). For Azure-hosted Anthropic via `@ai-sdk/azure`, you will get a URL construction error. Use provider 5 (azure-ai-inference) for those.
- Token usage sometimes reports `NaN` with certain Azure OpenAI configurations. Guard `usage.inputTokens ?? 0`.

### 2.2 Azure AI Inference (Foundry) — `@ai-sdk/openai-compatible`

**There is no `@ai-sdk/azure-inference` package.** The official `@ai-sdk/azure` package only handles Azure OpenAI deployments (OpenAI models deployed to your Azure resource). It cannot correctly construct the endpoint URL for non-OpenAI models (Anthropic, DeepSeek, Llama, etc.) hosted in Azure AI Foundry.

**Current canonical approach (as of 2026 Q1)**:

Azure AI Foundry now exposes an OpenAI-compatible `/openai/v1/` endpoint (GA since Aug 2025; the older `/models` Azure AI Inference SDK endpoint is deprecated and retires Aug 26, 2026). Route Foundry models through `@ai-sdk/openai-compatible` pointing at the `/openai/v1` path:

```typescript
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

export function createAzureAIInferenceModel(
  endpoint: string,    // e.g. https://my-resource.services.ai.azure.com
  apiKey: string,
  modelId: string,
) {
  const provider = createOpenAICompatible({
    name: 'azure-ai-inference',
    baseURL: `${endpoint}/openai/v1`,   // Foundry's OpenAI-compatible path
    apiKey,
    includeUsage: true,
  });
  return provider.languageModel(modelId);
}

// Usage:
const model = createAzureAIInferenceModel(
  process.env.AZURE_AI_INFERENCE_ENDPOINT!,  // https://my-resource.services.ai.azure.com
  process.env.AZURE_AI_INFERENCE_KEY!,
  'claude-haiku-4-5',
);
```

#### Env var → constructor mapping (Azure AI Inference)

| Env var | Used as | Notes |
|---|---|---|
| `AZURE_AI_INFERENCE_ENDPOINT` | `baseURL` (with `/openai/v1` appended) | Full resource URL from Azure portal. Do NOT include path. |
| `AZURE_AI_INFERENCE_KEY` | `apiKey` | Sent as `Authorization: Bearer <key>` header |

#### Community provider alternative

A community provider `@quail-ai/azure-ai-provider` also exists for Azure AI Foundry using the native (now-deprecated) Azure AI Inference API. Do NOT use this; the GA path is the OpenAI-compatible route above.

---

## 3. OpenAI-Compatible Adapter — `@ai-sdk/openai-compatible`

### 3.1 Constructor signature

```typescript
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

const provider = createOpenAICompatible({
  name: string,                          // display name, logged in errors
  baseURL: string,                       // no trailing slash; SDK adds /v1 paths
  apiKey?: string,                       // → "Authorization: Bearer <apiKey>" header
  headers?: Record<string, string>,      // merged with apiKey header (headers win)
  includeUsage?: boolean,               // request usage in streaming responses
  supportsStructuredOutputs?: boolean,
  transformRequestBody?: (body) => body,
});

// Create a model:
const model = provider.languageModel('model-id');  // or provider('model-id') — same
const model = provider.chatModel('model-id');       // identical
```

### 3.2 Ollama

Ollama exposes an OpenAI-compatible REST API at `${OLLAMA_HOST}/v1/...`. Default host: `http://127.0.0.1:11434`.

```typescript
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

export function createOllamaModel(host: string, modelId: string) {
  const provider = createOpenAICompatible({
    name: 'ollama',
    baseURL: `${host}/v1`,   // CORRECT: /v1 suffix, no /api
    apiKey: 'ollama',         // REQUIRED by SDK; value is arbitrary — Ollama ignores it
    includeUsage: true,
  });
  return provider.languageModel(modelId);
}

// Env var:
const model = createOllamaModel(
  process.env.OLLAMA_HOST ?? (() => { throw new Error('OLLAMA_HOST not set'); })(),
  modelId,
);
```

**Quirks**:
- `apiKey` must be a non-empty string (SDK validates). Pass `'ollama'` or any placeholder.
- Ollama's endpoint is `/v1` (OpenAI-compatible), not `/api` (Ollama-native). Using `/api` will fail.
- Usage token reporting: Ollama returns token counts in some versions but not all. Guard `usage.inputTokens ?? undefined`.
- `includeUsage: true` requests that streaming responses include usage metadata in the final chunk — Ollama supports this.
- As of AI SDK v6 (npm `ai@6.x`), the `@ai-sdk/openai-compatible` adapter is confirmed working with Ollama. There were compatibility issues reported mid-v5 lifecycle that were resolved.

**Popular models to document in `convo-coach.md`**:
```
ollama pull llama3.2        # 3B — default fast model (fits 8 GB RAM)
ollama pull llama3.1:8b     # 8B — convo-coach default
ollama pull llama3.3:70b    # 70B — high quality (needs 40 GB RAM / Apple M3 Ultra)
ollama pull qwen2.5:7b      # Alibaba 7B multilingual
ollama pull qwen2.5:14b     # Alibaba 14B quality step-up
ollama pull gemma2:9b       # Google 9B
ollama pull mistral         # Mistral 7B
```

### 3.3 LiteLLM Proxy

LiteLLM is OpenAI-compatible. Point `baseURL` at the proxy; pass the master key (or a user-scoped key) as `apiKey`.

```typescript
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

export function createLiteLLMModel(proxyUrl: string, masterKey: string, modelId: string) {
  const provider = createOpenAICompatible({
    name: 'litellm',
    baseURL: proxyUrl,          // e.g. http://localhost:4000  — NO trailing slash
    apiKey: masterKey,          // → "Authorization: Bearer sk-1234"
    includeUsage: true,
  });
  return provider.languageModel(modelId);
}

// Env vars:
const model = createLiteLLMModel(
  process.env.LITELLM_PROXY_URL!,
  process.env.LITELLM_MASTER_KEY!,
  process.env.CONVO_COACH_MODEL!,   // required — no default for litellm
);
```

**Quirks**:
- `LITELLM_PROXY_URL` must NOT have a trailing slash (the SDK appends `/chat/completions`; double slash breaks routing in some reverse-proxy configs).
- The model name passed to `provider.languageModel(modelId)` must match an entry in the LiteLLM proxy's `model_list` configuration. No client-side prefix is needed. If the proxy is configured with `model_name: gpt-4o`, pass `'gpt-4o'`.
- LiteLLM also accepts provider-prefixed model names (`openai/gpt-4o`, `anthropic/claude-haiku-4-5-20251001`) to override routing at the client — this is a LiteLLM-specific feature, not a standard OpenAI convention.
- No default model for `convo-coach`: the whole point of LiteLLM is to choose the provider at the proxy level. Require `--model` / `CONVO_COACH_MODEL`.

### 3.4 MLX-LM

MLX-LM (Apple MLX inference) starts an OpenAI-compatible server, typically at `http://127.0.0.1:8080/v1` by default. It reuses `OPENAI_BASE_URL` as the base URL env var (no dedicated MLX env var convention exists; document this in the tool's `.env` template).

```typescript
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';

export function createMLXModel(baseURL: string, modelId: string) {
  const provider = createOpenAICompatible({
    name: 'mlx',
    baseURL,              // e.g. http://127.0.0.1:8080/v1  — must include /v1
    apiKey: 'mlx',        // required by SDK; MLX-LM ignores it
    includeUsage: true,
  });
  return provider.languageModel(modelId);
}
```

**Quirks**:
- MLX-LM does not enforce authentication; any non-empty `apiKey` satisfies the SDK requirement.
- The user specifies which model MLX-LM is serving at server startup (`mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit`). The `--model` CLI flag on `convo-coach` must match whatever the MLX-LM server was started with.
- No default model — require `--model` / `CONVO_COACH_MODEL`.

---

## 4. Default Model IDs (Verified, 2026-05)

### OpenAI

| Model ID | Context | Tier | Notes |
|---|---|---|---|
| `gpt-4o-mini` | 128K | Cheap default | Still active in API as of 2026-05; retired from ChatGPT UI Feb 2026 but available via API. $0.15/$0.60 per MTok. |
| `gpt-4o` | 128K | Mid | Supports audio I/O. |
| `gpt-4.1` | 1M | Premium | 54.6% SWE-bench; $2/$8 per MTok. |
| `gpt-4.1-mini` | 1M | Cheap premium | Matches GPT-4o intelligence, 83% cheaper. |
| `gpt-4.1-nano` | 1M | Cheapest | Fastest; 80.1% MMLU. |

**Recommended `convo-coach` default**: `gpt-4o-mini` — still available, cheapest streaming model with acceptable quality for coaching.

### Anthropic

| Model ID | Context | Tier | Notes |
|---|---|---|---|
| `claude-haiku-4-5-20251001` | 200K | Cheap | $1/$5 per MTok. Claude 3 Haiku deprecated Apr 19, 2026. |
| `claude-sonnet-4-6` | 200K (1M beta) | Mid | $3/$15 per MTok. Released Feb 17, 2026. |
| `claude-opus-4-6` | 200K | Premium | Released Feb 5, 2026. |
| `claude-opus-4-7` | 200K | Flagship | Released Apr 16, 2026. $5/$25 per MTok. |

**Recommended `convo-coach` default**: `claude-haiku-4-5-20251001`. Avoid bare `claude-haiku-4-5` — always use the full versioned ID to prevent silent model changes.

**Deprecation warning**: `claude-sonnet-4-20250514` and `claude-opus-4-20250514` retire June 15, 2026. Do not use these IDs.

### Google Gemini

| Model ID | Context | Tier | Notes |
|---|---|---|---|
| `gemini-2.5-flash` | 1M | Cheap default | Price-performance leader; thinking model. |
| `gemini-2.5-flash-lite` | — | Cheapest | Budget-friendly variant. |
| `gemini-2.5-pro` | 2M | Premium | Most capable; coding and reasoning focus. |

**Recommended `convo-coach` default**: `gemini-2.5-flash`.

**Deprecation warning**: `gemini-2.0-flash` and `gemini-2.0-flash-lite` shut down June 1, 2026.

### Azure OpenAI

No default model — the effective model is determined by the deployment the user provisions. `AZURE_OPENAI_DEPLOYMENT` IS the default. `--model` overrides only when the user has multiple deployments and wants to pick one at runtime.

### Azure AI Inference (Foundry)

Default: `claude-haiku-4-5` — this is the Foundry-specific model ID for Azure-hosted Claude Haiku (Foundry typically uses the short-form ID without the date suffix). Verify at implementation time against the actual Azure AI Foundry model catalogue for your target region — region availability varies.

### Ollama

Default: `llama3.1:8b` — widely available, fits on 8 GB RAM, good general quality.

### LiteLLM / MLX-LM

No default — `--model` / `CONVO_COACH_MODEL` is required. Raise `MissingConfigError` if absent.

---

## 5. SDK Package Versions (as of 2026-05-02)

These are the npm latest versions observed during research. Pin these (or newer stable) in `package.json` and lock via `package-lock.json`.

| Package | Latest version | Install |
|---|---|---|
| `ai` | `6.0.173` | `npm install ai` |
| `@ai-sdk/openai` | `3.0.55` | `npm install @ai-sdk/openai` |
| `@ai-sdk/anthropic` | `3.0.74` | `npm install @ai-sdk/anthropic` |
| `@ai-sdk/google` | `3.0.64` | `npm install @ai-sdk/google` |
| `@ai-sdk/azure` | `3.0.59` | `npm install @ai-sdk/azure` |
| `@ai-sdk/openai-compatible` | `2.0.41` | `npm install @ai-sdk/openai-compatible` |

**Important versioning note**: The search results show `ai@6.0.173` as the npm latest. The investigation document and spec reference AI SDK v5. The v6 package is a continuation of v5 and the `streamText` API is compatible. The `ai@5.x` series is pinned at `5.0.x` on npm. **For `convo-coach`, pin to `ai@5.0.x` (last stable v5 release) if the investigation document intends v5; OR accept `ai@6.0.x` which maintains the same `streamText` / `textStream` / `usage` API**. The only material difference is in `fullStream` event naming (`textDelta` vs `delta`) and some renamed config options (`maxTokens` → `maxOutputTokens`). Confirm with the planner which major version to pin before writing `package.json`.

---

## 6. Gotchas

1. **Azure deployment name ≠ model name.** When a user sets `AZURE_OPENAI_DEPLOYMENT=my-gpt4o-deployment`, that string is the Azure deployment label they created — not the OpenAI model ID. Logging `model: 'gpt-4o'` in the sidecar would be misleading; log the deployment name. Use `CONVO_COACH_MODEL` to allow overriding the model label shown in the sidecar without changing the deployment.

2. **Ollama requires a non-empty `apiKey` placeholder.** The `@ai-sdk/openai-compatible` constructor validates that `apiKey` is set when not using `headers`. Pass `'ollama'` or any non-empty string. Failure to do so causes a constructor validation error at startup.

3. **Ollama endpoint path is `/v1`, NOT `/api`.** Ollama exposes two APIs: the native REST at `/api` (Ollama-specific) and the OpenAI-compatible API at `/v1`. The `@ai-sdk/openai-compatible` adapter expects the OpenAI-compatible `/v1` path. Setting `baseURL: 'http://127.0.0.1:11434/api'` will fail with a 404 or protocol error.

4. **LiteLLM `baseURL` trailing-slash sensitivity.** The adapter constructs the final URL as `${baseURL}/chat/completions`. If `LITELLM_PROXY_URL` ends with `/`, the resulting URL is `http://host//chat/completions`. Some nginx/reverse-proxy configs treat this as a different route and return 404. Strip trailing slashes from `LITELLM_PROXY_URL` in the config resolver.

5. **Azure AI Inference `/models` endpoint is deprecated.** The older `*.services.ai.azure.com/models` endpoint (used by the native Azure AI Inference SDK) retires August 26, 2026. Use `*.services.ai.azure.com/openai/v1` or `*.openai.azure.com/openai/v1` instead.

6. **`@ai-sdk/azure` cannot handle Azure-hosted Anthropic models.** The provider assumes all deployments are at the OpenAI path. Anthropic models on Azure are served at a different path. For `claude-haiku-4-5` on Azure AI Foundry, use provider 5 (`azure-ai-inference`) with `@ai-sdk/openai-compatible`.

7. **Token usage is `undefined` or `NaN` on some providers.** Azure OpenAI has a known NaN bug in some deployment configurations. Ollama may not report tokens at all for short completions. Always guard: `usage.inputTokens ?? 0`. Log a warning to stderr if both counts are `undefined` or `NaN`; do not crash.

8. **`streamText` does not throw on call — errors are async.** Unlike a `fetch()` wrapper, `streamText` returns immediately without any network activity. The provider connection is established only when the first `for await` iteration begins. All error handling MUST be inside the try/catch around the iteration, NOT around the `streamText()` call itself.

9. **v4 → v5 breaking rename**: `promptTokens` / `completionTokens` → `inputTokens` / `outputTokens`. If any code from pre-v5 examples is copied, update the field names.

10. **v5 → v6 migration `maxTokens` rename**: `maxTokens: 1000` becomes `maxOutputTokens: 1000` in v5+. The v4 name `maxTokens` is silently ignored in v5/v6, which can cause runaway completions.

11. **Azure `AZURE_RESOURCE_NAME` vs `AZURE_OPENAI_ENDPOINT`**: The SDK auto-reads `AZURE_RESOURCE_NAME`, but the spec uses `AZURE_OPENAI_ENDPOINT` (a full URL). The factory must derive `resourceName` from `AZURE_OPENAI_ENDPOINT` (`new URL(endpoint).hostname.split('.')[0]`) or accept both and prefer the explicit resource name.

12. **LiteLLM model names may need provider prefix.** When calling LiteLLM with a model that it routes to a non-OpenAI provider, the model name format `provider/model-id` may be required in the LiteLLM config. This is a proxy-side concern, not a client-side concern — `convo-coach` passes whatever string the user provides as `--model`.

---

## 7. Complete Factory Pattern for `convo-coach`

This is the recommended `src/providers/factory.ts` shape. Each provider returns a `LanguageModel` — the unified type that `streamText` accepts.

```typescript
// src/providers/factory.ts
import { LanguageModel } from 'ai';
import { createOpenAI } from '@ai-sdk/openai';
import { createAnthropic } from '@ai-sdk/anthropic';
import { createGoogleGenerativeAI } from '@ai-sdk/google';
import { createAzure } from '@ai-sdk/azure';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import type { ResolvedConfig } from './config.js';

export type ProviderName =
  | 'openai'
  | 'anthropic'
  | 'gemini'
  | 'azure-openai'
  | 'azure-ai-inference'
  | 'ollama'
  | 'litellm'
  | 'mlx';

export function createProviderModel(
  provider: ProviderName,
  modelId: string,
  cfg: ResolvedConfig,
): LanguageModel {
  switch (provider) {
    case 'openai': {
      const openai = createOpenAI({
        apiKey: cfg.OPENAI_API_KEY,
        ...(cfg.OPENAI_BASE_URL && { baseURL: cfg.OPENAI_BASE_URL }),
        ...(cfg.OPENAI_ORG_ID   && { organization: cfg.OPENAI_ORG_ID }),
      });
      return openai(modelId);
    }

    case 'anthropic': {
      const anthropic = createAnthropic({
        apiKey: cfg.ANTHROPIC_API_KEY,
        ...(cfg.ANTHROPIC_BASE_URL && { baseURL: cfg.ANTHROPIC_BASE_URL }),
      });
      return anthropic(modelId);
    }

    case 'gemini': {
      const google = createGoogleGenerativeAI({
        apiKey: cfg.GOOGLE_API_KEY,
      });
      return google(modelId);
    }

    case 'azure-openai': {
      const azure = createAzure({
        resourceName: deriveResourceName(cfg.AZURE_OPENAI_ENDPOINT),
        apiKey: cfg.AZURE_OPENAI_API_KEY,
        ...(cfg.AZURE_OPENAI_API_VERSION && { apiVersion: cfg.AZURE_OPENAI_API_VERSION }),
      });
      return azure(modelId);  // modelId = deploymentName here
    }

    case 'azure-ai-inference': {
      const provider = createOpenAICompatible({
        name: 'azure-ai-inference',
        baseURL: `${cfg.AZURE_AI_INFERENCE_ENDPOINT.replace(/\/$/, '')}/openai/v1`,
        apiKey: cfg.AZURE_AI_INFERENCE_KEY,
        includeUsage: true,
      });
      return provider.languageModel(modelId);
    }

    case 'ollama': {
      const provider = createOpenAICompatible({
        name: 'ollama',
        baseURL: `${cfg.OLLAMA_HOST.replace(/\/$/, '')}/v1`,
        apiKey: 'ollama',
        includeUsage: true,
      });
      return provider.languageModel(modelId);
    }

    case 'litellm': {
      const provider = createOpenAICompatible({
        name: 'litellm',
        baseURL: cfg.LITELLM_PROXY_URL.replace(/\/$/, ''),
        apiKey: cfg.LITELLM_MASTER_KEY,
        includeUsage: true,
      });
      return provider.languageModel(modelId);
    }

    case 'mlx': {
      const provider = createOpenAICompatible({
        name: 'mlx',
        baseURL: cfg.OPENAI_BASE_URL.replace(/\/$/, ''),
        apiKey: 'mlx',
        includeUsage: true,
      });
      return provider.languageModel(modelId);
    }
  }
}

/** Extract resource name from a full Azure endpoint URL.
 *  "https://my-resource.openai.azure.com" → "my-resource"
 */
function deriveResourceName(endpoint: string): string {
  const host = new URL(endpoint).hostname;
  return host.split('.')[0];
}
```

### Streaming usage in `src/cli.ts`

```typescript
import { streamText } from 'ai';
import { createProviderModel } from './providers/factory.js';

const model = createProviderModel(cfg.provider, cfg.model, cfg);

const started = Date.now();
let firstTokenMs: number | undefined;

const result = streamText({
  model,
  system: systemPrompt,
  prompt: userMessage,
  maxOutputTokens: 2048,
  abortSignal: controller.signal,
  onError({ error }) {
    // secondary error log — primary handling is in the catch below
    process.stderr.write(`Provider error: ${String(error)}\n`);
  },
});

try {
  for await (const delta of result.textStream) {
    if (firstTokenMs === undefined) firstTokenMs = Date.now() - started;
    process.stdout.write(delta);
    sidecarStream.write(delta);          // simultaneous sidecar write
  }
  process.stdout.write('\n');
} catch (err) {
  sidecarStream.write('\n\n# ERROR\n\n');
  sidecarStream.write(String(err) + '\n');
  sidecarStream.end();
  process.exit(70);  // EX_SOFTWARE
}

const usage    = await result.usage;
const elapsed  = Date.now() - started;

// Finalise sidecar Metrics block
sidecarStream.write(buildMetricsBlock(usage, firstTokenMs, elapsed));
sidecarStream.end();
```

---

## Assumptions & Scope

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| `ai@5.x` and `ai@6.x` share the same `streamText` / `textStream` / `usage` surface | HIGH | `textStream` and `usage` APIs are documented as stable; v6 adds some new features but does not break the basic streaming loop. |
| Azure AI Foundry's `/openai/v1` endpoint is OpenAI-compatible (GA since Aug 2025) | HIGH | If a specific Foundry model does not support this path, the user must use a different endpoint path — document in `docs/tools/convo-coach.md`. |
| Ollama's `@ai-sdk/openai-compatible` compatibility issue (reported mid-v5) is resolved in v5.0.4+ | MEDIUM | If not resolved, fall back to the dedicated `ollama-ai-provider` community package. |
| `AZURE_OPENAI_DEPLOYMENT` is the env var name (matching spec FR-CC-7) | HIGH | The SDK itself does not read this env var; it is `convo-coach`'s own key. |
| `claude-haiku-4-5` is the Foundry model ID for Azure-hosted Claude Haiku | MEDIUM | Azure region availability and naming varies. Verify in target region. |
| Anthropic API: `claude-haiku-4-5-20251001` is the correct versioned ID | HIGH | Confirmed from Anthropic platform docs via web search. |
| `fullStream` `text-delta` event uses `textDelta` field in v5 (renamed to `delta` in v6) | MEDIUM | Confirmed from v5 type definitions and GitHub issues; recommendation is to use `textStream` to avoid this ambiguity entirely. |

### What is explicitly out of scope

- AI SDK v4 compatibility (deprecated naming: `promptTokens`, `completionTokens`, `maxTokens`).
- Multi-step / agentic calls (`stopWhen`, `prepareStep`) — `convo-coach` does single-step.
- Tool calling, function calling, structured output — not needed for coaching.
- UI streaming (`toUIMessageStreamResponse`, React/Svelte hooks) — CLI only.
- Embeddings, image generation — not applicable.
- Google Vertex AI (`@ai-sdk/google-vertex`) — spec uses direct Gemini API.
- Provider-specific reasoning tokens (Claude `thinking`, OpenAI `o*` reasoning effort) — not needed for v1.

---

## References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Vercel AI SDK 5 announcement blog | https://vercel.com/blog/ai-sdk-5 | v4→v5 breaking changes; `inputTokens`/`outputTokens` rename; promise-based results. |
| 2 | AI SDK Core `streamText` reference | https://ai-sdk.dev/docs/reference/ai-sdk-core/stream-text | Full parameter and return-type API surface. |
| 3 | AI SDK stream cancellation docs | https://ai-sdk.dev/docs/advanced/stopping-streams | `abortSignal` pattern; `onAbort` callback; `abort` stream part. |
| 4 | AI SDK Azure OpenAI provider docs | https://ai-sdk.dev/providers/ai-sdk-providers/azure | `createAzure` constructor; `resourceName`, `apiKey`, `useDeploymentBasedUrls`; Responses vs Chat API. |
| 5 | AI SDK OpenAI-Compatible providers docs | https://ai-sdk.dev/providers/openai-compatible-providers | `createOpenAICompatible` constructor; `includeUsage`; factory methods. |
| 6 | npm: `@ai-sdk/azure` | https://www.npmjs.com/package/@ai-sdk/azure | Current version `3.0.59`. |
| 7 | npm: `@ai-sdk/openai-compatible` | https://www.npmjs.com/package/@ai-sdk/openai-compatible | Current version `2.0.41`. |
| 8 | npm: `ai` | https://www.npmjs.com/package/ai | Latest version `6.0.173`. |
| 9 | Context7: Vercel AI SDK docs | /vercel/ai (Context7) | `streamText` cancellation pattern; `fullStream` event types; Ollama example. |
| 10 | GitHub issue: NaN token counts Azure | https://github.com/vercel/ai/issues/2543 | Token reporting is unreliable with Azure; guard all usages. |
| 11 | GitHub issue: `text-delta` field naming | https://github.com/vercel/ai/issues/8335 | `textDelta` vs `delta` naming change between versions. |
| 12 | Microsoft Learn: Azure Foundry Endpoints | https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/endpoints | `/openai/v1` vs `/models` path; GA timeline. |
| 13 | Microsoft Learn: Migrate AI Inference to OpenAI SDK | https://learn.microsoft.com/en-us/azure/foundry/how-to/model-inference-to-openai-migration | Deprecation of `/models` endpoint; Aug 26, 2026 retirement. |
| 14 | Ollama OpenAI compatibility docs | https://docs.ollama.com/api/openai-compatibility | `/v1` path; `apiKey` placeholder pattern. |
| 15 | LiteLLM Proxy docs | https://docs.litellm.ai/docs/providers/litellm_proxy | baseURL pattern; model name routing; no trailing slash. |
| 16 | Anthropic model IDs | https://platform.claude.com/docs/en/about-claude/models/overview | `claude-haiku-4-5-20251001`, `claude-sonnet-4-6`, `claude-opus-4-7`. |
| 17 | OpenAI model docs | https://developers.openai.com/api/docs/models/all | `gpt-4o-mini`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`. |
| 18 | Google Gemini API models | https://ai.google.dev/gemini-api/docs/models | `gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-2.5-flash-lite`. |
| 19 | Ollama library / popular models | https://ollama.com/library | `llama3.2`, `llama3.1:8b`, `qwen2.5:7b`, `gemma2:9b`, `mistral`. |
| 20 | AI SDK community provider: Azure AI | https://ai-sdk.dev/providers/community-providers/azure-ai | Confirms no official `@ai-sdk/azure-inference`; community-only. |

### Recommended for deep reading before implementation

- **[AI SDK Core `streamText` reference](https://ai-sdk.dev/docs/reference/ai-sdk-core/stream-text)**: Full parameter list, `onChunk`, `onStepFinish`, `onFinish` callbacks — useful for the sidecar writer.
- **[Azure AI SDK provider page](https://ai-sdk.dev/providers/ai-sdk-providers/azure)**: `useDeploymentBasedUrls`, Responses vs Chat API differences, provider-specific metadata types.
- **[Microsoft Learn: Foundry Endpoints](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/endpoints)**: Canonical endpoint URLs for Azure AI Inference; verify `/openai/v1` availability for your target models.
- **[Anthropic model overview](https://platform.claude.com/docs/en/about-claude/models/overview)**: Always check before hardcoding model IDs; Anthropic deprecates older IDs with short notice.

---

## Clarifying Questions for Follow-up

1. **AI SDK v5 or v6?** The investigation document says v5 (`5.0.x`) but npm latest is `6.0.173`. Are they compatible? (Answer: mostly yes, but `fullStream` event field naming differs.) Which major version should `package.json` pin?

2. **Azure OpenAI env var names**: The spec uses `AZURE_OPENAI_API_KEY` and `AZURE_OPENAI_ENDPOINT`, but the SDK auto-reads `AZURE_API_KEY` and `AZURE_RESOURCE_NAME`. Should the factory accept BOTH and use spec names as primary?

3. **`GEMINI_API_KEY` alias**: Should the config resolver accept `GEMINI_API_KEY` as a fallback when `GOOGLE_API_KEY` is absent, or should `GOOGLE_API_KEY` be the only accepted name?

4. **Azure AI Foundry default model**: Is `claude-haiku-4-5` available in the user's target Azure region? Some Foundry model IDs differ by region (e.g., some regions use `claude-haiku-4-5-20251001`). Verify before hardcoding the default.

5. **Ollama: `ollama-ai-provider` vs `@ai-sdk/openai-compatible`**: Given the reported compatibility issues with v5/v6, should `convo-coach` use the dedicated `ollama-ai-provider` community package (`ollama-ai-provider@2.x` for AI SDK v5) or rely on `@ai-sdk/openai-compatible`? The dedicated package uses Ollama's native `/api` endpoint and may be more reliable.
