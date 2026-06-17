#!/usr/bin/env bash
# Manifest-driven pipeline entrypoint for CI, validation, builds, and releases.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

DIST_WORK=${DIST_WORK:-$DIST_ROOT/scripts/dist/work}

usage() {
    cat <<EOF
Usage: dist.sh <command> [options]

Commands:
    plan-ci            Emit CI matrix/scope outputs
    plan-release       Emit release version/matrix outputs
    reconcile-ggml     Rebase patched ggml fork onto manifest upstream_ref
    prefetch           Download Hugging Face models for validation (no build)
    verify-hf-cache    Assert manifest HF files are present in the hub cache
    validate           Build/validate one tool or all tools
    build              Build and package one release artifact
    publish-release    Create a GitHub release from artifacts
EOF
}

emit_output() {
    local key=$1 value=$2
    printf '%s=%s\n' "$key" "$value"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

matrix_has_work() {
    MATRIX=$1 python3 -c \
        'import json, os; print("true" if json.loads(os.environ["MATRIX"]).get("include") else "false")'
}

old_upstream_ref() {
    local repo_key=$1 base=${2:-HEAD} tmp
    tmp=$(_mktmp)
    git show "${base}:manifest.json" >"$tmp" 2>/dev/null \
        || die "Cannot read ${base}:manifest.json"
    MANIFEST="$tmp" python3 "$DIST_ROOT/scripts/manifest_cli.py" upstream-ref "$repo_key" 2>/dev/null \
        || return 1
}

resolve_manifest_upstream() {
    local repo_key=$1 upstream_url upstream_ref upstream_sha
    upstream_url=$(manifest_repo_field "$repo_key" upstream_url)
    upstream_ref=$(manifest_repo_field "$repo_key" upstream_ref)
    upstream_sha=$(resolve_remote_ref "$upstream_url" "$upstream_ref")
    [ -n "$upstream_sha" ] || die "cannot resolve upstream_ref '${upstream_ref}' for ${repo_key}"
    printf '%s' "$upstream_sha"
}

prepare_fork_worktree() {
    local repo_dir=$1 fork_url=$2 branch=$3 clean=${4:-0}

    if [ "$clean" = 1 ] && [ -d "$repo_dir" ]; then
        detail "clean | removing ${repo_dir}"
        rm -rf "$repo_dir"
    fi

    if [ ! -d "$repo_dir/.git" ]; then
        detail "clone | ${fork_url} @ ${branch}"
        rm -rf "$repo_dir"
        git -c submodule.recurse=false clone "$fork_url" "$repo_dir" >&2
    else
        detail "source | reuse ${repo_dir}"
        git -C "$repo_dir" remote set-url origin "$fork_url"
    fi

    git -C "$repo_dir" -c fetch.recurseSubmodules=false fetch origin "$branch" >&2
    git -C "$repo_dir" checkout -q -B "$branch" FETCH_HEAD
    git -C "$repo_dir" reset --hard FETCH_HEAD >&2
    git -C "$repo_dir" clean -fdx >&2
    git -C "$repo_dir" rev-parse HEAD
}

fetch_upstream_ref() {
    local repo_dir=$1 upstream_url=$2 upstream_ref=$3
    git -C "$repo_dir" remote remove upstream 2>/dev/null || true
    git -C "$repo_dir" remote add upstream "$upstream_url"
    git -C "$repo_dir" -c fetch.recurseSubmodules=false fetch upstream "$upstream_ref" >&2 2>&1 \
        || git -C "$repo_dir" -c fetch.recurseSubmodules=false fetch upstream tag "$upstream_ref" --no-tags >&2 2>&1 \
        || true
}

rebase_onto_upstream() {
    local repo_dir=$1 old_ref=$2 upstream_ref=$3 upstream_sha=$4
    local rebase_log new_ref_sha old_ref_sha max_attempts i unresolved

    detail "rebase | ${old_ref} -> ${upstream_ref}"
    git -C "$repo_dir" -c fetch.recurseSubmodules=false fetch upstream "$old_ref" >&2 2>&1 \
        || git -C "$repo_dir" -c fetch.recurseSubmodules=false fetch upstream tag "$old_ref" --no-tags >&2 2>&1 \
        || true

    new_ref_sha=$(git -C "$repo_dir" rev-parse "$upstream_sha") \
        || die "cannot resolve new ref: ${upstream_ref}"
    old_ref_sha=$(git -C "$repo_dir" rev-parse "$old_ref" 2>/dev/null) \
        || old_ref_sha=$(git -C "$repo_dir" rev-parse FETCH_HEAD 2>/dev/null) \
        || die "cannot resolve old ref: ${old_ref}"

    rebase_log=$(_mktmp)
    if git -C "$repo_dir" -c submodule.recurse=false -c rebase.recurseSubmodules=false \
        rebase --onto "$new_ref_sha" "$old_ref_sha" >"$rebase_log" 2>&1; then
        return 0
    fi

    max_attempts=20
    for ((i = 0; i < max_attempts; i++)); do
        unresolved=$(git -C "$repo_dir" diff --name-only --diff-filter=U 2>/dev/null \
            | grep -v '^scripts/sync-ggml.last$' || true)
        if [ -n "$unresolved" ]; then
            git -C "$repo_dir" rebase --abort 2>/dev/null || true
            tail -n 80 "$rebase_log" >&2 || true
            die "Rebase conflict in ggml rebasing onto ${upstream_ref}. Conflicting: ${unresolved}"
        fi
        detail "rebase | auto-resolve scripts/sync-ggml.last"
        git -C "$repo_dir" checkout --theirs scripts/sync-ggml.last 2>/dev/null || true
        git -C "$repo_dir" add scripts/sync-ggml.last 2>/dev/null || true
        if GIT_EDITOR=true git -C "$repo_dir" -c submodule.recurse=false -c rebase.recurseSubmodules=false \
            rebase --continue >>"$rebase_log" 2>&1; then
            break
        fi
    done

    if [ -d "$repo_dir/.git/rebase-merge" ] || [ -d "$repo_dir/.git/rebase-apply" ]; then
        git -C "$repo_dir" rebase --abort 2>/dev/null || true
        tail -n 80 "$rebase_log" >&2 || true
        die "Rebase conflict in ggml: could not auto-resolve after ${max_attempts} attempts"
    fi
}

GGML_HEAD=""

reconcile_ggml_worktree() {
    local work_dir=$1 base_ref=${2:-HEAD} clean=${3:-0}
    local repo_dir="$work_dir/ggml"
    local fork_url branch upstream_url upstream_ref upstream_sha remote_head old_ref rebase_base new_sha

    mkdir -p "$work_dir"
    fork_url=$(manifest_repo_field ggml url)
    branch=$(manifest_repo_field ggml branch)
    upstream_url=$(manifest_repo_field ggml upstream_url)
    upstream_ref=$(manifest_repo_field ggml upstream_ref)

    phase "Reconcile: ggml"
    upstream_sha=$(resolve_manifest_upstream ggml)
    detail "upstream_ref=${upstream_ref} -> $(short_ref "$upstream_sha")"

    remote_head=$(prepare_fork_worktree "$repo_dir" "$fork_url" "$branch" "$clean")
    fetch_upstream_ref "$repo_dir" "$upstream_url" "$upstream_ref"

    if git -C "$repo_dir" merge-base --is-ancestor "$upstream_sha" HEAD 2>/dev/null; then
        detail "up-to-date | $(short_ref "$remote_head")"
    else
        old_ref=$(old_upstream_ref ggml "$base_ref" || true)
        if [ -n "$old_ref" ] && [ "$old_ref" != "$upstream_ref" ]; then
            rebase_base=$old_ref
        else
            rebase_base=$(git -C "$repo_dir" merge-base "$upstream_sha" HEAD 2>/dev/null) \
                || die "cannot derive merge-base for ggml against ${upstream_ref}"
            [ -n "$rebase_base" ] || die "empty merge-base for ggml"
        fi
        rebase_onto_upstream "$repo_dir" "$rebase_base" "$upstream_ref" "$upstream_sha"
    fi

    new_sha=$(git -C "$repo_dir" rev-parse HEAD)
    GGML_HEAD=$new_sha
    detail "proposed HEAD | $(short_ref "$new_sha")"
}

cmd_reconcile_ggml() {
    local work_dir="$DIST_WORK/reconcile" base_ref=HEAD expected_head="" dry_run=0 clean=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --base-ref) shift; base_ref="${1:-}" ;;
            --work-dir) shift; work_dir="${1:-}" ;;
            --expected-head) shift; expected_head="${1:-}" ;;
            --dry-run) dry_run=1 ;;
            --clean) clean=1 ;;
            -h|--help)
                echo "Usage: dist.sh reconcile-ggml [--base-ref REF] [--work-dir DIR] [--expected-head SHA] [--dry-run] [--clean]"
                return 0
                ;;
            *) die "unknown reconcile-ggml option: $1" ;;
        esac
        shift
    done

    if [ "$dry_run" = 1 ]; then
        local upstream_url upstream_ref upstream_sha old_ref
        phase "Reconcile dry-run"
        upstream_url=$(manifest_repo_field ggml upstream_url)
        upstream_ref=$(manifest_repo_field ggml upstream_ref)
        upstream_sha=$(resolve_manifest_upstream ggml)
        old_ref=$(old_upstream_ref ggml "$base_ref" || true)
        log "ggml: ${old_ref:-<merge-base>} -> ${upstream_ref} ($(short_ref "$upstream_sha")) from ${upstream_url}"
        return 0
    fi

    reconcile_ggml_worktree "$work_dir" "$base_ref" "$clean"

    if [ -n "$expected_head" ] && [ "$GGML_HEAD" != "$expected_head" ]; then
        die "reconciled ggml HEAD changed after validation: validated=${expected_head}, current=${GGML_HEAD}"
    fi

    emit_output ggml_head "$GGML_HEAD" >/dev/null
    printf '%s\n' "$GGML_HEAD"
}

