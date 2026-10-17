// src/llm/budget.ts — token-budget guard for the convo-coach orchestrator.
//
// Two-tier estimator (CC-ADR-4):
//   * OpenAI / Azure-OpenAI:   real BPE count via js-tiktoken — o200k_base
//                              for the gpt-4o / 4.1 / 4.5 / 5 / o-series
//                              models, cl100k_base for older ones
//                              (EVAL-2026-06-12 B10).
//   * everyone else:           4-chars-per-token heuristic.
//
// EVAL-2026-06-12 B5 + EVAL-2026-10-16 CC-10 (plan-023 T5):
//   * Records are immutable, so each record's count is cached (a WeakMap
//     per tokenizer); stdin mode re-budgets the same records on every
//     trigger and used to re-encode all of them each time.
//   * The system prompt's count is cached too.
//   * Only the one rank file in use is loaded, through `js-tiktoken/lite`,
//     and only on first use — the main entry bundled every encoding.
//
// `applyBudget` compares the (system + user-records + per-record overhead)
// estimate against `getContextWindow(modelId) * SAFETY_MARGIN_RATIO` and
// either passes the records through, drops them from the head/tail until
// they fit, or throws a typed `ConvoCoachError('BAD_USAGE')`.
//
// See §CC-DSGN-6 of project-design.md for the signature contract and
// §CC-DSGN-12 CC-ADR-4 for the architectural rationale.

import { createRequire } from 'node:module';
import { Tiktoken, type TiktokenBPE } from 'js-tiktoken/lite';
import {
    ConvoCoachError,
    type NormalisedRecord,
    type OverflowStrategy,
    type ProviderName,
} from '../types.js';
import { SAFETY_MARGIN_RATIO, getContextWindow } from './model-context-windows.js';

// ---------------------------------------------------------------------------
// Lazy tokenizers — building one costs ~200 ms, so it happens at most
// once per encoding per process, and only for OpenAI-family requests.
// ---------------------------------------------------------------------------

type EncodingName = 'o200k_base' | 'cl100k_base';

const requireRanks = createRequire(import.meta.url);
const encoders = new Map<EncodingName, Tiktoken>();

function getEncoder(name: EncodingName): Tiktoken {
    let encoder = encoders.get(name);
    if (encoder === undefined) {
        const loaded = requireRanks(`js-tiktoken/ranks/${name}`) as TiktokenBPE | { default: TiktokenBPE };
        const ranks = 'default' in loaded ? loaded.default : loaded;
        encoder = new Tiktoken(ranks);
        encoders.set(name, encoder);
    }
    return encoder;
}

/**
 * The BPE encoding a model id tokenizes with. gpt-4o, gpt-4.1, gpt-4.5,
 * gpt-5.x and the o-series use o200k_base; older models use cl100k_base.
 * An unknown id is assumed current (o200k_base). Azure deployment names
 * follow the model names in this project (e.g. `gpt-5.1`).
 */
export function encodingForModel(modelId: string | undefined): EncodingName {
    if (modelId === undefined) return 'o200k_base';
    const id = modelId.toLowerCase();
    if (/^(gpt-3\.5|gpt-4(?![.o0-9])|gpt-4-|text-|davinci|babbage)/.test(id)) {
        return 'cl100k_base';
    }
    return 'o200k_base';
}

/** Approximate tokens consumed per record by formatting (timestamp + label
 *  + delimiter newlines). U8's prompt builder formats records similarly;
 *  we keep this constant in sync via §CC-DSGN-12 CC-ADR-4. */
const PER_RECORD_OVERHEAD_TOKENS = 10;

/** Providers whose tokenizer is known to be OpenAI-compatible (o200k_base /
 *  cl100k_base). Everything else falls back to the 4-cpt heuristic. */
const OPENAI_FAMILY: ReadonlySet<ProviderName> = new Set<ProviderName>([
    'openai',
    'azure-openai',
]);

// ---------------------------------------------------------------------------
// estimateTokens
// ---------------------------------------------------------------------------

/**
 * Estimate the number of tokens `text` will consume on the given provider.
 *
 *   * `openai` / `azure-openai` → real BPE count via js-tiktoken, with the
 *                                  encoding `modelId` uses.
 *   * everyone else            → `Math.ceil(text.length / 4)` heuristic.
 *
 * Pure function; safe to call repeatedly.
 */
export function estimateTokens(text: string, provider: ProviderName, modelId?: string): number {
    if (text.length === 0) {
        return 0;
    }
    if (OPENAI_FAMILY.has(provider)) {
        return getEncoder(encodingForModel(modelId)).encode(text).length;
    }
    return Math.ceil(text.length / 4);
}

