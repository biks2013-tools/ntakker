// index.ts — public API surface for programmatic consumers
// (e.g. macrec-ui calling the merger in-process via a future
// child-process bridge, or downstream Node tooling).

export { merge, contentTokens } from "./merger.js";
export { parseAll, parseLine, parseStream, MergerError } from "./parser.js";
export { toJsonl, toTxt, emit } from "./emitter.js";
export { resolveDefaults, applyCliOverrides } from "./config.js";
export type {
    FilterMode,
    FilterVerdict,
    IndexedRecord,
    MergeOptions,
    MergeResult,
    OutputFormat,
    SidecarRecord,
} from "./types.js";