ensure_reconciled_ggml_env() {
    local expected_head=${1:-}
    if [ -n "${GGML_SOURCE_DIR:-}" ]; then
        [ -d "$GGML_SOURCE_DIR" ] || die "GGML_SOURCE_DIR does not exist: $GGML_SOURCE_DIR"
        if [ -n "$expected_head" ]; then
            [ -d "$GGML_SOURCE_DIR/.git" ] \
                || die "cannot verify --expected-ggml-head for non-git GGML_SOURCE_DIR: $GGML_SOURCE_DIR"
            GGML_HEAD=$(git -C "$GGML_SOURCE_DIR" rev-parse HEAD)
            [ "$GGML_HEAD" = "$expected_head" ] \
                || die "reconciled ggml HEAD mismatch: expected=${expected_head}, current=${GGML_HEAD}"
        fi
        return 0
    fi

    local work_dir="$DIST_WORK/reconcile-for-command"
    local args=(--work-dir "$work_dir")
    [ -z "$expected_head" ] || args+=(--expected-head "$expected_head")
    cmd_reconcile_ggml "${args[@]}" >/dev/null
    GGML_SOURCE_DIR="$work_dir/ggml"
    export GGML_SOURCE_DIR
}

cmd_plan_ci() {
    local event_name="" pr_base_sha="" input_base_ref=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --event-name) shift; event_name="${1:-}" ;;
            --pr-base-sha) shift; pr_base_sha="${1:-}" ;;
            --base-ref) shift; input_base_ref="${1:-}" ;;
            *) die "unknown plan-ci option: $1" ;;
        esac
        shift
    done

    local matrix_mode=all affected_base_ref="" changed matrix brew_deps has_work
    if [ "$event_name" = pull_request ]; then
        [ -n "$pr_base_sha" ] || die "plan-ci requires --pr-base-sha for pull_request"
        changed=$(git diff --name-only "$pr_base_sha" HEAD)
        if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -v '^manifest\.json$' >/dev/null; then
            matrix_mode=affected
            affected_base_ref=$pr_base_sha
        fi
    elif [ -n "$input_base_ref" ]; then
        matrix_mode=affected
        affected_base_ref=$input_base_ref
    fi

    if [ "$matrix_mode" = affected ]; then
        matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix build --affected --base-ref "$affected_base_ref")
        prefetch_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix prefetch --affected --base-ref "$affected_base_ref")
    else
        matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix build)
        prefetch_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix prefetch)
    fi
    brew_deps=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" brew-deps build)
    has_work=$(matrix_has_work "$matrix")
    prefetch_has_work=$(matrix_has_work "$prefetch_matrix")

    emit_output matrix_mode "$matrix_mode"
    emit_output affected_base_ref "$affected_base_ref"
    emit_output matrix "$matrix"
    emit_output prefetch_matrix "$prefetch_matrix"
    emit_output brew_deps "$brew_deps"
    emit_output has_work "$has_work"
    emit_output prefetch_has_work "$prefetch_has_work"
}

