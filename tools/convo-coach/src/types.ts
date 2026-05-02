// src/types.ts — single source of truth for cross-module type contracts.
//
// This module is the FROZEN INTERFACE between every parallel unit (U2..U9).
// Do NOT extend it without updating §CC-DSGN-5 of project-design.md first.
//
// Frozen by U1 of plan-011 (Phase 6a). All other units in Phase 6b import
// from here.

// =====================================================================
// PROVIDERS (U6) — string-literal union of the eight supported providers.
// Names match the values accepted by `--provider` in
// docs/tools/convo-coach.md.
// =====================================================================

export type ProviderName =
    | 'openai'
    | 'anthropic'
    | 'google'
    | 'azure-openai'
    | 'azure-ai-inference'
    | 'ollama'
    | 'litellm'
    | 'mlx';

export const PROVIDER_NAMES: readonly ProviderName[] = Object.freeze([
    'openai',
    'anthropic',
    'google',
    'azure-openai',
    'azure-ai-inference',
    'ollama',
    'litellm',
    'mlx',
]);

// =====================================================================
// CLI / ORCHESTRATION (U3)
// =====================================================================

export type OverflowStrategy = 'truncate-start' | 'truncate-end' | 'error';

export const OVERFLOW_STRATEGIES: readonly OverflowStrategy[] = Object.freeze([
    'truncate-start',
    'truncate-end',
    'error',
]);

export type LogLevel = 'silent' | 'error' | 'warn' | 'info' | 'debug';

// =====================================================================
// CONFIGURATION (U2)
// =====================================================================

/** Tier of the four-tier resolution chain that supplied a value. */
export type ProvenanceTier =
    | 'shell'      // process.env (lowest priority)
    | 'tool-env'   // ~/.tool-agents/convo-coach/.env
    | 'cwd-env'    // <cwd>/.env
    | 'cli';       // CLI flags (highest priority)

/**
 * All recognised env-var keys. Includes vendor-canonical names plus the
 * documented aliases (read-only — they only fill the canonical slot when
 * the canonical key is unset).
 */
export type ConfigKey =
    // --- tool-specific (COACH_*) ---
    | 'COACH_PROVIDER'
    | 'COACH_MODEL'
    | 'MACREC_RECORDINGS_DIR'
    | 'COACH_DEBOUNCE'
    | 'COACH_ON_OVERFLOW'
    | 'COACH_SYSTEM_PROMPT_PATH'
    // --- OpenAI ---
    | 'OPENAI_API_KEY'
    | 'OPENAI_BASE_URL'
    | 'OPENAI_ORG_ID'
    // --- Anthropic ---
    | 'ANTHROPIC_API_KEY'
    | 'ANTHROPIC_BASE_URL'
    // --- Google Gemini ---
    | 'GOOGLE_API_KEY'
    | 'GEMINI_API_KEY'
    // --- Azure OpenAI ---
    | 'AZURE_OPENAI_API_KEY'
    | 'AZURE_OPENAI_ENDPOINT'
    | 'AZURE_OPENAI_DEPLOYMENT'
    | 'AZURE_OPENAI_API_VERSION'
    // --- Azure AI Inference (Foundry) ---
    | 'AZURE_AI_INFERENCE_KEY'
    | 'AZURE_AI_INFERENCE_ENDPOINT'
    | 'ANTHROPIC_FOUNDRY_API_KEY'
    | 'ANTHROPIC_FOUNDRY_ENDPOINT'
    // --- Ollama ---
    | 'OLLAMA_HOST'
    // --- LiteLLM ---
    | 'LITELLM_PROXY_URL'
    | 'LITELLM_MASTER_KEY'
    | 'LITELLM_API_BASE'
    | 'LITELLM_API_KEY';

/**
 * Resolved configuration after walking the four-tier chain. The `get()`
 * accessor transparently resolves documented aliases (e.g. asking for
 * AZURE_AI_INFERENCE_KEY returns ANTHROPIC_FOUNDRY_API_KEY when the
 * canonical key is unset). The `provenance()` accessor reports which
 * tier supplied the returned value — `undefined` means no tier set it.
 */
export interface ResolvedConfig {
    get(key: ConfigKey): string | undefined;
    provenance(key: ConfigKey): ProvenanceTier | undefined;
}

// =====================================================================
// CLI ARGS (U3)
// =====================================================================

export interface CliArgs {
    readonly transcript?: string;       // --transcript <path>
    readonly last?: string;             // --last <duration>      (raw; parsed by U4)
    readonly since?: string;            // --since <timestamp>    (raw; parsed by U4)
    readonly provider?: ProviderName;   // --provider <name>
    readonly model?: string;            // --model <id>
    readonly systemPrompt?: string;     // --system-prompt <path>
    readonly debounce?: string;         // --debounce <duration>
    readonly onOverflow?: OverflowStrategy;
    readonly recordingsDir?: string;    // --recordings-dir <dir>
    readonly help?: boolean;
    readonly version?: boolean;
}

// =====================================================================
// TRANSCRIPT (U4)
// =====================================================================

