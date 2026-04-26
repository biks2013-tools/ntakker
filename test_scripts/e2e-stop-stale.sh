#!/usr/bin/env bash
# test_scripts/e2e-stop-stale.sh -- exercises AC-18 + AC-19
#
# AC-18: `macrec stop` with no PID file present exits with
#        MacrecError.noActiveRecording (exit 78). No PID file is created.
# AC-19: `macrec stop` with a stale PID file (PID no longer alive) cleans
#        up the file and exits with MacrecError.staleRecording (exit 75).
#
# This script does NOT require TCC permissions because `stop` does not
# touch ScreenCaptureKit / AVFoundation. It is fully self-contained.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="/tmp/macrec-e2e-stop-stale.pid"
STALE_PID=999999

cat <<'BANNER'
==============================================================================
  e2e-stop-stale.sh -- AC-18 + AC-19 (no PID file / stale PID file)
==============================================================================
  AC-18: `macrec stop` with no PID file -> exit 78 (noActiveRecording)
  AC-19: `macrec stop` with a stale PID -> exit 75 (staleRecording),
         and the PID file is removed.
  TCC permissions are NOT required for this script.
==============================================================================
BANNER

echo "[1/3] Building macrec ..."
cd "${REPO_ROOT}"
swift build

BIN="${REPO_ROOT}/.build/debug/macrec"
if [[ ! -x "${BIN}" ]]; then
    echo "ERROR: built binary not found at ${BIN}" >&2
    exit 1
fi

echo "[2/3] AC-18: stop with no PID file -> expect exit 78 ..."
rm -f "${PID_FILE}"
if [[ -f "${PID_FILE}" ]]; then
    echo "FAIL: pre-condition: ${PID_FILE} should not exist" >&2
    exit 1
fi

set +e
"${BIN}" stop --pid-file "${PID_FILE}" >/dev/null 2>"${PID_FILE}.stderr"
RC=$?
set -e

echo "  stop exit code: ${RC}"
echo "  stderr:"
sed 's/^/    /' "${PID_FILE}.stderr" || true

if (( RC != 78 )); then
    echo "FAIL: expected exit 78 (noActiveRecording), got ${RC}" >&2
    exit 1
fi

# stop MUST NOT have created a PID file.
if [[ -f "${PID_FILE}" ]]; then
    echo "FAIL: stop should not have created a PID file at ${PID_FILE}" >&2
    exit 1
fi

# Cross-check the stderr summary string.
if ! grep -q "No active macrec recording found" "${PID_FILE}.stderr"; then
    echo "FAIL: stderr did not contain the expected 'No active macrec recording found' summary" >&2
    exit 1
fi

echo "  OK: AC-18 satisfied"

echo "[3/3] AC-19: stop with a stale PID file -> expect exit 75, file removed ..."
# Pick a PID that is essentially guaranteed not to be alive on macOS (PID
# values are bounded by the kernel's PID_MAX which is well below 999999
# on macOS 14+).
echo "${STALE_PID}" > "${PID_FILE}"
chmod 0600 "${PID_FILE}"
if ! [[ -f "${PID_FILE}" ]]; then
    echo "FAIL: pre-condition: stale PID file should exist at ${PID_FILE}" >&2
    exit 1
fi

set +e
"${BIN}" stop --pid-file "${PID_FILE}" >/dev/null 2>"${PID_FILE}.stderr"
RC=$?
set -e

echo "  stop exit code: ${RC}"
echo "  stderr:"
sed 's/^/    /' "${PID_FILE}.stderr" || true

if (( RC != 75 )); then
    echo "FAIL: expected exit 75 (staleRecording), got ${RC}" >&2
    exit 1
fi

if [[ -f "${PID_FILE}" ]]; then
    echo "FAIL: stop should have removed the stale PID file at ${PID_FILE}" >&2
    exit 1
fi

if ! grep -q "Stale PID file" "${PID_FILE}.stderr"; then
    echo "FAIL: stderr did not contain the expected 'Stale PID file' summary" >&2
    exit 1
fi

echo "  OK: AC-19 satisfied"

# Cleanup
rm -f "${PID_FILE}.stderr"

echo "PASS: e2e-stop-stale.sh"
exit 0
