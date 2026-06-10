#!/usr/bin/env bash
# Shared helpers for ggml-metal-dist scripts.
set -euo pipefail

DIST_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST=${MANIFEST:-$DIST_ROOT/manifest.json}

die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
# Diagnostics go to stderr so functions can return values via stdout cleanly.
log() { printf '==> %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# --- temp file cleanup ---
_TMPFILES=()
_cleanup_tmp() {
    if [ "${_TMPFILES+set}" = set ] && [ "${#_TMPFILES[@]}" -gt 0 ]; then
        rm -f "${_TMPFILES[@]}" 2>/dev/null || true
    fi
}
trap _cleanup_tmp EXIT
_mktmp() { local f; f=$(mktemp); _TMPFILES+=("$f"); printf '%s' "$f"; }

# --- harness presentation (stderr only) ---
# Colors and emojis when stderr is a TTY. Disable with NO_COLOR or NO_EMOJI.

HARNESS_VERBOSE=${HARNESS_VERBOSE:-0}
HARNESS_TTY=0
USE_COLOR=0
USE_VISUAL=0

if [ -t 2 ] || [ "${HARNESS_FORCE_TTY:-0}" = 1 ]; then
    HARNESS_TTY=1
    [ -z "${NO_COLOR:-}" ] && USE_COLOR=1
    [ -z "${NO_EMOJI:-}" ] && USE_VISUAL=1
fi

if [ "$USE_COLOR" = 1 ]; then
    C_RESET=$'\033[0m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET= C_DIM= C_BOLD= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_CYAN=
fi

_HARNESS_NL=0

_harness_sep() {
    [ "$HARNESS_VERBOSE" = 1 ] || return 0
    if [ "$_HARNESS_NL" = 1 ]; then
        printf '\n' >&2
    else
        _HARNESS_NL=1
    fi
}

_phase_icon() {
    local title=$1
    [ "$USE_VISUAL" != 1 ] && return 0
    case "$title" in
        📋*|🎉*) return 0 ;;
        Validate\ all*) printf '🚀 ' ;;
        Host*) printf '🖥️  ' ;;
        Validate*) printf '🔬 ' ;;
        Source*|Clone*|Update*) printf '📥 ' ;;
        Build*) printf '🔨 ' ;;
        Prebuilt*) printf '📦 ' ;;
        Op*) printf '⚙️  ' ;;
        Model*) printf '🧪 ' ;;
        Bench*) printf '📊 ' ;;
        All\ tools\ passed*) printf '✅ ' ;;
        *) printf '▸ ' ;;
    esac
}

phase() {
    local title=$1 icon
    icon=$(_phase_icon "$title")
    _harness_sep
    if [ "$USE_COLOR" = 1 ]; then
        printf '%s%s%s%s%s\n' "$C_BLUE" "$icon" "$C_BOLD" "$title" "$C_RESET" >&2
    else
        printf '==> %s%s\n' "$icon" "$title" >&2
    fi
}

detail() {
    [ "$HARNESS_VERBOSE" = 1 ] || return 0
    if [ "$USE_VISUAL" = 1 ]; then
        printf '%s💬 %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
    else
        printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
    fi
}

# Subsection header inside a phase (--verbose only).
verbose_section() {
    [ "$HARNESS_VERBOSE" = 1 ] || return 0
    if [ "$USE_VISUAL" = 1 ]; then
        _harness_sep
        printf '%s── %s ──%s\n' "$C_DIM" "$1" "$C_RESET" >&2
    else
        _harness_sep
        printf '[%s]\n' "$1" >&2
    fi
}

# Pass stdin to stderr unchanged (full terminal width).
verbose_lines() {
    cat >&2
}

_verbose_cmd_label() {
    local arg cmd=''
    for arg in "$@"; do
        cmd+="$(printf '%q' "$arg") "
    done
    printf '%s' "${cmd% }"
}

verbose_cmd_open() {
    [ "$HARNESS_VERBOSE" = 1 ] || return 0
    local cmd
    cmd=$(_verbose_cmd_label "$@")
    if [ "$USE_VISUAL" = 1 ]; then
        printf '%s▶ %s%s\n' "$C_DIM" "$cmd" "$C_RESET" >&2
    else
        printf '$ %s\n' "$cmd" >&2
    fi
}

verbose_cmd_close() {
    :
}

_verbose_replay_log() {
    cat "$1" >&2
}

# Stream a command's combined stdout/stderr (--verbose only). VERBOSE is unset so
# cmake/make do not inherit harness verbose mode.
verbose_cmd() {
    local rc=0
    verbose_cmd_open "$@"
    env -u VERBOSE "$@" >&2
    rc=$?
    return "$rc"
}

# Run a sub-command quietly unless --verbose; on failure, replay captured output.
run_q() {
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_cmd "$@"
        return "$?"
    fi
    local log rc=0
    log=$(_mktmp)
    env -u VERBOSE "$@" >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        _verbose_replay_log "$log"
    fi
    return "$rc"
}

# Run a sub-command, capture combined output in RUN_OUTPUT; stream to stderr when --verbose.
# Sets: RUN_OUTPUT (combined stdout+stderr of the command)
RUN_OUTPUT=""

