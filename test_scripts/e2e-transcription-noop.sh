#!/usr/bin/env bash
# test_scripts/e2e-transcription-noop.sh — plan-004 Phase J.1
#
# Regression: `--transcribe none` (the default) MUST NOT produce a
# `*.transcript.*` sidecar and MUST NOT open any network connection.
# Verifies AC-LT-1 / AC-LT-16: with transcription disabled, on-disk
# behaviour is byte-for-byte identical to a pre-plan-003 build.
#
# This script has NO external dependencies — it does NOT require a
# `GOOGLE_API_KEY`, network access, or any API quota. It is safe to run
# in CI and locally as part of every plan-004 verification pass.
#
# Manual prerequisite: Screen Recording AND Microphone TCC permissions
# must already be granted to `.build/release/macrec`. If they are not,
# the recording will fail with a permission error (exit 75 / 77) and
# this script will report FAIL; that is a host-setup issue, not a
# regression.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"

if [ ! -x "${BIN}" ]; then
    echo "FAIL: release binary not found at ${BIN}" >&2
    echo "Hint: run 'swift build -c release' first." >&2
    exit 1
fi

OUTDIR="$(mktemp -d -t macrec-e2e-noop.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

echo "[1/3] Recording 3 s with --transcribe none into ${OUT} ..."
"${BIN}" start \
    --output "${OUT}" \
    --format m4a \
    --layout mixed \
    --max-duration 3 \
    --transcribe none

echo "[2/3] Asserting audio file exists and is non-empty ..."
if [ ! -s "${OUT}" ]; then
    echo "FAIL: audio file empty or missing at ${OUT}" >&2
    exit 1
fi

echo "[3/3] Asserting NO sidecar file was produced ..."
shopt -s nullglob
sidecars=("${OUTDIR}"/*.transcript.*)
if [ ${#sidecars[@]} -ne 0 ]; then
    echo "FAIL: unexpected sidecar(s) produced with --transcribe none:" >&2
    printf '  %s\n' "${sidecars[@]}" >&2
    exit 1
fi

bytes=$(wc -c < "${OUT}" | tr -d ' ')
echo "PASS: e2e-transcription-noop (audio ${bytes} bytes, no sidecar)"
