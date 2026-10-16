// src/index.ts — convo-coach orchestrator entry.
//
// Wires together U2 (config) → U3 (CLI args) → U4 (transcript reader +
// window) → U5 (autodetect / stdin) → U6 (LLM factory) → U7 (sidecar +
// stream) → U8 (prompt builder) → U9 (token budget). The exported `main()`
// is testable; the side-effecting shebang launcher lives in `cli.ts`.
//
// Two execution modes are dispatched from a single entry:
//   * file   — single-shot: read transcript file → window → budget →
//              build prompt → stream advice → finalise sidecar → exit.
//   * stdin  — long-lived: each trigger from `readFromStdin` runs the
//              same downstream pipeline; sidecar is fresh per request.
//
// All errors are caught at the top level and translated to the exit codes
// declared in `EXIT_CODES`.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { helpText, isStdinPiped, parseCliArgs } from './args.js';
import { loadConfig } from './config.js';
import {
    ConfigError,
    ConvoCoachError,
    EXIT_CODES,
    ProviderError,
    UsageError,
    type CliArgs,
    type ExitCodeKey,
    type NormalisedRecord,
    type OverflowStrategy,
    type ResolvedConfig,
    type SidecarFrontMatter,
    type StreamSink,
    type WindowFilter,
} from './types.js';
import { autodetectLatestSidecar } from './transcript/autodetect.js';
import { readFromStdin, type StdinTrigger } from './transcript/stdin.js';
import { readTranscriptFile } from './transcript/reader.js';
import { applyWindow, parseSinceArg } from './transcript/window.js';
import { parseDuration } from './transcript/duration.js';
import { buildLanguageModel, type BuildLanguageModelResult } from './llm/factory.js';
import { applyBudget } from './llm/budget.js';
import { buildPrompt, loadSystemPrompt } from './prompt/build.js';
import {
    SidecarWriter,
    buildSidecarPath,
} from './output/sidecar.js';
import { StdoutWriter, runOneAdvice } from './output/stream.js';

interface PackageJsonShape {
    readonly version?: string;
}

// ---------------------------------------------------------------------------
// version
// ---------------------------------------------------------------------------

function readVersion(): string {
    try {
        const here = dirname(fileURLToPath(import.meta.url));
        // dist/index.js → ../package.json
        const pkgPath = join(here, '..', 'package.json');
        const raw = readFileSync(pkgPath, 'utf8');
        const parsed = JSON.parse(raw) as PackageJsonShape;
        if (typeof parsed.version === 'string' && parsed.version.length > 0) {
            return parsed.version;
        }
    } catch {
        // fall through to default
    }
    return '0.1.0';
}

// ---------------------------------------------------------------------------
// helpers shared by file and stdin modes
// ---------------------------------------------------------------------------

function expandTilde(p: string): string {
    if (p === '~') return homedir();
    if (p.startsWith('~/')) return join(homedir(), p.slice(2));
    return p;
}

function resolveRecordingsDir(config: ResolvedConfig, cliArgs: CliArgs): string {
    const fromCli = cliArgs.recordingsDir;
    const fromEnv = config.get('NTAKKER_RECORDINGS_DIR');
    const raw = fromCli ?? fromEnv ?? join(homedir(), 'Recordings');
    return expandTilde(raw);
}

function resolveOverflow(config: ResolvedConfig, cliArgs: CliArgs): OverflowStrategy {
    if (cliArgs.onOverflow !== undefined) return cliArgs.onOverflow;
    const env = config.get('COACH_ON_OVERFLOW');
    if (env === 'truncate-start' || env === 'truncate-end' || env === 'error') {
        return env;
    }
    return 'truncate-start';
}

function buildWindowFilter(cliArgs: CliArgs, transcriptEnd: Date): WindowFilter {
    const filter: { last?: { value: number; unitMs: number }; since?: Date } = {};
    if (cliArgs.last !== undefined) {
        const parsed = parseDuration(cliArgs.last);
        filter.last = { value: parsed.value, unitMs: parsed.unitMs };
    }
    if (cliArgs.since !== undefined) {
        filter.since = parseSinceArg(cliArgs.since, transcriptEnd);
    }
    return filter;
}

function makeFrontMatter(
    built: BuildLanguageModelResult,
    cliArgs: CliArgs,
    transcriptPath: string | undefined,
): SidecarFrontMatter {
    const fm: SidecarFrontMatter = {
        provider: built.provider,
        model: built.modelId,
        ...(transcriptPath !== undefined && { transcript: transcriptPath }),
        window: {
            ...(cliArgs.last !== undefined && { last: cliArgs.last }),
            ...(cliArgs.since !== undefined && { since: cliArgs.since }),
        },
        createdAt: new Date().toISOString(),
    };
    return fm;
}

