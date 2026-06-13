#!/usr/bin/env bash
# test_scripts/e2e-transcription-soniox.sh — plan-006 Phase 10
#
# Real-key end-to-end validation script for the Soniox streaming
# transcription provider. Executes three back-to-back recordings
# (Greek, English, bilingual) with --transcribe soniox, then inspects
# the produced *.transcript.jsonl sidecars to verify the acceptance
# criteria AC-SX-1..AC-SX-4 from
# `docs/design/refined-request-soniox-streaming.md`.
#
# REQUIRES:
#   * A real `SONIOX_API_KEY` exported in the shell. Sign up at
#     https://console.soniox.com to obtain one. The script exits 1 with
#     a helpful message if the key is unset.
#   * `jq` for JSONL parsing. Install with `brew install jq`.
#   * The release `ntakker-cli` binary at `.build/release/ntakker-cli`. If it is
#     missing the script will offer to build it for you.
#   * macOS 14.0+ with Screen Recording AND Microphone TCC granted to
#     the `.build/release/ntakker-cli` binary (the script invokes recording
#     with --layout mixed, which captures both system audio and mic).
#
# USAGE:
#   export SONIOX_API_KEY="sk-soniox-..."
#   bash test_scripts/e2e-transcription-soniox.sh
#
# The script runs three ~12-second recordings using `say` + `afplay`
# fixtures (mirroring the established pattern from
# e2e-transcription-gemini.sh and e2e-transcription-apple.sh):
#
#   1. Greek    - validates AC-SX-2 (>= 5 Greek keyword hits, first
#                 matched segment language starts with `el`).
#   2. English  - validates AC-SX-3 (>= 5 English keyword hits, first
#                 matched segment language starts with `en`).
#   3. Bilingual- validates AC-SX-4 (sidecar contains >= 1 segment
#                 tagged `el` AND >= 1 tagged `en`).
#   AC-SX-1 (>= 2 segments + model:"soniox") is verified on every run.
#
# This script does NOT use SIGINT-based stop; it relies on
# --max-duration to terminate ntakker-cli cleanly so the sidecar finalizes
# normally (parity with the other e2e-transcription-* scripts). If you
# want to test the SIGINT stop path, use e2e-sigint-finalize.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.build/release/ntakker-cli"

echo "================================================================"
echo " Soniox e2e validation script (plan-006 Phase 10)"
echo " Verifies: AC-SX-1, AC-SX-2, AC-SX-3, AC-SX-4"
echo " Requires: SONIOX_API_KEY, jq, .build/release/ntakker-cli, TCC perms"
echo "================================================================"

# --- Pre-flight checks ----------------------------------------------------

if [ -z "${SONIOX_API_KEY:-}" ]; then
    echo "FAIL: SONIOX_API_KEY is not set." >&2
    echo "" >&2
    echo "Sign up at https://console.soniox.com and export the key:" >&2
    echo "  export SONIOX_API_KEY=\"sk-soniox-...\"" >&2
    echo "" >&2
    echo "Or place it in ~/.tool-agents/ntakker-cli/.env or ./.env (lower-priority tiers)." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: 'jq' is not installed; install with 'brew install jq'." >&2
    exit 1
fi

if [ ! -x "${BIN}" ]; then
    echo "FAIL: release binary not found at ${BIN}" >&2
    echo "Hint: run 'swift build -c release --product ntakker-cli' first." >&2
    exit 1
fi

OUTDIR="${ROOT}/test_output"
mkdir -p "${OUTDIR}"

GREEK_OUT="${OUTDIR}/soniox-greek.m4a"
ENGLISH_OUT="${OUTDIR}/soniox-english.m4a"
BILINGUAL_OUT="${OUTDIR}/soniox-bilingual.m4a"

# --- Fixture generation (cached) -----------------------------------------

FIXTURE_DIR="${ROOT}/test_scripts/fixtures"
mkdir -p "${FIXTURE_DIR}"

