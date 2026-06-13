#!/usr/bin/env bash
# test_scripts/e2e-detach-stop.sh -- exercises AC-16 + AC-17
#
# AC-16: `start --detach` returns the shell prompt within ~1 s, writes a
#        live PID file, and produces a recording when stopped.
# AC-17: `stop` against a live detached process sends SIGTERM, the process
#        exits cleanly within --stop-timeout, the file is finalized, and
#        the PID file is removed.
#
# Manual prerequisite: Screen Recording AND Microphone TCC permissions must
# already be granted to the freshly built `ntakker-cli` binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="/tmp/ntakker-cli-e2e-detach-stop.m4a"
PID_FILE="${HOME}/.tool-agents/ntakker-cli/ntakker-cli.pid"
RECORD_FOR_SECONDS=4
PROMPT_RETURN_BUDGET_SECONDS=2

cat <<'BANNER'
==============================================================================
  e2e-detach-stop.sh -- AC-16 + AC-17 (detach + stop)
==============================================================================
  1. Verifies `start --detach` returns the prompt in <2 s.
  2. Verifies a live PID file is written.
  3. Verifies `ntakker-cli stop` cleanly stops the daemon.
  4. Verifies the PID file is gone afterwards.
  5. Verifies the resulting .m4a is playable.
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

echo "[3/7] Pre-flight cleanup (no leftover PID file or output) ..."
rm -f "${OUTPUT}"
if [[ -f "${PID_FILE}" ]]; then
    EXISTING_PID="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
    if [[ -n "${EXISTING_PID}" ]] && kill -0 "${EXISTING_PID}" 2>/dev/null; then
        echo "ERROR: another ntakker-cli is already running (PID ${EXISTING_PID})." >&2
        echo "       Stop it first: ntakker-cli stop" >&2
        exit 1
    fi
    echo "(cleanup) removing stale PID file at ${PID_FILE}"
    rm -f "${PID_FILE}"
fi

echo "[4/7] Starting detached recording (measuring prompt-return time) ..."
START_NS="$(date +%s)"
"${BIN}" start --detach --output "${OUTPUT}" --overwrite
END_NS="$(date +%s)"
ELAPSED="$(( END_NS - START_NS ))"
echo "  start --detach returned in ${ELAPSED} s"

if (( ELAPSED > PROMPT_RETURN_BUDGET_SECONDS )); then
    echo "FAIL: start --detach took ${ELAPSED}s; expected <= ${PROMPT_RETURN_BUDGET_SECONDS}s" >&2
    exit 1
fi

# Cleanup hook: if anything below errors out, attempt to stop the daemon.
cleanup() {
    if [[ -f "${PID_FILE}" ]]; then
        echo "(cleanup) found leftover PID file; attempting ntakker-cli stop"
        "${BIN}" stop --stop-timeout 60 || true
    fi
    rm -f "${OUTPUT}"
}
trap cleanup EXIT

# Give the daemon a moment to write its PID file (the parent has returned;
# the grandchild is still spinning up the SCStream + AVCaptureSession).
sleep 1

if [[ ! -f "${PID_FILE}" ]]; then
    echo "FAIL: PID file was not created at ${PID_FILE}" >&2
    exit 1
fi

DAEMON_PID="$(cat "${PID_FILE}")"
if [[ -z "${DAEMON_PID}" ]]; then
    echo "FAIL: PID file at ${PID_FILE} is empty" >&2
    exit 1
fi
if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
    echo "FAIL: PID ${DAEMON_PID} from PID file is not alive" >&2
    exit 1
fi
echo "  PID file present, daemon PID ${DAEMON_PID} alive"

echo "[5/7] Letting the recording run for ${RECORD_FOR_SECONDS} s ..."
sleep "${RECORD_FOR_SECONDS}"

echo "[6/7] Stopping the recording with `ntakker-cli stop` ..."
STOP_START="$(date +%s)"
"${BIN}" stop
STOP_END="$(date +%s)"
STOP_ELAPSED="$(( STOP_END - STOP_START ))"
echo "  ntakker-cli stop returned in ${STOP_ELAPSED} s"

# After stop, the daemon must be gone and the PID file must be removed.
if kill -0 "${DAEMON_PID}" 2>/dev/null; then
    echo "FAIL: daemon PID ${DAEMON_PID} is still alive after ntakker-cli stop" >&2
    exit 1
fi
if [[ -f "${PID_FILE}" ]]; then
    echo "FAIL: PID file at ${PID_FILE} still exists after ntakker-cli stop" >&2
    exit 1
fi
echo "  daemon exited; PID file cleaned up"

echo "[7/7] Validating finalized output ..."
if [[ ! -f "${OUTPUT}" ]]; then
    echo "FAIL: expected output file at ${OUTPUT} was not created" >&2
    exit 1
fi

INFO="$(afinfo "${OUTPUT}" 2>&1)"
echo "${INFO}"
echo "${INFO}" | grep -qiE "format(:| ID:).*aac|'aac '" || { echo "FAIL: expected AAC format" >&2; exit 1; }
echo "${INFO}" | grep -qiE "estimated duration"         || { echo "FAIL: missing 'estimated duration'" >&2; exit 1; }

trap - EXIT
rm -f "${OUTPUT}"

echo "PASS: e2e-detach-stop.sh"
exit 0
