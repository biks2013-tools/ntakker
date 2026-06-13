// src/output/stream.ts — LangChain `model.stream()` loop + StdoutWriter sink
// + fan-out helper.
//
// Owned by U7 (plan-011 Phase 6c). LangChain refactor: replaces the previous
// `streamText` Vercel-AI-SDK pipeline with `BaseChatModel.stream(messages)`
// returning `AsyncIterable<AIMessageChunk>`. Per-chunk text is read from
// `chunk.content`; aggregated `usage_metadata` lives on the final concatenated
// chunk. Cancellation flows through the `signal` option of `.stream()`.

import { performance } from 'node:perf_hooks';

import type { AIMessageChunk } from '@langchain/core/messages';
import { HumanMessage, SystemMessage } from '@langchain/core/messages';
import { concat } from '@langchain/core/utils/stream';

import {
    ProviderError,
    type LanguageModel,
    type StreamSink,
} from '../types.js';

// ---------------------------------------------------------------------------
// StdoutWriter — direct unbuffered writes (per R7 in plan-011).
// ---------------------------------------------------------------------------

export class StdoutWriter implements StreamSink {
    write(chunk: string): void {
        if (chunk.length === 0) return;
        process.stdout.write(chunk);
    }
    // No close() — process.stdout is owned by the runtime.
}

// ---------------------------------------------------------------------------
// streamToSinks — fan deltas to every sink in lock-step. Closing the sinks
// remains the orchestrator's responsibility (it appends sidecar metrics
// after the loop).
// ---------------------------------------------------------------------------

export interface StreamFanOutResult {
    /** Time-to-first-token in ms; undefined when the stream produced zero
     *  chunks. */
    readonly ttftMs: number | undefined;
}

/**
 * Iterate `textStream`, writing each chunk to every sink in parallel via
 * `Promise.all`. Errors propagate to the caller verbatim.
 */
export async function streamToSinks(
    textStream: AsyncIterable<string>,
    sinks: readonly StreamSink[],
): Promise<StreamFanOutResult> {
    const start = performance.now();
    let ttftMs: number | undefined;

    for await (const chunk of textStream) {
        if (ttftMs === undefined) {
            ttftMs = performance.now() - start;
        }
        await Promise.all(sinks.map((sink) => Promise.resolve(sink.write(chunk))));
    }

    return { ttftMs };
}

// ---------------------------------------------------------------------------
// Internal: error classification (B3, EVAL 2026-06-12). LangChain provider
// errors carry an HTTP status in various shapes (`status`, `error.status`,
// OpenAI-style `response.status`); transport failures surface as Node
// system errors (`ECONNRESET`, `fetch failed`, …). Preserve both signals
// on the ProviderError so the orchestrator can retry intelligently.
// ---------------------------------------------------------------------------

function extractStatus(err: unknown): number | undefined {
    if (err === null || typeof err !== 'object') return undefined;
    const candidate = err as {
        status?: unknown;
        statusCode?: unknown;
        error?: { status?: unknown };
        response?: { status?: unknown };
    };
    for (const value of [
        candidate.status,
        candidate.statusCode,
        candidate.error?.status,
        candidate.response?.status,
    ]) {
        if (typeof value === 'number' && value >= 100 && value < 600) return value;
    }
    return undefined;
}

const NETWORK_ERROR_MARKERS = [
    'ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'ENOTFOUND', 'EPIPE',
    'EAI_AGAIN', 'fetch failed', 'network', 'socket hang up', 'aborted by server',
];

function looksLikeNetworkError(err: unknown): boolean {
    const message = err instanceof Error
        ? `${err.message} ${(err.cause instanceof Error ? err.cause.message : '')} ${(err as { code?: string }).code ?? ''}`
        : String(err);
    const lowered = message.toLowerCase();
    return NETWORK_ERROR_MARKERS.some((marker) => lowered.includes(marker.toLowerCase()));
}

function toProviderError(err: unknown, phase: 'setup' | 'stream'): ProviderError {
    const message = err instanceof Error ? err.message : String(err);
    const status = extractStatus(err);
    const retryable = status !== undefined
        ? ProviderError.isRetryableStatus(status)
        : looksLikeNetworkError(err);
    return new ProviderError(
        `stream ${phase} failed: ${message}${status !== undefined ? ` (HTTP ${status})` : ''}`,
        { ...(status !== undefined && { status }), retryable },
    );
}