# Greek phrase per AC-SX-2 keyword set in refined-request §AC-SX-2.
GREEK_PHRASE="Καλημέρα, σήμερα είναι μια όμορφη μέρα. Δοκιμάζω την υπηρεσία αναγνώρισης ομιλίας Soniox."
GREEK_FIXTURE="${FIXTURE_DIR}/soniox-greek.aiff"
if [ ! -f "${GREEK_FIXTURE}" ]; then
    echo "[setup] Generating Greek fixture phrase via 'say' (voice: Anna) ..."
    say -v Anna "${GREEK_PHRASE}" -o "${GREEK_FIXTURE}" 2>/dev/null \
        || say "${GREEK_PHRASE}" -o "${GREEK_FIXTURE}"
fi

# English phrase per AC-SX-3 keyword set in refined-request §AC-SX-3.
ENGLISH_PHRASE="Good morning, today is a beautiful day. I am testing the Soniox speech recognition service."
ENGLISH_FIXTURE="${FIXTURE_DIR}/soniox-english.aiff"
if [ ! -f "${ENGLISH_FIXTURE}" ]; then
    echo "[setup] Generating English fixture phrase via 'say' (voice: Samantha) ..."
    say -v Samantha "${ENGLISH_PHRASE}" -o "${ENGLISH_FIXTURE}" 2>/dev/null \
        || say "${ENGLISH_PHRASE}" -o "${ENGLISH_FIXTURE}"
fi

# Bilingual fixture per AC-SX-4: alternating Greek + English sentences.
BILINGUAL_FIXTURE="${FIXTURE_DIR}/soniox-bilingual.aiff"
if [ ! -f "${BILINGUAL_FIXTURE}" ]; then
    echo "[setup] Generating bilingual (Greek + English) fixture ..."
    TMP_EL=$(mktemp -t soniox-bil-el.XXXXXX).aiff
    TMP_EN=$(mktemp -t soniox-bil-en.XXXXXX).aiff
    say -v Anna "Καλημέρα, σήμερα είναι όμορφη μέρα." -o "${TMP_EL}" 2>/dev/null \
        || say "Καλημέρα" -o "${TMP_EL}"
    say -v Samantha "Good morning, today is beautiful." -o "${TMP_EN}" 2>/dev/null \
        || say "Good morning" -o "${TMP_EN}"
    cat "${TMP_EL}" "${TMP_EN}" > "${BILINGUAL_FIXTURE}" || cp "${TMP_EL}" "${BILINGUAL_FIXTURE}"
    rm -f "${TMP_EL}" "${TMP_EN}"
fi

# --- Helpers --------------------------------------------------------------

run_recording() {
    local label="$1"
    local language="$2"
    local out="$3"
    local fixture="$4"
    local duration="${5:-12}"

    echo ""
    echo "----- ${label} (${duration}s, --transcribe soniox --transcribe-language ${language}) -----"
    rm -f "${out}" "${out%.m4a}.transcript.jsonl"

    "${BIN}" start \
        --output "${out}" \
        --format m4a \
        --layout mixed \
        --max-duration "${duration}" \
        --transcribe soniox \
        --transcribe-language "${language}" \
        --transcribe-source mixed \
        --transcribe-format jsonl &
    local pid=$!

    # SCKit warm-up (empirically 1.5s suffices, per Phase J.8 of plan-004).
    sleep 1.5
    afplay "${fixture}" || echo "[warn] afplay returned non-zero for ${fixture}" >&2

    # Wait for ntakker-cli to finish at --max-duration.
    wait "${pid}" || {
        echo "FAIL: ntakker-cli exited non-zero for ${label}" >&2
        return 1
    }
}

