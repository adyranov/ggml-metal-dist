#!/usr/bin/env bash
# CrispASR runtime validation.
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
CRISPASR_CLI=$BIN_DIR/crispasr
THREADS=${THREADS:-$(ncpu)}

if [ "$TEST_TYPE" = unit ]; then
    detail "unit | skipped for ${TOOL}"
    exit 0
fi

normalize_text() {
    tr '[:upper:]' '[:lower:]' \
        | tr -cs "[:alnum:]'" ' ' \
        | awk '{$1=$1; print}'
}

keywords_present() {
    local got=$1 expected=$2 word
    got=$(printf '%s' "$got" | normalize_text)
    for word in $expected; do
        case " $got " in
            *" $word "*) ;;
            *) return 1 ;;
        esac
    done
}

run_cli() {
    local label=$1 model=$2 backend=$3 expected=$4
    local args=(-m "$model" -f "$SAMPLE" -nt -t "$THREADS")
    [ -z "$backend" ] || args=(--backend "$backend" "${args[@]}")
    case "$backend" in
        cohere) args+=(-sl en) ;;
        qwen3) args+=(-tp 0) ;;
        *) ;;
    esac

    detail "run | ${label} (${backend:-auto}, threads=${THREADS})"
    local out_log err_log rc=0
    out_log=$(_mktmp)
    err_log=$(_mktmp)
    "$CRISPASR_CLI" "${args[@]}" >"$out_log" 2>"$err_log" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        [ ! -s "$err_log" ] || cat "$err_log" >&2
        return 1
    fi
    RUN_OUTPUT=$(cat "$out_log")
    keywords_present "$RUN_OUTPUT" "$expected"
}

run_crispasr() {
    local name repo file expected backend
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    if [ ! -x "$CRISPASR_CLI" ] && [ -x "$BUILD_DIR/bin/crispasr" ]; then
        CRISPASR_CLI="$BUILD_DIR/bin/crispasr"
    fi
    [ -x "$CRISPASR_CLI" ] || die "crispasr not found at $CRISPASR_CLI"

    if [ -n "${BIN_DIR:-}" ] && [ "${RUN_BUILD:-1}" = 0 ] && [ ! -f "${SRC_DIR:-}/samples/jfk.wav" ]; then
        SRC_DIR=$(ensure_source_tree "$TOOL" "$REF")
        export SRC_DIR
    fi

    SAMPLE=${SAMPLE:-$SRC_DIR/samples/jfk.wav}
    detail "crispasr | sample ${SAMPLE}"
    [ -f "$SAMPLE" ] || die "sample not found: $SAMPLE (set SAMPLE= or clone source)"

    while IFS=$'\t' read -r name repo file expected backend; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        detail "model | ${repo}/${file}"
        if ! hf_fetch "$repo" "$file"; then
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
else
    run_crispasr "$@"
fi