next_calver() {
    local year month prefix last build
    year=$(date -u +%y)
    month=$(date -u +%-m)
    prefix="v${year}.${month}."
    last=$(git tag --list "${prefix}*" --sort=-version:refname | head -n1 || true)
    if [ -z "$last" ]; then
        printf '%s0' "$prefix"
    else
        build="${last##*.}"
        printf '%s%s' "$prefix" "$((build + 1))"
    fi
}

validate_version() {
    local version=$1
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid version format: '$version' (expected vYY.M.BUILD)"
}

cmd_plan_release() {
    local input_version="" affected_base_ref="" version ci_matrix release_matrix ci_brew_deps release_brew_deps
    local has_ci_work has_release_work
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) shift; input_version="${1:-}" ;;
            --base-ref) shift; affected_base_ref="${1:-}" ;;
            *) die "unknown plan-release option: $1" ;;
        esac
        shift
    done

    if [ -n "$input_version" ]; then
        version=$input_version
    else
        version=$(next_calver)
    fi
    validate_version "$version"

    if [ -n "$affected_base_ref" ]; then
        ci_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix build --affected --base-ref "$affected_base_ref")
        release_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix release --affected --base-ref "$affected_base_ref")
        prefetch_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix prefetch --affected --base-ref "$affected_base_ref")
    else
        ci_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix build)
        release_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix release)
        prefetch_matrix=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix prefetch)
    fi
    ci_brew_deps=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" brew-deps build)
    release_brew_deps=$(python3 "$DIST_ROOT/scripts/manifest_cli.py" brew-deps release)
    has_ci_work=$(matrix_has_work "$ci_matrix")
    has_release_work=$(matrix_has_work "$release_matrix")
    prefetch_has_work=$(matrix_has_work "$prefetch_matrix")

    emit_output version "$version"
    emit_output matrix "$release_matrix"
    emit_output ci_matrix "$ci_matrix"
    emit_output release_matrix "$release_matrix"
    emit_output prefetch_matrix "$prefetch_matrix"
    emit_output brew_deps "$release_brew_deps"
    emit_output ci_brew_deps "$ci_brew_deps"
    emit_output release_brew_deps "$release_brew_deps"
    emit_output affected_base_ref "$affected_base_ref"
    emit_output has_work "$has_release_work"
    emit_output has_ci_work "$has_ci_work"
    emit_output has_release_work "$has_release_work"
    emit_output prefetch_has_work "$prefetch_has_work"
}