assert_sidecar_ac_sx_1() {
    # AC-SX-1: sidecar exists with >= 2 segments AND at least one line
    # whose `model` field equals `"soniox"`.
    local out="$1"
    local label="$2"
    local sidecar="${out%.m4a}.transcript.jsonl"

    if [ ! -s "${sidecar}" ]; then
        echo "FAIL [${label}/AC-SX-1]: sidecar missing or empty at ${sidecar}" >&2
        return 1
    fi
    local n_lines
    n_lines=$(grep -v '_tombstone' "${sidecar}" | grep -cv '^[[:space:]]*$' || true)
    n_lines=$(echo "${n_lines}" | tr -d ' ')
    if [ "${n_lines}" -lt 2 ]; then
        echo "FAIL [${label}/AC-SX-1]: only ${n_lines} non-tombstone lines (need >= 2)" >&2
        echo "--- sidecar contents ---" >&2
        cat "${sidecar}" >&2
        return 1
    fi
    local soniox_lines
    soniox_lines=$(grep -c '"model":"soniox"' "${sidecar}" || true)
    if [ "${soniox_lines}" -lt 1 ]; then
        echo "FAIL [${label}/AC-SX-1]: zero lines with model:\"soniox\"" >&2
        cat "${sidecar}" >&2
        return 1
    fi
    echo "PASS [${label}/AC-SX-1]: ${n_lines} segments, ${soniox_lines} model:soniox lines"
}

count_keyword_hits() {
    local sidecar="$1"
    shift
    local hits=0
    local text
    text=$(jq -r 'select(._tombstone != true) | .text // empty' "${sidecar}" 2>/dev/null \
           | tr '[:upper:]' '[:lower:]')
    for w in "$@"; do
        local lw
        lw=$(echo "${w}" | tr '[:upper:]' '[:lower:]')
        if grep -qF "${lw}" <<<"${text}"; then
            hits=$((hits + 1))
        fi
    done
    echo "${hits}"
}

first_language_starts_with() {
    local sidecar="$1"
    local prefix="$2"
    local first_lang
    first_lang=$(jq -r 'select(._tombstone != true) | .language // empty' "${sidecar}" \
                 | grep -v '^$' | head -1)
    if [[ "${first_lang}" == ${prefix}* ]]; then
        return 0
    fi
    echo "[detail] first language tag = '${first_lang}', expected prefix '${prefix}'"
    return 1
}

# --- Run #1: Greek (AC-SX-2) ---------------------------------------------

GREEK_PASS=0
ENGLISH_PASS=0
BILINGUAL_PASS=0

if run_recording "Greek" "el" "${GREEK_OUT}" "${GREEK_FIXTURE}"; then
    if assert_sidecar_ac_sx_1 "${GREEK_OUT}" "Greek"; then
        SIDECAR="${GREEK_OUT%.m4a}.transcript.jsonl"
        HITS=$(count_keyword_hits "${SIDECAR}" Καλημέρα σήμερα όμορφη μέρα δοκιμάζω υπηρεσία αναγνώρισης ομιλίας Soniox)
        if [ "${HITS}" -ge 5 ]; then
            if first_language_starts_with "${SIDECAR}" "el"; then
                echo "PASS [Greek/AC-SX-2]: ${HITS}/9 Greek keyword hits, first language starts with el"
                GREEK_PASS=1
            else
                echo "FAIL [Greek/AC-SX-2]: keyword hits OK (${HITS}/9) but first segment language is not 'el*'"
            fi
        else
            echo "FAIL [Greek/AC-SX-2]: only ${HITS}/9 keyword hits (need >= 5)"
            jq -r '.text // empty' "${SIDECAR}"
        fi
    fi
fi

# --- Run #2: English (AC-SX-3) -------------------------------------------

