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
REF_KEYWORD=country
THREADS=${THREADS:-$(ncpu)}
LANG_CODE=${LANG_CODE:-en}
RUN_NOFA=${RUN_NOFA:-1}

# whisper-cpp does not have compiled unit tests.
if [ "$TEST_TYPE" = unit ]; then
    detail "unit | skipped for ${TOOL}"
    exit 0
fi

resolve_whisper_model() {
    local id=$1 models_dir=$2 dl=$3
    GGUF_PATH="$models_dir/ggml-$id.bin"
    if [ -f "$GGUF_PATH" ]; then
        detail "whisper | cached ${id} ($(harness_file_size "$GGUF_PATH")) @ ${GGUF_PATH}"
        return 0
    fi
    detail "whisper | download ${id} → ${models_dir}"
    # Try hf_fetch first (goes to HF cache)
    if hf_fetch "ggerganov/whisper.cpp" "ggml-${id}.bin" "ggml-${id}.bin" 2>/dev/null; then
        cp "$HF_FILE" "$GGUF_PATH" || {
            detail "whisper | hf_fetch copy failed, falling back to downloader"
            run_q "$dl" "$id" "$models_dir" || { detail "whisper | download failed: ${id}"; return 1; }
        }
    else
        # Fall back to original downloader
        if ! run_q "$dl" "$id" "$models_dir"; then
            detail "whisper | download failed: ${id}"
            return 1
        fi
    fi
    if [ -f "$GGUF_PATH" ]; then
        detail "whisper | ready ${id} ($(harness_file_size "$GGUF_PATH")) @ ${GGUF_PATH}"
        return 0
    fi
    return 1
}

run_cli() {
    local label=$1 model=$2 fa=$3 flag
    [ "$fa" = on ] && flag=-fa || flag=-nfa
    detail "run | ${label} (${fa})"
    if ! run_capture "$WHISPER_CLI" -m "$model" -f "$SAMPLE" -l "$LANG_CODE" "$flag" \
        -t "$THREADS" -nt </dev/null; then
        return 1
    fi
    printf '%s' "$RUN_OUTPUT" | tr '[:upper:]' '[:lower:]' | grep -q "$REF_KEYWORD"
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
    DL=${DL:-$MODELS_DIR/download-ggml-model.sh}
    detail "whisper | models ${MODELS_DIR}"
    [ -x "$DL" ] || die "model downloader not found: $DL"

    while IFS=$'\t' read -r name id; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Bench: ${name}"
        detail "model | ${id}"
        if ! resolve_whisper_model "$id" "$MODELS_DIR" "$DL"; then
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
    MODELS_DIR=${MODELS_DIR:-$SRC_DIR/models}
    DL=${DL:-$MODELS_DIR/download-ggml-model.sh}
    detail "whisper | sample ${SAMPLE}"
    detail "whisper | models ${MODELS_DIR}"
    [ -f "$SAMPLE" ] || die "sample not found: $SAMPLE (set SAMPLE= or clone source)"
    [ -x "$DL" ] || die "model downloader not found: $DL"

    while IFS=$'\t' read -r name id; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        local want_nofa=0
        [ "$RUN_NOFA" = 1 ] && [ "$MODEL_TIER" = full ] && want_nofa=1
        phase "Model: ${name}"
        detail "model | ${id}"
        if ! resolve_whisper_model "$id" "$MODELS_DIR" "$DL"; then
            harness_record fail "${name} (download)"
            continue
        fi
        if run_cli "$name [fa]" "$GGUF_PATH" on; then
            harness_record pass "${name} [fa]"
        else
            harness_record fail "${name} (fa)"
        fi
        if [ "$want_nofa" = 1 ]; then
            if run_cli "$name [no-fa]" "$GGUF_PATH" off; then
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
else
    run_whisper "$@"
fi
