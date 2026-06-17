#!/usr/bin/env bash
# whisper.cpp runtime validation and benchmarking.
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
WHISPER_CLI=$BIN_DIR/whisper-cli
WHISPER_BENCH=$BIN_DIR/whisper-bench
THREADS=${THREADS:-$(ncpu)}
LANG_CODE=${LANG_CODE:-en}
RUN_NOFA=${RUN_NOFA:-1}



resolve_whisper_model() {
    local id=$1
    if hf_fetch "ggerganov/whisper.cpp" "ggml-${id}.bin" "ggml-${id}.bin"; then
        GGUF_PATH=$HF_FILE
        detail "whisper | ready ${id} ($(harness_file_size "$GGUF_PATH")) @ ${GGUF_PATH}"
        return 0
    fi
    detail "whisper | download failed: ${id}"
    return 1
}

run_cli() {
    local label=$1 model=$2 fa=$3 expected=$4 flag
    [ "$fa" = on ] && flag=-fa || flag=-nfa
    detail "run | ${label} (${fa})"
    describe_test "transcribe jfk.wav (${label}, fa=${fa})" "transcript contains \"${expected}\""
    if ! run_capture "$WHISPER_CLI" -m "$model" -f "$SAMPLE" -l "$LANG_CODE" "$flag" \
        -t "$THREADS" -nt </dev/null; then
        return 1
    fi
    keywords_present "$RUN_OUTPUT" "$expected"
}

parse_whisper_bench() {
    local ms
    ms=$(printf '%s\n' "$RUN_OUTPUT" | awk '/encode time/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/) { print $i; exit }
        }
    }')
    bench_row "$1" "encode ms" "${ms:-n/a}"
}

bench_whisper() {
    local repo_ref name id
    bench_reset
    bench_preamble "$TOOL" "$RUN_BUILD"
    [ -x "$WHISPER_BENCH" ] || die "whisper-bench not found at $WHISPER_BENCH"

    if [ -n "${BIN_DIR:-}" ] && [ "${RUN_BUILD:-1}" = 0 ] && [ ! -f "${SRC_DIR:-}/samples/jfk.wav" ]; then
        SRC_DIR=$(ensure_source_tree "$TOOL" "$REF")
        export SRC_DIR
    fi

    MODELS_DIR=${MODELS_DIR:-$SRC_DIR/models}
    detail "whisper | models ${MODELS_DIR}"

    while IFS=$'\t' read -r name id; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Bench: ${name}"
        detail "model | ${id}"
        if ! resolve_whisper_model "$id"; then
            bench_warn "${name}: model download failed"
            bench_row "$name" "encode ms" "n/a"
            continue
        fi
        if ! run_capture "$WHISPER_BENCH" -m "$GGUF_PATH" -t "$THREADS" -w 0 </dev/null; then
            bench_warn "${name}: whisper-bench failed"
            bench_row "$name" "encode ms" "n/a"
            continue
        fi
        parse_whisper_bench "$name"
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    repo_ref=$(tool_source_ref "$TOOL" "$REF")
    bench_emit "$TOOL" "$repo_ref"
}

run_whisper() {
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$WHISPER_CLI" ] || die "whisper-cli not found at $WHISPER_CLI"

    # Prebuilt bins need the source tree for jfk.wav and the model downloader.
    if [ -n "${BIN_DIR:-}" ] && [ "${RUN_BUILD:-1}" = 0 ] && [ ! -f "${SRC_DIR:-}/samples/jfk.wav" ]; then
        SRC_DIR=$(ensure_source_tree "$TOOL" "$REF")
        export SRC_DIR
    fi

    SAMPLE=${SAMPLE:-$SRC_DIR/samples/jfk.wav}
    detail "whisper | sample ${SAMPLE}"
    [ -f "$SAMPLE" ] || die "sample not found: $SAMPLE (set SAMPLE= or clone source)"

    while IFS=$'\t' read -r name id expected; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        local want_nofa=0
        [ "$RUN_NOFA" = 1 ] && [ "$MODEL_TIER" = full ] && want_nofa=1
        phase "Model: ${name}"
        detail "model | ${id}"
        if ! resolve_whisper_model "$id"; then
            harness_record fail "${name} (download)"
            continue
        fi
        if run_cli "$name [fa]" "$GGUF_PATH" on "$expected"; then
            harness_record pass "${name} [fa]"
        else
            harness_record fail "${name} (fa)"
        fi
        if [ "$want_nofa" = 1 ]; then
            if run_cli "$name [no-fa]" "$GGUF_PATH" off "$expected"; then
                harness_record pass "${name} [no-fa]"
            else
                harness_record fail "${name} (no-fa)"
            fi
        fi
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    harness_summary
}

if [ "$TEST_TYPE" = performance ]; then
    bench_whisper "$@"
elif [ "$TEST_TYPE" = integration ]; then
    run_whisper "$@"
elif [ "$TEST_TYPE" = build ]; then
    run_whisper "$@"
elif [ "$TEST_TYPE" = unit ]; then
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    detail "unit | ${TOOL} compiled successfully (no unit tests configured)"
else
    detail "${TEST_TYPE} | skipped for ${TOOL}"
    exit 0
fi