run_capture() {
    local log rc=0
    log=$(_mktmp)
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_cmd_open "$@"
    fi
    env -u VERBOSE "$@" >"$log" 2>&1 || rc=$?
    RUN_OUTPUT=$(cat "$log")
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        printf '%s' "$RUN_OUTPUT" | verbose_lines
        verbose_cmd_close
    elif [ "$rc" -ne 0 ]; then
        _verbose_replay_log "$log"
    fi
    return "$rc"
}

PASS=0
FAIL=0
FAILED_LABELS=""

harness_reset() {
    PASS=0
    FAIL=0
    FAILED_LABELS=""
    _HARNESS_NL=0
}

harness_record() {
    local status=$1 label=$2 mark
    # shellcheck disable=SC2249
    case "$status" in
        pass)
            PASS=$((PASS + 1))
            if [ "$USE_VISUAL" = 1 ]; then mark='✅'; else mark='[PASS]'; fi
            printf '%s%s%s %s%s%s\n' "$C_GREEN" "$mark" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" >&2
            ;;
        fail)
            FAIL=$((FAIL + 1))
            if [ "$USE_VISUAL" = 1 ]; then
                FAILED_LABELS="${FAILED_LABELS}
❌ ${label}"
                mark='❌'
            else
                FAILED_LABELS="${FAILED_LABELS}
- ${label}"
                mark='[FAIL]'
            fi
            printf '%s%s%s %s%s%s\n' "$C_RED" "$mark" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" >&2
            ;;
    esac
}

check() {
    local label=$1
    shift
    if run_q "$@"; then
        harness_record pass "$label"
        return 0
    fi
    harness_record fail "$label"
    return 1
}

parse_validate_cli() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --type) shift; TEST_TYPE="${1:-}" ;;
            --tier) shift; MODEL_TIER="${1:-}" ;;
            --model) shift; TARGET_MODEL="${1:-}" ;;
            --ref) shift; REF="${1:-}" ;;
            --no-build) RUN_BUILD=0 ;;
            -h|--help)
                echo "Usage: $(basename "$0") [--type TYPE] [--tier smoke|full] [--model NAME] [--ref REF] [--no-build]"
                exit 0
                ;;
            *) die "unknown validation option for $(basename "$0"): $1" ;;
        esac
        shift
    done
}

harness_summary() {
    local total=$((PASS + FAIL)) header
    if [ "$USE_VISUAL" = 1 ]; then header='📋 Summary'; else header='Summary'; fi
    _harness_sep
    if [ "$USE_COLOR" = 1 ]; then
        printf '%s%s%s\n' "$C_CYAN" "$header" "$C_RESET" >&2
    else
        printf '==> %s\n' "$header" >&2
    fi
    if [ "$FAIL" -eq 0 ]; then
        if [ "$USE_VISUAL" = 1 ]; then
            printf '%s🎉 %s%d passed%s  (%d total)\n' "$C_GREEN" "$C_BOLD" "$PASS" "$C_RESET" "$total" >&2
        else
            printf '%s%d passed%s  (%d total)\n' "$C_GREEN" "$PASS" "$C_RESET" "$total" >&2
        fi
    else
        if [ "$USE_VISUAL" = 1 ]; then
            printf '%s✅ %d passed%s  %s❌ %d failed%s  (%d total)\n' \
                "$C_GREEN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET" "$total" >&2
            printf '\n%s⚠️  Failures:%s\n' "$C_YELLOW" "$C_RESET" >&2
        else
            printf '%d passed  %d failed  (%d total)\n' "$PASS" "$FAIL" "$total" >&2
            printf '\nFailures:\n' >&2
        fi
        printf '%s\n' "$FAILED_LABELS" >&2
    fi
    [ "$FAIL" -eq 0 ]
}

BENCH_ROWS=""

bench_reset() {
    BENCH_ROWS=""
}

bench_row() {
    local model=$1 metric=$2 value=$3
    BENCH_ROWS="${BENCH_ROWS}${model}	${metric}	${value}
"
}

bench_warn() {
    printf 'WARN: %s\n' "$*" >&2
}

