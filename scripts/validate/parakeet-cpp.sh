#!/usr/bin/env bash
# parakeet.cpp runtime validation.
set -euo pipefail

TEST_TYPE=build
MODEL_TIER=smoke
TARGET_MODEL=
REF=
RUN_BUILD=1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"
parse_validate_cli "$@"

TOOL=$(basename "$0" .sh)
PARAKEET_CLI=$BIN_DIR/parakeet-cli
THREADS=${THREADS:-$(ncpu)}

# parakeet-cpp model-independent ctests are not built in the release profile yet.
if [ "$TEST_TYPE" = unit ]; then
    detail "unit | skipped for ${TOOL}"
    exit 0
fi

normalize_text() {
    tr '[:upper:]' '[:lower:]' \
        | tr -cs "[:alnum:]'" ' ' \
        | awk '{$1=$1; print}'
}

run_cli() {
    local label=$1 model=$2 decoder=$3 expected=$4
    local args=(transcribe --model "$model" --input "$SAMPLE" --threads "$THREADS")
    [ -z "$decoder" ] || args+=(--decoder "$decoder")

    detail "run | ${label} (${decoder:-default}, threads=${THREADS})"
    # Capture stdout for comparison; keep stderr separate for diagnostics.
    local out_log err_log rc=0
    out_log=$(_mktmp)
    err_log=$(_mktmp)
    "$PARAKEET_CLI" "${args[@]}" >"$out_log" 2>"$err_log" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        [ ! -s "$err_log" ] || cat "$err_log" >&2
        return 1
    fi
    RUN_OUTPUT=$(cat "$out_log")

    local got_norm expected_norm
    got_norm=$(printf '%s' "$RUN_OUTPUT" | normalize_text)
    expected_norm=$(printf '%s' "$expected" | normalize_text)
    [ -n "$expected_norm" ] || die "missing expected transcript for ${label}"
    [ "$got_norm" = "$expected_norm" ]
}

run_parakeet() {
    local name repo file decoder expected
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    if [ ! -x "$PARAKEET_CLI" ] && [ -x "$BUILD_DIR/examples/cli/bin/parakeet-cli" ]; then
        PARAKEET_CLI="$BUILD_DIR/examples/cli/bin/parakeet-cli"
    elif [ ! -x "$PARAKEET_CLI" ] && [ -x "$BUILD_DIR/examples/cli/parakeet-cli" ]; then
        PARAKEET_CLI="$BUILD_DIR/examples/cli/parakeet-cli"
    fi
    [ -x "$PARAKEET_CLI" ] || die "parakeet-cli not found at $PARAKEET_CLI"

    # Prebuilt bins need the source tree for the committed speech fixture.
    if [ -n "${BIN_DIR:-}" ] && [ "${RUN_BUILD:-1}" = 0 ] && [ ! -f "${SRC_DIR:-}/tests/fixtures/speech.wav" ]; then
        SRC_DIR=$(ensure_source_tree "$TOOL" "$REF")
        export SRC_DIR
    fi

    SAMPLE=${SAMPLE:-$SRC_DIR/tests/fixtures/speech.wav}
    detail "parakeet | sample ${SAMPLE}"
    [ -f "$SAMPLE" ] || die "sample not found: $SAMPLE (set SAMPLE= or clone source)"

    while IFS=$'\t' read -r name repo file decoder expected; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        detail "model | ${repo}/${file}"
        if ! hf_fetch "$repo" "$file"; then
            harness_record fail "${name} (download)"
            continue
        fi
        if run_capture "$PARAKEET_CLI" info "$HF_FILE" </dev/null; then
            detail "info | ok ${name} ($(harness_file_size "$HF_FILE"))"
        else
            harness_record fail "${name} (info)"
            continue
        fi
        if run_cli "$name" "$HF_FILE" "$decoder" "$expected"; then
            harness_record pass "${name}"
        else
            harness_record fail "${name} (transcribe)"
        fi
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    harness_summary
}

if [ "$TEST_TYPE" = performance ]; then
    detail "performance | skipped for ${TOOL} (no stable parser yet)"
    exit 0
else
    run_parakeet "$@"
fi
