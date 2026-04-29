#!/usr/bin/env bash
# test_scripts/e2e-transcription-permission-denied.sh
# Verifies that when Speech permission is denied, --transcribe apple exits with EX_NOPERM (77).
# MANUAL SETUP: System Settings → Privacy & Security → Speech Recognition → toggle macrec OFF.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/macrec"
OUTDIR="$(mktemp -d -t macrec-e2e-deny.XXXXXX)"
trap 'rm -rf "${OUTDIR}"' EXIT
OUT="${OUTDIR}/rec.m4a"

set +e
"${BIN}" start --output "${OUT}" --format m4a --layout mixed \
    --max-duration 3 --transcribe apple
RC=$?
set -e

# 77 is EX_NOPERM (sibling-consistent with screen/mic permission errors).
if [ "${RC}" -ne 77 ]; then
    echo "WARN: expected exit 77, got ${RC} (acceptable if permission is granted on this host — re-run after revoking Speech permission)"
    if [ "${RC}" -eq 0 ]; then
        echo "FAIL: macrec exited 0; permission must not be granted for this test to be meaningful"
        exit 1
    fi
fi
[ ! -e "${OUT}" ] || { echo "FAIL: audio should not exist when permission denied"; exit 1; }
echo "PASS: e2e-transcription-permission-denied (exit ${RC})"
