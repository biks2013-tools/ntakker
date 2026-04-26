#!/usr/bin/env bash
# test_scripts/e2e-sigint-finalize.sh — exercises AC-7 (SIGINT-finalized recording)
#
# Starts a foreground recording (no --max-duration), sleeps 5 s, sends SIGINT,
# and verifies the resulting `.m4a` is playable end-to-end via `afinfo`.
#
# Manual prerequisite: Screen Recording AND Microphone TCC permissions must
# already be granted.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="/tmp/macrec-e2e-sigint-finalize.m4a"
RECORD_FOR_SECONDS=5
# Allow up to 60 s for the writer to finalize after SIGINT (project default
# stop-timeout is 35 s; we widen to absorb dev-machine variance).
FINALIZE_GRACE_SECONDS=60

cat <<'BANNER'
==============================================================================
  e2e-sigint-finalize.sh -- AC-7 (SIGINT cleanly finalizes the file)
==============================================================================
  Starts a foreground recording, sleeps 5 s, sends SIGINT, and verifies
  the resulting .m4a is playable end-to-end via afinfo.
==============================================================================
BANNER

echo "[1/5] Building macrec ..."
cd "${REPO_ROOT}"
swift build

BIN="${REPO_ROOT}/.build/debug/macrec"
if [[ ! -x "${BIN}" ]]; then
    echo "ERROR: built binary not found at ${BIN}" >&2
    exit 1
fi

echo "[2/5] Checking TCC permissions ..."
if ! "${BIN}" check-permissions >/dev/null 2>&1; then
    cat <<'SKIP'
  ----------------------------------------------------------------------------
  SKIPPING -- TCC permissions are not (yet) granted.
  Grant Screen Recording AND Microphone permission to the macrec binary.
  ----------------------------------------------------------------------------
SKIP
    echo "Skipped (no permissions). Treating as PASS (manual prerequisite)."
    exit 0
fi

rm -f "${OUTPUT}"

echo "[3/5] Starting recording in background (will SIGINT after ${RECORD_FOR_SECONDS}s) ..."
"${BIN}" start --output "${OUTPUT}" --overwrite &
REC_PID=$!

# Cleanup hook: if anything below errors out, make sure we don't leave
# the recorder running.
cleanup() {
    if kill -0 "${REC_PID}" 2>/dev/null; then
        echo "(cleanup) sending SIGTERM to lingering macrec at PID ${REC_PID}"
        kill -TERM "${REC_PID}" 2>/dev/null || true
        sleep 2
        kill -KILL "${REC_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

sleep "${RECORD_FOR_SECONDS}"

if ! kill -0 "${REC_PID}" 2>/dev/null; then
    echo "FAIL: macrec process exited prematurely (PID ${REC_PID})" >&2
    exit 1
fi

echo "Sending SIGINT to macrec (PID ${REC_PID}) ..."
kill -INT "${REC_PID}"

# Wait up to FINALIZE_GRACE_SECONDS for the process to exit on its own.
WAITED=0
while kill -0 "${REC_PID}" 2>/dev/null; do
    if (( WAITED >= FINALIZE_GRACE_SECONDS )); then
        echo "FAIL: macrec did not exit within ${FINALIZE_GRACE_SECONDS}s of SIGINT" >&2
        exit 1
    fi
    sleep 1
    WAITED=$(( WAITED + 1 ))
done

# `wait` would exit 130 (SIGINT) -- that's the expected exit status.
wait "${REC_PID}" || true

if [[ ! -f "${OUTPUT}" ]]; then
    echo "FAIL: expected output file at ${OUTPUT} was not created" >&2
    exit 1
fi

echo "[4/5] Validating finalized file with afinfo ..."
INFO="$(afinfo "${OUTPUT}" 2>&1)"
echo "${INFO}"

# AC-7: the file must open cleanly. afinfo errors out non-zero on a
# truncated atom / malformed header, which is what we are guarding
# against here.
echo "${INFO}" | grep -qiE "format(:| ID:).*aac|'aac '"  || { echo "FAIL: expected AAC format"  >&2; exit 1; }
echo "${INFO}" | grep -qiE "estimated duration"          || { echo "FAIL: missing 'estimated duration'" >&2; exit 1; }

DUR_LINE="$(echo "${INFO}" | grep -iE "estimated duration" | head -n 1)"
DUR_SECONDS="$(echo "${DUR_LINE}" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n 1)"
echo "Recorded duration: ${DUR_SECONDS}s (target ~${RECORD_FOR_SECONDS}s)."

# Sanity: duration should be at least RECORD_FOR_SECONDS - 1, no upper
# bound (writer flushes a small tail after SIGINT).
if awk -v d="${DUR_SECONDS}" -v t="${RECORD_FOR_SECONDS}" 'BEGIN { exit !(d >= t - 1.0) }'; then
    echo "OK: duration looks reasonable for a ${RECORD_FOR_SECONDS}s SIGINT cut"
else
    echo "FAIL: duration ${DUR_SECONDS}s seems too short for a ${RECORD_FOR_SECONDS}s recording" >&2
    exit 1
fi

echo "[5/5] Cleanup ..."
rm -f "${OUTPUT}"
trap - EXIT

echo "PASS: e2e-sigint-finalize.sh"
exit 0
