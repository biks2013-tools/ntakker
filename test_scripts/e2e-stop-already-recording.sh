#!/usr/bin/env bash
# test_scripts/e2e-stop-already-recording.sh -- exercises AC-20
#
# AC-20: Attempting `ntakker-cli start --detach` while another detached
#        recording is running exits with NtakkerError.alreadyRecording
#        (exit 78) and does not disturb the running recording.
#
# Manual prerequisite: Screen Recording AND Microphone TCC permissions
# must already be granted to the freshly built `ntakker-cli` binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_A="/tmp/ntakker-cli-e2e-stop-already-A.m4a"
OUTPUT_B="/tmp/ntakker-cli-e2e-stop-already-B.m4a"
PID_FILE="${HOME}/.tool-agents/ntakker-cli/ntakker-cli.pid"
STDERR_TMP="/tmp/ntakker-cli-e2e-stop-already.stderr"
RECORD_FOR_SECONDS=3

cat <<'BANNER'
==============================================================================
  e2e-stop-already-recording.sh -- AC-20 (refuse second concurrent --detach)
==============================================================================
  1. Start a detached recording (A).
  2. Try to start a second detached recording (B) reusing the same PID file.
  3. Expect exit 78 (alreadyRecording).
  4. Verify A is still alive.
  5. Stop A; verify the .m4a file is finalized.
==============================================================================
BANNER

echo "[1/7] Building ntakker-cli ..."
cd "${REPO_ROOT}"
swift build

BIN="${REPO_ROOT}/.build/debug/ntakker-cli"
if [[ ! -x "${BIN}" ]]; then
    echo "ERROR: built binary not found at ${BIN}" >&2
    exit 1
fi

echo "[2/7] Checking TCC permissions ..."
if ! "${BIN}" check-permissions >/dev/null 2>&1; then
    cat <<'SKIP'
  ----------------------------------------------------------------------------
  SKIPPING -- TCC permissions are not (yet) granted.
  Grant Screen Recording AND Microphone permission to the ntakker-cli binary.
  ----------------------------------------------------------------------------
SKIP
    echo "Skipped (no permissions). Treating as PASS (manual prerequisite)."
    exit 0
fi

echo "[3/7] Pre-flight cleanup ..."
rm -f "${OUTPUT_A}" "${OUTPUT_B}" "${STDERR_TMP}"
if [[ -f "${PID_FILE}" ]]; then
    EXISTING_PID="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
    if [[ -n "${EXISTING_PID}" ]] && kill -0 "${EXISTING_PID}" 2>/dev/null; then
        echo "ERROR: another ntakker-cli is already running (PID ${EXISTING_PID})." >&2
        echo "       Stop it first: ntakker-cli stop" >&2
        exit 1
    fi
    rm -f "${PID_FILE}"
fi

cleanup() {
    if [[ -f "${PID_FILE}" ]]; then
        echo "(cleanup) attempting ntakker-cli stop"
        "${BIN}" stop --stop-timeout 60 || true
    fi
    rm -f "${OUTPUT_A}" "${OUTPUT_B}" "${STDERR_TMP}"
}
trap cleanup EXIT

echo "[4/7] Starting detached recording A (PID file: default) ..."
"${BIN}" start --detach --output "${OUTPUT_A}" --overwrite
sleep 1

if [[ ! -f "${PID_FILE}" ]]; then
    echo "FAIL: PID file was not created at ${PID_FILE}" >&2
    exit 1
fi
PID_A="$(cat "${PID_FILE}")"
if [[ -z "${PID_A}" ]] || ! kill -0 "${PID_A}" 2>/dev/null; then
    echo "FAIL: detached recording A did not produce a live PID (got '${PID_A}')" >&2
    exit 1
fi
echo "  recording A: PID ${PID_A}, alive"

echo "[5/7] Trying to start a second detached recording B with the same PID file ..."
set +e
"${BIN}" start --detach --output "${OUTPUT_B}" --overwrite >/dev/null 2>"${STDERR_TMP}"
RC=$?
set -e

echo "  start --detach (B) exit code: ${RC}"
echo "  stderr:"
sed 's/^/    /' "${STDERR_TMP}" || true

if (( RC != 78 )); then
    echo "FAIL: expected exit 78 (alreadyRecording), got ${RC}" >&2
    exit 1
fi

if ! grep -q "Another ntakker-cli recording is already running" "${STDERR_TMP}"; then
    echo "FAIL: stderr did not contain the expected 'Another ntakker-cli recording is already running' summary" >&2
    exit 1
fi

# AC-20 — Recording A must NOT be disturbed.
if ! kill -0 "${PID_A}" 2>/dev/null; then
    echo "FAIL: recording A (PID ${PID_A}) was disturbed by the rejected B start" >&2
    exit 1
fi
echo "  OK: recording A is undisturbed; B was rejected"

# Recording B must not have produced an output file.
if [[ -f "${OUTPUT_B}" ]]; then
    echo "FAIL: recording B unexpectedly produced an output file at ${OUTPUT_B}" >&2
    exit 1
fi

echo "[6/7] Letting A run for ${RECORD_FOR_SECONDS}s, then stopping it ..."
sleep "${RECORD_FOR_SECONDS}"
"${BIN}" stop

if kill -0 "${PID_A}" 2>/dev/null; then
    echo "FAIL: recording A (PID ${PID_A}) is still alive after ntakker-cli stop" >&2
    exit 1
fi
if [[ -f "${PID_FILE}" ]]; then
    echo "FAIL: PID file at ${PID_FILE} still exists after ntakker-cli stop" >&2
    exit 1
fi

echo "[7/7] Validating recording A's output ..."
if [[ ! -f "${OUTPUT_A}" ]]; then
    echo "FAIL: recording A's output file at ${OUTPUT_A} was not created" >&2
    exit 1
fi
INFO="$(afinfo "${OUTPUT_A}" 2>&1)"
echo "${INFO}"
echo "${INFO}" | grep -qiE "format(:| ID:).*aac|'aac '" || { echo "FAIL: expected AAC format" >&2; exit 1; }

trap - EXIT
rm -f "${OUTPUT_A}" "${OUTPUT_B}" "${STDERR_TMP}"

echo "PASS: e2e-stop-already-recording.sh"
exit 0
