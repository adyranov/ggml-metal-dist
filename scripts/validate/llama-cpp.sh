#!/usr/bin/env bash
# llama.cpp runtime validation and benchmarking.
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
LLAMA_COMPLETION=$BIN_DIR/llama-completion
LLAMA_BENCH=$BIN_DIR/llama-bench

NGL=${NGL:-999}
FA=${FA:-on}
THREADS=${THREADS:-$(ncpu)}
RUN_JINJA=${RUN_JINJA:-1}

if [ "$MODEL_TIER" = smoke ]; then
    CTX=${CTX:-512}
else
    CTX=${CTX:-4096}
fi

run_cli() {
    local label=$1 gguf=$2 np=$3 prompt=$4 expect=$5 ctx=$6 mode=$7
    shift 7
    local common=(--no-warmup)
    [ "$HARNESS_VERBOSE" != 1 ] && common+=(--log-file /dev/null)
    if [ "$mode" = chat ]; then
        set -- "$LLAMA_COMPLETION" -m "$gguf" -ngl "$NGL" -c "$ctx" -n "$np" \
            -fa "$FA" -t "$THREADS" "${common[@]}" \
            --jinja -cnv -st -p "$prompt" "$@"
    else
        set -- "$LLAMA_COMPLETION" -m "$gguf" -ngl "$NGL" -c "$ctx" -n "$np" \
            -fa "$FA" -t "$THREADS" "${common[@]}" \
            -no-cnv -p "$prompt" "$@"
    fi
    detail "run | ${label} (${mode}, n=${np}, ctx=${ctx})"
    if [ -n "$expect" ]; then
        describe_test "${label} ${mode} completion (n=${np}, ctx=${ctx})" "output contains \"${expect}\""
    else
        describe_test "${label} ${mode} completion (n=${np}, ctx=${ctx})" "non-empty completion, exit 0"
    fi
    if ! run_capture "$@" </dev/null; then
        return 1
    fi
    if [ -n "$expect" ]; then
        keywords_present "$RUN_OUTPUT" "$expect" || return 1
    fi
    return 0
}

stage_model() {
    local label=$1 repo=$2 pat=$3 ctx=$4 np=$5 prompt=$6 expect=$7
    shift 7
    phase "Model: ${label}"
    detail "model | ${repo}"
    if ! resolve_hf_gguf "$repo" "$pat"; then
        harness_record fail "${label} (download)"
        return 0
    fi
    local gguf=$GGUF_PATH
    if [ "$MODEL_TIER" = smoke ]; then
        if run_cli "$label [chat]" "$gguf" "$np" "$prompt" "$expect" "$ctx" chat "$@"; then
            harness_record pass "${label} [chat]"
        else
            harness_record fail "${label} (chat)"
        fi
    elif run_cli "$label [raw]" "$gguf" "$np" "$prompt" "$expect" "$ctx" raw "$@"; then
        harness_record pass "${label} [raw]"
    else
        harness_record fail "${label} (raw)"
    fi
    if [ "$RUN_JINJA" = 1 ] && [ "$MODEL_TIER" = full ]; then
        if run_cli "$label [chat]" "$gguf" "$np" "$prompt" "$expect" "$ctx" chat "$@"; then
            harness_record pass "${label} [chat]"
        else
            harness_record fail "${label} (chat)"
        fi
    fi
}

parse_llama_bench_md() {
    local pp512="" tg128=""
    while IFS='|' read -r _ _ _ _ _ test val _; do
        test=${test#"${test%%[![:space:]]*}"}
        test=${test%"${test##*[![:space:]]}"}
        val=${val#"${val%%[![:space:]]*}"}
        val=${val%"${val##*[![:space:]]}"}
        # shellcheck disable=SC2249
        case "$test" in
            pp512) pp512=$val ;;
            tg128) tg128=$val ;;
        esac
    done <<< "$RUN_OUTPUT"
    bench_row "$1" "pp512 t/s" "${pp512:-n/a}"
    bench_row "$1" "tg128 t/s" "${tg128:-n/a}"
}

bench_llama() {
    local repo_ref label repo pat kind samplers
    bench_reset
    bench_preamble "$TOOL" "$RUN_BUILD"
    [ -x "$LLAMA_BENCH" ] || die "llama-bench not found at $LLAMA_BENCH"

    while IFS=$'\t' read -r label repo pat samplers ctx np prompt expect; do
        [ -n "$label" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$label" ] || continue
        phase "Bench: ${label}"
        detail "model | ${repo}"
        if ! resolve_hf_gguf "$repo" "$pat"; then
            bench_warn "${label}: model download failed"
            bench_row "$label" "pp512 t/s" "n/a"
            bench_row "$label" "tg128 t/s" "n/a"
            continue
        fi
        if ! run_capture "$LLAMA_BENCH" -m "$GGUF_PATH" -ngl "$NGL" -fa "$FA" \
            -p 512 -n 128 -r 1 -o md </dev/null; then
            bench_warn "${label}: llama-bench failed"
            bench_row "$label" "pp512 t/s" "n/a"
            bench_row "$label" "tg128 t/s" "n/a"
            continue
        fi
        parse_llama_bench_md "$label"
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    repo_ref=$(tool_source_ref "$TOOL" "$REF")
    bench_emit "$TOOL" "$repo_ref"
}

run_llama() {
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$LLAMA_COMPLETION" ] || die "llama-completion not found at $LLAMA_COMPLETION"

    while IFS=$'\t' read -r label repo pat samplers ctx np prompt expect; do
        [ -n "$label" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$label" ] || continue
        # shellcheck disable=SC2086
        stage_model "$label" "$repo" "$pat" "$ctx" "$np" "$prompt" "$expect" $samplers
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    harness_summary
}

if [ "$TEST_TYPE" = performance ]; then
    bench_llama "$@"
elif [ "$TEST_TYPE" = integration ]; then
    run_llama "$@"
elif [ "$TEST_TYPE" = build ]; then
    run_llama "$@"
elif [ "$TEST_TYPE" = unit ]; then
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    detail "unit | ${TOOL} compiled successfully (no unit tests configured)"
else
    detail "${TEST_TYPE} | skipped for ${TOOL}"
    exit 0
fi
