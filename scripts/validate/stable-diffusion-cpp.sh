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
if [ "$TEST_TYPE" = unit ]; then
    detail "unit | skipped for ${TOOL}"
    exit 0
fi

# Per-tier defaults. Smoke is lighter: smaller image and a trivial prompt; the
# encoder quant (LLM_QUANT, used by family_args) is also smaller. QUANT feeds
# {quant} in the manifest file_tpl and is resolved in run_sd.
if [ "$MODEL_TIER" = smoke ]; then
    MIN_PNG_BYTES=${MIN_PNG_BYTES:-5000}
    PROMPT=${PROMPT:-"a cat"}
    W=${WIDTH:-512}
    H=${HEIGHT:-512}
else
    MIN_PNG_BYTES=${MIN_PNG_BYTES:-10000}
    PROMPT=${PROMPT:-"A cinematic photograph of an astronaut in a neon Tokyo ramen bar at night."}
    W=${WIDTH:-1024}
    H=${HEIGHT:-1024}
fi
QUANT=${QUANT:-Q8_0}

resolve_file_tpl() {
    printf '%s' "$1" | sed "s/{quant}/$QUANT/g"
}

family_args() {
    local llm_quant
    if [ "$MODEL_TIER" = smoke ]; then
        llm_quant=${LLM_QUANT:-Q4_0}
    else
        llm_quant=${LLM_QUANT:-Q8_0}
    fi
    case "$1" in
        sdxs) printf '' ;;
        zimg)
            hf_fetch Comfy-Org/z_image_turbo "split_files/vae/*.safetensors" || return 1
            local vae=$HF_FILE
            hf_fetch unsloth/Qwen3-4B-Instruct-2507-GGUF "Qwen3-4B-Instruct-2507-${llm_quant}.gguf" || return 1
            printf -- '--vae %s --llm %s' "$vae" "$HF_FILE" ;;
        flux)
            hf_fetch "$2" "ae.safetensors" || return 1
            local vae=$HF_FILE
            hf_fetch "$2" "clip_l.safetensors" || return 1
            local clip=$HF_FILE
            hf_fetch "$2" "t5xxl-Q8_0.gguf" || return 1
            printf -- '--vae %s --clip_l %s --t5xxl %s' "$vae" "$clip" "$HF_FILE" ;;
        *) return 1 ;;
    esac
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
    local repo_ref name family repo file_tpl steps cfg neg file diff_path extra out
    local args=() start wall elapsed
    bench_reset
    bench_preamble "$TOOL" "$RUN_BUILD"
    [ -x "$SD_CLI" ] || die "sd-cli not found at $SD_CLI"
    mkdir -p "$OUT_DIR"

    COMMON_ARGS="--offload-to-cpu --diffusion-fa --vae-tiling --clip-on-cpu -W $W -H $H -t $THREADS --seed 42"

    while IFS=$'\t' read -r name family repo file_tpl steps cfg neg; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Bench: ${name}"
        file=$(resolve_file_tpl "$file_tpl")
        detail "model | ${family}, ${file}, ${W}x${H}, steps=${steps}"
        if ! hf_fetch "$repo" "$file"; then
            bench_warn "${name}: diffusion download failed"
            bench_row "$name" "s/image" "n/a"
            continue
        fi
        diff_path=$HF_FILE
        detail "sd | fetch encoders (${family})"
        if ! extra=$(family_args "$family" "$repo"); then
            bench_warn "${name}: encoder download failed"
            bench_row "$name" "s/image" "n/a"
            continue
        fi
        out="$OUT_DIR/$name-bench.png"
        rm -f "$out"
        args=()
        if [ "$family" = sdxs ]; then
            args+=( --model "$diff_path" )
        else
            args+=( --diffusion-model "$diff_path" )
        fi
        # shellcheck disable=SC2206
        args+=( $extra -p "$PROMPT" )
        [ "$neg" = 1 ] && args+=( -n "$NEGATIVE" )
        args+=( --cfg-scale "$cfg" --steps "$steps" )
        # shellcheck disable=SC2206
        args+=( $COMMON_ARGS -o "$out" -v )
        detail "run | benchmark → ${out}"
        start=$SECONDS
        if ! run_capture "$SD_CLI" "${args[@]}" </dev/null || [ ! -f "$out" ]; then
            bench_warn "${name}: sd-cli benchmark run failed"
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
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$SD_CLI" ] || die "sd-cli not found at $SD_CLI"
    mkdir -p "$OUT_DIR"

    COMMON_ARGS="--offload-to-cpu --diffusion-fa --vae-tiling --clip-on-cpu -W $W -H $H -t $THREADS --seed 42"

    while IFS=$'\t' read -r name family repo file_tpl steps cfg neg; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        file=$(resolve_file_tpl "$file_tpl")
        detail "model | ${family}, ${file}, ${W}x${H}, steps=${steps}"
        if ! hf_fetch "$repo" "$file"; then
            harness_record fail "${name} (download diffusion)"
            continue
        fi
        local diff_path=$HF_FILE extra
        detail "sd | fetch encoders (${family})"
        if ! extra=$(family_args "$family" "$repo"); then
            harness_record fail "${name} (download encoders)"
            continue
        fi
        local out="$OUT_DIR/$name.png"
        rm -f "$out"
        # Bundled single-GGUF families (sdxs) need --model; split encoder suites use --diffusion-model.
        local args=()
        if [ "$family" = sdxs ]; then
            args+=( --model "$diff_path" )
        else
            args+=( --diffusion-model "$diff_path" )
        fi
        # shellcheck disable=SC2206
        args+=( $extra -p "$PROMPT" )
        [ "$neg" = 1 ] && args+=( -n "$NEGATIVE" )
        args+=( --cfg-scale "$cfg" --steps "$steps" )
        # shellcheck disable=SC2206
        args+=( $COMMON_ARGS -o "$out" -v )
        detail "run | generate → ${out}"
        if run_q "$SD_CLI" "${args[@]}" </dev/null && [ -f "$out" ] && [ "$(wc -c < "$out")" -gt "$MIN_PNG_BYTES" ]; then
            detail "run | ok $(basename "$out") ($(harness_file_size "$out"))"
            harness_record pass "${name}"
        else
            harness_record fail "${name} (generate)"
        fi
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    harness_summary
}

if [ "$TEST_TYPE" = performance ]; then
    bench_sd "$@"
else
    run_sd "$@"
fi
