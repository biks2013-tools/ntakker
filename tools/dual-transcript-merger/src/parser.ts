// parser.ts — JSONL line parser for macrec sidecar files.
//
// The sidecar format is one JSON object per line, blank lines tolerated.
// Required fields are validated by name; missing or wrong-typed fields
// cause an immediate `MergerError` (no fallbacks per the project's
// no-fallback rule). Extra unknown keys are preserved in `extras` so
// the merger round-trips them cleanly to the output JSONL.

import type { SidecarRecord, IndexedRecord } from "./types.js";

export class MergerError extends Error {
    public readonly code: string;
    public readonly lineNumber?: number;

    public constructor(code: string, message: string, lineNumber?: number) {
        super(lineNumber !== undefined ? `[line ${lineNumber}] ${message}` : message);
        this.name = "MergerError";
        this.code = code;
        this.lineNumber = lineNumber;
    }
}

const REQUIRED_KEYS = [
    "id",
    "timestamp",
    "source",
    "channel",
    "language",
    "model",
    "text",
    "durationSec",
] as const;

type RequiredKey = (typeof REQUIRED_KEYS)[number];

function isObject(v: unknown): v is Record<string, unknown> {
    return typeof v === "object" && v !== null && !Array.isArray(v);
}

function asString(v: unknown, key: string, lineNumber: number): string {
    if (typeof v !== "string") {
        throw new MergerError(
            "BAD_TYPE",
            `field '${key}' must be a string (got ${typeof v})`,
            lineNumber,
        );
    }
    return v;
}

function asNumber(v: unknown, key: string, lineNumber: number): number {
    if (typeof v !== "number" || !Number.isFinite(v)) {
        throw new MergerError(
            "BAD_TYPE",
            `field '${key}' must be a finite number (got ${typeof v})`,
            lineNumber,
        );
    }
    return v;
}

function parseIso(timestamp: string, lineNumber: number): number {
    const ms = Date.parse(timestamp);
    if (Number.isNaN(ms)) {
        throw new MergerError(
            "BAD_TIMESTAMP",
            `field 'timestamp'='${timestamp}' is not an ISO-8601 date`,
            lineNumber,
        );
    }
    return ms;
}

/**
 * Parse a single JSONL line into an `IndexedRecord`. Blank lines (and
 * lines that are only whitespace) are signaled by returning `null` so
 * the streaming caller can skip them silently.
 *
 * Throws `MergerError` for malformed JSON, missing required fields, or
 * type mismatches — these are unrecoverable and the project's
 * no-fallback rule forbids defaulting them.
 */
export function parseLine(raw: string, lineNumber: number): IndexedRecord | null {
    const trimmed = raw.trim();
    if (trimmed.length === 0) return null;

    let obj: unknown;
    try {
        obj = JSON.parse(trimmed);
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new MergerError("BAD_JSON", `JSON parse failed: ${message}`, lineNumber);
    }
    if (!isObject(obj)) {
        throw new MergerError(
            "BAD_SHAPE",
            `expected JSON object, got ${Array.isArray(obj) ? "array" : typeof obj}`,
            lineNumber,
        );
    }

    for (const k of REQUIRED_KEYS) {
        if (!(k in obj)) {
            throw new MergerError(
                "MISSING_FIELD",
                `required field '${k}' is missing`,
                lineNumber,
            );
        }
    }

    const id = asString(obj["id"], "id", lineNumber);
    const timestamp = asString(obj["timestamp"], "timestamp", lineNumber);
    const source = asString(obj["source"], "source", lineNumber);
    const channel = asString(obj["channel"], "channel", lineNumber);
    const language = asString(obj["language"], "language", lineNumber);
    const model = asString(obj["model"], "model", lineNumber);
    const text = asString(obj["text"], "text", lineNumber);
    const durationSec = asNumber(obj["durationSec"], "durationSec", lineNumber);
    if (durationSec < 0) {
        throw new MergerError(
            "BAD_RANGE",
            `field 'durationSec' must be >= 0 (got ${durationSec})`,
            lineNumber,
        );
    }

    const extras: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(obj)) {
        if (!REQUIRED_KEYS.includes(k as RequiredKey)) {
            extras[k] = v;
        }
    }

    const startMs = parseIso(timestamp, lineNumber);
    const endMs = startMs + Math.round(durationSec * 1000);

    const record: SidecarRecord = {
        id,
        timestamp,
        source,
        channel,
        language,
        model,
        text,
        durationSec,
        extras,
    };

    return { ...record, startMs, endMs };
}

/**
 * Parse an entire JSONL payload (string) into a flat array of records.
 * Convenience for unit tests and small files; for large sidecars use
 * `parseStream` (line-by-line).
 */
export function parseAll(payload: string): IndexedRecord[] {
    const out: IndexedRecord[] = [];
    const lines = payload.split(/\r?\n/);
    for (let i = 0; i < lines.length; i += 1) {
        const r = parseLine(lines[i] ?? "", i + 1);
        if (r !== null) out.push(r);
    }
    return out;
}

/**
 * Async generator that yields records one-at-a-time from any
 * `AsyncIterable<string>` of NDJSON lines. The CLI uses this so a
 * multi-megabyte sidecar never lands in RAM all at once.
 */
export async function* parseStream(
    lines: AsyncIterable<string>,
): AsyncGenerator<IndexedRecord> {
    let n = 0;
    for await (const line of lines) {
        n += 1;
        const r = parseLine(line, n);
        if (r !== null) yield r;
    }
}