prefetch_tools_from_matrix() {
    local matrix_json=$1
    python3 -c '
import json, sys
data = json.load(sys.stdin)
for row in data.get("include", []):
    tool = row.get("tool")
    if tool:
        print(tool)
' <<<"$matrix_json"
}

cmd_prefetch() {
    local tool="" model_tier=smoke all_mode=0 prefetch_matrix=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier) shift; model_tier="${1:-}" ;;
            --full) model_tier=full ;;
            --matrix-json) shift; prefetch_matrix="${1:-}" ;;
            -h|--help)
                echo "Usage: dist.sh prefetch [tool|all] [--tier smoke|full] [--full] [--matrix-json JSON]"
                exit 0
                ;;
            *)
                if [ -z "$tool" ]; then
                    tool=$1
                else
                    die "unexpected prefetch argument: $1"
                fi
                ;;
        esac
        shift
    done
    case "$model_tier" in
        smoke|full) ;;
        *) die "invalid --tier: ${model_tier} (expected smoke|full)" ;;
    esac
    if [ -z "$tool" ] || [ "$tool" = all ]; then
        all_mode=1
    fi

    prefetch_one() {
        local t=$1 repo pattern
        phase "Prefetch: ${t} (${model_tier})"
        while IFS=$'\t' read -r repo pattern; do
            [ -n "$repo" ] || continue
            hf_fetch "$repo" "$pattern" || die "prefetch failed: ${repo}/${pattern}"
        done < <(manifest_hf_files "$t" "$model_tier")
    }

    if [ "$all_mode" = 1 ]; then
        local tools=() t
        if [ -n "$prefetch_matrix" ]; then
            while IFS= read -r t; do
                [ -n "$t" ] || continue
                tools+=("$t")
            done < <(prefetch_tools_from_matrix "$prefetch_matrix")
        else
            while IFS= read -r t; do
                [ -n "$t" ] || continue
                tools+=("$t")
            done < <(prefetch_tools_from_matrix "$(python3 "$DIST_ROOT/scripts/manifest_cli.py" matrix prefetch)")
        fi
        for t in "${tools[@]:-}"; do
            prefetch_one "$t"
        done
        return 0
    fi

    is_manifest_tool "$tool" || die "unknown tool: $tool (expected one of: $(tools_usage))"
    prefetch_one "$tool"
}

