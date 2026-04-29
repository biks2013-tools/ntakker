#!/usr/bin/env bash
# test_scripts/e2e-transcription-apple-detach.sh
# Verifies detach + apple parity (FR-AS-10).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"
OUTDIR="$(mktemp -d -t macrec-e2e-apple-detach.XXXXXX)"
OUT="${OUTDIR}/rec.m4a"
cleanup() {
    "${BIN}" stop --output "${OUT}" 2>/dev/null || true
    rm -rf "${OUTDIR}"
}
trap cleanup EXIT
FIXTURE="${ROOT}/test_scripts/fixtures/known-phrase.aiff"
[ -f "${FIXTURE}" ] || say "Hello world from detached macrec" -o "${FIXTURE}"

"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --detach --max-duration 8 --transcribe apple --transcribe-format jsonl
sleep 1.5
afplay "${FIXTURE}"
sleep 12

[ -s "${OUT}" ] || { echo "FAIL: detach audio empty"; exit 1; }
SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "${SIDECAR}" ] || { echo "FAIL: detach sidecar missing"; exit 1; }
echo "PASS: e2e-transcription-apple-detach"