bench_host_line() {
    local chip="" cores="" osver="" arch="" parts=()
    if command -v system_profiler >/dev/null 2>&1; then
        chip=$(system_profiler SPHardwareDataType 2>/dev/null \
            | awk -F': ' '/Chipset Model:|Processor Name:/ { sub(/^ +/, "", $2); print $2; exit }')
        cores=$(system_profiler SPDisplaysDataType 2>/dev/null \
            | awk -F': ' '/Total Number of Cores:/ { sub(/^ +/, "", $2); print $2; exit }')
    fi
    osver=$(sw_vers -productVersion 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)
    [ -n "$chip" ] && parts+=("$chip")
    [ -n "$cores" ] && parts+=("${cores} GPU cores")
    [ -n "$osver" ] && parts+=("macOS ${osver}")
    [ -n "$arch" ] && parts+=("$arch")
    if [ ${#parts[@]} -eq 0 ]; then
        printf 'unknown host'
        return 0
    fi
    local IFS=' · '
    printf '%s' "${parts[*]}"
}

# Print a commit-ready summary block to stdout (diagnostics stay on stderr).
bench_emit() {
    local tool=$1 ref=$2
    ref=$(short_ref "$ref")
    printf 'benchmark: %s @ %s\n' "$tool" "$ref"
    printf 'host: %s\n' "$(bench_host_line)"
    printf 'date: %s\n\n' "$(date +%Y-%m-%d)"
    {
        printf 'model\tmetric\tvalue\n'
        printf '%s' "$BENCH_ROWS"
    } | column -t -s $'\t'
}

bench_preamble() {
    local tool=$1 run_build=${2:-1}
    phase "Benchmark ${tool}"
    if [ "$run_build" = 0 ]; then
        detail "mode: prebuilt → ${BIN_DIR}"
    else
        detail "mode: built → ${BIN_DIR}"
    fi
    command -v cmake >/dev/null || die "cmake not found"
    host_info
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_section "GPU / system"
        gpu_report | verbose_lines
    fi
    hf_report_env
}

harness_file_size() {
    local f=$1
    [ -f "$f" ] || return 0
    du -h "$f" | awk '{print $1}'
}

# All manifest reads funnel through scripts/manifest_cli.py (single reader).
manifest_query() {
    MANIFEST="$MANIFEST" python3 "$DIST_ROOT/scripts/manifest_cli.py" "$@"
}

manifest_get() {
    manifest_query get "$1"
}

manifest_repo_field() {
    manifest_query repo-field "$1" "$2"
}

manifest_tool_field() {
    manifest_query tool-field "$1" "$2"
}

manifest_tools() {
    manifest_query tools
}

tools_usage() {
    manifest_tools | awk 'BEGIN{f=1}{if(!f)printf ", "; printf "%s",$0; f=0}'
}

manifest_models() {
    manifest_query models "$1" "$2"
}

require_version() {
    [ -n "${VERSION:-}" ] || die "VERSION not set (export VERSION=vYY.M.BUILD or pass --version)"
}

ncpu() {
    sysctl -n hw.ncpu 2>/dev/null || echo 8
}

# Abbreviate 40-char hex SHAs for display; branches/tags pass through unchanged.
short_ref() {
    local ref=$1 len=${2:-12}
    if [ ${#ref} -eq 40 ]; then
        case "$ref" in
            *[!0-9a-f]*) printf '%s' "$ref" ;;
            *) printf '%s' "${ref:0:len}" ;;
        esac
    else
        printf '%s' "$ref"
    fi
}

# Resolve any ref (tag, branch, SHA) to a commit SHA via ls-remote.
# Returns empty string if unresolvable.
resolve_remote_ref() {
    local url=$1 ref=$2 sha=""
    # Annotated tag dereference
    sha=$(git ls-remote --tags "$url" "refs/tags/${ref}^{}" 2>/dev/null | awk '{print $1}') || true
    # Lightweight tag
    [ -n "$sha" ] || sha=$(git ls-remote --tags "$url" "refs/tags/${ref}" 2>/dev/null | awk '{print $1}') || true
    # Branch
    [ -n "$sha" ] || sha=$(git ls-remote "$url" "refs/heads/${ref}" 2>/dev/null | awk '{print $1}') || true
    # Raw ref / SHA prefix (ls-remote matches full SHAs)
    [ -n "$sha" ] || sha=$(git ls-remote "$url" "${ref}" 2>/dev/null | awk '{print $1}') || true
    printf '%s' "$sha"
}

gpu_report() {
    if command -v system_profiler >/dev/null 2>&1; then
        system_profiler SPDisplaysDataType 2>/dev/null \
            | grep -E 'Chipset Model|Vendor|Metal|VRAM|Total Number of Cores' || true
    fi
    sw_vers 2>/dev/null || true
}

host_info() {
    [ "${HOST_INFO_SUPPRESS:-0}" = 1 ] && return 0
    local cpu="" ram="" osver="" arch=""
    local cores_logical="" cores_physical="" gpu_model="" gpu_cores=""
    local cpu_line="" gpu_line="" os_line=""

    _host_row() {
        local key=$1 value=$2
        [ -n "$value" ] || return 0
        if [ "$USE_COLOR" = 1 ]; then
            printf '%s  %-3s%s | %s\n' "$C_CYAN" "$key" "$C_RESET" "$value" >&2
        else
            printf '  %-3s | %s\n' "$key" "$value" >&2
        fi
    }

    # CPU info (Intel brand string or Apple Silicon chip)
    if command -v sysctl >/dev/null 2>&1; then
        cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    fi
    if [ -z "$cpu" ] && command -v system_profiler >/dev/null 2>&1; then
        cpu=$(system_profiler SPHardwareDataType 2>/dev/null \
            | awk -F': ' '/Chipset Model:|Processor Name:/ { sub(/^ +/, "", $2); print $2; exit }' || true)
    fi

    # CPU core counts (logical and physical)
    if command -v sysctl >/dev/null 2>&1; then
        cores_logical=$(sysctl -n hw.ncpu 2>/dev/null || true)
        cores_physical=$(sysctl -n hw.physicalcpu 2>/dev/null || true)
    fi

    # RAM in GB
    if command -v sysctl >/dev/null 2>&1; then
        local mem_bytes
        mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
        if [ -n "$mem_bytes" ]; then
            ram=$((mem_bytes / 1024 / 1024 / 1024))
        fi
    fi

    # GPU info (model and core count)
    if command -v system_profiler >/dev/null 2>&1; then
        gpu_model=$(system_profiler SPDisplaysDataType 2>/dev/null \
            | awk -F': ' '/Chipset Model:/ { sub(/^ +/, "", $2); print $2; exit }' || true)
        gpu_cores=$(system_profiler SPDisplaysDataType 2>/dev/null \
            | awk -F': ' '/Total Number of Cores:/ { sub(/^ +/, "", $2); print $2; exit }' || true)
    fi

    # macOS version and architecture
    osver=$(sw_vers -productVersion 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)

    if [ -z "$cpu" ] && [ -z "$ram" ] && [ -z "$gpu_model" ] && [ -z "$osver" ] && [ -z "$arch" ]; then
        log "host | unknown hardware"
        return 0
    fi

    if [ -n "$cpu" ]; then
        if [ -n "$cores_logical" ] && [ "$cores_logical" != "$cores_physical" ] && [ -n "$cores_physical" ]; then
            cpu_line="${cpu} (${cores_physical}p/${cores_logical}l)"
        elif [ -n "$cores_logical" ]; then
            cpu_line="${cpu} (${cores_logical}c)"
        else
            cpu_line="$cpu"
        fi
    fi

    if [ -n "$gpu_model" ]; then
        if [ -n "$gpu_cores" ]; then
            gpu_line="${gpu_model} (${gpu_cores}c)"
        else
            gpu_line="$gpu_model"
        fi
    fi

    if [ -n "$osver" ] && [ -n "$arch" ]; then
        os_line="macOS ${osver} (${arch})"
    elif [ -n "$osver" ]; then
        os_line="macOS ${osver}"
    else
        os_line="$arch"
    fi

    phase "Host"
    _host_row CPU "$cpu_line"
    _host_row RAM "${ram:+${ram} GB}"
    _host_row GPU "$gpu_line"
    _host_row OS "$os_line"
}

brew_prefix() {
    local pkg=$1
    if ! brew list "$pkg" >/dev/null 2>&1; then
        die "brew package not found: $pkg (install with: brew install $pkg)"
    fi
    brew --prefix "$pkg" 2>/dev/null
}

cmake_prefix_args() {
    local paths=()
    local dep
    for dep in "$@"; do
        [ -n "$dep" ] || continue
        paths+=("$(brew_prefix "$dep")")
    done
    if [ ${#paths[@]} -eq 0 ]; then
        return 0
    fi
    local sep=:
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) sep=';' ;;
        *) ;;
    esac
    local joined
    joined=$(IFS="$sep"; echo "${paths[*]}")
    printf '%s\n' "-DCMAKE_PREFIX_PATH=$joined"
}

# Enable ccache in the current shell. Returns 0 when ccache is active.
cmake_ccache_init() {
    command -v ccache >/dev/null 2>&1 || return 1
    : "${CCACHE_DIR:=${DIST_ROOT}/.ccache}"
    export CCACHE_DIR
    : "${CCACHE_BASEDIR:=${DIST_ROOT}}"
    export CCACHE_BASEDIR
    return 0
}

# Emit -D launcher flags for cmake (call cmake_ccache_init in the current shell first).
cmake_ccache_args() {
    printf '%s\n' \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
}

ensure_brew_deps() {
    local dep
    for dep in "$@"; do
        [ -n "$dep" ] || continue
        brew_prefix "$dep" >/dev/null
    done
}

_clone_repo_die() {
    local dest=$1 action=$2
    local tool_hint
    tool_hint=$(basename "$dest")
    die "git ${action} failed in ${dest} (try: dist.sh validate ${tool_hint} --clean)"
}

# Fetch a specific ref as shallow history first; fall back to full fetch when necessary.
_clone_repo_fetch_ref() {
    local url=$1 ref=$2 dest=$3
    run_q git -C "$dest" remote set-url origin "$url" || true
    if run_q git -C "$dest" fetch --depth=1 --no-tags origin "$ref"; then
        return 0
    fi
    detail "source | shallow fetch failed, retrying full fetch for ${ref}"
    run_q git -C "$dest" fetch --all --tags
}

# Sync an existing checkout to <ref> (fetch, discard local/untracked changes, checkout).
_clone_repo_sync() {
    local url=$1 ref=$2 dest=$3
    detail "source | fetch ${url} @ ${ref}"
    _clone_repo_fetch_ref "$url" "$ref" "$dest" \
        || _clone_repo_die "$dest" "fetch"
    run_q git -C "$dest" reset --hard \
        || _clone_repo_die "$dest" "reset"
    run_q git -C "$dest" clean -fdx \
        || _clone_repo_die "$dest" "clean"
    run_q git -C "$dest" checkout -f FETCH_HEAD \
        || _clone_repo_die "$dest" "checkout $(short_ref "$ref")"
}

# Idempotent clone: reuse checkout at ref, fetch+checkout when ref differs.
clone_repo() {
    local url=$1 ref=$2 dest=$3
    local head

    if [ -d "$dest/.git" ]; then
        head=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
        if [ "$head" = "$ref" ]; then
            detail "source | reuse ${dest} @ $(short_ref "$ref")"
            return 0
        fi
        phase "Update source @ $(short_ref "$ref")"
        _clone_repo_sync "$url" "$ref" "$dest"
        return 0
    fi

    phase "Clone source @ $(short_ref "$ref")"
    detail "source | clone ${url}"
    rm -rf "$dest"
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_cmd git clone --depth=1 --no-single-branch --filter=blob:none --progress "$url" "$dest" \
            || _clone_repo_die "$dest" "clone"
    else
        run_q git clone --depth=1 --no-single-branch --filter=blob:none "$url" "$dest" \
            || _clone_repo_die "$dest" "clone"
    fi
    _clone_repo_fetch_ref "$url" "$ref" "$dest" \
        || _clone_repo_die "$dest" "fetch"
    run_q git -C "$dest" checkout -f FETCH_HEAD \
        || _clone_repo_die "$dest" "checkout $(short_ref "$ref")"
}

repo_source_ref() {
    local repo_key=$1 override=${2:-}
    if [ -n "$override" ]; then
        printf '%s' "$override"
    elif [ "$repo_key" = ggml ]; then
        manifest_repo_field "$repo_key" branch
    else
        manifest_repo_field "$repo_key" upstream_ref
    fi
}

repo_source_url() {
    local repo_key=$1
    if [ "$repo_key" = ggml ]; then
        manifest_repo_field "$repo_key" url
    else
        manifest_repo_field "$repo_key" upstream_url
    fi
}

tool_source_ref() {
    local tool=$1 override=${2:-} repo_key
    repo_key=$(manifest_tool_field "$tool" repo)
    repo_source_ref "$repo_key" "$override"
}

apply_repo_patches() {
    local repo_key=$1 repo_dir=$2 patches_str patch_path full_path patch_file
    patches_str=$(manifest_query repo-patches "$repo_key")
    [ -n "$patches_str" ] || return 0

    phase "Apply patches: ${repo_key}"
    while IFS= read -r patch_path; do
        [ -n "$patch_path" ] || continue
        full_path="$DIST_ROOT/$patch_path"
        patch_file=$(basename "$patch_path")
        [ -f "$full_path" ] || die "patch file not found for ${repo_key}: ${patch_path}"

        if git -C "$repo_dir" apply --reverse --check "$full_path" >/dev/null 2>&1; then
            detail "patch | skip ${patch_file} (already applied)"
            continue
        fi
        detail "patch | apply ${patch_file}"
        run_q git -C "$repo_dir" apply "$full_path" \
            || die "failed to apply ${patch_path} to ${repo_key}"
    done <<< "$patches_str"
}

prepare_ggml_source() {
    local dest=$1 override=${2:-}
    local repo_url repo_ref source_real dest_real

    if [ -n "${GGML_SOURCE_DIR:-}" ]; then
        [ -d "$GGML_SOURCE_DIR" ] || die "GGML_SOURCE_DIR does not exist: $GGML_SOURCE_DIR"
        source_real=$(cd "$GGML_SOURCE_DIR" && pwd -P)
        dest_real=
        [ ! -d "$dest" ] || dest_real=$(cd "$dest" && pwd -P)
        phase "Source: ggml @ reconciled"
        if [ "$source_real" = "$dest_real" ]; then
            detail "source | reuse ${dest}"
            return 0
        fi
        rm -rf "${dest:?}"
        mkdir -p "$(dirname "$dest")"
        rsync -a --exclude='.git' --exclude='.git/' "$GGML_SOURCE_DIR/" "$dest/"
        return 0
    fi

    repo_url=$(repo_source_url ggml)
    repo_ref=$(repo_source_ref ggml "$override")
    phase "Source: ggml @ $(short_ref "$repo_ref")"
    clone_repo "$repo_url" "$repo_ref" "$dest"
}

repo_ggml_path() {
    local repo_key=$1 ggml_path
    ggml_path=$(manifest_repo_field "$repo_key" ggml_path)
    printf '%s' "${ggml_path:-ggml}"
}

normalize_repo_path() {
    local path=$1
    while [ "${path#./}" != "$path" ]; do
        path=${path#./}
    done
    while [ "${path%/}" != "$path" ]; do
        path=${path%/}
    done
    printf '%s' "$path"
}

init_app_submodules() {
    local repo_key=$1 repo_dir=$2 ggml_path=$3
    local key path normalized_path normalized_ggml
    local -a submodule_paths=()

    [ -f "$repo_dir/.gitmodules" ] || return 0
    normalized_ggml=$(normalize_repo_path "$ggml_path")

    while read -r key path; do
        [ -n "$key" ] && [ -n "$path" ] || continue
        normalized_path=$(normalize_repo_path "$path")
        [ "$normalized_path" != "$normalized_ggml" ] || continue
        submodule_paths+=("$normalized_path")
    done < <(git -C "$repo_dir" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)

    [ "${#submodule_paths[@]}" -gt 0 ] || return 0
    phase "Submodules: ${repo_key}"
    run_q git -C "$repo_dir" submodule update --init --recursive -- "${submodule_paths[@]}" \
        || _clone_repo_die "$repo_dir" "submodule update"
}

inject_ggml_source() {
    local repo_key=$1 repo_dir=$2 ggml_dir=$3
    local ggml_path target_dir
    ggml_path=$(repo_ggml_path "$repo_key")
    target_dir="$repo_dir/$ggml_path"

    phase "Inject ggml: ${repo_key} -> ${ggml_path}"
    rm -rf "${target_dir:?}"
    mkdir -p "$(dirname "$target_dir")"
    rsync -a --exclude='.git' --exclude='.git/' "$ggml_dir/" "$target_dir/"
}

prepare_tool_source() {
    local tool=$1 dest=$2 ref_override=${3:-}
    local repo_key repo_url repo_ref ggml_dir ggml_path
    repo_key=$(manifest_tool_field "$tool" repo)

    if [ "$repo_key" = ggml ]; then
        prepare_ggml_source "$dest" "$ref_override"
        return 0
    fi

    repo_url=$(repo_source_url "$repo_key")
    repo_ref=$(repo_source_ref "$repo_key" "$ref_override")
    ggml_path=$(repo_ggml_path "$repo_key")

    phase "Source: ${tool} @ $(short_ref "$repo_ref")"
    clone_repo "$repo_url" "$repo_ref" "$dest"
    init_app_submodules "$repo_key" "$dest" "$ggml_path"
    apply_repo_patches "$repo_key" "$dest"

    ggml_dir="${dest}.ggml"
    prepare_ggml_source "$ggml_dir"
    inject_ggml_source "$repo_key" "$dest" "$ggml_dir"
}

# Ephemeral work dir for release builds.
work_dir() {
    local name=$1
    mktemp -d "${TMPDIR:-/tmp}/ggml-metal-dist-${name}.XXXXXX"
}

# Stable gitignored checkout dir for validation.
VALIDATE_WORK=${VALIDATE_WORK:-$DIST_ROOT/scripts/validate/work}

tool_work_dir() {
    printf '%s/%s' "$VALIDATE_WORK" "$1"
}

clean_tool_work() {
    local tool=$1
    detail "clean | removing $(tool_work_dir "$tool")"
    rm -rf "$(tool_work_dir "$tool")"
}

# All-tools validation footer.
harness_all_done() {
    local failed=$1
    if [ "$failed" -eq 0 ]; then
        if [ "$USE_VISUAL" = 1 ]; then
            phase "All tools passed 🎉"
        else
            phase "All tools passed"
        fi
    fi
}

sha256_file() {
    local file=$1
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        sha256sum "$file" | awk '{print $1}'
    fi
}

codesign_binaries() {
    local dir=$1
    find "$dir" -type f \( -perm +111 -o -name '*.dylib' \) -print0 \
        | while IFS= read -r -d '' f; do
            if file "$f" | grep -q 'Mach-O'; then
                codesign -s - --force "$f" 2>/dev/null || true
            fi
        done
}

audit_no_vendored_deps() {
    # Fail if runtime deps (openssl, sdl2, …) were copied into the tarball lib/.
    # Linking against brew paths via otool is expected and correct.
    local stage=$1
    shift
    local pkg patterns pat
    [ -d "$stage/lib" ] || return 0
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        case "$pkg" in
            openssl@3) patterns="libssl libcrypto" ;;
            sdl2) patterns="libSDL2" ;;
            *) patterns="" ;;
        esac
        for pat in $patterns; do
            if find "$stage/lib" -maxdepth 1 -name "${pat}*" -print -quit | grep -q .; then
                die "vendored $pkg ($pat*) in $stage/lib — use depends_on, do not bundle"
            fi
        done
    done
}

