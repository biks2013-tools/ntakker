// config.ts — four-tier resolution chain for the two optional config
// vars. Lowest-to-highest priority:
//
//   1. process.env (shell)
//   2. ~/.tool-agents/dual-transcript-merger/.env  (durable defaults)
//   3. <cwd>/.env                                  (project-local override)
//   4. CLI flags                                   (per-invocation override)
//
// Tier 4 is layered on top of the resolved (1+2+3) value at the CLI
// boundary — `cli.ts` calls `resolveDefaults()` here and overrides
// each field only when the user passed an explicit flag. Per the
// project no-fallback rule, an UNRECOGNISED value at any tier
// (e.g. `--filter banana` or `DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT=xml`)
// throws — we never silently substitute a default.
//
// We do NOT shell out to `dotenv` to keep the dependency footprint
// zero (the CLI ships with only `@types/node` as a build-time dep).
// The parser below handles the small subset of `.env` syntax the
// scaffolded `.env` template uses: `KEY=value` lines, optional
// surrounding whitespace, full-line `#` comments, blank lines tolerated.
// Quoting is NOT supported; if a future config var needs spaces we
// will switch to a real .env library.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

import type { FilterMode, MergeOptions, OutputFormat } from "./types.js";
import { MergerError } from "./parser.js";

const ENV_FILTER_KEY = "DUAL_TRANSCRIPT_MERGER_DEFAULT_FILTER";
const ENV_FORMAT_KEY = "DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT";

const HARDCODED_DEFAULTS = {
    filter: "conservative" as FilterMode,
    format: "jsonl" as OutputFormat,
    minTokensToKeep: 4,
} as const;

const VALID_FILTERS: ReadonlySet<string> = new Set(["off", "conservative", "aggressive"]);
const VALID_FORMATS: ReadonlySet<string> = new Set(["jsonl", "txt"]);

/** Public-facing resolved config (CLI hasn't applied flags yet). */
export interface ResolvedDefaults {
    readonly filter: FilterMode;
    readonly format: OutputFormat;
    readonly minTokensToKeep: number;
    /** Where each value came from — surfaced under `--show-config` for
     *  debugging the resolution chain. */
    readonly provenance: Readonly<Record<"filter" | "format", string>>;
}

function parseDotEnv(text: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (line.length === 0 || line.startsWith("#")) continue;
        const eq = line.indexOf("=");
        if (eq === -1) continue;
        const key = line.slice(0, eq).trim();
        const value = line.slice(eq + 1).trim();
        if (key.length > 0) out[key] = value;
    }
    return out;
}

function tryReadDotEnv(path: string): Record<string, string> {
    if (!existsSync(path)) return {};
    try {
        return parseDotEnv(readFileSync(path, "utf8"));
    } catch {
        return {};
    }
}

function validateFilter(raw: string, source: string): FilterMode {
    const v = raw.trim().toLowerCase();
    if (!VALID_FILTERS.has(v)) {
        throw new MergerError(
            "BAD_CONFIG",
            `${source}: ${ENV_FILTER_KEY}='${raw}' is invalid (allowed: off, conservative, aggressive)`,
        );
    }
    return v as FilterMode;
}

function validateFormat(raw: string, source: string): OutputFormat {
    const v = raw.trim().toLowerCase();
    if (!VALID_FORMATS.has(v)) {
        throw new MergerError(
            "BAD_CONFIG",
            `${source}: ${ENV_FORMAT_KEY}='${raw}' is invalid (allowed: jsonl, txt)`,
        );
    }
    return v as OutputFormat;
}

/**
 * Walk the four-tier chain (1 → 3 only — CLI flags belong to
 * `cli.ts`) and return the resolved defaults plus a provenance map.
 * Throws `MergerError` on any invalid value at any tier.
 */
export function resolveDefaults(cwd: string = process.cwd()): ResolvedDefaults {
    let filter: FilterMode = HARDCODED_DEFAULTS.filter;
    let format: OutputFormat = HARDCODED_DEFAULTS.format;
    const provenance: Record<"filter" | "format", string> = {
        filter: "built-in default",
        format: "built-in default",
    };

    // Tier 1 — process.env
    const envFilter = process.env[ENV_FILTER_KEY];
    if (envFilter !== undefined && envFilter.length > 0) {
        filter = validateFilter(envFilter, "process.env");
        provenance.filter = "process.env";
    }
    const envFormat = process.env[ENV_FORMAT_KEY];
    if (envFormat !== undefined && envFormat.length > 0) {
        format = validateFormat(envFormat, "process.env");
        provenance.format = "process.env";
    }

    // Tier 2 — ~/.tool-agents/dual-transcript-merger/.env
    const toolAgentsPath = join(homedir(), ".tool-agents", "dual-transcript-merger", ".env");
    const tier2 = tryReadDotEnv(toolAgentsPath);
    if (tier2[ENV_FILTER_KEY] !== undefined) {
        filter = validateFilter(tier2[ENV_FILTER_KEY], toolAgentsPath);
        provenance.filter = toolAgentsPath;
    }
    if (tier2[ENV_FORMAT_KEY] !== undefined) {
        format = validateFormat(tier2[ENV_FORMAT_KEY], toolAgentsPath);
        provenance.format = toolAgentsPath;
    }

    // Tier 3 — <cwd>/.env
    const cwdPath = resolve(cwd, ".env");
    const tier3 = tryReadDotEnv(cwdPath);
    if (tier3[ENV_FILTER_KEY] !== undefined) {
        filter = validateFilter(tier3[ENV_FILTER_KEY], cwdPath);
        provenance.filter = cwdPath;
    }
    if (tier3[ENV_FORMAT_KEY] !== undefined) {
        format = validateFormat(tier3[ENV_FORMAT_KEY], cwdPath);
        provenance.format = cwdPath;
    }

    return {
        filter,
        format,
        minTokensToKeep: HARDCODED_DEFAULTS.minTokensToKeep,
        provenance,
    };
}

/**
 * Apply CLI overrides on top of the resolved defaults. Only fields
 * with a defined override value win — `undefined` means "user did not
 * pass this flag, keep the resolved default".
 */
export function applyCliOverrides(
    base: ResolvedDefaults,
    overrides: { readonly filter?: FilterMode; readonly format?: OutputFormat },
): { readonly options: MergeOptions; readonly format: OutputFormat; readonly provenance: Readonly<Record<"filter" | "format", string>> } {
    const provenance = { ...base.provenance };
    let filter = base.filter;
    let format = base.format;
    if (overrides.filter !== undefined) {
        filter = overrides.filter;
        provenance.filter = "CLI flag";
    }
    if (overrides.format !== undefined) {
        format = overrides.format;
        provenance.format = "CLI flag";
    }
    return {
        options: { filter, minTokensToKeep: base.minTokensToKeep },
        format,
        provenance,
    };
}

export const __test = {
    HARDCODED_DEFAULTS,
    ENV_FILTER_KEY,
    ENV_FORMAT_KEY,
    parseDotEnv,
    validateFilter,
    validateFormat,
};
