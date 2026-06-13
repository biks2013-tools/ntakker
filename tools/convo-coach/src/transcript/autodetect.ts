// src/transcript/autodetect.ts — find the newest ntakker-cli sidecar in a folder.
//
// Owned by U5 (plan-011 Phase 6c). Pure-ish — does I/O (readdir + stat) but
// no streaming. Top-level only (no recursion) to match how ntakker-cli writes
// sidecars next to their audio files.
//
// Behaviour:
//   * Tilde-expand the input directory using `os.homedir()`.
//   * Throw `TranscriptError` (NO_INPUT) when the path does not exist, is
//     not a directory, or contains zero candidate files.
//   * A "candidate" is any top-level entry whose lowercase extension is
//     `.jsonl` or `.txt` (matches U4's `SUPPORTED_EXTENSIONS`).
//   * Return the absolute path of the candidate with the newest mtime.
//
// See plan-011 §U5 and CC-DSGN-12 CC-ADR-5 for the rationale behind the
// `~/Recordings` default and the no-recursion contract.

import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { TranscriptError } from '../types.js';

const SUPPORTED_EXTENSIONS = new Set<string>(['.jsonl', '.txt']);

/**
 * Expand a leading `~` (with or without a trailing `/`) into the current
 * user's home directory. Other paths are returned unchanged. Pure helper.
 */
function expandTilde(input: string): string {
    if (input === '~') return os.homedir();
    if (input.startsWith('~/')) return path.join(os.homedir(), input.slice(2));
    return input;
}

/**
 * Scan `recordingsDir` (top-level only) and return the absolute path of the
 * most-recently-modified `.jsonl` / `.txt` file.
 *
 * Throws `TranscriptError` (NO_INPUT) on every error path:
 *   * directory does not exist
 *   * path exists but is not a directory
 *   * no candidate files
 */
export function autodetectLatestSidecar(recordingsDir: string): string {
    const expanded = expandTilde(recordingsDir);
    const absolute = path.resolve(expanded);

    let stat: fs.Stats;
    try {
        stat = fs.statSync(absolute);
    } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        throw new TranscriptError(
            `recordings directory '${absolute}' is not accessible: ${reason}. ` +
            `Pass --transcript <path> explicitly, or set NTAKKER_RECORDINGS_DIR ` +
            `in ~/.tool-agents/convo-coach/.env.`,
        );
    }
    if (!stat.isDirectory()) {
        throw new TranscriptError(
            `recordings path '${absolute}' is not a directory. ` +
            `Pass --transcript <path> explicitly, or set NTAKKER_RECORDINGS_DIR ` +
            `to a folder containing ntakker-cli sidecars.`,
        );
    }

    let entries: fs.Dirent[];
    try {
        entries = fs.readdirSync(absolute, { withFileTypes: true });
    } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        throw new TranscriptError(
            `failed to enumerate recordings directory '${absolute}': ${reason}.`,
        );
    }

    let bestPath: string | undefined;
    let bestMtimeMs = Number.NEGATIVE_INFINITY;

    for (const entry of entries) {
        if (!entry.isFile()) continue;
        const ext = path.extname(entry.name).toLowerCase();
        if (!SUPPORTED_EXTENSIONS.has(ext)) continue;

        const fullPath = path.join(absolute, entry.name);
        let entryStat: fs.Stats;
        try {
            entryStat = fs.statSync(fullPath);
        } catch {
            // A racy unlink between readdir and stat — skip silently.
            continue;
        }
        const mtimeMs = entryStat.mtimeMs;
        if (mtimeMs > bestMtimeMs) {
            bestMtimeMs = mtimeMs;
            bestPath = fullPath;
        }
    }

    if (bestPath === undefined) {
        throw new TranscriptError(
            `no transcript sidecars found in '${absolute}' ` +
            `(looked for top-level .jsonl or .txt files). ` +
            `Pass --transcript <path> explicitly, or run ntakker-cli to produce one.`,
        );
    }

    return bestPath;
}
