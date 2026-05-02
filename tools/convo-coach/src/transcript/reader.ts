// src/transcript/reader.ts — file→records dispatcher for the transcript stack.
//
// Owned by U4 (plan-011 Phase 6b). The ONLY module in the transcript folder
// that does I/O.
//
// Detects the format from the file extension and delegates to the right
// parser. Establishes `transcriptEnd` (used by the windowing layer) from the
// latest record's timestamp, falling back to the file's mtime when the
// transcript is empty.

import * as fs from 'node:fs';
import * as path from 'node:path';

import { TranscriptError, type NormalisedRecord } from '../types.js';
import { parseJsonl, parsePlainText } from './jsonl.js';

const SUPPORTED_EXTENSIONS = ['.jsonl', '.txt'] as const;

export interface ReadTranscriptResult {
    readonly records: NormalisedRecord[];
    readonly transcriptEnd: Date;
}

/**
 * Read a transcript file and return its normalised records plus an explicit
 * `transcriptEnd` (used as the anchor for `--last` boundary calculation).
 *
 * Behaviour:
 *   * `.jsonl` → `parseJsonl`. `transcriptEnd` is `MAX(records.timestamp)` or
 *     the file's mtime when the parser produced no records.
 *   * `.txt`   → `parsePlainText`, with the file's mtime supplied as the
 *     base time for every produced record. `transcriptEnd` is the file mtime.
 *   * Any other extension → `TranscriptError` (NO_INPUT) listing the
 *     supported extensions.
 *   * Missing/unreadable file → `TranscriptError` (NO_INPUT) with the OS
 *     error attached.
 *   * Non-empty file but zero records after parsing → `TranscriptError`
 *     (NO_INPUT) — signals every line failed to parse (this can only happen
 *     for `.txt`, since `parseJsonl` already throws in that case).
 */
export function readTranscriptFile(filePath: string): ReadTranscriptResult {
    const ext = path.extname(filePath).toLowerCase();
    if (!isSupportedExt(ext)) {
        throw new TranscriptError(
            `unsupported transcript extension '${ext || '(none)'}' for '${filePath}'. Supported: ${SUPPORTED_EXTENSIONS.join(', ')}.`,
        );
    }

    let stat: fs.Stats;
    try {
        stat = fs.statSync(filePath);
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        throw new TranscriptError(
            `cannot access transcript file '${filePath}': ${msg}`,
        );
    }
    if (!stat.isFile()) {
        throw new TranscriptError(
            `transcript path '${filePath}' is not a regular file.`,
        );
    }

    let content: string;
    try {
        content = fs.readFileSync(filePath, 'utf8');
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        throw new TranscriptError(
            `failed to read transcript file '${filePath}': ${msg}`,
        );
    }

    const fileMtime = stat.mtime;
    const isNonEmpty = content.trim().length > 0;

    let records: NormalisedRecord[];
    if (ext === '.jsonl') {
        records = parseJsonl(content);
    } else {
        // ext === '.txt'
        records = parsePlainText(content, fileMtime);
    }

    if (records.length === 0 && isNonEmpty) {
        throw new TranscriptError(
            `transcript file '${filePath}' contained content but produced zero records after parsing. Verify the file format matches its extension.`,
        );
    }

    const transcriptEnd = records.length > 0
        ? new Date(records[records.length - 1]!.timestamp.getTime())
        : fileMtime;

    return { records, transcriptEnd };
}

function isSupportedExt(ext: string): ext is (typeof SUPPORTED_EXTENSIONS)[number] {
    return (SUPPORTED_EXTENSIONS as readonly string[]).includes(ext);
}
