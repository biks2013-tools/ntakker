// merger.test.ts — pin the bidirectional filter behaviour against the
// real macrec sample the user reported (Greek speech with English
// asides; on-device en-US channel hallucinates Greek as English).

import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { merge } from "../src/merger.ts";
import { parseAll } from "../src/parser.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const samplePath = resolve(__dirname, "..", "..", "..", "test_scripts", "dual-transcript-merger", "sample.jsonl");
const sample = readFileSync(samplePath, "utf8");

describe("merger — user's real macrec sample", () => {

    it("off mode keeps all 7 records, sorted by timestamp", () => {
        const records = parseAll(sample);
        const r = merge(records, { filter: "off", minTokensToKeep: 4 });
        assert.equal(r.merged.length, 7);
        assert.equal(r.droppedCount, 0);
        // EL window starts at 02:26:09.001 — must be first chronologically.
        assert.equal(r.merged[0]?.channel, "EL");
        assert.equal(r.merged[1]?.channel, "EN");
        assert.equal(r.merged[6]?.channel, "EN");
    });

    it("conservative mode keeps all 7 records (each has >= 4 content tokens)", () => {
        const records = parseAll(sample);
        const r = merge(records, { filter: "conservative", minTokensToKeep: 4 });
        assert.equal(r.merged.length, 7);
        assert.equal(r.droppedCount, 0);
    });

    it("aggressive mode drops the 3 garbled-Greek-as-English EN entries", () => {
        const records = parseAll(sample);
        const r = merge(records, { filter: "aggressive", minTokensToKeep: 4 });
        assert.equal(r.merged.length, 4);
        assert.equal(r.droppedCount, 3);
        // The dropped 3 are the EN entries that share zero tokens with EL.
        const droppedTexts = records
            .filter((rec) => r.verdicts.get(rec.id)?.kind === "drop")
            .map((rec) => rec.text.trim());
        assert.deepEqual(
            droppedTexts.sort(),
            [
                "After finish, then I do...",
                "Ultimalon in the glibo. Cynthia's wool.",
                "Yeah, I've been told.",
            ].sort(),
        );
        // The 3 kept EN entries each share at least one token with EL
        // (better, best, time).
        const keptEN = r.merged.filter((rec) => rec.channel === "EN");
        assert.equal(keptEN.length, 3);
    });

    it("classifies EN as primary (more records) and EL as secondary", () => {
        const records = parseAll(sample);
        const r = merge(records, { filter: "off", minTokensToKeep: 4 });
        assert.equal(r.primaryChannel, "EN");
        assert.equal(r.secondaryChannel, "EL");
    });

    it("EL fragment shares 'better', 'best', 'time' with EN — keeps in all modes", () => {
        const records = parseAll(sample);
        for (const mode of ["off", "conservative", "aggressive"] as const) {
            const r = merge(records, { filter: mode, minTokensToKeep: 4 });
            const elKept = r.merged.some((rec) => rec.channel === "EL");
            assert.equal(elKept, true, `EL fragment must survive in ${mode} mode`);
        }
    });
});

describe("merger — single-channel input", () => {
    it("passes through unchanged when only one channel is present", () => {
        const onlyEN = parseAll(
            sample
                .split("\n")
                .filter((l) => l.length === 0 || l.includes('"channel":"EN"'))
                .join("\n"),
        );
        const r = merge(onlyEN, { filter: "aggressive", minTokensToKeep: 4 });
        assert.equal(r.merged.length, 6);
        assert.equal(r.droppedCount, 0);
        assert.equal(r.primaryChannel, "EN");
        assert.equal(r.secondaryChannel, null);
    });
});