cmd_verify_hf_cache() {
    local tool="" model_tier=smoke
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier) shift; model_tier="${1:-}" ;;
            --full) model_tier=full ;;
            -h|--help)
                echo "Usage: dist.sh verify-hf-cache <tool> [--tier smoke|full] [--full]"
                return 0
                ;;
            *)
                if [ -z "$tool" ]; then
                    tool=$1
                else
                    die "unexpected verify-hf-cache argument: $1"
                fi
                ;;
        esac
        shift
    done
    case "$model_tier" in
        smoke|full) ;;
        *) die "invalid --tier: ${model_tier} (expected smoke|full)" ;;
    esac
    [ -n "$tool" ] || die "verify-hf-cache requires a tool name"
    is_manifest_tool "$tool" || die "unknown tool: $tool (expected one of: $(tools_usage))"

    hf_init_env
    local repo pattern find_pat cache
    cache=$(hf_cache_dir)
    local missing=0
    while IFS=$'\t' read -r repo pattern; do
        [ -n "$repo" ] || continue
        find_pat=${pattern##*/}
        case "$pattern" in
            *'?'*|*'*'*) find_pat=$pattern ;;
            *) ;;
        esac
        if _hf_find_cached "$cache" "$repo" "$find_pat" >/dev/null; then
            detail "hf-cache | ok ${repo}/${pattern}"
        else
            detail "hf-cache | miss ${repo}/${pattern}"
            missing=1
        fi
    done < <(manifest_hf_files "$tool" "$model_tier")
    [ "$missing" -eq 0 ] || die "HF cache incomplete for ${tool} (${model_tier}); run prefetch or restore cache first"
}

