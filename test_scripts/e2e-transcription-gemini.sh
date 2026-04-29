#!/usr/bin/env bash
# test_scripts/e2e-transcription-gemini.sh — plan-004 Phase J.2
#
# Happy-path end-to-end test for `--transcribe gemini` (REST batch
# architecture). Plays a known phrase via macOS `say` + `afplay` while
# `macrec` records, then asserts that the resulting JSONL sidecar
# contains a fuzzy keyword match against the phrase.
#
# REQUIRES a real `GOOGLE_API_KEY` exported in the shell. Obtain one at
# <https://aistudio.google.com/app/apikey>. This script will exit 1
# immediately if the key is unset (set -u + parameter expansion).
#
# REQUIRES `jq` for JSONL parsing. Install with `brew install jq`.
#
# Manual prerequisites:
#   1. Screen Recording AND Microphone TCC granted to
#      `.build/release/macrec`.
#   2. The system audio output device (speakers / headphones) must be
#      audible enough that `ScreenCaptureKit` can capture the `afplay`
#      output. Bluetooth output routes are known to mute the submix in
#      rare configs (R-9) — use a wired output if the script reports
#      0 keyword hits despite a successful API call.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"

if [ ! -x "${BIN}" ]; then
    echo "FAIL: release binary not found at ${BIN}" >&2
    echo "Hint: run 'swift build -c release' first." >&2
    exit 1
fi

: "${GOOGLE_API_KEY:?GOOGLE_API_KEY must be set; obtain at https://aistudio.google.com/app/apikey}"

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: 'jq' is not installed; install with 'brew install jq'." >&2
    exit 1
fi

PHRASE="The quick brown fox jumps over the lazy dog"
OUTDIR="$(mktemp -d -t macrec-e2e-gemini.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

# Generate the fixture phrase via macOS `say` if not present (cached
# under test_scripts/fixtures/ across runs to avoid regenerating it).
FIXTURE_DIR="${ROOT}/test_scripts/fixtures"
FIXTURE="${FIXTURE_DIR}/known-phrase.aiff"
mkdir -p "${FIXTURE_DIR}"
if [ ! -f "${FIXTURE}" ]; then
    echo "[setup] Generating fixture phrase via 'say' at ${FIXTURE} ..."
    say "${PHRASE}" -o "${FIXTURE}"
fi

# Order matters: start macrec first (background), let ScreenCaptureKit
# warm up for ~1.5 s, THEN play the fixture. If `afplay` runs before
# SCKit is capturing, the phrase plays into a void and only background
# noise lands in the recording — the energy gate filters it out and no
# segments are produced. Empirically observed during plan-004 Phase J.8.
echo "[1/4] Starting macrec in background (12 s) into ${OUT} ..."
"${BIN}" start \
    --output "${OUT}" \
    --format m4a \
    --layout mixed \
    --max-duration 12 \
    --transcribe gemini \
    --transcribe-source mixed \
    --transcribe-format jsonl &
MACREC_PID=$!

echo "[2/4] Waiting 1.5 s for SCKit warm-up, then playing fixture ..."
sleep 1.5
afplay "${FIXTURE}"

# Wait for macrec to finish at --max-duration.
wait "${MACREC_PID}"

echo "[3/4] Asserting audio file and sidecar exist and are non-empty ..."
if [ ! -s "${OUT}" ]; then
    echo "FAIL: audio file empty or missing at ${OUT}" >&2
    exit 1
fi
SIDECAR="${OUT%.m4a}.transcript.jsonl"
if [ ! -s "${SIDECAR}" ]; then
    echo "FAIL: sidecar missing or empty at ${SIDECAR}" >&2
    echo "Hint: the audio file exists, so capture worked. Check that GOOGLE_API_KEY is valid and that the model id is accepted by Google." >&2
    exit 1
fi

N_LINES=$(grep -v '_tombstone' "${SIDECAR}" | grep -cv '^[[:space:]]*$' || true)
N_LINES=$(echo "${N_LINES}" | tr -d ' ')
if [ "${N_LINES}" -lt 1 ]; then
    echo "FAIL: zero non-tombstone lines in sidecar ${SIDECAR}" >&2
    echo "--- sidecar contents ---" >&2
    cat "${SIDECAR}" >&2
    exit 1
fi

echo "[4/4] Asserting fuzzy keyword match against the known phrase ..."
TEXT=$(jq -r 'select(._tombstone != true) | .text // empty' "${SIDECAR}" 2>/dev/null \
       | tr '[:upper:]' '[:lower:]')
HITS=0
for w in quick brown fox jumps lazy dog; do
    if grep -qF "${w}" <<<"${TEXT}"; then
        HITS=$((HITS + 1))
    fi
done
if [ "${HITS}" -lt 3 ]; then
    echo "FAIL: only ${HITS} keyword hits (need >= 3) in sidecar text:" >&2
    echo "  ${TEXT}" >&2
    echo "" >&2
    echo "If the build returns HTTP 4xx errors, set" >&2
    echo "  MACREC_TRANSCRIBE_MODEL=gemini-3-flash-preview" >&2
    echo "per plan-004 §9.1 (the documented Google REST audio model)." >&2
    exit 1
fi

echo "PASS: e2e-transcription-gemini (${N_LINES} segments, ${HITS} keyword hits)"
echo "  audio:   ${OUT}"
echo "  sidecar: ${SIDECAR}"
