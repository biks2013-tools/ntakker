// merger.ts — chronological merge + bidirectional cross-language
// hallucination filter.
//
// ## Why bidirectional
//
// Either channel can hallucinate, depending on which language the
// audio is in at any moment. Real-world example: a Greek speaker
// occasionally code-switches to English. The English-tuned on-device
// model (`apple`, en-US) catches the English asides correctly but
// emits garbled English approximations of the Greek (`"Για να δούμε"`
// → `"Yeah I've been told"`). The Greek cloud model (`apple-cloud`,
// el-GR) does the opposite — captures the Greek backbone faithfully
// but compresses or skips the English asides.
//
// The merger therefore applies the SAME heuristic to BOTH channels:
// every fragment is judged against the OTHER channel's overlapping
// content. The "primary" channel is just whichever has more records
// (used as a stable tie-break for chronological ordering); it carries
// no immunity from filtering.
//
// ## Filter heuristic (per fragment)
//
// For each fragment X, find the OTHER channel's records whose
// `[startMs, endMs]` intervals overlap X's interval. Then:
//
//   conservative (default):
//     drop X only when ALL of:
//       (a) at least one other-channel window overlaps X,
//       (b) zero content tokens are shared with the union of those
//           overlapping windows' text,
//       (c) X has fewer than `minTokensToKeep` content tokens
//           (default 4).
//     Long, overlap-but-no-overlap fragments are kept on the theory
//     that they're real asides the other channel missed.
//
//   aggressive:
//     drop when (a) AND (b), regardless of length. Cleaner output,
//     occasional false positives on real-but-unfamiliar asides.
//
//   off:
//     no drops; chronological merge only.
//
// Fragments outside any other-channel window are always kept — the
// other channel cannot vouch for or against a moment it never covered.
//
// "Content tokens" are lowercased Unicode word runs (`\p{L}+`) of
// length >= 2, with locale-agnostic Unicode case-folding. Numbers,
// punctuation, and single-letter tokens are excluded so common Greek
// articles like `ο` / `η` don't trigger a false positive.

import type {
    FilterMode,
    FilterVerdict,
    IndexedRecord,
    MergeOptions,
    MergeResult,
} from "./types.js";

// ---------------- Tokenization ----------------

/**
 * Locale-agnostic content tokens: lowercased Unicode letters runs of
 * length >= 2. Greek and Latin tokens both flow through identically.
 * Returns a Set so membership tests are O(1) at the call site.
 */
export function contentTokens(text: string): Set<string> {
    const out = new Set<string>();
    for (const m of text.matchAll(/\p{L}+/gu)) {
        const tok = m[0].toLocaleLowerCase();
        if (tok.length >= 2) out.add(tok);
    }
    return out;
}

// ---------------- Channel classification ----------------

interface ChannelSplit {
    primary: string;
    secondary: string | null;
    primaryRecords: IndexedRecord[];
    secondaryRecords: IndexedRecord[];
}

function splitByChannel(records: readonly IndexedRecord[]): ChannelSplit {
    const buckets = new Map<string, IndexedRecord[]>();
    for (const r of records) {
        const arr = buckets.get(r.channel);
        if (arr === undefined) {
            buckets.set(r.channel, [r]);
        } else {
            arr.push(r);
        }
    }

    if (buckets.size === 0) {
        return { primary: "", secondary: null, primaryRecords: [], secondaryRecords: [] };
    }

    if (buckets.size === 1) {
        // Single-channel input — degenerate but valid. Treat the only
        // channel as primary; nothing to filter.
        const [only] = [...buckets.entries()];
        if (only === undefined) {
            return { primary: "", secondary: null, primaryRecords: [], secondaryRecords: [] };
        }
        return {
            primary: only[0],
            secondary: null,
            primaryRecords: only[1],
            secondaryRecords: [],
        };
    }

    // Pick the two channels with the largest counts. (If the input has
    // >2 channels — not produced by macrec today — we still operate on
    // the top two and pass the rest through unfiltered.)
    const sorted = [...buckets.entries()].sort((a, b) => {
        if (b[1].length !== a[1].length) return b[1].length - a[1].length;
        // Deterministic tie-break: lexicographic on the channel label.
        return a[0].localeCompare(b[0]);
    });
    const first = sorted[0];
    const second = sorted[1];
    if (first === undefined || second === undefined) {
        // Defensive — bucket count >= 2 but sort returned <2 entries
        // is impossible here, keeps strict TS happy.
        return { primary: "", secondary: null, primaryRecords: [], secondaryRecords: [] };
    }
    return {
        primary: first[0],
        secondary: second[0],
        primaryRecords: first[1],
        secondaryRecords: second[1],
    };
}

// ---------------- Primary-window lookup ----------------

/**
 * Given a fragment, return every record from `others` whose
 * `[startMs, endMs]` interval overlaps the fragment's interval.
 * Streaming records (`endMs == startMs`) count as overlapping when
 * `startMs` falls inside the other window.
 *
 * Linear scan — fine for any realistic sidecar (≤ thousands of
 * records); replace with a sorted-array binary search if a future
 * sidecar grows past tens of thousands of lines.
 */
