#!/usr/bin/env bash
# test_scripts/e2e-60min-stability.sh — exercises AC-11 + NFR-3 (long-run stability)
#
# Records for 60 minutes (3600 s) and verifies the resulting file's duration
# is within ±1 s of the requested cap (AC-11). This script is OPT-IN: it is
# skipped unless the user sets `NTAKKER_LONG_RUN=1` in the environment, since
# a 60-minute recording is far too slow for routine CI / local feedback.
#
# Manual prerequisite: Screen Recording AND Microphone TCC permissions must
# already be granted to the freshly built `ntakker-cli` binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="/tmp/ntakker-cli-e2e-60min-stability.m4a"
DURATION_SECONDS=3600

cat <<'BANNER'
==============================================================================
  e2e-60min-stability.sh — AC-11 + NFR-3 (60-minute stability)
==============================================================================
  Records for 3600 s and verifies the resulting file's duration is within
  +/- 1 s of the requested cap. OPT-IN -- set NTAKKER_LONG_RUN=1 to actually
  run; otherwise this script exits 0 immediately.
==============================================================================
BANNER

if [[ "${NTAKKER_LONG_RUN:-0}" != "1" ]]; then
    cat <<'SKIP'
  Skipping: set NTAKKER_LONG_RUN=1 to run the full 60-minute test.
  Example:  NTAKKER_LONG_RUN=1 bash test_scripts/e2e-60min-stability.sh
SKIP
    echo "Skipped (opt-in). Treating as PASS."
    exit 0
fi

echo "[1/5] Building ntakker-cli ..."
cd "${REPO_ROOT}"
swift build

BIN="${REPO_ROOT}/.build/debug/ntakker-cli"
if [[ ! -x "${BIN}" ]]; then
    echo "ERROR: built binary not found at ${BIN}" >&2
    exit 1
fi

echo "[2/5] Checking TCC permissions ..."
if ! "${BIN}" check-permissions >/dev/null 2>&1; then
    cat <<'SKIP'
  ----------------------------------------------------------------------------
  SKIPPING -- TCC permissions are not (yet) granted.
  Open System Settings > Privacy & Security and grant Screen Recording AND
  Microphone permission to the ntakker-cli binary, then re-run.
  ----------------------------------------------------------------------------
SKIP
    echo "Skipped (no permissions). Treating as PASS (manual prerequisite)."
    exit 0
fi

echo "[3/5] Recording ${DURATION_SECONDS} s (this will take ~60 minutes) ..."
rm -f "${OUTPUT}"
START_TS="$(date +%s)"
"${BIN}" start --output "${OUTPUT}" --max-duration "${DURATION_SECONDS}" --overwrite
END_TS="$(date +%s)"
WALL_CLOCK="$(( END_TS - START_TS ))"

if [[ ! -f "${OUTPUT}" ]]; then
    echo "FAIL: expected output file at ${OUTPUT} was not created" >&2
    exit 1
fi

echo "[4/5] Validating with afinfo ..."
INFO="$(afinfo "${OUTPUT}" 2>&1)"
echo "${INFO}"

DUR_LINE="$(echo "${INFO}" | grep -iE "estimated duration" | head -n 1 || true)"
if [[ -z "${DUR_LINE}" ]]; then
    echo "FAIL: could not find 'estimated duration' line in afinfo output" >&2
    exit 1
fi
DUR_SECONDS="$(echo "${DUR_LINE}" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n 1)"
if [[ -z "${DUR_SECONDS}" ]]; then
    echo "FAIL: could not parse seconds from: ${DUR_LINE}" >&2
    exit 1
fi

# AC-11: duration within +/- 1 s of 3600 s.
if awk -v d="${DUR_SECONDS}" -v t="${DURATION_SECONDS}" 'BEGIN { delta = (d > t) ? d - t : t - d; exit !(delta <= 1.0) }'; then
    echo "OK: duration ${DUR_SECONDS}s within +/- 1 s of ${DURATION_SECONDS}s"
else
    echo "FAIL: duration ${DUR_SECONDS}s deviates by more than 1 s from ${DURATION_SECONDS}s" >&2
    exit 1
fi

FILESIZE_BYTES="$(stat -f '%z' "${OUTPUT}")"
echo "Stats:"
echo "  wall-clock:     ${WALL_CLOCK} s"
echo "  audio duration: ${DUR_SECONDS} s"
echo "  file size:      ${FILESIZE_BYTES} bytes"

echo "[5/5] Cleanup ..."
rm -f "${OUTPUT}"

echo "PASS: e2e-60min-stability.sh"
exit 0
