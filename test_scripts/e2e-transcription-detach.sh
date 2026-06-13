#!/usr/bin/env bash
# test_scripts/e2e-transcription-detach.sh — plan-004 Phase J.3
#
# Verifies that `--detach` is now compatible with `--transcribe gemini`.
# The plan-003-era restriction (R-LT-2 / `transcriptionDetachUnsupported`)
# was lifted by plan-004 Phase G.1 because the REST batch architecture
# has no terminal-output dependency: the detached daemon can perfectly
# well POST audio chunks and write the JSONL sidecar alongside the
# audio file with no foreground stderr/stdout.
#
# REQUIRES a real `GOOGLE_API_KEY` exported in the shell. Obtain at
# <https://aistudio.google.com/app/apikey>.
#
# Manual prerequisites (same as e2e-transcription-gemini.sh):
#   1. Screen Recording AND Microphone TCC granted to
#      `.build/release/ntakker-cli`.
#   2. Audible system audio output route.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/ntakker-cli"

if [ ! -x "${BIN}" ]; then
    echo "FAIL: release binary not found at ${BIN}" >&2
    echo "Hint: run 'swift build -c release' first." >&2
    exit 1
fi

: "${GOOGLE_API_KEY:?GOOGLE_API_KEY must be set; obtain at https://aistudio.google.com/app/apikey}"

OUTDIR="$(mktemp -d -t ntakker-cli-e2e-detach.XXXXXX)"
OUT="${OUTDIR}/rec.m4a"
PID_FILE="${OUTDIR}/ntakker-cli.pid"
LOG_FILE="${OUTDIR}/ntakker-cli.log"

cleanup() {
    # Best-effort stop in case --max-duration didn't fire.
    "${BIN}" stop --pid-file "${PID_FILE}" >/dev/null 2>&1 || true
    rm -rf "${OUTDIR}"
}
trap cleanup EXIT

# Generate the fixture phrase (cached across runs).
FIXTURE_DIR="${ROOT}/test_scripts/fixtures"
FIXTURE="${FIXTURE_DIR}/known-phrase.aiff"
mkdir -p "${FIXTURE_DIR}"
if [ ! -f "${FIXTURE}" ]; then
    echo "[setup] Generating fixture phrase via 'say' ..."
    say "Hello world from a detached ntakker-cli recording" \
        -o "${FIXTURE}" --data-format=LEI16@44100
fi

echo "[1/4] Starting fixture playback in the background ..."
afplay "${FIXTURE}" &
AFPLAY_PID=$!

echo "[2/4] Launching detached recording (8 s) with --transcribe gemini ..."
"${BIN}" start \
    --output "${OUT}" \
    --format m4a \
    --layout mixed \
    --detach \
    --pid-file "${PID_FILE}" \
    --log-file "${LOG_FILE}" \
    --max-duration 8 \
    --transcribe gemini \
    --transcribe-format jsonl

echo "[3/4] Waiting up to 30 s for the detached recording to finalize ..."
# --max-duration 8 + finalize/upload margin. Poll the PID file: when the
# daemon exits cleanly it removes the PID file (or kill -0 returns
# ESRCH on the recorded pid).
DEADLINE=$((SECONDS + 30))
while [ -f "${PID_FILE}" ] && [ "${SECONDS}" -lt "${DEADLINE}" ]; do
    sleep 1
done
wait "${AFPLAY_PID}" 2>/dev/null || true

if [ -f "${PID_FILE}" ]; then
    echo "FAIL: detached recording did not exit within 30 s; PID file still present at ${PID_FILE}" >&2
    echo "--- daemon log ---" >&2
    cat "${LOG_FILE}" >&2 || true
    exit 1
fi

echo "[4/4] Asserting audio file and sidecar exist and are non-empty ..."
if [ ! -s "${OUT}" ]; then
    echo "FAIL: detach audio empty or missing at ${OUT}" >&2
    echo "--- daemon log ---" >&2
    cat "${LOG_FILE}" >&2 || true
    exit 1
fi
SIDECAR="${OUT%.m4a}.transcript.jsonl"
if [ ! -s "${SIDECAR}" ]; then
    echo "FAIL: detach sidecar missing or empty at ${SIDECAR}" >&2
    echo "--- daemon log ---" >&2
    cat "${LOG_FILE}" >&2 || true
    exit 1
fi

echo "PASS: e2e-transcription-detach"
echo "  audio:   ${OUT}"
echo "  sidecar: ${SIDECAR}"
