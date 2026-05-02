// src/output/sidecar.ts — atomic temp-rename sidecar writer.
//
// Owned by U7 (plan-011 Phase 6c). Implements CC-ADR-6/7:
//   * Path naming: `<basename-without-ext>.advice-<YYYYMMDD-HHMMSS>.md`
//     placed in the same directory as the source transcript (or in the
//     fallback directory in stdin mode, with basename `convo-coach-stdin`).
//   * Collision: append `-2`, `-3`, …, `-99` before `.md`. After 99 → throw.
//   * Atomicity: writes always go to a `.tmp` sibling; close() renames it
//     to the final path.
//
// The frontmatter is hand-rolled YAML — no `js-yaml` dependency. Only the
// fields in `SidecarFrontMatter` are emitted; nesting depth is at most 1.

import * as fs from 'node:fs';
import * as path from 'node:path';

import {
    ConvoCoachError,
    type SidecarFrontMatter,
    type StreamSink,
} from '../types.js';

// ---------------------------------------------------------------------------
// Path construction
// ---------------------------------------------------------------------------

export interface BuildSidecarPathInput {
    /** Path to the source transcript file, if any. When undefined the
     *  sidecar uses the basename `convo-coach-stdin` and is placed in
     *  `fallbackDir`. */
    readonly transcriptPath?: string;
    /** Directory used in stdin mode (i.e. when `transcriptPath` is undefined). */
    readonly fallbackDir: string;
    readonly now: Date;
}

/**
 * Compute a unique sidecar path. Format:
 *   `<dir>/<basename-without-ext>.advice-<YYYYMMDD-HHMMSS>.md`
 *
 * On collision (rare — same wall-clock second), append `-2`, `-3`, … up to
 * `-99`. After 99 attempts, throw `ConvoCoachError('GENERIC')`.
 */
export function buildSidecarPath(input: BuildSidecarPathInput): string {
    const { transcriptPath, fallbackDir, now } = input;

    const dir = transcriptPath !== undefined
        ? path.dirname(transcriptPath)
        : fallbackDir;

    let stem: string;
    if (transcriptPath !== undefined) {
        const base = path.basename(transcriptPath);
        const ext = path.extname(base);
        stem = ext.length > 0 ? base.slice(0, -ext.length) : base;
    } else {
        stem = 'convo-coach-stdin';
    }

    const ts = formatTimestamp(now);
    const baseName = `${stem}.advice-${ts}`;

    const primary = path.join(dir, `${baseName}.md`);
    if (!fs.existsSync(primary)) return primary;

    for (let i = 2; i <= 99; i += 1) {
        const candidate = path.join(dir, `${baseName}-${i}.md`);
        if (!fs.existsSync(candidate)) return candidate;
    }

    throw new ConvoCoachError(
        'GENERIC',
        `unable to find a free sidecar path under '${dir}' for stem '${baseName}' ` +
        `(99 collisions). Move or delete some old advice files and retry.`,
    );
}

function formatTimestamp(d: Date): string {
    const yyyy = String(d.getFullYear()).padStart(4, '0');
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    const hh = String(d.getHours()).padStart(2, '0');
    const mi = String(d.getMinutes()).padStart(2, '0');
    const ss = String(d.getSeconds()).padStart(2, '0');
    return `${yyyy}${mm}${dd}-${hh}${mi}${ss}`;
}

// ---------------------------------------------------------------------------
// YAML emission (minimal — handles only the SidecarFrontMatter shape)
// ---------------------------------------------------------------------------

/**
 * Emit a single YAML scalar — quote with double quotes when it could be
 * mis-parsed (contains a colon, quote, leading/trailing space, or starts
 * with a YAML metacharacter). Newlines are escaped.
 */
function yamlScalar(v: string): string {
    if (v.length === 0) return '""';
    const needsQuoting =
        /[:#"'\\\n\r\t]/.test(v) ||
        /^[-?@%&*!|>]/.test(v) ||
        /^(true|false|null|yes|no|on|off)$/i.test(v) ||
        /^\s/.test(v) ||
        /\s$/.test(v);
    if (!needsQuoting) return v;
    const escaped = v
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\n/g, '\\n')
        .replace(/\r/g, '\\r')
        .replace(/\t/g, '\\t');
    return `"${escaped}"`;
}

