#!/usr/bin/env bash
# test_scripts/e2e-transcription-key-missing.sh — plan-004 Phase J.4
#
# Verifies AC-LT-4: when `--transcribe gemini` is requested but no API
# key is resolvable from any tier of the configuration chain, `macrec`
# MUST exit with a non-zero status (currently 78 / EX_CONFIG via
# `MacrecError.transcriptionApiKeyMissing`) and MUST NOT create an
# audio file. The failure is raised before any capture session opens.
#
# This script has NO external dependencies — it does NOT require a
# real `GOOGLE_API_KEY`, network access, or any API quota. Safe to run
# in CI and locally as part of every plan-004 verification pass.
#
# Manual prerequisite: none. The TCC permission check is short-
# circuited by the missing-key check (raised earlier in the resolver
# pipeline).
#
# Plan-005 default-flip note: `MACREC_TRANSCRIBE` now defaults to
# `apple` (on-device, no API key required), not `none`. This script
# MUST therefore pass `--transcribe gemini` explicitly to keep
# exercising the missing-key code path; the implicit default no
# longer routes through `gemini`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"

if [ ! -x "${BIN}" ]; then
    echo "FAIL: release binary not found at ${BIN}" >&2
    echo "Hint: run 'swift build -c release' first." >&2
    exit 1
fi

OUTDIR="$(mktemp -d -t macrec-e2e-keymissing.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

# Scrub any inherited GOOGLE_API_KEY from this process's environment so
# the resolver finds nothing in tier 1 (shell env). User and local .env
# tiers are the user's responsibility — if they have a key in
# `~/.tool-agents/macrec/.env` this assertion will not hold; that is
# expected (the resolver is doing its job).
unset GOOGLE_API_KEY

echo "[1/3] Running --transcribe gemini with no API key ..."
set +e
"${BIN}" start \
    --output "${OUT}" \
    --format m4a \
    --layout mixed \
    --max-duration 3 \
    --transcribe gemini \
    >/dev/null 2>&1
RC=$?
set -e

echo "[2/3] Asserting non-zero exit code (got ${RC}) ..."
# Per project-design.md §LT-4 / §9.5, transcriptionApiKeyMissing maps
# to EX_CONFIG (78). The script accepts any non-zero exit because
# the strict assertion is the no-audio-file invariant in step 3 — the
# precise exit code is verified by the unit tests.
if [ "${RC}" -eq 0 ]; then
    echo "FAIL: expected non-zero exit code, got 0" >&2
    exit 1
fi
if [ "${RC}" -ne 78 ]; then
    echo "WARN: expected exit 78 (EX_CONFIG) per design §9.5, got ${RC}" >&2
    echo "      (still treated as PASS because non-zero is the strict assertion;" >&2
    echo "      update this comment if the project changes the mapping.)" >&2
fi

echo "[3/3] Asserting NO audio file was produced (AC-LT-4) ..."
if [ -e "${OUT}" ]; then
    bytes=$(wc -c < "${OUT}" 2>/dev/null | tr -d ' ' || echo "?")
    echo "FAIL: audio file should NOT exist on missing-key error, but found ${OUT} (${bytes} bytes)" >&2
    exit 1
fi

echo "PASS: e2e-transcription-key-missing (exit ${RC}, no audio file produced)"