hf_cli() {
    if command -v hf >/dev/null 2>&1; then
        printf '%s\n' hf
    elif command -v huggingface-cli >/dev/null 2>&1; then
        printf '%s\n' huggingface-cli
    elif command -v uvx >/dev/null 2>&1; then
        printf '%s\n' uvx --from huggingface-hub hf
    else
        die "Hugging Face CLI not found (install hf or uvx)"
    fi
}

# Resolve the Hugging Face hub cache directory from env (see dist.sh validate --help).
hf_cache_dir() {
    if [ -n "${HF_HUB_CACHE:-}" ]; then
        printf '%s' "$HF_HUB_CACHE"
    elif [ -n "${HUGGINGFACE_HUB_CACHE:-}" ]; then
        printf '%s' "$HUGGINGFACE_HUB_CACHE"
    elif [ -n "${HF_HOME:-}" ]; then
        printf '%s/hub' "$HF_HOME"
    else
        printf '%s/.cache/huggingface/hub' "${HOME}"
    fi
}

# Normalize HF_* env vars for huggingface_hub and child processes.
hf_init_env() {
    if [ -n "${HF_HUB_CACHE:-}" ]; then
        export HF_HUB_CACHE
        export HUGGINGFACE_HUB_CACHE="$HF_HUB_CACHE"
    elif [ -n "${HUGGINGFACE_HUB_CACHE:-}" ]; then
        export HF_HUB_CACHE="$HUGGINGFACE_HUB_CACHE"
        export HUGGINGFACE_HUB_CACHE
    elif [ -n "${HF_HOME:-}" ]; then
        export HF_HUB_CACHE="${HF_HOME}/hub"
        export HUGGINGFACE_HUB_CACHE="$HF_HUB_CACHE"
    fi
    if [ -n "${HF_HOME:-}" ]; then
        export HF_HOME
    fi
    if [ -n "${HF_TOKEN:-}" ]; then
        export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"
    elif [ -n "${HUGGINGFACE_HUB_TOKEN:-}" ]; then
        export HF_TOKEN="$HUGGINGFACE_HUB_TOKEN"
    fi
    : "${HF_HUB_DISABLE_PROGRESS_BARS:=1}"
    export HF_HUB_DISABLE_PROGRESS_BARS
    if [ -z "${HF_HUB_VERBOSITY:-}" ]; then
        if [ "${HARNESS_VERBOSE:-0}" = 1 ]; then
            export HF_HUB_VERBOSITY=warning
        else
            export HF_HUB_VERBOSITY=error
        fi
    fi
}

