// src/llm/budget.ts — token-budget guard for the convo-coach orchestrator.
//
// Two-tier estimator (CC-ADR-4):
//   * OpenAI / Azure-OpenAI:   real BPE count via js-tiktoken (cl100k_base).
//   * everyone else:           4-chars-per-token heuristic.
//
// `applyBudget` compares the (system + user-records + per-record overhead)
// estimate against `getContextWindow(modelId) * SAFETY_MARGIN_RATIO` and
// either passes the records through, drops them from the head/tail until
// they fit, or throws a typed `ConvoCoachError('BAD_USAGE')`.
//
// See §CC-DSGN-6 of project-design.md for the signature contract and
// §CC-DSGN-12 CC-ADR-4 for the architectural rationale.

import { getEncoding, type Tiktoken } from 'js-tiktoken';
import {
    ConvoCoachError,
    type NormalisedRecord,
    type OverflowStrategy,
    type ProviderName,
} from '../types.js';
import { SAFETY_MARGIN_RATIO, getContextWindow } from './model-context-windows.js';

// ---------------------------------------------------------------------------
// Lazy js-tiktoken singleton — the ranks file is ~1.5 MB and we only want
// to pay the load cost when an OpenAI-family request actually happens.
// ---------------------------------------------------------------------------

let cl100kEncoder: Tiktoken | undefined;

function getCl100kEncoder(): Tiktoken {
    if (cl100kEncoder === undefined) {
        cl100kEncoder = getEncoding('cl100k_base');
    }
    return cl100kEncoder;
}

/** Approximate tokens consumed per record by formatting (timestamp + label
 *  + delimiter newlines). U8's prompt builder formats records similarly;
 *  we keep this constant in sync via §CC-DSGN-12 CC-ADR-4. */
const PER_RECORD_OVERHEAD_TOKENS = 10;

/** Providers whose tokenizer is known to be OpenAI-compatible (cl100k_base
 *  family). Everything else falls back to the 4-cpt heuristic. */
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
 *   * `openai` / `azure-openai` → real BPE count via js-tiktoken.
 *   * everyone else            → `Math.ceil(text.length / 4)` heuristic.
 *
 * Pure function; safe to call repeatedly.
 */
export function estimateTokens(text: string, provider: ProviderName): number {
    if (text.length === 0) {
        return 0;
    }
    if (OPENAI_FAMILY.has(provider)) {
        return getCl100kEncoder().encode(text).length;
    }
    return Math.ceil(text.length / 4);
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
    systemPromptTokens: number,
    provider: ProviderName,
): number {
    let total = systemPromptTokens;
    for (const r of records) {
        total += estimateTokens(r.text, provider) + PER_RECORD_OVERHEAD_TOKENS;
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

    const systemPromptTokens = estimateTokens(systemPrompt, provider);
    const originalTokenCount = totalTokens(records, systemPromptTokens, provider);

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
        runningTotal -= estimateTokens(dropped.text, provider) + PER_RECORD_OVERHEAD_TOKENS;
    }

    return {
        records: working,
        truncated: true,
        originalTokenCount,
        finalTokenCount: runningTotal,
    };
}