if run_recording "English" "en" "${ENGLISH_OUT}" "${ENGLISH_FIXTURE}"; then
    if assert_sidecar_ac_sx_1 "${ENGLISH_OUT}" "English"; then
        SIDECAR="${ENGLISH_OUT%.m4a}.transcript.jsonl"
        HITS=$(count_keyword_hits "${SIDECAR}" morning today beautiful day testing Soniox speech recognition service)
        if [ "${HITS}" -ge 5 ]; then
            if first_language_starts_with "${SIDECAR}" "en"; then
                echo "PASS [English/AC-SX-3]: ${HITS}/9 English keyword hits, first language starts with en"
                ENGLISH_PASS=1
            else
                echo "FAIL [English/AC-SX-3]: keyword hits OK (${HITS}/9) but first segment language is not 'en*'"
            fi
        else
            echo "FAIL [English/AC-SX-3]: only ${HITS}/9 keyword hits (need >= 5)"
            jq -r '.text // empty' "${SIDECAR}"
        fi
    fi
fi

# --- Run #3: Bilingual (AC-SX-4) -----------------------------------------

if run_recording "Bilingual" "el,en" "${BILINGUAL_OUT}" "${BILINGUAL_FIXTURE}" 15; then
    if assert_sidecar_ac_sx_1 "${BILINGUAL_OUT}" "Bilingual"; then
        SIDECAR="${BILINGUAL_OUT%.m4a}.transcript.jsonl"
        EL_LINES=$(jq -r 'select(._tombstone != true) | .language // empty' "${SIDECAR}" \
                   | grep -c '^el' || true)
        EN_LINES=$(jq -r 'select(._tombstone != true) | .language // empty' "${SIDECAR}" \
                   | grep -c '^en' || true)
        echo "[Bilingual] el-tagged: ${EL_LINES}, en-tagged: ${EN_LINES}"
        if [ "${EL_LINES}" -ge 1 ] && [ "${EN_LINES}" -ge 1 ]; then
            echo "PASS [Bilingual/AC-SX-4]: >= 1 el-tagged AND >= 1 en-tagged segment"
            BILINGUAL_PASS=1
        else
            echo "FAIL [Bilingual/AC-SX-4]: need >= 1 el AND >= 1 en, got el=${EL_LINES} en=${EN_LINES}"
            cat "${SIDECAR}"
        fi
    fi
fi

# --- Summary --------------------------------------------------------------

echo ""
echo "================================================================"
echo " Soniox e2e summary"
echo "================================================================"
[ "${GREEK_PASS}" -eq 1 ]     && echo "  AC-SX-1 (Greek run sidecar)      : PASS" || echo "  AC-SX-1 (Greek run sidecar)      : FAIL"
[ "${ENGLISH_PASS}" -eq 1 ]   && echo "  AC-SX-1 (English run sidecar)    : PASS" || echo "  AC-SX-1 (English run sidecar)    : FAIL"
[ "${BILINGUAL_PASS}" -eq 1 ] && echo "  AC-SX-1 (Bilingual run sidecar)  : PASS" || echo "  AC-SX-1 (Bilingual run sidecar)  : FAIL"
[ "${GREEK_PASS}" -eq 1 ]     && echo "  AC-SX-2 (Greek recognition)      : PASS" || echo "  AC-SX-2 (Greek recognition)      : FAIL"
[ "${ENGLISH_PASS}" -eq 1 ]   && echo "  AC-SX-3 (English recognition)    : PASS" || echo "  AC-SX-3 (English recognition)    : FAIL"
[ "${BILINGUAL_PASS}" -eq 1 ] && echo "  AC-SX-4 (Bilingual recognition)  : PASS" || echo "  AC-SX-4 (Bilingual recognition)  : FAIL"
echo ""
echo "Outputs preserved at:"
echo "  ${GREEK_OUT}"
echo "  ${ENGLISH_OUT}"
echo "  ${BILINGUAL_OUT}"
echo "(plus matching .transcript.jsonl sidecars)"

if [ "${GREEK_PASS}" -eq 1 ] && [ "${ENGLISH_PASS}" -eq 1 ] && [ "${BILINGUAL_PASS}" -eq 1 ]; then
    echo ""
    echo "OVERALL: PASS (AC-SX-1..AC-SX-4 all green)"
    exit 0
fi

echo ""
echo "OVERALL: FAIL (one or more acceptance criteria did not pass)"
exit 1
