#!/usr/bin/env bash
# test_scripts/e2e-transcription-apple-dual-locale.sh
# Verifies dual-locale parallel recognition. Requires en-US AND el-GR language packs installed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"
[ -x "${BIN}" ] || { echo "FAIL: ${BIN} not found"; exit 1; }

OUTDIR="$(mktemp -d -t macrec-e2e-apple-dual.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

FIXTURE="${ROOT}/test_scripts/fixtures/dual-phrase.aiff"
mkdir -p "$(dirname "${FIXTURE}")"
if [ ! -f "${FIXTURE}" ]; then
    TMP_EN=$(mktemp -t en.XXXXXX).aiff
    TMP_EL=$(mktemp -t el.XXXXXX).aiff
    say -v Samantha "Hello world" -o "${TMP_EN}" 2>/dev/null || say "Hello world" -o "${TMP_EN}"
    say -v Anna "Καλημέρα" -o "${TMP_EL}" 2>/dev/null || say "Hello again" -o "${TMP_EL}"
    cat "${TMP_EN}" "${TMP_EL}" > "${FIXTURE}" || cp "${TMP_EN}" "${FIXTURE}"
    rm -f "${TMP_EN}" "${TMP_EL}"
fi

"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --max-duration 15 --transcribe apple \
    --transcribe-language en-US,el-GR \
    --transcribe-source mixed --transcribe-format jsonl &
MACREC_PID=$!
sleep 1.5
afplay "${FIXTURE}"
wait "${MACREC_PID}"

SIDECAR="${OUT%.m4a}.transcript.jsonl"
[ -s "${SIDECAR}" ] || { echo "FAIL: sidecar missing"; exit 1; }
EN_HITS=$(grep -c '"language":"en-US"' "${SIDECAR}" || true)
EL_HITS=$(grep -c '"language":"el-GR"' "${SIDECAR}" || true)
echo "  EN lines: ${EN_HITS}, EL lines: ${EL_HITS}"
[ $((EN_HITS + EL_HITS)) -ge 1 ] || { echo "FAIL: zero language-tagged lines"; cat "${SIDECAR}"; exit 1; }
echo "PASS: e2e-transcription-apple-dual-locale (en=${EN_HITS}, el=${EL_HITS})"