interface StageInput {
    readonly records: NormalisedRecord[];
    readonly transcriptEnd: Date;
}

interface StagedAdvice {
    readonly system: string;
    readonly user: string;
    readonly window: WindowFilter;
}

/**
 * Apply the window → budget → prompt-build pipeline to a record set.
 * Logs a stderr warning when the budget had to drop records.
 */
function stageAdvice(
    stage: StageInput,
    cliArgs: CliArgs,
    built: BuildLanguageModelResult,
    systemPrompt: string,
    overflow: OverflowStrategy,
    transcriptPath: string | undefined,
): StagedAdvice {
    const window = buildWindowFilter(cliArgs, stage.transcriptEnd);
    const sliced = applyWindow(stage.records, window, stage.transcriptEnd);

    const budgeted = applyBudget(
        sliced,
        systemPrompt,
        built.modelId,
        built.provider,
        overflow,
    );

    if (budgeted.truncated) {
        process.stderr.write(
            `[convo-coach] Transcript truncated from ${budgeted.originalTokenCount} ` +
            `tokens to ${budgeted.finalTokenCount} tokens (strategy=${overflow}) ` +
            `to fit model context window.\n`,
        );
    }

    const prompt = buildPrompt({
        records: budgeted.records,
        systemPrompt,
        ...(transcriptPath !== undefined && { transcriptPath }),
        window,
    });

    return { system: prompt.system, user: prompt.user, window };
}

function metricsSummary(
    built: BuildLanguageModelResult,
    sidecarPath: string,
    metrics: { promptTokens?: number; completionTokens?: number; totalTokens?: number; ttftMs: number; latencyMs: number },
    extras: Record<string, string | number> = {},
): string {
    const inT = metrics.promptTokens ?? 'N/A';
    const outT = metrics.completionTokens ?? 'N/A';
    const totalT = metrics.totalTokens ?? 'N/A';
    const extraStr = Object.entries(extras)
        .map(([k, v]) => ` ${k}=${v}`)
        .join('');
    return (
        `[convo-coach] provider=${built.provider} model=${built.modelId} ` +
        `tokens=${inT}/${outT}/${totalT} ` +
        `ttft=${Math.round(metrics.ttftMs)}ms latency=${Math.round(metrics.latencyMs)}ms ` +
        `sidecar=${sidecarPath}${extraStr}\n`
    );
}

// ---------------------------------------------------------------------------
// Mode runners
// ---------------------------------------------------------------------------

interface RunContext {
    readonly cliArgs: CliArgs;
    readonly config: ResolvedConfig;
    readonly built: BuildLanguageModelResult;
    readonly systemPrompt: string;
    readonly overflow: OverflowStrategy;
    readonly abortController: AbortController;
}

async function runFileMode(ctx: RunContext, transcriptPath: string): Promise<void> {
    const { records, transcriptEnd } = readTranscriptFile(transcriptPath);

    const staged = stageAdvice(
        { records, transcriptEnd },
        ctx.cliArgs,
        ctx.built,
        ctx.systemPrompt,
        ctx.overflow,
        transcriptPath,
    );

    const sidecarPath = buildSidecarPath({
        transcriptPath,
        fallbackDir: dirname(transcriptPath),
        now: new Date(),
    });
    const frontMatter = makeFrontMatter(ctx.built, ctx.cliArgs, transcriptPath);
    const sidecar = new SidecarWriter(sidecarPath, frontMatter);
    const stdoutSink = new StdoutWriter();
    const sinks: StreamSink[] = [stdoutSink, sidecar];

    let result;
    try {
        result = await runOneAdvice({
            model: ctx.built.model,
            system: staged.system,
            user: staged.user,
            sinks,
            abortSignal: ctx.abortController.signal,
        });
    } catch (err) {
        // Best-effort: write an error footer to the sidecar and finalise
        // it so the user can inspect what happened.
        try {
            sidecar.appendFooter(`\n\n# ERROR\n\n${err instanceof Error ? err.message : String(err)}\n`);
            sidecar.close();
        } catch {
            /* swallow — we're already failing */
        }
        throw err;
    }

    sidecar.appendMetricsBlock({
        ...(result.usage.inputTokens !== undefined && { promptTokens: result.usage.inputTokens }),
        ...(result.usage.outputTokens !== undefined && { completionTokens: result.usage.outputTokens }),
        ...(result.usage.totalTokens !== undefined && { totalTokens: result.usage.totalTokens }),
        ttftMs: Math.round(result.ttftMs),
        latencyMs: Math.round(result.latencyMs),
    });
    // Atomically rename the .tmp sidecar to its final path now that
    // metrics have been appended. streamToSinks intentionally does NOT
    // close sinks — the orchestrator owns that lifecycle.
    sidecar.close();

    process.stdout.write('\n');
    process.stderr.write(metricsSummary(ctx.built, sidecar.path, {
        ...(result.usage.inputTokens !== undefined && { promptTokens: result.usage.inputTokens }),
        ...(result.usage.outputTokens !== undefined && { completionTokens: result.usage.outputTokens }),
        ...(result.usage.totalTokens !== undefined && { totalTokens: result.usage.totalTokens }),
        ttftMs: result.ttftMs,
        latencyMs: result.latencyMs,
    }));
}

