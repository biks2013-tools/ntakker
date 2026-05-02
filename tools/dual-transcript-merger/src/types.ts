// types.ts — wire shapes for the macrec dual-channel JSONL sidecar.
//
// Source of truth: the channel-tagged JSONL records emitted by
// `MacrecCore`'s `DualTranscriptionManager` (plan-010). Each line is a
// JSON object with the following keys (order is not significant — we
// always parse line-by-line and re-key by name):
//
//   * id         (string)  — UUID or "00000000-..."-style sequential id.
//   * timestamp  (string)  — ISO-8601 UTC, e.g. "2026-05-02T02:26:09.001Z".
//   * source     (string)  — "system" | "mic" | "mixed" | "both".
//   * channel    (string)  — short label (e.g. "EN", "EL"). Set by the
//                            sidecar writer from `ChannelConfig.locale`.
//   * language   (string)  — BCP-47 locale tag (e.g. "en-US", "el-GR").
//   * model      (string)  — provider id ("apple", "apple-cloud", ...).
//   * text       (string)  — finalized transcript fragment.
//   * durationSec(number)  — elapsed audio for this fragment, seconds.
//                            On-device streaming providers report 0;
//                            cloud rotation-window providers report
//                            ~55 s per chunk.
//
// Unknown extra keys are preserved verbatim on JSONL output (we round-
// trip via the `extras` bag) so future sidecar additions don't get
// silently dropped by the merger.

/** Required, well-known fields on every JSONL line. */
export interface SidecarRecord {
    readonly id: string;
    readonly timestamp: string;        // ISO-8601 UTC
    readonly source: string;
    readonly channel: string;
    readonly language: string;
    readonly model: string;
    readonly text: string;
    readonly durationSec: number;

    /** Pass-through bag for any unrecognised keys. */
    readonly extras: Readonly<Record<string, unknown>>;
}

/**
 * A `SidecarRecord` augmented with the parsed numeric timestamps the
 * merger / filter operates on. Computed once at parse time so the
 * downstream pipeline never re-parses ISO strings.
 */
export interface IndexedRecord extends SidecarRecord {
    /** Epoch ms for `timestamp`. */
    readonly startMs: number;
    /** `startMs + durationSec * 1000`. Equals `startMs` for streaming
     *  fragments with `durationSec == 0`. */
    readonly endMs: number;
}

/**
 * Filter modes for cross-language hallucination removal on the
 * SECONDARY channel (the channel with fewer records / coarser
 * granularity). The PRIMARY channel is always passed through unchanged.
 *
 *   - "off"          — no filtering; chronological merge only.
 *   - "conservative" — drop a secondary fragment ONLY when it is
 *                      simultaneously: (a) inside a primary window,
 *                      (b) shares ZERO content tokens with that window,
 *                      AND (c) shorter than `minTokensToKeep` tokens
 *                      (default 4). Keeps any plausible rescue.
 *   - "aggressive"   — drop a secondary fragment when it shares ZERO
 *                      content tokens with the primary window it falls
 *                      inside, regardless of length. Cleaner, but may
 *                      discard real asides.
 */
export type FilterMode = "off" | "conservative" | "aggressive";

/** Sidecar emission format the merger writes. */
export type OutputFormat = "jsonl" | "txt";

/**
 * Per-record verdict produced by the filter pass. Surfaced both to the
 * merged output (when verbose) and to test assertions.
 */
export type FilterVerdict =
    | { kind: "keep"; reason: "primary" }
    | { kind: "keep"; reason: "secondary-no-overlap" }     // outside any primary window
    | { kind: "keep"; reason: "secondary-shares-tokens"; sharedTokens: readonly string[] }
    | { kind: "keep"; reason: "secondary-long-enough"; tokenCount: number }
    | { kind: "drop"; reason: "secondary-hallucination"; tokenCount: number; primaryWindowId: string };

/** Complete merge result — the merged records plus per-record audit. */
export interface MergeResult {
    readonly merged: readonly IndexedRecord[];
    readonly verdicts: ReadonlyMap<string /* record.id */, FilterVerdict>;
    readonly primaryChannel: string;
    readonly secondaryChannel: string | null;
    readonly droppedCount: number;
}

/**
 * Options resolved by the CLI from the four-tier config chain
 * (process.env → ~/.tool-agents/dual-transcript-merger/.env → local
 * .env → CLI flags). Engine-level — no I/O concerns leak in.
 */
export interface MergeOptions {
    readonly filter: FilterMode;
    /** Conservative-mode threshold: a short secondary fragment with
     *  fewer than this many content tokens AND zero overlap is
     *  dropped. Tunable for unit tests; defaults to 4. */
    readonly minTokensToKeep: number;
}