cmd_validate() {
    local tool="" test_type=build model_tier=smoke bin_dir="" src_dir="" ref="" target_model=""
    local expected_ggml_head="" run_build=1 clean=0 all_mode=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --type) shift; test_type="${1:-}" ;;
            --tier) shift; model_tier="${1:-}" ;;
            --full) model_tier=full ;;
            --bin-dir) shift; bin_dir="${1:-}"; run_build=0 ;;
            --src-dir) shift; src_dir="${1:-}" ;;
            --ref) shift; ref="${1:-}" ;;
            --model) shift; target_model="${1:-}" ;;
            --expected-ggml-head) shift; expected_ggml_head="${1:-}" ;;
            --no-build) run_build=0 ;;
            --clean) clean=1 ;;
            --verbose|-v) HARNESS_VERBOSE=1; export HARNESS_VERBOSE ;;
            -h|--help)
                echo "Usage: dist.sh validate [tool|all] [--type TYPE] [--tier smoke|full] [--bin-dir DIR] [--src-dir DIR] [--ref SHA] [--model NAME] [--expected-ggml-head SHA] [--no-build] [--clean] [--verbose]"
                return 0
                ;;
            -*)
                die "unknown validate option: $1"
                ;;
            *)
                if [ -z "$tool" ]; then tool=$1; else die "unexpected validate argument: $1"; fi
                ;;
        esac
        shift
    done

    case "$test_type" in
        unit|build|integration|performance) ;;
        *) die "invalid --type: ${test_type} (expected unit|build|integration|performance)" ;;
    esac
    case "$model_tier" in
        smoke|full) ;;
        *) die "invalid --tier: ${model_tier} (expected smoke|full)" ;;
    esac
    if [ "$test_type" = integration ] || [ "$test_type" = performance ]; then
        run_build=0
    fi
    if [ -z "$tool" ] || [ "$tool" = all ]; then
        all_mode=1
    fi
    if [ "$run_build" = 1 ]; then
        ensure_reconciled_ggml_env "$expected_ggml_head"
    fi

    if [ "$all_mode" = 1 ]; then
        [ -z "$bin_dir" ] && [ -z "$src_dir" ] && [ -z "$ref" ] && [ -z "$target_model" ] \
            || die "all-mode does not support --bin-dir, --src-dir, --ref, or --model"
        phase "Validate all tools (${test_type} ${model_tier})"
        host_info
        local failures=() t pipelines
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            pipelines=$(manifest_tool_field "$t" pipelines)
            case " $pipelines " in
                *" $test_type "*) ;;
                *) detail "skip ${t} (no ${test_type} pipeline)"; continue ;;
            esac
            local args=("$t" "--type" "$test_type" "--tier" "$model_tier")
            [ "$clean" = 0 ] || args+=(--clean)
            [ -z "$expected_ggml_head" ] || args+=(--expected-ggml-head "$expected_ggml_head")
            [ "$HARNESS_VERBOSE" = 0 ] || args+=(--verbose)
            HOST_INFO_SUPPRESS=1 "$DIST_ROOT/scripts/dist.sh" validate "${args[@]}" \
                || failures+=("$t")
        done < <(manifest_tools)
        if [ ${#failures[@]} -gt 0 ]; then
            log "FAILED tools: ${failures[*]}"
            harness_all_done 1
            return 1
        fi
        harness_all_done 0
        return 0
    fi

    is_manifest_tool "$tool" || die "unknown tool: $tool (expected one of: $(tools_usage))"

    local pipelines local_bin bin_path system_bin=0
    pipelines=$(manifest_tool_field "$tool" pipelines)
    case " $pipelines " in
        *" $test_type "*) ;;
        *) log "skip ${tool} (no ${test_type} pipeline)"; return 0 ;;
    esac

    if [ "$run_build" = 0 ] && [ -z "$bin_dir" ]; then
        local_bin=$(manifest_tool_field "$tool" binaries | awk '{print $1}')
        [ -n "$local_bin" ] || die "--bin-dir is required (tool has no binaries defined)"
        bin_path=$(command -v "$local_bin" 2>/dev/null) || true
        if [ -z "$bin_path" ]; then
            log "skip ${tool} (${local_bin} not found in PATH)"
            return 0
        fi
        bin_dir=$(dirname "$bin_path")
        system_bin=1
    fi

    if [ "$clean" = 1 ]; then
        phase "Clean work dir: ${tool}"
        clean_tool_work "$tool"
    fi

    export HARNESS_VERBOSE
    hf_init_env
    if [ "$system_bin" = 1 ]; then
        phase "System binaries"
        detail "setup | BIN_DIR=${bin_dir}"
        BIN_DIR=$bin_dir
    else
        setup_bin_dir "$tool" "$bin_dir" "$src_dir" "" "$ref"
    fi
    export BIN_DIR BUILD_DIR SRC_DIR

    local script="$DIST_ROOT/scripts/validate/$tool.sh"
    [ -x "$script" ] || [ -f "$script" ] || die "no validation script for tool: $tool"
    local validate_args=(--type "$test_type" --tier "$model_tier")
    [ -z "$target_model" ] || validate_args+=(--model "$target_model")
    [ -z "$ref" ] || validate_args+=(--ref "$ref")
    [ "$run_build" = 1 ] || validate_args+=(--no-build)
    "$script" "${validate_args[@]}"
}

