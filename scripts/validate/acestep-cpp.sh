#!/usr/bin/env bash
# acestep.cpp runtime validation: run the LM -> synth pipeline and check audio.
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
ACE_LM=$BIN_DIR/ace-lm
ACE_SYNTH=$BIN_DIR/ace-synth


# Fetch one GGUF and link it into the shared --models dir under its real name.
link_model() {
    local repo=$1 file=$2 dir=$3
    hf_fetch "$repo" "$file" || return 1
    ln -sf "$HF_FILE" "$dir/$file"
}

run_pipeline() {
    local name=$1 models_dir=$2 request_dir=$3 lm=$4 dit=$5 caption=$6 steps=$7 duration=$8
    local req log rc=0 wav

    req="$request_dir/req.json"
    rm -rf "$request_dir"
    mkdir -p "$request_dir"
    cat > "$req" <<JSON
{
    "lm_model": "$lm",
    "synth_model": "$dit",
    "caption": "$caption",
    "vocal_language": "en",
    "inference_steps": $steps,
    "guidance_scale": 1.0,
    "shift": 3.0,
    "output_format": "wav16",
    "duration": $duration
}
JSON
    log=$(_mktmp)
    describe_test "LM -> synth pipeline (${name}, steps=${steps})" "valid WAV, duration > 0, non-silent"
    show_file request "$req"
    detail "run | ${name} ace-lm"
    echo_cmd "$ACE_LM" --models "$models_dir" --request "$req"
    "$ACE_LM" --models "$models_dir" --request "$req" >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$log" >&2
        return 1
    fi
    [ -f "$request_dir/req0.json" ] || { detail "lm | no codes json produced"; return 1; }
    show_file "request (lm out)" "$request_dir/req0.json"
    detail "run | ${name} ace-synth"
    echo_cmd "$ACE_SYNTH" --models "$models_dir" --request "$request_dir/req0.json"
    "$ACE_SYNTH" --models "$models_dir" --request "$request_dir/req0.json" >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$log" >&2
        return 1
    fi
    wav=$(find "$request_dir" -maxdepth 1 -name '*.wav' | sort | head -n1)
    [ -n "$wav" ] || { detail "synth | no wav produced"; return 1; }
    assert_wav "$wav"
    cp "$wav" "$ARTIFACTS_DIR/${name}.wav"
}

run_acestep() {
    local name repo lm enc dit vae caption steps duration run_root models_dir request_dir
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$ACE_LM" ] || die "ace-lm not found at $ACE_LM"
    [ -x "$ACE_SYNTH" ] || die "ace-synth not found at $ACE_SYNTH"
    mkdir -p "$ARTIFACTS_DIR"

    while IFS=$'\t' read -r name repo lm enc dit vae caption steps duration; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        detail "model | ${repo} (lm=${lm}, dit=${dit})"
        run_root="$(tool_work_dir "$TOOL")/run/${name}"
        models_dir="$run_root/models"
        request_dir="$run_root/request"
        rm -rf "$run_root"
        mkdir -p "$models_dir"
        if ! link_model "$repo" "$lm" "$models_dir" ||
            ! link_model "$repo" "$enc" "$models_dir" ||
            ! link_model "$repo" "$dit" "$models_dir" ||
            ! link_model "$repo" "$vae" "$models_dir"; then
            harness_record fail "${name} (download)"
            continue
        fi
        if run_pipeline "$name" "$models_dir" "$request_dir" "$lm" "$dit" "$caption" "$steps" "$duration"; then
            harness_record pass "${name}"
        else
            harness_record fail "${name} (synth)"
        fi
    done < <(manifest_models "$TOOL" "$MODEL_TIER")

    harness_summary
}

if [ "$TEST_TYPE" = performance ]; then
    detail "performance | skipped for ${TOOL} (no stable parser yet)"
    exit 0
elif [ "$TEST_TYPE" = integration ]; then
    run_acestep "$@"
elif [ "$TEST_TYPE" = build ]; then
    run_acestep "$@"
elif [ "$TEST_TYPE" = unit ]; then
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    detail "unit | ${TOOL} compiled successfully (no unit tests configured)"
else
    detail "${TEST_TYPE} | skipped for ${TOOL}"
fi
