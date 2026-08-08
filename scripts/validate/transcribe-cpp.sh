#!/usr/bin/env bash
# transcribe.cpp runtime validation.
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
TRANSCRIBE_CLI=$BIN_DIR/transcribe-cli
THREADS=${THREADS:-$(ncpu)}

run_cli() {
    local label=$1 model=$2 backend=$3 expected=$4
    local args=(-m "$model" --backend "$backend" --threads "$THREADS" -q)
    local out_log err_log rc=0

    detail "run | ${label} (backend=${backend}, threads=${THREADS})"
    describe_test "transcribe jfk.wav (${label}, ${backend})" "transcript contains: ${expected}"
    out_log=$(_mktmp)
    err_log=$(_mktmp)
    echo_cmd "$TRANSCRIBE_CLI" "${args[@]}" "$SAMPLE"
    "$TRANSCRIBE_CLI" "${args[@]}" "$SAMPLE" >"$out_log" 2>"$err_log" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        [ ! -s "$err_log" ] || cat "$err_log" >&2
        return 1
    fi
    RUN_OUTPUT=$(cat "$out_log")
    # transcribe.cpp reports the effective backend as the bound ggml device
    # name (e.g. "backend: MTL0"); fail on CPU/Vulkan fallback.
    assert_metal_backend "$RUN_OUTPUT" "$label" || return 1
    keywords_present "$RUN_OUTPUT" "$expected"
}

run_transcribe() {
    local name repo file expected backend sha256
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    if [ ! -x "$TRANSCRIBE_CLI" ] && [ -x "$BUILD_DIR/bin/transcribe-cli" ]; then
        TRANSCRIBE_CLI="$BUILD_DIR/bin/transcribe-cli"
    fi
    [ -x "$TRANSCRIBE_CLI" ] || die "transcribe-cli not found at $TRANSCRIBE_CLI"

    if [ -n "${BIN_DIR:-}" ] && [ "${RUN_BUILD:-1}" = 0 ] && [ ! -f "${SRC_DIR:-}/samples/jfk.wav" ]; then
        SRC_DIR=$(ensure_source_tree "$TOOL" "$REF")
        export SRC_DIR
    fi

    SAMPLE=${SAMPLE:-$SRC_DIR/samples/jfk.wav}
    detail "transcribe-cpp | sample ${SAMPLE}"
    [ -f "$SAMPLE" ] || die "sample not found: $SAMPLE (set SAMPLE= or clone source)"

    while IFS=$'\t' read -r name repo file expected backend; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        detail "model | ${repo}/${file}"
        sha256=$(manifest_hf_sha256 "$TOOL" "$MODEL_TIER" "$repo" "$file")
        if ! hf_fetch "$repo" "$file" "$file" "$sha256"; then
            harness_record fail "${name} (download)"
            continue
        fi
        if run_cli "$name" "$HF_FILE" "$backend" "$expected"; then
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
elif [ "$TEST_TYPE" = integration ]; then
    run_transcribe "$@"
elif [ "$TEST_TYPE" = build ]; then
    run_transcribe "$@"
elif [ "$TEST_TYPE" = unit ]; then
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    detail "unit | ${TOOL} compiled successfully (no unit tests configured)"
else
    detail "${TEST_TYPE} | skipped for ${TOOL}"
fi
