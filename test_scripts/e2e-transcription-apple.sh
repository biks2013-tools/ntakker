#!/usr/bin/env bash
# test_scripts/e2e-transcription-apple.sh
# Happy path for --transcribe apple. Requires macOS 26+ and Speech permission.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"

[ -x "${BIN}" ] || { echo "FAIL: ${BIN} not found; run 'swift build -c release'"; exit 1; }

PHRASE="The quick brown fox jumps over the lazy dog"
OUTDIR="$(mktemp -d -t macrec-e2e-apple.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

FIXTURE="${ROOT}/test_scripts/fixtures/known-phrase.aiff"
mkdir -p "$(dirname "${FIXTURE}")"
[ -f "${FIXTURE}" ] || say "${PHRASE}" -o "${FIXTURE}"

echo "[1/4] Starting macrec in background (12s, --transcribe apple) ..."
"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --max-duration 12 --transcribe apple \
    --transcribe-source mixed --transcribe-format jsonl &
MACREC_PID=$!

echo "[2/4] Waiting 1.5s for SpeechAnalyzer warm-up, then playing fixture ..."
sleep 1.5
afplay "${FIXTURE}"
wait "${MACREC_PID}"

echo "[3/4] Asserting audio + sidecar exist ..."
[ -s "${OUT}" ] || { echo "FAIL: audio empty"; exit 1; }
SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "${SIDECAR}" ] || { echo "FAIL: sidecar missing or empty at ${SIDECAR}"; exit 1; }

echo "[4/4] Asserting model:apple and >= 3 keyword hits ..."
APPLE_LINES=$(grep -c '"model":"apple"' "${SIDECAR}" || true)
[ "${APPLE_LINES}" -ge 1 ] || { echo "FAIL: no model:apple lines in sidecar"; cat "${SIDECAR}"; exit 1; }
TEXT=$(jq -r 'select(._tombstone != true) | .text // empty' "${SIDECAR}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
HITS=0
for w in quick brown fox jumps lazy dog; do
    if grep -qF "${w}" <<<"${TEXT}"; then HITS=$((HITS+1)); fi
done
if [ "${HITS}" -lt 3 ]; then
    echo "FAIL: only ${HITS} keyword hits in:"
    echo "  ${TEXT}"
    exit 1
fi
echo "PASS: e2e-transcription-apple (${APPLE_LINES} apple lines, ${HITS} keyword hits)"
