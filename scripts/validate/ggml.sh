#!/usr/bin/env bash
# ggml op-level validation.
set -euo pipefail

TEST_TYPE=unit
MODEL_TIER=smoke
TARGET_MODEL=
REF=
RUN_BUILD=1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../lib.sh
. "$SCRIPT_DIR/../lib.sh"
parse_validate_cli "$@"

TOOL=$(basename "$0" .sh)
TEST_OPS=$BIN_DIR/test-backend-ops

# Build smoke is the same op-level check as unit smoke for ggml.
case "$TEST_TYPE" in
    unit|build) ;;
    *)
        detail "${TEST_TYPE} | skipped for ${TOOL} (unit/build only)"
        exit 0
        ;;
esac

run_ggml() {
    harness_reset
    harness_preamble "$TOOL" "$MODEL_TIER" "$RUN_BUILD"
    [ -x "$TEST_OPS" ] || die "test-backend-ops not found at $TEST_OPS"

    if [ "$MODEL_TIER" = smoke ]; then
        phase "Op checks (smoke)"
        for op in MUL_MAT FLASH_ATTN_EXT; do
            describe_test "Metal op ${op} vs CPU reference" "test-backend-ops reports OK"
            check "op:${op}" "$TEST_OPS" test -o "$op" -b MTL0 </dev/null
        done
    else
        phase "Op checks (full suite)"
        describe_test "full Metal op suite vs CPU reference" "test-backend-ops reports OK"
        check "full-suite" "$TEST_OPS" test -b MTL0 </dev/null
    fi

    harness_summary
}

run_ggml "$@"
