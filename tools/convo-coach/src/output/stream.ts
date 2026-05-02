// src/output/stream.ts — streamText loop + StdoutWriter sink + fan-out helper.
//
// Owned by U7 (plan-011 Phase 6c). See plan-011 §U7 and CC-DSGN-6 for the
// signature contracts. Implementation pattern lifted from
// `docs/research/vercel-ai-sdk-v5-multiprovider.md` §1.7.

import { performance } from 'node:perf_hooks';
import { streamText } from 'ai';

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
// streamToSinks — fan deltas to every sink in lock-step, then close them.
// ---------------------------------------------------------------------------

export interface StreamFanOutResult {
    /** Time-to-first-token in ms; undefined when the stream produced zero
     *  chunks. */
    readonly ttftMs: number | undefined;
}

/**
 * Iterate `textStream`, writing each chunk to every sink in parallel via
 * `Promise.all`. Closing the sinks is the CALLER's responsibility — the
 * orchestrator typically appends metrics to the sidecar after the stream
 * finishes, then closes everything itself. Errors propagate to the
 * caller verbatim.
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
    readonly inputTokens?: number;
    readonly outputTokens?: number;
    readonly totalTokens?: number;
}

export interface RunOneAdviceResult {
    readonly usage: AdviceUsage;
    readonly ttftMs: number;
    readonly latencyMs: number;
}

/**
 * Run one streamText call, fan deltas to `sinks`, await usage, return
 * timing + token metrics. All errors thrown inside the stream are wrapped
 * in `ProviderError` (exit 70) with the original message preserved.
 */
export async function runOneAdvice(
    input: RunOneAdviceInput,
): Promise<RunOneAdviceResult> {
    const start = performance.now();

    // Capture errors emitted via onError callback as well — some
    // provider errors (e.g. auth failures on first byte) surface there in
    // ai@6.x rather than via the textStream iterator.
    let onErrorCapture: unknown;

    let result: ReturnType<typeof streamText>;
    try {
        result = streamText({
            model: input.model,
            system: input.system,
            prompt: input.user,
            maxOutputTokens: input.maxOutputTokens ?? 2048,
            ...(input.abortSignal !== undefined && { abortSignal: input.abortSignal }),
            onError: ({ error }: { error: unknown }) => {
                if (onErrorCapture === undefined) onErrorCapture = error;
            },
        });
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new ProviderError(`streamText setup failed: ${message}`);
    }

    let ttftMs: number | undefined;
    try {
        const fanOut = await streamToSinks(result.textStream, input.sinks);
        ttftMs = fanOut.ttftMs;
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new ProviderError(`stream failed: ${message}`);
    }

    if (onErrorCapture !== undefined) {
        const message = onErrorCapture instanceof Error
            ? onErrorCapture.message
            : String(onErrorCapture);
        throw new ProviderError(`stream failed: ${message}`);
    }

    const latencyMs = performance.now() - start;

    // Resolve usage AFTER the stream loop ends — per Vercel AI SDK §1.4.
    let usage: AdviceUsage;
    try {
        const raw = await result.usage;
        usage = {
            ...(typeof raw.inputTokens === 'number' && { inputTokens: raw.inputTokens }),
            ...(typeof raw.outputTokens === 'number' && { outputTokens: raw.outputTokens }),
            ...(typeof raw.totalTokens === 'number' && { totalTokens: raw.totalTokens }),
        };
    } catch {
        // Some providers (Ollama, MLX, certain Azure deployments) don't
        // populate usage. Leave it empty rather than failing the request.
        usage = {};
    }

    return {
        usage,
        ttftMs: ttftMs ?? 0,
        latencyMs,
    };
}