hf_report_env() {
    hf_init_env
    detail "huggingface | cache=$(hf_cache_dir)"
    if [ -n "${HF_HOME:-}" ]; then
        detail "huggingface | HF_HOME=${HF_HOME}"
    fi
    if [ -n "${HF_TOKEN:-}${HUGGINGFACE_HUB_TOKEN:-}" ]; then
        detail "huggingface | auth token set"
    fi
}

_hf_repo_cache_dir() {
    local cache=$1 repo=$2
    printf '%s/models--%s' "$cache" "$(printf '%s' "$repo" | tr '/:' '--')"
}

# Return a cached snapshot path when the file is already present locally.
_hf_find_cached() {
    local cache=$1 repo=$2 find_pat=$3
    local repo_cache cached
    repo_cache=$(_hf_repo_cache_dir "$cache" "$repo")
    [ -d "$repo_cache/snapshots" ] || return 1
    cached=$(find -L "$repo_cache/snapshots" -type f -iname "$find_pat" 2>/dev/null | sort | head -n1)
    [ -n "$cached" ] && [ -f "$cached" ] || return 1
    printf '%s' "$cached"
}

# Parse hf/huggingface-cli download stdout (quiet, agent, or human formats).
_hf_parse_download_path() {
    local raw=$1 line
    raw=$(printf '%s' "$raw" | tr -d '\r')
    line=$(printf '%s\n' "$raw" | grep -E '^[[:space:]]*(path|file):[[:space:]]+' | tail -n1)
    if [ -n "$line" ]; then
        line=${line#"${line%%[![:space:]]*}"}
        line=${line#path:}
        line=${line#file:}
        line=${line#"${line%%[![:space:]]*}"}
        printf '%s' "$line"
        return 0
    fi
    line=$(printf '%s\n' "$raw" | grep -E '^(path|file)=' | tail -n1)
    # shellcheck disable=SC2249
    case "$line" in
        path=*|file=*)
            printf '%s' "${line#*=}"
            return 0
            ;;
    esac
    line=$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | tail -n1)
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || return 1
    printf '%s' "$line"
}

# Download a single file matching <pattern> from a Hugging Face repo.
# Sets: HF_FILE (absolute path to the downloaded/cached file)
hf_fetch() {
    local repo=$1 pattern=$2 find_glob=${3:-}
    local cache out find_pat dl_args=() dl_log rc=0 cached hf_cmd=()
    hf_init_env
    while IFS= read -r arg; do
        hf_cmd+=("$arg")
    done < <(hf_cli)
    cache=$(hf_cache_dir)
    find_pat=${find_glob:-$(basename "$pattern")}
    detail "hf | ${repo} ← ${pattern}"
    detail "hf | cache ${cache}"
    if cached=$(_hf_find_cached "$cache" "$repo" "$find_pat"); then
        HF_FILE=$cached
        detail "hf | cached $(basename "$HF_FILE") ($(harness_file_size "$HF_FILE")) @ ${HF_FILE}"
        return 0
    fi
    dl_args=(download "$repo" --cache-dir "$cache")
    # Literal filenames download directly; globs use --include + snapshot dir.
    case "$pattern" in
        *'?'*|*'*'*) dl_args+=(--include "$pattern") ;;
        *) dl_args+=("$pattern") ;;
    esac
    detail "hf | downloading ${repo} ← ${pattern} (large files may take several minutes)"
    dl_log=$(_mktmp)
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_cmd_open "${hf_cmd[@]}" "${dl_args[@]}"
    fi
    # Stream progress to stderr; do not use -q or HF_HUB_DISABLE_PROGRESS_BARS here.
    local rc=0
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        HF_HUB_DISABLE_PROGRESS_BARS=0 "${hf_cmd[@]}" "${dl_args[@]}" 2>&1 | tee "$dl_log" || true
        rc=${PIPESTATUS[0]}
    else
        HF_HUB_DISABLE_PROGRESS_BARS=0 "${hf_cmd[@]}" "${dl_args[@]}" >"$dl_log" 2>&1 || rc=$?
    fi
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_cmd_close
    elif [ "$rc" -ne 0 ]; then
        _verbose_replay_log "$dl_log"
    fi
    out=$(cat "$dl_log")
    if [ "$rc" -ne 0 ]; then
        detail "hf | download failed: ${repo}/${pattern}"
        return 1
    fi
    if ! out=$(_hf_parse_download_path "$out"); then
        detail "hf | could not parse download path: ${repo}/${pattern}"
        return 1
    fi
    if [ -f "$out" ]; then
        HF_FILE="$out"
    else
        HF_FILE=$(find -L "$out" -type f -iname "$find_pat" 2>/dev/null | sort | head -n1)
    fi
    if [ -n "$HF_FILE" ] && [ -f "$HF_FILE" ]; then
        detail "hf | ready $(basename "$HF_FILE") ($(harness_file_size "$HF_FILE")) @ ${HF_FILE}"
        return 0
    fi
    detail "hf | could not resolve: ${repo}/${pattern} (from ${out})"
    return 1
}