function overlapping(
    fragment: IndexedRecord,
    others: readonly IndexedRecord[],
): IndexedRecord[] {
    const out: IndexedRecord[] = [];
    for (const o of others) {
        // Standard interval-overlap test: `oEnd >= fStart && fEnd >= oStart`.
        if (o.endMs >= fragment.startMs && fragment.endMs >= o.startMs) {
            out.push(o);
        }
    }
    return out;
}

// ---------------- Per-record filter decision ----------------

/**
 * Judge a single fragment against the OTHER channel's records.
 * Symmetric — used for both primary and secondary channels in
 * conservative / aggressive modes.
 */
function judgeAgainstOther(
    fragment: IndexedRecord,
    otherRecords: readonly IndexedRecord[],
    mode: FilterMode,
    minTokensToKeep: number,
): FilterVerdict {
    if (mode === "off") {
        return { kind: "keep", reason: "secondary-no-overlap" };
    }

    const overlaps = overlapping(fragment, otherRecords);
    if (overlaps.length === 0) {
        // Outside any other-channel window — keep unconditionally.
        // The other channel cannot vouch for or against a moment it
        // never covered.
        return { kind: "keep", reason: "secondary-no-overlap" };
    }

    const fragTokens = contentTokens(fragment.text);
    if (fragTokens.size === 0) {
        // Empty / punctuation-only fragment that overlaps a real
        // window — drop as a hallucination candidate under both
        // filter modes.
        return {
            kind: "drop",
            reason: "secondary-hallucination",
            tokenCount: 0,
            primaryWindowId: overlaps[0]?.id ?? "",
        };
    }

    // Combine all overlapping other-channel windows into one token set.
    const otherTokens = new Set<string>();
    for (const o of overlaps) {
        for (const t of contentTokens(o.text)) {
            otherTokens.add(t);
        }
    }

    const shared: string[] = [];
    for (const t of fragTokens) {
        if (otherTokens.has(t)) shared.push(t);
    }

    if (shared.length > 0) {
        return {
            kind: "keep",
            reason: "secondary-shares-tokens",
            sharedTokens: shared,
        };
    }

    if (mode === "aggressive") {
        return {
            kind: "drop",
            reason: "secondary-hallucination",
            tokenCount: fragTokens.size,
            primaryWindowId: overlaps[0]?.id ?? "",
        };
    }
    // conservative — also gate on length.
    if (fragTokens.size >= minTokensToKeep) {
        return {
            kind: "keep",
            reason: "secondary-long-enough",
            tokenCount: fragTokens.size,
        };
    }
    return {
        kind: "drop",
        reason: "secondary-hallucination",
        tokenCount: fragTokens.size,
        primaryWindowId: overlaps[0]?.id ?? "",
    };
}

// ---------------- Public API ----------------

/**
 * Merge + bidirectionally filter the records. Both channels are
 * judged against each other using the same heuristic, and ANY fragment
 * (regardless of channel) can be dropped under conservative or
 * aggressive modes.
 *
 * The output is sorted by `startMs` ascending. Stable: ties on
 * `startMs` resolve in favour of the primary (larger-count) channel
 * first, preserving deterministic chronological order across runs.
 */
export function merge(
    records: readonly IndexedRecord[],
    options: MergeOptions,
): MergeResult {
    const split = splitByChannel(records);
    const verdicts = new Map<string, FilterVerdict>();

    const keptPrimary: IndexedRecord[] = [];
    const keptSecondary: IndexedRecord[] = [];
    let dropped = 0;

    // Judge the PRIMARY channel against the SECONDARY channel.
    for (const p of split.primaryRecords) {
        if (split.secondaryRecords.length === 0) {
            // No other channel to compare against — primary passes
            // unconditionally (single-channel input).
            verdicts.set(p.id, { kind: "keep", reason: "primary" });
            keptPrimary.push(p);
            continue;
        }
        const v = judgeAgainstOther(
            p,
            split.secondaryRecords,
            options.filter,
            options.minTokensToKeep,
        );
        verdicts.set(p.id, v);
        if (v.kind === "keep") {
            keptPrimary.push(p);
        } else {
            dropped += 1;
        }
    }

    // Judge the SECONDARY channel against the PRIMARY channel.
    for (const s of split.secondaryRecords) {
        const v = judgeAgainstOther(
            s,
            split.primaryRecords,
            options.filter,
            options.minTokensToKeep,
        );
        verdicts.set(s.id, v);
        if (v.kind === "keep") {
            keptSecondary.push(s);
        } else {
            dropped += 1;
        }
    }

    // Stable chronological merge of the two kept lists.
    const merged = [...keptPrimary, ...keptSecondary].sort((a, b) => {
        if (a.startMs !== b.startMs) return a.startMs - b.startMs;
        // Deterministic tie-break: primary-channel records first,
        // then secondary; within the same channel preserve insertion
        // order (`Array.prototype.sort` is stable in V8 / Node 20+).
        if (a.channel !== b.channel) {
            if (a.channel === split.primary) return -1;
            if (b.channel === split.primary) return 1;
        }
        return 0;
    });

    return {
        merged,
        verdicts,
        primaryChannel: split.primary,
        secondaryChannel: split.secondary,
        droppedCount: dropped,
    };
}