/** B3 (EVAL 2026-06-12): consecutive-failure budget for the long-lived
 *  stdin coaching session. One transient 429 / network blip must not
 *  kill the session; sustained failure (e.g. a revoked key failing
 *  every trigger) still exits after this many triggers in a row. */
const MAX_CONSECUTIVE_TRIGGER_FAILURES = 5;
/** Backoff before processing the next trigger after failure N (capped). */
const TRIGGER_FAILURE_BACKOFF_MS = [1_000, 4_000, 15_000] as const;

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runStdinMode(ctx: RunContext): Promise<void> {
    const debounceRaw = ctx.cliArgs.debounce ?? ctx.config.get('COACH_DEBOUNCE') ?? '15s';
    const debounceMs = parseDuration(debounceRaw).ms;
    const recordingsDir = resolveRecordingsDir(ctx.config, ctx.cliArgs);

    let consecutiveFailures = 0;
    let separatorNeeded = false;
    for await (const batch of readFromStdin({ debounceMs })) {
        const trigger: StdinTrigger = batch;
        if (trigger.records.length === 0) {
            // Empty buffer (e.g. EOF before any input) — skip silently
            // unless this was the EOF event, in which case we're done.
            if (trigger.reason === 'eof') return;
            continue;
        }

        const staged = stageAdvice(
            { records: trigger.records, transcriptEnd: trigger.transcriptEnd },
            ctx.cliArgs,
            ctx.built,
            ctx.systemPrompt,
            ctx.overflow,
            undefined,
        );

        if (separatorNeeded) {
            process.stdout.write('\n---\n');
        }
        separatorNeeded = true;

        const sidecarPath = buildSidecarPath({
            fallbackDir: recordingsDir,
            now: new Date(),
        });
        const frontMatter = makeFrontMatter(ctx.built, ctx.cliArgs, undefined);
        const sidecar = new SidecarWriter(sidecarPath, frontMatter);
        const sinks: StreamSink[] = [new StdoutWriter(), sidecar];

        let result;
        try {
            result = await runOneAdvice({
                model: ctx.built.model,
                system: staged.system,
                user: staged.user,
                sinks,
                abortSignal: ctx.abortController.signal,
            });
        } catch (err) {
            try {
                sidecar.appendFooter(`\n\n# ERROR\n\n${err instanceof Error ? err.message : String(err)}\n`);
                sidecar.close();
            } catch {
                /* swallow */
            }
            // B3 (EVAL 2026-06-12): a provider failure must not kill the
            // long-lived coaching session attached to an ongoing
            // conversation. Exit only on configuration/usage errors, a
            // user-initiated abort, or sustained consecutive failure.
            if (err instanceof ConfigError || err instanceof UsageError) throw err;
            if (ctx.abortController.signal.aborted) throw err;

            consecutiveFailures += 1;
            if (consecutiveFailures >= MAX_CONSECUTIVE_TRIGGER_FAILURES) {
                process.stderr.write(
                    `[convo-coach] giving up after ${consecutiveFailures} consecutive provider failures\n`,
                );
                throw err;
            }

            const message = err instanceof Error ? err.message : String(err);
            const backoff = TRIGGER_FAILURE_BACKOFF_MS[
                Math.min(consecutiveFailures - 1, TRIGGER_FAILURE_BACKOFF_MS.length - 1)
            ] as number;
            const retryable = err instanceof ProviderError ? err.retryable : false;
            process.stderr.write(
                `[convo-coach] advice failed (${message}) — session continues ` +
                `(failure ${consecutiveFailures}/${MAX_CONSECUTIVE_TRIGGER_FAILURES}` +
                `${retryable ? `, backing off ${Math.round(backoff / 1000)}s` : ''})\n`,
            );
            if (retryable) {
                await sleep(backoff);
            }
            if (trigger.reason === 'eof') return;
            continue;
        }

        // B3: a successful round-trip resets the failure budget.
        consecutiveFailures = 0;

        sidecar.appendMetricsBlock({
            ...(result.usage.inputTokens !== undefined && { promptTokens: result.usage.inputTokens }),
            ...(result.usage.outputTokens !== undefined && { completionTokens: result.usage.outputTokens }),
            ...(result.usage.totalTokens !== undefined && { totalTokens: result.usage.totalTokens }),
            ttftMs: Math.round(result.ttftMs),
            latencyMs: Math.round(result.latencyMs),
        });
        sidecar.close();

        process.stdout.write('\n');
        process.stderr.write(metricsSummary(
            ctx.built,
            sidecar.path,
            {
                ...(result.usage.inputTokens !== undefined && { promptTokens: result.usage.inputTokens }),
                ...(result.usage.outputTokens !== undefined && { completionTokens: result.usage.outputTokens }),
                ...(result.usage.totalTokens !== undefined && { totalTokens: result.usage.totalTokens }),
                ttftMs: result.ttftMs,
                latencyMs: result.latencyMs,
            },
            { reason: trigger.reason },
        ));

        if (trigger.reason === 'eof') return;
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

export async function main(argv: readonly string[]): Promise<number> {
    let cliArgs: CliArgs;
    try {
        cliArgs = parseCliArgs(argv);
    } catch (err) {
        if (err instanceof ConvoCoachError) {
            process.stderr.write(`error: ${err.message}\n`);
            return EXIT_CODES[err.code];
        }
        throw err;
    }

    if (cliArgs.help === true) {
        process.stdout.write(helpText());
        return EXIT_CODES.SUCCESS;
    }

    if (cliArgs.version === true) {
        process.stdout.write(`convo-coach ${readVersion()}\n`);
        return EXIT_CODES.SUCCESS;
    }

    const config = loadConfig(cliArgs);
    const built = buildLanguageModel(config, cliArgs.provider, cliArgs.model);
    const systemPrompt = loadSystemPrompt(
        cliArgs.systemPrompt ?? config.get('COACH_SYSTEM_PROMPT_PATH'),
    );
    const overflow = resolveOverflow(config, cliArgs);

    const abortController = new AbortController();
    const onSigint = (): void => {
        process.stderr.write('\n[convo-coach] aborting on SIGINT…\n');
        abortController.abort();
    };
    process.on('SIGINT', onSigint);

    // Decide input mode.
    // Priority per AC-CC-8: explicit --transcript wins over stdin, which
    // wins over autodetect.
    let transcriptPath: string | undefined;
    let useStdin = false;
    if (cliArgs.transcript !== undefined) {
        transcriptPath = cliArgs.transcript;
    } else if (isStdinPiped(process.stdin.isTTY)) {
        useStdin = true;
    } else {
        const recordingsDir = resolveRecordingsDir(config, cliArgs);
        transcriptPath = autodetectLatestSidecar(recordingsDir);
    }

    const ctx: RunContext = {
        cliArgs,
        config,
        built,
        systemPrompt,
        overflow,
        abortController,
    };

    try {
        if (useStdin) {
            await runStdinMode(ctx);
        } else {
            await runFileMode(ctx, transcriptPath as string);
        }
        return EXIT_CODES.SUCCESS;
    } finally {
        process.removeListener('SIGINT', onSigint);
    }
}

/**
 * Top-level wrapper: invoke `main()` and translate any uncaught
 * `ConvoCoachError` into its `EXIT_CODES` value. Any other exception
 * surfaces as exit code 1 with a `[convo-coach] Unexpected error:` prefix
 * and the stack trace.
 */
export async function runCli(argv: readonly string[]): Promise<number> {
    try {
        return await main(argv);
    } catch (err) {
        if (err instanceof ConvoCoachError) {
            process.stderr.write(`error: ${err.message}\n`);
            const code: ExitCodeKey = err.code;
            return EXIT_CODES[code];
        }
        if (err instanceof UsageError) {
            process.stderr.write(`error: ${err.message}\n`);
            return EXIT_CODES.BAD_USAGE;
        }
        const message = err instanceof Error ? err.message : String(err);
        const stack = err instanceof Error && err.stack ? `\n${err.stack}` : '';
        process.stderr.write(`[convo-coach] Unexpected error: ${message}${stack}\n`);
        return EXIT_CODES.GENERIC;
    }
}
