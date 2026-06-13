#!/usr/bin/env bash
# scripts/build-ntakker-cli-cli.sh —
# 2026-05-09 build script for the `ntakker-cli` CLI tool.
#
# Counterpart to scripts/package-ntakker-app.sh. Where the UI script
# assembles a `.app` bundle (necessary because SFSpeechRecognizer SIGABRTs
# raw CLI binaries on macOS 26), this script handles the plain CLI:
#
#   1. Runs `swift build -c release --product ntakker-cli`.
#   2. Ad-hoc codesigns the produced binary (overridable via
#      CODESIGN_IDENTITY for shipping builds).
#   3. Prints the install recipe documented in CLAUDE.md.
#   4. Interactively asks whether to install the binary to
#      $INSTALL_PREFIX/bin/ntakker-cli (default /usr/local) and, if the user
#      agrees, performs the copy — falling back to `sudo` only when the
#      target directory isn't writable by the current user.
#
# Usage:
#   bash scripts/build-ntakker-cli-cli.sh                       # release build, prompt to install to /usr/local/bin
#   SWIFT_CONFIG=debug bash scripts/build-ntakker-cli-cli.sh    # debug build (faster iteration)
#   INSTALL_PREFIX="$HOME/.local" bash scripts/...         # prompt to install to ~/.local/bin (no sudo)
#   CODESIGN_IDENTITY="Developer ID Application: …" bash …  # sign with a real identity
#   ASSUME_NO=1 bash scripts/...                           # non-interactive: build only, never install
#
# Output:
#   .build/<config>/ntakker-cli        (the freshly built + codesigned binary)
#   $INSTALL_PREFIX/bin/ntakker-cli    (only if the user answers `y` at the prompt)
#
# Notes:
#   * Why ad-hoc codesign even for a CLI: per CLAUDE.md (R-2), every
#     `swift build` rebuild can change the binary's TCC identity and
#     re-trigger Screen Recording / Microphone prompts. Ad-hoc signing
#     gives the binary a stable code-signing identity for the duration
#     of a single build, which is the most we can do without a paid
#     Developer ID — but it does cleanly stamp the produced binary so
#     downstream `codesign -dv` checks succeed.
#   * No-prompt path: when stdin is not a TTY (CI, piped invocation)
#     the install prompt is auto-declined and the script exits 0 after
#     printing the install hint. Set ASSUME_NO=1 to force this from a
#     TTY too.
#   * The script never edits ~/.tool-agents/ntakker-cli/ — runtime config
#     stays under the user's control per the four-tier env-var chain.

set -euo pipefail

# Resolve repo root regardless of where the script was invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
cd "${REPO_ROOT}"

CONFIG="${SWIFT_CONFIG:-release}"
PRODUCT="ntakker-cli"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
INSTALL_BIN_DIR="${INSTALL_PREFIX}/bin"
INSTALL_PATH="${INSTALL_BIN_DIR}/${PRODUCT}"

echo "==> swift build -c ${CONFIG} --product ${PRODUCT}"
swift build -c "${CONFIG}" --product "${PRODUCT}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${PRODUCT}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "error: built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

# Sign. Default = ad-hoc (sufficient for a stable per-build TCC identity);
# override via env var to use a real identity for shipping builds.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> codesign --force --sign '${IDENTITY}' ${BIN_PATH}"
codesign --force --sign "${IDENTITY}" "${BIN_PATH}"

echo "==> verifying signature"
codesign -dv "${BIN_PATH}" 2>&1 | head -5

echo
echo "Built: ${BIN_PATH}"
echo
echo "Install recipe (from CLAUDE.md):"
if [[ "${INSTALL_BIN_DIR}" == "/usr/local/bin" ]]; then
  echo "  sudo cp '${BIN_PATH}' '${INSTALL_PATH}'"
else
  echo "  cp '${BIN_PATH}' '${INSTALL_PATH}'"
fi
echo "  ${PRODUCT} --help"
echo

# --- Optional install prompt -------------------------------------------------
# Auto-decline when:
#   * ASSUME_NO=1 in the environment, OR
#   * stdin is not a TTY (CI, piped, automated invocation).
if [[ "${ASSUME_NO:-0}" == "1" ]]; then
  echo "ASSUME_NO=1 set — skipping install prompt."
  exit 0
fi
if [[ ! -t 0 ]]; then
  echo "stdin is not a TTY — skipping install prompt."
  exit 0
fi

read -r -p "Install ${PRODUCT} to ${INSTALL_PATH} now? [y/N] " reply
case "${reply}" in
  [yY] | [yY][eE][sS])
    ;;
  *)
    echo "Skipped install. Run the recipe above by hand whenever you're ready."
    exit 0
    ;;
esac

mkdir -p "${INSTALL_BIN_DIR}" 2>/dev/null || true

# Decide whether sudo is needed: try to write a sentinel; fall back to sudo if
# the directory isn't writable by the current user. This handles both
# /usr/local/bin (sudo on most setups) and ~/.local/bin (no sudo) cleanly.
if [[ -w "${INSTALL_BIN_DIR}" ]] || ( [[ ! -e "${INSTALL_BIN_DIR}" ]] && mkdir -p "${INSTALL_BIN_DIR}" 2>/dev/null ); then
  echo "==> cp '${BIN_PATH}' '${INSTALL_PATH}'"
  cp "${BIN_PATH}" "${INSTALL_PATH}"
  chmod +x "${INSTALL_PATH}"
else
  echo "==> sudo cp '${BIN_PATH}' '${INSTALL_PATH}'"
  sudo mkdir -p "${INSTALL_BIN_DIR}"
  sudo cp "${BIN_PATH}" "${INSTALL_PATH}"
  sudo chmod +x "${INSTALL_PATH}"
fi

echo
echo "Installed. Verify with:"
echo "  which ${PRODUCT}"
echo "  ${PRODUCT} --version"