install_targets() {
    local build=$1 stage=$2
    shift 2
    mkdir -p "$stage"
    if [ "${1:-}" = install ]; then
        run_q cmake --install "$build" --prefix "$stage"
        return 0
    fi
    mkdir -p "$stage/bin"
    local target src
    for target in "$@"; do
        src=$(find "$build" -type f -path "*/bin/$target" -perm +111 2>/dev/null | head -n1)
        [ -n "$src" ] || die "built target not found: $target"
        install -m 755 "$src" "$stage/bin/$target"
    done
}

validate_stage_bins() {
    local tool=$1 stage=$2 bin_dir expected b path name
    bin_dir=$stage/bin
    expected=$(manifest_tool_field "$tool" binaries)
    [ -n "$expected" ] || return 0

    for b in $expected; do
        [ -x "$bin_dir/$b" ] || die "missing declared binary after install: $b"
    done

    if [ -d "$bin_dir" ]; then
        for path in "$bin_dir"/*; do
            [ -e "$path" ] || continue
            [ -f "$path" ] && [ -x "$path" ] || continue
            name=$(basename "$path")
            case " $expected " in
                *" $name "*) ;;
                *) die "undeclared binary installed: $name" ;;
            esac
        done
    fi
}

prune_dev_artifacts() {
    local stage=$1
    rm -rf "$stage/include" "$stage/lib/cmake" "$stage/lib/pkgconfig"
    if [ -d "$stage/lib" ]; then
        find "$stage/lib" -type f -name '*.a' -delete
        find "$stage/lib" -type d -empty -delete
    fi
}

cmd_build() {
    local tool="" version=${VERSION:-} arch=${ARCH:-$(uname -m)} build_work_dir="" no_tar=0
    local expected_ggml_head="" no_upload=0 jobs=${JOBS:-$(ncpu)}

    while [ $# -gt 0 ]; do
        case "$1" in
            --arch) shift; arch="${1:-}" ;;
            --version) shift; version="${1:-}" ;;
            --work-dir) shift; build_work_dir="${1:-}" ;;
            --expected-ggml-head) shift; expected_ggml_head="${1:-}" ;;
            --no-tar) no_tar=1 ;;
            --no-upload) no_upload=1 ;;
            -h|--help)
                echo "Usage: dist.sh build <tool> [--arch x86_64|arm64] [--version vYY.M.BUILD] [--work-dir DIR] [--expected-ggml-head SHA] [--no-tar] [--no-upload]"
                return 0
                ;;
            -*)
                die "unknown build option: $1"
                ;;
            *)
                if [ -z "$tool" ]; then tool=$1; else die "unexpected build argument: $1"; fi
                ;;
        esac
        shift
    done

    [ -n "$tool" ] || die "build requires a tool"
    is_manifest_tool "$tool" || die "unknown tool: $tool (expected one of: $(tools_usage))"
    if [ "$no_tar" = 0 ]; then
        VERSION=$version
        require_version
    fi
    ensure_reconciled_ggml_env "$expected_ggml_head"

    local repo_key repo_ref cleanup src build stage out tar_file
    local -a install_targets_arr=() depends_on=()
    repo_key=$(manifest_tool_field "$tool" repo)
    repo_ref=$(repo_source_ref "$repo_key")
    read -r -a install_targets_arr <<< "$(manifest_tool_field "$tool" install_targets)"
    read -r -a depends_on <<< "$(manifest_tool_field "$tool" depends_on)"

    if [ -z "$build_work_dir" ]; then
        build_work_dir=$(work_dir "$tool-build")
        cleanup=1
    else
        cleanup=0
    fi

    src=$build_work_dir/src
    build=$build_work_dir/build
    stage=$build_work_dir/stage

    phase "Build $tool"
    host_info
    log "build $tool @ $repo_ref ($arch)"
    need cmake
    need git
    need python3
    if [ "${#depends_on[@]}" -gt 0 ]; then
        ensure_brew_deps "${depends_on[@]:-}"
    fi

    prepare_tool_source "$tool" "$src"
    build_tool "$tool" "$src" "$build" "$arch" "$jobs"
    install_targets "$build" "$stage" "${install_targets_arr[@]:-}"
    prune_dev_artifacts "$stage"
    validate_stage_bins "$tool" "$stage"

    codesign_binaries "$stage"
    local dep
    if [ "${#depends_on[@]}" -gt 0 ]; then
        for dep in "${depends_on[@]:-}"; do
            [ -n "$dep" ] || continue
            audit_no_vendored_deps "$stage" "$dep"
        done
    fi

    if [ "$no_tar" = 0 ]; then
        local pkg_parent pkg_root root_name
        out=$DIST_ROOT/artifacts
        mkdir -p "$out"
        root_name=${tool}-${version}
        pkg_parent=$(mktemp -d "${TMPDIR:-/tmp}/ggml-metal-dist-package.XXXXXX")
        pkg_root=$pkg_parent/$root_name
        mkdir -p "$pkg_root"
        tar -C "$stage" -cf - . | tar -C "$pkg_root" -xf -
        tar_file=$out/${tool}-${version}-${arch}-apple-darwin.tar.gz
        rm -f "$tar_file"
        tar -C "$pkg_parent" -czf "$tar_file" "$root_name"
        sha256_file "$tar_file" > "$tar_file.sha256"
        rm -rf "$pkg_parent"
        log "artifact: $tar_file"
        log "sha256: $(cat "$tar_file.sha256")"
    fi

    [ "$cleanup" = 0 ] || rm -rf "$build_work_dir"
    [ "$no_upload" = 0 ] || detail "build | --no-upload is a no-op for local builds"
}

cmd_publish_release() {
    local version=${VERSION:-} artifacts=${ARTIFACTS:-$DIST_ROOT/artifacts} dry_run=0 flatten=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) shift; version="${1:-}" ;;
            --artifacts-dir) shift; artifacts="${1:-}" ;;
            --dry-run) dry_run=1 ;;
            --flatten) flatten=1 ;;
            -h|--help)
                echo "Usage: dist.sh publish-release [--version vYY.M.BUILD] [--artifacts-dir DIR] [--dry-run] [--flatten]"
                return 0
                ;;
            *) die "unknown publish-release option: $1" ;;
        esac
        shift
    done

    VERSION=$version
    require_version
    [ -d "$artifacts" ] || die "artifacts dir not found: $artifacts"
    local scan_dir=$artifacts flat_dir
    if [ "$flatten" = 1 ]; then
        flat_dir=$(mktemp -d "${TMPDIR:-/tmp}/ggml-metal-dist-artifacts.XXXXXX")
        find "$artifacts" -name '*.tar.gz' -exec cp {} "$flat_dir/" \;
        find "$artifacts" -name '*.sha256' -exec cp {} "$flat_dir/" \;
        scan_dir=$flat_dir
    fi

    local assets=() tar_file
    while IFS= read -r tar_file; do
        [ -n "$tar_file" ] || continue
        [ -f "$tar_file.sha256" ] || die "missing checksum for artifact: $tar_file.sha256"
        assets+=("$tar_file" "$tar_file.sha256")
    done < <(find "$scan_dir" -maxdepth 1 -type f -name '*.tar.gz' | sort)

    [ "${#assets[@]}" -gt 0 ] || die "no .tar.gz artifacts found in $scan_dir"

    log "release $version from $scan_dir (${#assets[@]} assets)"
    if [ "$dry_run" = 1 ]; then
        log "dry run - would create release $version with:"
        printf '  %s\n' "${assets[@]}"
        return 0
    fi

    need gh
    gh release create "$version" \
        "${assets[@]}" \
        --title "$version" \
        --notes "Metal-enabled macOS builds (Intel + Apple Silicon)."
    log "release created: $version"
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 1; }
shift || true

case "$cmd" in
    plan-ci) cmd_plan_ci "$@" ;;
    plan-release) cmd_plan_release "$@" ;;
    reconcile-ggml) cmd_reconcile_ggml "$@" ;;
    prefetch) cmd_prefetch "$@" ;;
    verify-hf-cache) cmd_verify_hf_cache "$@" ;;
    validate) cmd_validate "$@" ;;
    build) cmd_build "$@" ;;
    publish-release) cmd_publish_release "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
esac
