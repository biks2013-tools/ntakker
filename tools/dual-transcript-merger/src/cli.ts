#!/usr/bin/env node
// cli.ts — entry point. Parses argv, resolves config, runs the
// pipeline, writes the result. The four-tier resolution chain lives
// in `config.ts`; this file is purely the I/O shell.
//
// Exit codes:
//   0  success
//   1  unexpected error (anything we didn't classify)
//   4  config / input validation error (MergerError)
//
// Usage (matches docs/tools/dual-transcript-merger.md `<command>`):
//
//   dual-transcript-merger <input.jsonl>
//       [--filter conservative|aggressive|off]
//       [--out <path>]
//       [--format jsonl|txt]
//       [--show-config]
//       [--quiet | --verbose]
//       [-h | --help]

import { createInterface } from "node:readline";
import { createReadStream, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import { applyCliOverrides, resolveDefaults } from "./config.js";
import { emit } from "./emitter.js";
import { merge } from "./merger.js";
import { MergerError, parseStream } from "./parser.js";
import type { FilterMode, IndexedRecord, OutputFormat } from "./types.js";

interface CliArgs {
    inputPath?: string;
    filter?: FilterMode;
    format?: OutputFormat;
    outPath?: string;
    showConfig: boolean;
    verbose: boolean;
    quiet: boolean;
    help: boolean;
}

function printHelp(): void {
    const help = `dual-transcript-merger — merge macrec dual-channel JSONL sidecars

USAGE
  dual-transcript-merger <input.jsonl> [options]

OPTIONS
  --filter MODE       conservative | aggressive | off
                      Cross-language hallucination filter applied to the
                      SECONDARY channel (the cloud channel with fewer,
                      longer chunks). Default: conservative.

  --format FMT        jsonl | txt
                      Output format. jsonl preserves all fields and
                      round-trips back into the macrec sidecar shape;
                      txt is human-readable with channel + model tags.
                      Default: jsonl.

  --out PATH          Write to PATH instead of stdout.
  --show-config       Print resolved config (incl. four-tier provenance)
                      to stderr and exit 0 without merging.
  --verbose           Print drop summary to stderr after merging.
  --quiet             Suppress all stderr output (errors still go to stderr).
  -h, --help          Show this message and exit.

CONFIG (.env)
  DUAL_TRANSCRIPT_MERGER_DEFAULT_FILTER  conservative | aggressive | off
  DUAL_TRANSCRIPT_MERGER_DEFAULT_FORMAT  jsonl | txt

  Resolution order (low to high):
    process.env  →  ~/.tool-agents/dual-transcript-merger/.env
                 →  <cwd>/.env  →  CLI flags

EXIT CODES
  0  success
  1  unexpected error
  4  config / input validation error
`;
    process.stdout.write(help);
}

function parseArgs(argv: readonly string[]): CliArgs {
    const out: CliArgs = {
        showConfig: false,
        verbose: false,
        quiet: false,
        help: false,
    };
    let i = 0;
    while (i < argv.length) {
        const arg = argv[i] ?? "";
        const next = (): string => {
            const v = argv[i + 1];
            if (v === undefined) {
                throw new MergerError("BAD_USAGE", `${arg} requires a value`);
            }
            i += 1;
            return v;
        };
        switch (arg) {
            case "-h":
            case "--help":
                out.help = true;
                break;
            case "--filter": {
                const v = next();
                if (v !== "conservative" && v !== "aggressive" && v !== "off") {
                    throw new MergerError(
                        "BAD_USAGE",
                        `--filter='${v}' is invalid (allowed: conservative, aggressive, off)`,
                    );
                }
                out.filter = v;
                break;
            }
            case "--format": {
                const v = next();
                if (v !== "jsonl" && v !== "txt") {
                    throw new MergerError(
                        "BAD_USAGE",
                        `--format='${v}' is invalid (allowed: jsonl, txt)`,
                    );
                }
                out.format = v;
                break;
            }
            case "--out": {
                out.outPath = next();
                break;
            }
            case "--show-config":
                out.showConfig = true;
                break;
            case "--verbose":
                out.verbose = true;
                break;
            case "--quiet":
                out.quiet = true;
                break;
            default:
                if (arg.startsWith("-")) {
                    throw new MergerError("BAD_USAGE", `unknown option '${arg}' (try --help)`);
                }
                if (out.inputPath !== undefined) {
                    throw new MergerError(
                        "BAD_USAGE",
                        `unexpected positional argument '${arg}' (only one input file is supported)`,
                    );
                }
                out.inputPath = arg;
        }
        i += 1;
    }
    return out;
}

/**
 * Bootstrap: ensure `~/.tool-agents/dual-transcript-merger/` exists so
 * the four-tier chain's tier 2 read never silently misses a user-
 * created `.env`. The directory is created with mode 0700 per the
 * tool-conventions spec; an empty `.env` placeholder is NOT created
 * (the scaffold subagent already wrote one with the canonical header
 * comments — we don't want to clobber it).
 */
function bootstrapToolAgentsDir(): void {
    const dir = join(homedir(), ".tool-agents", "dual-transcript-merger");
    try {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
    } catch {
        // Best effort — the chain treats a missing/unreadable tier 2
        // file as "not set", so a permissions failure here just means
        // tier 2 is silently skipped.
    }
}

async function readAllRecords(path: string): Promise<IndexedRecord[]> {
    const stream = createReadStream(path, { encoding: "utf8" });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    const records: IndexedRecord[] = [];
    for await (const r of parseStream(rl)) {
        records.push(r);
    }
    return records;
}

async function main(): Promise<number> {
    bootstrapToolAgentsDir();

    let args: CliArgs;
    try {
        args = parseArgs(process.argv.slice(2));
    } catch (err) {
        if (err instanceof MergerError) {
            process.stderr.write(`error: ${err.message}\n`);
            return 4;
        }
        throw err;
    }

    if (args.help) {
        printHelp();
        return 0;
    }

    let defaults;
    try {
        defaults = resolveDefaults();
    } catch (err) {
        if (err instanceof MergerError) {
            process.stderr.write(`error: ${err.message}\n`);
            return 4;
        }
        throw err;
    }

    const resolved = applyCliOverrides(defaults, {
        ...(args.filter !== undefined && { filter: args.filter }),
        ...(args.format !== undefined && { format: args.format }),
    });

    if (args.showConfig) {
        const lines = [
            `dual-transcript-merger config:`,
            `  filter           = ${resolved.options.filter}    [${resolved.provenance.filter}]`,
            `  format           = ${resolved.format}    [${resolved.provenance.format}]`,
            `  minTokensToKeep  = ${resolved.options.minTokensToKeep}    [built-in default]`,
        ];
        process.stderr.write(lines.join("\n") + "\n");
        return 0;
    }

    if (args.inputPath === undefined) {
        process.stderr.write("error: input file is required (try --help)\n");
        return 4;
    }

    let records: IndexedRecord[];
    try {
        records = await readAllRecords(args.inputPath);
    } catch (err) {
        if (err instanceof MergerError) {
            process.stderr.write(`error: ${err.message}\n`);
            return 4;
        }
        const message = err instanceof Error ? err.message : String(err);
        process.stderr.write(`error: failed to read '${args.inputPath}': ${message}\n`);
        return 1;
    }

    const result = merge(records, resolved.options);
    const payload = emit(result, resolved.format);

    if (args.outPath !== undefined) {
        try {
            mkdirSync(dirname(args.outPath), { recursive: true });
            writeFileSync(args.outPath, payload, "utf8");
        } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            process.stderr.write(`error: failed to write '${args.outPath}': ${message}\n`);
            return 1;
        }
    } else {
        process.stdout.write(payload);
    }

    if (args.verbose && !args.quiet) {
        const total = records.length;
        const kept = result.merged.length;
        const dropped = result.droppedCount;
        const droppedByChannel = new Map<string, number>();
        for (const r of records) {
            const v = result.verdicts.get(r.id);
            if (v?.kind === "drop") {
                droppedByChannel.set(r.channel, (droppedByChannel.get(r.channel) ?? 0) + 1);
            }
        }
        const dropBreakdown = [...droppedByChannel.entries()]
            .sort((a, b) => a[0].localeCompare(b[0]))
            .map(([ch, n]) => `${ch}=${n}`)
            .join(", ");
        const summary = [
            `merged: ${kept}/${total} records (filter=${resolved.options.filter}, format=${resolved.format})`,
            `primary channel:   ${result.primaryChannel || "(none)"}`,
            `secondary channel: ${result.secondaryChannel ?? "(none)"}`,
            `dropped (bidirectional): ${dropped}${dropBreakdown.length > 0 ? ` [${dropBreakdown}]` : ""}`,
        ];
        process.stderr.write(summary.join("\n") + "\n");
    }

    return 0;
}

void main().then(
    (code) => process.exit(code),
    (err) => {
        const message = err instanceof Error ? err.message : String(err);
        process.stderr.write(`fatal: ${message}\n`);
        process.exit(1);
    },
);
