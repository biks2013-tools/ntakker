// emitter.ts — serialize a `MergeResult` back to JSONL or human-
// readable TXT. Both formats are deterministic so diff-based testing
// is straightforward.

import type { IndexedRecord, MergeResult, OutputFormat, SidecarRecord } from "./types.js";

function withoutDerivedFields(rec: IndexedRecord): SidecarRecord {
    // Strip the parser-derived `startMs` / `endMs` so they don't leak
    // into the output JSONL — they aren't part of the macrec sidecar
    // contract, only an in-process indexing optimisation.
    const { id, timestamp, source, channel, language, model, text, durationSec, extras } = rec;
    return { id, timestamp, source, channel, language, model, text, durationSec, extras };
}

/**
 * JSONL emission round-trips every original key (`extras` are spread
 * back at the end) so unrecognised fields the parser preserved are
 * still present after a merge.
 */
export function toJsonl(result: MergeResult): string {
    const lines: string[] = [];
    for (const r of result.merged) {
        const base = withoutDerivedFields(r);
        const flat: Record<string, unknown> = {
            id: base.id,
            timestamp: base.timestamp,
            source: base.source,
            channel: base.channel,
            language: base.language,
            model: base.model,
            text: base.text,
            durationSec: base.durationSec,
            ...base.extras,
        };
        lines.push(JSON.stringify(flat));
    }
    return lines.join("\n") + (lines.length > 0 ? "\n" : "");
}

/**
 * Human-readable TXT — one line per record:
 *
 *   [HH:MM:SS.mmm] {channel} ({model}) text
 *
 * The timestamp is in the input's UTC. Channel and model are tagged
 * so a quick visual scan can tell apple from apple-cloud at a glance.
 */
export function toTxt(result: MergeResult): string {
    const lines: string[] = [];
    for (const r of result.merged) {
        const date = new Date(r.startMs);
        const hh = String(date.getUTCHours()).padStart(2, "0");
        const mm = String(date.getUTCMinutes()).padStart(2, "0");
        const ss = String(date.getUTCSeconds()).padStart(2, "0");
        const mmm = String(date.getUTCMilliseconds()).padStart(3, "0");
        const time = `${hh}:${mm}:${ss}.${mmm}`;
        const text = r.text.replace(/\r?\n/g, " ").trimEnd();
        lines.push(`[${time}] ${r.channel} (${r.model}) ${text}`);
    }
    return lines.join("\n") + (lines.length > 0 ? "\n" : "");
}

export function emit(result: MergeResult, format: OutputFormat): string {
    if (format === "jsonl") return toJsonl(result);
    return toTxt(result);
}
