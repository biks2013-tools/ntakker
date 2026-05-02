// src/llm/model-context-windows.ts — static lookup of input-token capacity
// per model id. Used by `applyBudget` (src/llm/budget.ts) to decide whether
// the prompt fits inside the model's context window before dispatching a
// request to a provider.
//
// See §CC-DSGN-6 of project-design.md for the signature contract and
// §CC-DSGN-12 CC-ADR-4 for the budget/estimator architecture.
//
// The numbers below are sourced from
// docs/research/vercel-ai-sdk-v5-multiprovider.md (Provider matrix). Update
// both the document and this file together when a new model is added.

/**
 * Mapping from model id → maximum INPUT-token capacity. The output is not
 * counted here — `SAFETY_MARGIN_RATIO` reserves headroom for the response.
 */
export const MODEL_CONTEXT_WINDOWS: Record<string, number> = Object.freeze({
    // ---- OpenAI ----
    'gpt-4o': 128_000,
    'gpt-4o-mini': 128_000,
    'gpt-4.1': 1_000_000,
    'gpt-4.1-mini': 1_000_000,
    'gpt-4.1-nano': 1_000_000,

    // ---- Anthropic ----
    'claude-haiku-4-5-20251001': 200_000,
    'claude-haiku-4-5': 200_000,
    'claude-sonnet-4-6': 200_000,
    'claude-opus-4-7': 200_000,

    // ---- Google Gemini ----
    'gemini-2.5-flash': 1_000_000,
    'gemini-2.5-pro': 1_000_000,
    'gemini-2.5-flash-lite': 1_000_000,

    // ---- Ollama (local) ----
    'llama3.1:8b': 128_000,
    'llama3.2': 128_000,
    'llama3.3': 128_000,
    'qwen2.5:7b': 32_000,
    'gemma2:9b': 8_000,
    'mistral': 32_000,
});

/**
 * Fraction of the raw context window that we treat as USABLE by the prompt.
 * The remaining 15 % is reserved for the model's response.
 */
export const SAFETY_MARGIN_RATIO = 0.85;

/** Conservative fallback for unknown models. Matches the smallest known
 *  Ollama window (`gemma2:9b`) so the warning is rarely a footgun. */
const UNKNOWN_MODEL_FALLBACK = 8_000;

/**
 * Look up the input-token capacity for a model id. Unknown ids fall back to
 * a conservative 8 000 tokens and emit a one-time-per-call warning so the
 * caller is aware that overflow guards may behave too aggressively.
 */
export function getContextWindow(modelId: string): number {
    const known = MODEL_CONTEXT_WINDOWS[modelId];
    if (known !== undefined) {
        return known;
    }
    console.warn(
        `Unknown model '${modelId}' — assuming ${UNKNOWN_MODEL_FALLBACK}-token context window. ` +
        `Pass --on-overflow error if you want the tool to fail loudly on overflow instead of silently truncating.`,
    );
    return UNKNOWN_MODEL_FALLBACK;
}