/** Per-tokenizer cache of record counts. Keyed by the record object, which
 *  stdin mode keeps across triggers. */
const recordTokenCache = new Map<string, WeakMap<NormalisedRecord, number>>();
/** Last system prompt counted per tokenizer. */
const systemPromptCache = new Map<string, { prompt: string; tokens: number }>();

function tokenizerKey(provider: ProviderName, modelId: string): string {
    return OPENAI_FAMILY.has(provider) ? encodingForModel(modelId) : 'heuristic';
}

/** Tokens for one record, text plus formatting overhead, cached. */
function recordTokens(record: NormalisedRecord, provider: ProviderName, modelId: string): number {
    const key = tokenizerKey(provider, modelId);
    let cache = recordTokenCache.get(key);
    if (cache === undefined) {
        cache = new WeakMap();
        recordTokenCache.set(key, cache);
    }
    let n = cache.get(record);
    if (n === undefined) {
        n = estimateTokens(record.text, provider, modelId) + PER_RECORD_OVERHEAD_TOKENS;
        cache.set(record, n);
    }
    return n;
}

function systemPromptTokens(prompt: string, provider: ProviderName, modelId: string): number {
    const key = tokenizerKey(provider, modelId);
    const cached = systemPromptCache.get(key);
    if (cached !== undefined && cached.prompt === prompt) return cached.tokens;
    const tokens = estimateTokens(prompt, provider, modelId);
    systemPromptCache.set(key, { prompt, tokens });
    return tokens;
}

// ---------------------------------------------------------------------------
// applyBudget
// ---------------------------------------------------------------------------

export interface BudgetResult {
    /** The records that should be sent to the provider (possibly truncated). */
    readonly records: NormalisedRecord[];
    /** True when at least one record was dropped to fit the budget. */
    readonly truncated: boolean;
    /** Token estimate BEFORE any truncation. */
    readonly originalTokenCount: number;
    /** Token estimate AFTER truncation. Equals originalTokenCount when no
     *  records were dropped. */
    readonly finalTokenCount: number;
}

/** Sum the token cost of the system prompt plus an array of records. */
function totalTokens(
    records: readonly NormalisedRecord[],
    promptTokens: number,
    provider: ProviderName,
    modelId: string,
): number {
    let total = promptTokens;
    for (const r of records) {
        total += recordTokens(r, provider, modelId);
    }
    return total;
}

/**
 * Compare the (systemPrompt + records) estimate to the model's usable
 * context window. If it overflows, apply `strategy`:
 *
 *   * `'error'`           → throw `ConvoCoachError('BAD_USAGE')`.
 *   * `'truncate-start'`  → drop oldest records (front of array) until it fits.
 *   * `'truncate-end'`    → drop newest records (end of array) until it fits.
 *
 * The `records` argument is treated as immutable; the returned `records`
 * field is a fresh array.
 */
export function applyBudget(
    records: NormalisedRecord[],
    systemPrompt: string,
    modelId: string,
    provider: ProviderName,
    strategy: OverflowStrategy,
): BudgetResult {
    const contextWindow = getContextWindow(modelId);
    const budget = Math.floor(contextWindow * SAFETY_MARGIN_RATIO);

    const promptTokens = systemPromptTokens(systemPrompt, provider, modelId);
    const originalTokenCount = totalTokens(records, promptTokens, provider, modelId);

    if (originalTokenCount <= budget) {
        return {
            records: [...records],
            truncated: false,
            originalTokenCount,
            finalTokenCount: originalTokenCount,
        };
    }

    if (strategy === 'error') {
        throw new ConvoCoachError(
            'BAD_USAGE',
            `Transcript (${originalTokenCount} tokens) exceeds model '${modelId}' budget ` +
            `(${budget} tokens after ${SAFETY_MARGIN_RATIO * 100}% safety margin). ` +
            `Use --on-overflow truncate-start|truncate-end or pick a model with a larger context window.`,
        );
    }

    // Greedy truncation: drop one record at a time from the chosen end and
    // re-check. The per-record overhead makes the running total cheap to
    // recompute incrementally.
    const working = [...records];
    let runningTotal = originalTokenCount;
    while (runningTotal > budget && working.length > 0) {
        const dropped = strategy === 'truncate-start' ? working.shift() : working.pop();
        if (dropped === undefined) {
            break;
        }
        runningTotal -= recordTokens(dropped, provider, modelId);
    }

    return {
        records: working,
        truncated: true,
        originalTokenCount,
        finalTokenCount: runningTotal,
    };
}