// ---------------------------------------------------------------------------
// Internal: convert LangChain's AIMessageChunk.content (string | array) to
// a plain string. The `content` field is `MessageContent` which is either a
// string or an array of `MessageContentText | MessageContentImageUrl | …`
// blocks. For chat completions we only ever see text blocks.
// ---------------------------------------------------------------------------

function chunkText(chunk: AIMessageChunk): string {
    const c = chunk.content;
    if (typeof c === 'string') return c;
    if (Array.isArray(c)) {
        let out = '';
        for (const block of c) {
            if (block && typeof block === 'object' && 'type' in block && block.type === 'text' && typeof (block as { text?: unknown }).text === 'string') {
                out += (block as { text: string }).text;
            }
        }
        return out;
    }
    return '';
}

// ---------------------------------------------------------------------------
// Internal: project LangChain's UsageMetadata onto our flat AdviceUsage shape.
// ---------------------------------------------------------------------------

interface UsageMetadataLike {
    input_tokens?: number;
    output_tokens?: number;
    total_tokens?: number;
}

function projectUsage(meta: UsageMetadataLike | undefined): AdviceUsage {
    if (meta === undefined) return {};
    const out: AdviceUsage = {};
    if (typeof meta.input_tokens === 'number') out.inputTokens = meta.input_tokens;
    if (typeof meta.output_tokens === 'number') out.outputTokens = meta.output_tokens;
    if (typeof meta.total_tokens === 'number') out.totalTokens = meta.total_tokens;
    return out;
}

// ---------------------------------------------------------------------------
// runOneAdvice — full single-shot streaming pipeline.
// ---------------------------------------------------------------------------

export interface RunOneAdviceInput {
    readonly model: LanguageModel;
    readonly system: string;
    readonly user: string;
    readonly sinks: readonly StreamSink[];
    readonly abortSignal?: AbortSignal;
    /** Optional cap on output tokens. Defaults to 2048 per FR-CC-13. */
    readonly maxOutputTokens?: number;
}

export interface AdviceUsage {
    inputTokens?: number;
    outputTokens?: number;
    totalTokens?: number;
}

export interface RunOneAdviceResult {
    readonly usage: AdviceUsage;
    readonly ttftMs: number;
    readonly latencyMs: number;
}

/**
 * Stream one chat completion via LangChain's `model.stream()`, fanning text
 * deltas into `sinks` and aggregating usage metadata from the final chunk.
 * All errors are wrapped in `ProviderError` (exit 70) with the original
 * message preserved.
 */
export async function runOneAdvice(
    input: RunOneAdviceInput,
): Promise<RunOneAdviceResult> {
    const start = performance.now();

    const messages = [
        new SystemMessage(input.system),
        new HumanMessage(input.user),
    ];

    const callOptions: { signal?: AbortSignal; maxTokens?: number } = {};
    if (input.abortSignal !== undefined) callOptions.signal = input.abortSignal;
    if (input.maxOutputTokens !== undefined) callOptions.maxTokens = input.maxOutputTokens;

    let stream: AsyncIterable<AIMessageChunk>;
    try {
        stream = await input.model.stream(messages, callOptions);
    } catch (err) {
        throw toProviderError(err, 'setup');
    }

    let ttftMs: number | undefined;
    let aggregate: AIMessageChunk | undefined;

    try {
        for await (const chunk of stream) {
            const text = chunkText(chunk);
            if (text.length > 0 && ttftMs === undefined) {
                ttftMs = performance.now() - start;
            }
            if (text.length > 0) {
                await Promise.all(
                    input.sinks.map((sink) => Promise.resolve(sink.write(text))),
                );
            }
            aggregate = aggregate === undefined ? chunk : concat(aggregate, chunk);
        }
    } catch (err) {
        throw toProviderError(err, 'stream');
    }

    const latencyMs = performance.now() - start;

    // Usage lives on the final aggregated chunk; some providers
    // (Ollama, MLX, certain Azure deployments) don't populate it. The
    // top-level usage_metadata field is the standard cross-provider place.
    const usage = projectUsage(
        aggregate?.usage_metadata as UsageMetadataLike | undefined,
    );

    return {
        usage,
        ttftMs: ttftMs ?? 0,
        latencyMs,
    };
}