/**
 * Normalised transcript record. The same shape is produced by every parser
 * (jsonl, txt, srt, vtt). `channel` is only set for dual-channel inputs.
 */
export interface NormalisedRecord {
    readonly timestamp: Date;
    readonly text: string;
    readonly channel?: 'A' | 'B';
    readonly language?: string;
    readonly isFinal?: boolean;
    readonly speaker?: string;
}

/**
 * Window passed to the slicer. `transcriptEnd` is "now" for finite files
 * (= timestamp of the last record) and wall-clock-at-trigger-time for
 * stdin mode. Required parameter on the slicer function so the resolver
 * can compute `last` boundaries without re-walking the records.
 */
export interface WindowFilter {
    readonly last?: { readonly value: number; readonly unitMs: number };
    readonly since?: Date;
}

// =====================================================================
// PROMPT (U8)
// =====================================================================

export interface BuildPromptOptions {
    readonly records: readonly NormalisedRecord[];
    readonly systemPrompt: string;
    readonly transcriptPath?: string;
    readonly window?: WindowFilter;
}

export interface BuiltPrompt {
    readonly system: string;
    readonly user: string;
    readonly estimatedTokens: number;
}

// =====================================================================
// LLM PROVIDER (U6)
// =====================================================================

// Re-export LangChain's BaseChatModel as the project-internal `LanguageModel`
// type so consumers depend on this module rather than directly on a specific
// LangChain package during type-checking. Every provider module returns an
// instance whose runtime class is a subclass of BaseChatModel (e.g.
// ChatOpenAI, ChatAnthropic, AzureChatOpenAI, ChatOllama,
// ChatGoogleGenerativeAI). All exposed via a uniform `.stream(messages,
// options?)` and `.invoke(messages, options?)` surface.
import type { BaseChatModel } from '@langchain/core/language_models/chat_models';
export type LanguageModel = BaseChatModel;

export interface ProviderCreateInput {
    readonly config: ResolvedConfig;
    /** Optional explicit model id; provider modules may fall back to
     *  their own `defaultModel` when this is undefined. The factory
     *  layer typically pre-applies the per-provider default before
     *  calling `create`. */
    readonly modelOverride?: string;
}

/** Every src/llm/providers/*.ts file MUST export an object of this shape. */
export interface LlmProviderModule {
    readonly name: ProviderName;
    /** Default model id for this provider when --model is not passed.
     *  null means "no default; --model is required" (e.g. litellm, mlx). */
    readonly defaultModel: string | null;
    create(input: ProviderCreateInput): LanguageModel;
}

// =====================================================================
// OUTPUT / STREAMING (U7)
// =====================================================================

/**
 * Sink abstraction so the streaming loop can write the same delta to
 * multiple destinations (stdout + sidecar) without each sink owning its
 * own iteration.
 */
export interface StreamSink {
    write(chunk: string): Promise<void> | void;
    close?(): Promise<void> | void;
}

/** Front-matter values written to the sidecar file. */
export interface SidecarFrontMatter {
    readonly provider: ProviderName;
    readonly model: string;
    readonly transcript?: string;
    readonly window?: {
        readonly last?: string;
        readonly since?: string;
    };
    readonly createdAt: string;     // ISO-8601
}

// =====================================================================
// ERRORS (U2) — exit-code-bearing typed exception hierarchy.
//
// Every error thrown by the orchestrator is one of these subclasses; the
// CLI's top-level catch maps `error.code` → `EXIT_CODES[error.code]`.
// =====================================================================

export const EXIT_CODES = Object.freeze({
    SUCCESS: 0,
    GENERIC: 1,
    BAD_USAGE: 64,
    NO_INPUT: 66,
    PROVIDER_FAILURE: 70,
    MISSING_CONFIG: 78,
} as const);

export type ExitCodeKey = keyof typeof EXIT_CODES;

export class ConvoCoachError extends Error {
    public readonly code: ExitCodeKey;

    constructor(code: ExitCodeKey, message: string) {
        super(message);
        this.code = code;
        this.name = 'ConvoCoachError';
    }
}

/** Raised when a required configuration value is missing. Exit 78. */
export class ConfigError extends ConvoCoachError {
    constructor(message: string) {
        super('MISSING_CONFIG', message);
        this.name = 'ConfigError';
    }
}

/** Raised when no transcript input is available. Exit 66. */
export class TranscriptError extends ConvoCoachError {
    constructor(message: string) {
        super('NO_INPUT', message);
        this.name = 'TranscriptError';
    }
}

/** Raised when an LLM provider call fails. Exit 70. */
export class ProviderError extends ConvoCoachError {
    constructor(message: string) {
        super('PROVIDER_FAILURE', message);
        this.name = 'ProviderError';
    }
}

/** Raised when a window specification (--last/--since) is invalid. Exit 64. */
export class WindowError extends ConvoCoachError {
    constructor(message: string) {
        super('BAD_USAGE', message);
        this.name = 'WindowError';
    }
}

/** Raised on bad CLI usage (unknown flag, invalid enum value, etc.). Exit 64. */
export class UsageError extends ConvoCoachError {
    constructor(message: string) {
        super('BAD_USAGE', message);
        this.name = 'UsageError';
    }
}