# GGUF convenience wrapper: resolves to a *.gguf inside the repo.
# Sets: GGUF_PATH (absolute path to the .gguf file)
resolve_hf_gguf() {
    local repo=$1 pattern=$2
    # Use the manifest pattern for cache/find (not '*.gguf' — that hits the wrong quant).
    hf_fetch "$repo" "$pattern" "$pattern" || return 1
    GGUF_PATH=$HF_FILE
}

# Clone tool source into the stable work dir when samples/assets are needed
# (e.g. prebuilt binaries without --src-dir). Returns work dir path on stdout.
ensure_source_tree() {
    local tool=$1 ref_override=${2:-}
    local work
    work=$(tool_work_dir "$tool")
    phase "Source: ${tool} (assets)"
    prepare_tool_source "$tool" "$work" "$ref_override"
    printf '%s' "$work"
}

build_tool() {
    local tool=$1 src=$2 build=$3
    local arch=${4:-} jobs=${5:-$(ncpu)}
    local cmake_flags_raw build_targets_raw depends_on_raw
    local -a CMAKE_FLAGS=() BUILD_TARGETS=() DEPENDS_ON=() PREFIX_ARGS=() CCACHE_ARGS=()
    local -a ARCH_ARGS=()

    cmake_flags_raw=$(manifest_tool_field "$tool" cmake_flags)
    build_targets_raw=$(manifest_tool_field "$tool" build_targets)
    depends_on_raw=$(manifest_tool_field "$tool" depends_on)

    [ -n "$cmake_flags_raw" ] && read -r -a CMAKE_FLAGS <<< "$cmake_flags_raw"
    [ -n "$build_targets_raw" ] && read -r -a BUILD_TARGETS <<< "$build_targets_raw"
    [ -n "$depends_on_raw" ] && read -r -a DEPENDS_ON <<< "$depends_on_raw"

    if [ "${#DEPENDS_ON[@]}" -gt 0 ]; then
        ensure_brew_deps "${DEPENDS_ON[@]}"
        while IFS= read -r arg; do
            [ -n "$arg" ] && PREFIX_ARGS+=("$arg")
        done < <(cmake_prefix_args "${DEPENDS_ON[@]}")
    else
        ensure_brew_deps
        while IFS= read -r arg; do
            [ -n "$arg" ] && PREFIX_ARGS+=("$arg")
        done < <(cmake_prefix_args)
    fi
    if cmake_ccache_init; then
        detail "build | ccache ${CCACHE_DIR}"
        while IFS= read -r arg; do
            [ -n "$arg" ] && CCACHE_ARGS+=("$arg")
        done < <(cmake_ccache_args)
    fi
    if [ -n "$arch" ]; then
        ARCH_ARGS=(-DCMAKE_OSX_ARCHITECTURES="$arch")
    fi
    detail "build | cmake configure → ${build}"
    run_q cmake -S "$src" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        ${CMAKE_FLAGS[@]+"${CMAKE_FLAGS[@]}"} \
        ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} \
        ${PREFIX_ARGS[@]+"${PREFIX_ARGS[@]}"} \
        ${CCACHE_ARGS[@]+"${CCACHE_ARGS[@]}"}
    detail "build | targets: ${BUILD_TARGETS[*]}"
    run_q cmake --build "$build" -j "$jobs" --target "${BUILD_TARGETS[@]}"
    detail "build | done ${build}/bin"
}

