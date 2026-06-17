#!/usr/bin/env bash
# omnivoice.cpp runtime validation: synthesize speech and check the WAV output.
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
TTS_CLI=$BIN_DIR/omnivoice-tts



run_tts() {
    local name=$1 model=$2 codec=$3 lang=$4 text=$5
    local out_wav log rc=0
    out_wav="$ARTIFACTS_DIR/${name}.wav"
    log=$(_mktmp)
    describe_test "TTS synth (${name}, lang=${lang})" "valid WAV, duration > 0, non-silent"
    detail "run | ${name} (lang=${lang})"
    echo_cmd "$TTS_CLI" --model "$model" --codec "$codec" --lang "$lang" -o "$out_wav"
    printf '%s\n' "$text" | "$TTS_CLI" --model "$model" --codec "$codec" --lang "$lang" -o "$out_wav" >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$log" >&2
        return 1
    fi
    assert_wav "$out_wav"
}

run_omnivoice() {
    local name repo model_file codec_file lang text out_dir
    local model_path codec_path
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$TTS_CLI" ] || die "omnivoice-tts not found at $TTS_CLI"
    mkdir -p "$ARTIFACTS_DIR"

    while IFS=$'\t' read -r name repo model_file codec_file lang text; do
        [ -n "$name" ] || continue
        [ -z "$TARGET_MODEL" ] || [ "$TARGET_MODEL" = "$name" ] || continue
        phase "Model: ${name}"
        detail "model | ${repo}/${model_file} + ${codec_file}"
        if ! hf_fetch "$repo" "$model_file"; then
            harness_record fail "${name} (download model)"
            continue
        fi
        model_path=$HF_FILE
        if ! hf_fetch "$repo" "$codec_file"; then
            harness_record fail "${name} (download codec)"
            continue
        fi
        codec_path=$HF_FILE
        if run_tts "$name" "$model_path" "$codec_path" "$lang" "$text"; then
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
    run_omnivoice "$@"
elif [ "$TEST_TYPE" = build ]; then
    run_omnivoice "$@"
elif [ "$TEST_TYPE" = unit ]; then
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    detail "unit | ${TOOL} compiled successfully (no unit tests configured)"
else
    detail "${TEST_TYPE} | skipped for ${TOOL}"
fi
