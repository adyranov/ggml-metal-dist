#!/usr/bin/env bash
# stable-diffusion.cpp runtime validation and benchmarking.
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
SD_CLI=$BIN_DIR/sd-cli
OUT_DIR=${OUT_DIR:-$DIST_ROOT/scripts/validate/out}
THREADS=${THREADS:-$(ncpu)}
NEGATIVE=${NEGATIVE:-"blurry, low quality, deformed, watermark"}

# Clean generated images when work dir was just wiped (--clean).
if [ ! -d "$(tool_work_dir "$TOOL")" ] && [ -d "$OUT_DIR" ]; then
    detail "clean | removing $OUT_DIR"
    rm -rf "$OUT_DIR"
fi

# stable-diffusion-cpp does not have compiled unit tests.

QUANT=${QUANT:-Q8_0}

resolve_file_tpl() {
    printf '%s' "$1" | sed "s/{quant}/$QUANT/g"
}

family_args() {
    local name=$1 flag repo file args=()
    while IFS=$'\t' read -r flag repo file; do
        [ -n "$flag" ] || continue
        if ! hf_fetch "$repo" "$file"; then
            return 1
        fi
        args+=( "--${flag}" "$HF_FILE" )
    done < <(manifest_model_encoders "$TOOL" "$MODEL_TIER" "$name")
    # shellcheck disable=SC2145
    printf '%s' "${args[*]:-}"
}

parse_sd_sampling_s() {
    local parsed wall=$1
    parsed=$(printf '%s\n' "$RUN_OUTPUT" | awk '
        /sampling|sample time|generation time/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+(\.[0-9]+)?s,?$/ || $i ~ /^[0-9]+(\.[0-9]+)?$/) {
                    gsub(/s/, "", $i)
                    gsub(/,$/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ')
    if [ -n "$parsed" ]; then
        printf '%s' "$parsed"
    else
        printf '%s' "$wall"
    fi
}

bench_sd() {
    local repo_ref name family repo file_tpl steps cfg neg prompt width height min_bytes file diff_path extra out
    local args=() start wall elapsed
    bench_reset
    bench_preamble "$TOOL" "$RUN_BUILD"
    [ -x "$SD_CLI" ] || die "sd-cli not found at $SD_CLI"
    mkdir -p "$OUT_DIR"

    while IFS=$'\t' read -r name family repo file_tpl steps cfg neg prompt width height min_bytes; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Bench: ${name}"
        file=$(resolve_file_tpl "$file_tpl")
        detail "model | ${family}, ${file}, ${width}x${height}, steps=${steps}"
        if ! hf_fetch "$repo" "$file"; then
            bench_warn "${name}: diffusion download failed"
            bench_row "$name" "s/image" "n/a"
            continue
        fi
        diff_path=$HF_FILE
        detail "sd | fetch encoders (${family})"
        if ! extra=$(family_args "$name"); then
            bench_warn "${name}: encoder download failed"
            bench_row "$name" "s/image" "n/a"
            continue
        fi
        out="$OUT_DIR/$name-bench.png"
        rm -f "$out"
        args=()
        if [ -z "$extra" ]; then
            args+=(--model "$diff_path")
        else
            args+=(--diffusion-model "$diff_path")
        fi
        # shellcheck disable=SC2206
        args+=( $extra -p "$prompt" -W "$width" -H "$height" )
        [ "$neg" = 1 ] && args+=( -n "$NEGATIVE" )
        args+=( --cfg-scale "$cfg" --steps "$steps" )
        args+=( --offload-to-cpu --diffusion-fa --vae-tiling --clip-on-cpu -t "$THREADS" --seed 42 -o "$out" -v )
        detail "run | benchmark → ${out}"
        start=$SECONDS
        if ! run_capture "$SD_CLI" "${args[@]}" </dev/null; then
            bench_warn "${name}: sd-cli benchmark run failed"
            bench_row "$name" "s/image" "n/a"
            continue
        fi
        if ! assert_png "$out" "$width" "$height" "$min_bytes"; then
            bench_warn "${name}: output image check failed"
            bench_row "$name" "s/image" "n/a"
            continue
        fi
        wall=$((SECONDS - start))
        elapsed=$(parse_sd_sampling_s "$wall")
        bench_row "$name" "s/image" "$elapsed"
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    repo_ref=$(tool_source_ref "$TOOL" "$REF")
    bench_emit "$TOOL" "$repo_ref"
}

run_sd() {
    local name=$1 family=$2 steps=$3 cfg=$4 neg=$5 prompt=$6 w=$7 h=$8 min_bytes=$9
    shift 9
    local out_png log rc=0
    out_png="$ARTIFACTS_DIR/${name}.png"
    log=$(_mktmp)

    describe_test "txt2img ${family} (${w}x${h}, ${steps} steps)" "valid PNG, > ${min_bytes}B"
    detail "run | ${name} (family=${family})"

    local args=()
    if [ $# -eq 0 ]; then
        args+=(--model "$GGUF_PATH")
    else
        args+=(--diffusion-model "$GGUF_PATH")
    fi
    args+=(-p "$prompt" -W "$w" -H "$h"
        --steps "$steps" --cfg-scale "$cfg" -o "$out_png" -v
        --offload-to-cpu --diffusion-fa --vae-tiling --clip-on-cpu -t "$THREADS" --seed 42 "$@")
    [ "$neg" = 1 ] && args+=( -n "$NEGATIVE" )

    if run_q "$SD_CLI" "${args[@]}" >"$log" 2>&1 && assert_png "$out_png" "$w" "$h" "$min_bytes"; then
        detail "run | ok $(basename "$out_png") ($(harness_file_size "$out_png"))"
        harness_record pass "${name}"
    else
        harness_record fail "${name} (generate)"
    fi
}

run_all() {
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$SD_CLI" ] || die "sd-cli not found at $SD_CLI"
    mkdir -p "$ARTIFACTS_DIR"

    while IFS=$'\t' read -r name family repo tpl steps cfg neg prompt width height min_bytes; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        local file
        file=$(resolve_file_tpl "$tpl")
        detail "model | ${repo}/${file}"
        if ! hf_fetch "$repo" "$file"; then
            harness_record fail "${name} (download)"
            continue
        fi
        GGUF_PATH=$HF_FILE
        local run_args=""
        if ! run_args=$(family_args "$name"); then
            harness_record fail "${name} (encoders)"
            continue
        fi
        # shellcheck disable=SC2086
        run_sd "$name" "$family" "$steps" "$cfg" "$neg" "$prompt" "$width" "$height" "$min_bytes" $run_args
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    harness_summary
}

if [ "$TEST_TYPE" = performance ]; then
    bench_sd "$@"
elif [ "$TEST_TYPE" = integration ]; then
    run_all "$@"
elif [ "$TEST_TYPE" = build ]; then
    run_all "$@"
elif [ "$TEST_TYPE" = unit ]; then
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    detail "unit | ${TOOL} compiled successfully (no unit tests configured)"
else
    detail "${TEST_TYPE} | skipped for ${TOOL}"
fi