function renderFrontMatter(fm: SidecarFrontMatter): string {
    const lines: string[] = ['---'];
    lines.push(`provider: ${yamlScalar(fm.provider)}`);
    lines.push(`model: ${yamlScalar(fm.model)}`);
    lines.push(`transcript: ${yamlScalar(fm.transcript ?? 'stdin')}`);
    lines.push('window:');
    const lastVal = fm.window?.last;
    const sinceVal = fm.window?.since;
    lines.push(`  last: ${lastVal !== undefined && lastVal !== null && lastVal !== '' ? yamlScalar(lastVal) : 'null'}`);
    lines.push(`  since: ${sinceVal !== undefined && sinceVal !== null && sinceVal !== '' ? yamlScalar(sinceVal) : 'null'}`);
    lines.push(`createdAt: ${yamlScalar(fm.createdAt)}`);
    lines.push('---');
    lines.push('');
    lines.push('# Conversational coaching advice');
    lines.push('');
    return lines.join('\n');
}

// ---------------------------------------------------------------------------
// SidecarWriter — the StreamSink
// ---------------------------------------------------------------------------

export interface MetricsBlockInput {
    readonly promptTokens?: number;
    readonly completionTokens?: number;
    readonly totalTokens?: number;
    readonly ttftMs?: number;
    readonly latencyMs?: number;
}

/**
 * Append-only sidecar writer. Writes the YAML frontmatter immediately on
 * construction (so a crash mid-stream still leaves a parseable file at the
 * temp path), buffers each delta with `appendFileSync` so partial advice
 * is durable, and atomically renames the `.tmp` to the final path on
 * `close()`.
 */
export class SidecarWriter implements StreamSink {
    public readonly path: string;
    private readonly tempPath: string;
    private closed = false;

    constructor(targetPath: string, frontMatter: SidecarFrontMatter) {
        this.path = targetPath;
        this.tempPath = `${targetPath}.tmp`;

        // Make sure the parent directory exists before we touch the temp
        // file. This is a no-op when it already exists.
        const parentDir = path.dirname(targetPath);
        try {
            fs.mkdirSync(parentDir, { recursive: true });
        } catch {
            // mkdirSync({recursive:true}) only throws on permission errors;
            // let the subsequent write throw with a more useful message.
        }

        // Write frontmatter immediately so even a crash leaves a parseable
        // file behind. We use writeFileSync here (not appendFileSync) so a
        // pre-existing stale .tmp is replaced, not appended to.
        fs.writeFileSync(this.tempPath, renderFrontMatter(frontMatter), {
            encoding: 'utf8',
            mode: 0o644,
        });
    }

    write(chunk: string): void {
        if (this.closed) {
            throw new Error('SidecarWriter.write called after close()');
        }
        if (chunk.length === 0) return;
        fs.appendFileSync(this.tempPath, chunk, 'utf8');
    }

    appendMetricsBlock(metrics: MetricsBlockInput): void {
        if (this.closed) {
            throw new Error('SidecarWriter.appendMetricsBlock called after close()');
        }
        const lines: string[] = ['', '', '## Metrics', ''];
        lines.push(`- promptTokens: ${metrics.promptTokens ?? 'N/A'}`);
        lines.push(`- completionTokens: ${metrics.completionTokens ?? 'N/A'}`);
        lines.push(`- totalTokens: ${metrics.totalTokens ?? 'N/A'}`);
        lines.push(`- ttftMs: ${metrics.ttftMs ?? 'N/A'}`);
        lines.push(`- latencyMs: ${metrics.latencyMs ?? 'N/A'}`);
        lines.push('');
        fs.appendFileSync(this.tempPath, lines.join('\n'), 'utf8');
    }

    /**
     * Append a free-form footer (e.g. `# ERROR\n\n<message>\n`) to the
     * temp file. Used by the orchestrator's error path so partial advice
     * + the failure reason are both preserved.
     */
    appendFooter(text: string): void {
        if (this.closed) return;
        fs.appendFileSync(this.tempPath, text, 'utf8');
    }

    close(): void {
        if (this.closed) return;
        this.closed = true;
        try {
            fs.renameSync(this.tempPath, this.path);
        } catch (err) {
            const reason = err instanceof Error ? err.message : String(err);
            throw new Error(
                `SidecarWriter: failed to rename '${this.tempPath}' → '${this.path}': ${reason}`,
            );
        }
    }
}