# True when every manifest-declared binary for <tool> exists in <dir>.
bins_present() {
    local tool=$1 dir=$2 b
    [ -d "$dir" ] || return 1
    for b in $(manifest_tool_field "$tool" binaries); do
        [ -n "$b" ] || continue
        [ -x "$dir/$b" ] || return 1
    done
    return 0
}

# Sets: BIN_DIR, BUILD_DIR, SRC_DIR (exported by caller after return)
setup_bin_dir() {
    local tool=$1 bin_dir=$2 src_dir=${3:-} build_dir=${4:-} ref_override=${5:-}
    local work

    if [ -n "$bin_dir" ]; then
        BIN_DIR=$bin_dir
        BUILD_DIR=${build_dir:-$(dirname "$bin_dir")}
        SRC_DIR=${src_dir:-$BUILD_DIR/..}
        phase "Prebuilt binaries"
        detail "setup | BIN_DIR=${BIN_DIR}"
        bins_present "$tool" "$BIN_DIR" || die "missing binaries in ${BIN_DIR}"
        return 0
    fi

    work=$(tool_work_dir "$tool")
    SRC_DIR=${src_dir:-$work}
    BUILD_DIR=${build_dir:-$SRC_DIR/build}
    BIN_DIR=$BUILD_DIR/bin

    prepare_tool_source "$tool" "$SRC_DIR" "$ref_override"

    phase "Build: ${tool}"
    build_tool "$tool" "$SRC_DIR" "$BUILD_DIR"
}

harness_preamble() {
    local tool=$1 tier=$2 run_build=${3:-1}
    phase "Validate ${tool} (${tier})"
    if [ "$run_build" = 0 ]; then
        detail "mode: prebuilt → ${BIN_DIR}"
    else
        detail "mode: built → ${BIN_DIR}"
    fi
    command -v cmake >/dev/null || die "cmake not found"
    host_info
    if [ "$HARNESS_VERBOSE" = 1 ]; then
        verbose_section "GPU / system"
        gpu_report | verbose_lines
    fi
    hf_report_env
}

is_manifest_tool() {
    local tool=$1 tools
    tools=$(manifest_tools)
    grep -qxF "$tool" <<< "$tools"
}
