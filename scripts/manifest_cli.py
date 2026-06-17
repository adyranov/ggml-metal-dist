#!/usr/bin/env python3
"""Emit GitHub Actions matrix and CI helper values from manifest.json.

Usage:
    manifest_cli.py matrix <pipeline> [--affected --base-ref REF]  # JSON matrix
    manifest_cli.py repos                   # newline-separated repo keys
    manifest_cli.py tools                   # newline-separated tool keys
    manifest_cli.py brew-deps <pipeline>    # brew packages for a pipeline
    manifest_cli.py get <dotted.key>        # scalar/JSON value at a dotted key path
    manifest_cli.py repo-field <repo> <fld> # one field of repos.<repo> (bool -> 1/0)
    manifest_cli.py tool-field <tool> <fld> # one field of tools.<tool> (list -> joined)
    manifest_cli.py hf-files <tool> <tier>       # tab-separated repo/pattern rows
    manifest_cli.py model-encoders <tool> <tier> <name>  # tab-separated flag/repo/file
    manifest_cli.py upstream-ref <repo>     # current upstream_ref for a repo
    manifest_cli.py affected-tools --base-ref REF [pipeline]  # affected tools

This module is the single manifest reader; shell helpers in lib.sh call it
rather than re-parsing manifest.json with inline Python.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

WHISPER_HF_REPO = "ggerganov/whisper.cpp"


def manifest_path() -> Path:
    return Path(os.environ.get("MANIFEST", ROOT / "manifest.json"))


def load() -> dict:
    with manifest_path().open() as f:
        data = json.load(f)
    _validate_manifest(data)
    return data


_REQUIRED_TOP_KEYS = ("repos", "tools", "ci")
_REQUIRED_GGML_REPO_KEYS = ("url", "branch", "upstream_url", "upstream_ref")
_REQUIRED_APP_REPO_KEYS = ("upstream_url", "upstream_ref")
_REQUIRED_TOOL_KEYS = ("repo", "pipelines")


def _validate_manifest(data: dict, allow_legacy_app_forks: bool = False) -> None:
    for key in _REQUIRED_TOP_KEYS:
        if key not in data:
            sys.exit(f"manifest missing required top-level key: {key}")
    # Validate repos
    if not isinstance(data["repos"], dict) or not data["repos"]:
        sys.exit("manifest 'repos' must be a non-empty object")
    for name, repo in data["repos"].items():
        required_keys = _REQUIRED_GGML_REPO_KEYS if name == "ggml" else _REQUIRED_APP_REPO_KEYS
        for key in required_keys:
            if key not in repo:
                sys.exit(f"repo '{name}' missing required key: {key}")
        if name != "ggml" and not allow_legacy_app_forks:
            for key in ("url", "branch"):
                if key in repo:
                    sys.exit(f"repo '{name}' must not declare fork field: {key}")
        # Validate optional patches field
        patches = repo.get("patches")
        if patches is not None:
            if not isinstance(patches, list):
                sys.exit(f"repo '{name}' patches must be a list, not {type(patches).__name__}")
            for patch_path in patches:
                if not isinstance(patch_path, str):
                    sys.exit(f"repo '{name}' patch entry is not a string: {patch_path}")
                if patch_path.startswith("/"):
                    sys.exit(
                        f"repo '{name}' patch path must be relative, not absolute: {patch_path}"
                    )
                if ".." in patch_path:
                    sys.exit(f"repo '{name}' patch path must not contain '..': {patch_path}")
    # Validate tools
    if not isinstance(data["tools"], dict) or not data["tools"]:
        sys.exit("manifest 'tools' must be a non-empty object")
    for name, tool in data["tools"].items():
        for key in _REQUIRED_TOOL_KEYS:
            if key not in tool:
                sys.exit(f"tool '{name}' missing required key: {key}")


def tools_for_pipeline(data: dict, pipeline: str) -> list[str]:
    return [name for name, tool in data["tools"].items() if pipeline in tool.get("pipelines", [])]


MODEL_FIELDS: dict[str, list[str]] = {
    "llama-cpp": ["name", "repo", "file", "samplers", "ctx", "n_predict", "prompt", "expect"],
    "whisper-cpp": ["name", "id", "expected"],
    "stable-diffusion-cpp": [
        "name",
        "family",
        "repo",
        "file_tpl",
        "steps",
        "cfg",
        "neg",
        "prompt",
        "width",
        "height",
        "min_bytes",
    ],
    "parakeet-cpp": ["name", "repo", "file", "decoder", "expected"],
    "crispasr": ["name", "repo", "file", "expected", "backend"],
    "acestep-cpp": ["name", "repo", "lm", "enc", "dit", "vae", "caption", "steps", "duration"],
    "omnivoice-cpp": ["name", "repo", "model_file", "codec_file", "lang", "text"],
}


def _arch_tool_include(data: dict, tools: list[str], respect_exclusions: bool = True) -> list[dict]:
    """Build [{tool, arch, runs-on, type}, ...] for the given tool list."""
    include = []
    for t in tools:
        exclude_test = set(data.get("tools", {}).get(t, {}).get("exclude_test_archs", []))
        for a in data["ci"]["architectures"]:
            arch = a["arch"]
            runs_on = a["runs_on"]
            if respect_exclusions and arch in exclude_test:
                include.append({"tool": t, "arch": arch, "runs-on": runs_on, "type": "unit"})
            else:
                include.append({"tool": t, "arch": arch, "runs-on": runs_on, "type": "build"})
    return include


def matrix_arch_tool(data: dict, pipeline: str) -> dict:
    return {"include": _arch_tool_include(data, tools_for_pipeline(data, pipeline))}


def matrix_arch_tool_for_tools(data: dict, tools: list[str], pipeline: str) -> dict:
    pipeline_tools = set(tools_for_pipeline(data, pipeline))
    selected = [tool for tool in tools if tool in pipeline_tools]
    return {"include": _arch_tool_include(data, selected)}


def matrix_release(data: dict) -> dict:
    """Matrix using all hosted architectures × release-pipeline tools."""
    return {"include": _arch_tool_include(data, tools_for_pipeline(data, "release"), False)}


def matrix_release_for_tools(data: dict, tools: list[str]) -> dict:
    release_tools = set(tools_for_pipeline(data, "release"))
    selected = [tool for tool in tools if tool in release_tools]
    return {"include": _arch_tool_include(data, selected, False)}


def matrix_prefetch(data: dict, pipeline: str) -> dict:
    """Arch-independent tool list for HF cache pre-population."""
    tools = [t for t in tools_for_pipeline(data, pipeline) if t in MODEL_FIELDS]
    return {"include": [{"tool": t} for t in tools]}


def matrix_prefetch_for_tools(data: dict, tools: list[str], pipeline: str) -> dict:
    pipeline_tools = set(tools_for_pipeline(data, pipeline))
    selected = [tool for tool in tools if tool in pipeline_tools and tool in MODEL_FIELDS]
    return {"include": [{"tool": t} for t in selected]}


def brew_deps(data: dict, pipeline: str) -> list[str]:
    deps = {"cmake"}
    for tool in tools_for_pipeline(data, pipeline):
        deps.update(data["tools"][tool].get("depends_on", []))
    return sorted(deps)


def repo_to_tools(data: dict) -> dict[str, list[str]]:
    by_repo: dict[str, list[str]] = {}
    for tool_name, tool in data["tools"].items():
        repo = tool.get("repo")
        if repo:
            by_repo.setdefault(repo, []).append(tool_name)
    return by_repo


def app_tools(data: dict) -> list[str]:
    return [name for name, tool in data["tools"].items() if tool.get("repo") != "ggml"]


def read_manifest_at_ref(ref: str) -> dict:
    try:
        raw = subprocess.check_output(
            ["git", "show", f"{ref}:manifest.json"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        sys.exit(f"cannot read {ref}:manifest.json")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.exit(f"cannot parse {ref}:manifest.json: {exc}")
    _validate_manifest(data, allow_legacy_app_forks=True)
    return data


def _repo_change_affects_build(old_repo: dict, new_repo: dict, repo_name: str) -> bool:
    if repo_name == "ggml":
        keys = ("upstream_url", "upstream_ref", "url", "branch")
    else:
        keys = ("upstream_url", "upstream_ref", "ggml_path", "patches")
    return any(old_repo.get(key) != new_repo.get(key) for key in keys)


def affected_tools(data: dict, base_ref: str, pipeline: str | None = None) -> list[str]:
    old = read_manifest_at_ref(base_ref)
    by_repo = repo_to_tools(data)
    changed: list[str] = []
    all_repo_names = list(dict.fromkeys([*old.get("repos", {}), *data.get("repos", {})]))

    for repo_name in all_repo_names:
        old_repo = old.get("repos", {}).get(repo_name, {})
        new_repo = data.get("repos", {}).get(repo_name, {})
        if not _repo_change_affects_build(old_repo, new_repo, repo_name):
            continue
        if repo_name == "ggml":
            changed.extend(by_repo.get("ggml", []))
            changed.extend(app_tools(data))
        else:
            changed.extend(by_repo.get(repo_name, []))

    all_tool_names = list(dict.fromkeys([*old.get("tools", {}), *data.get("tools", {})]))
    for tool_name in all_tool_names:
        if old.get("tools", {}).get(tool_name) != data.get("tools", {}).get(tool_name):
            changed.append(tool_name)

    pipeline_tools = set(tools_for_pipeline(data, pipeline)) if pipeline else None
    result = []
    seen = set()
    for tool in changed:
        if tool in seen or tool not in data.get("tools", {}):
            continue
        if pipeline_tools is not None and tool not in pipeline_tools:
            continue
        result.append(tool)
        seen.add(tool)
    return result


def resolve_dotted(data: dict, key: str):
    cur = data
    for part in key.split("."):
        if part.endswith("]"):
            base, idx = part[:-1].split("[")
            cur = cur[base][int(idx)]
        else:
            cur = cur[part]
    return cur


def fmt_scalar(val) -> str:
    """Render a manifest leaf for shell consumption."""
    if val is None:
        return ""
    if isinstance(val, bool):
        return "1" if val else "0"
    if isinstance(val, list):
        return " ".join(str(v) for v in val)
    if isinstance(val, dict):
        return json.dumps(val)
    return str(val)


def model_row(tool: str, entry: dict) -> str:
    fields = MODEL_FIELDS[tool]
    parts = []
    for field in fields:
        val = entry.get(field, "")
        if isinstance(val, bool):
            parts.append("1" if val else "0")
        else:
            s = str(val)
            if "\t" in s:
                sys.exit(f"model field '{field}' contains TAB in tool '{tool}': {s!r}")
            parts.append(s)
    return "\t".join(parts)


def emit_models(data: dict, tool: str, tier: str) -> None:
    if tool not in data["tools"]:
        sys.exit(f"unknown tool: {tool}")
    if tier not in ("smoke", "full"):
        sys.exit(f"unknown tier: {tier} (expected smoke|full)")
    if tool not in MODEL_FIELDS:
        sys.exit(f"tool '{tool}' has no MODEL_FIELDS definition in manifest_cli.py")
    models = data["tools"][tool].get("models", {}).get(tier, [])
    for entry in models:
        print(model_row(tool, entry))


def resolve_quant_tokens(tier: str, tpl: str) -> str:
    """Expand {quant} and {llm_quant} placeholders (mirrors validate script defaults)."""
    quant = os.environ.get("QUANT", "Q8_0")
    llm_quant = os.environ.get("LLM_QUANT", "Q4_0" if tier == "smoke" else "Q8_0")
    return tpl.replace("{quant}", quant).replace("{llm_quant}", llm_quant)


def _hf_pairs_for_entry(tool: str, tier: str, entry: dict) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    if tool == "whisper-cpp":
        model_id = entry["id"]
        pairs.append((WHISPER_HF_REPO, f"ggml-{model_id}.bin"))
    elif tool in ("llama-cpp", "parakeet-cpp", "crispasr"):
        pairs.append((entry["repo"], entry["file"]))
    elif tool == "acestep-cpp":
        repo = entry["repo"]
        for key in ("lm", "enc", "dit", "vae"):
            pairs.append((repo, entry[key]))
    elif tool == "omnivoice-cpp":
        repo = entry["repo"]
        pairs.append((repo, entry["model_file"]))
        pairs.append((repo, entry["codec_file"]))
    elif tool == "stable-diffusion-cpp":
        repo = entry["repo"]
        pairs.append((repo, resolve_quant_tokens(tier, entry["file_tpl"])))
        for enc in entry.get("encoders", []):
            enc_repo = enc.get("repo", repo)
            pairs.append((enc_repo, resolve_quant_tokens(tier, enc["file"])))
    else:
        sys.exit(f"tool '{tool}' has no hf_files mapping in manifest_cli.py")
    return pairs


def _dedupe_pairs(pairs: list[tuple[str, str]]) -> list[tuple[str, str]]:
    seen: set[tuple[str, str]] = set()
    out: list[tuple[str, str]] = []
    for repo, pattern in pairs:
        key = (repo, pattern)
        if key in seen:
            continue
        seen.add(key)
        out.append(key)
    return out


def hf_files(data: dict, tool: str, tier: str) -> list[tuple[str, str]]:
    if tool not in data["tools"]:
        sys.exit(f"unknown tool: {tool}")
    if tier not in ("smoke", "full"):
        sys.exit(f"unknown tier: {tier} (expected smoke|full)")
    if tool not in MODEL_FIELDS:
        return []
    pairs: list[tuple[str, str]] = []
    for entry in data["tools"][tool].get("models", {}).get(tier, []):
        pairs.extend(_hf_pairs_for_entry(tool, tier, entry))
    return _dedupe_pairs(pairs)


def model_encoders(data: dict, tool: str, tier: str, model_name: str) -> list[tuple[str, str, str]]:
    if tool not in data["tools"]:
        sys.exit(f"unknown tool: {tool}")
    if tier not in ("smoke", "full"):
        sys.exit(f"unknown tier: {tier} (expected smoke|full)")
    for entry in data["tools"][tool].get("models", {}).get(tier, []):
        if entry.get("name") != model_name:
            continue
        repo = entry["repo"]
        rows: list[tuple[str, str, str]] = []
        for enc in entry.get("encoders", []):
            flag = enc["flag"]
            enc_repo = enc.get("repo", repo)
            enc_file = resolve_quant_tokens(tier, enc["file"])
            rows.append((flag, enc_repo, enc_file))
        return rows
    return []


def emit_hf_files(data: dict, tool: str, tier: str) -> None:
    for repo, pattern in hf_files(data, tool, tier):
        if "\t" in repo or "\t" in pattern:
            sys.exit(f"HF file field contains TAB in tool '{tool}': {repo!r} / {pattern!r}")
        print(f"{repo}\t{pattern}")


def emit_model_encoders(data: dict, tool: str, tier: str, model_name: str) -> None:
    for flag, repo, enc_file in model_encoders(data, tool, tier, model_name):
        for val in (flag, repo, enc_file):
            if "\t" in val:
                sys.exit(f"encoder field contains TAB in tool '{tool}': {val!r}")
        print(f"{flag}\t{repo}\t{enc_file}")


def main() -> None:
    data = load()
    argv = sys.argv[1:]
    if not argv:
        sys.exit("usage: manifest_cli.py <command> [args...]")

    cmd = argv[0]

    if cmd == "matrix":
        if len(argv) < 2:
            sys.exit(
                "usage: manifest_cli.py matrix "
                "<unit|build|integration|performance|release|prefetch> [--affected --base-ref REF]"
            )
        pipeline = argv[1]
        affected = "--affected" in argv[2:]
        base_ref = None
        if "--base-ref" in argv[2:]:
            idx = argv.index("--base-ref")
            if idx + 1 >= len(argv):
                sys.exit("--base-ref requires a value")
            base_ref = argv[idx + 1]
        if affected:
            if not base_ref:
                sys.exit("--affected requires --base-ref REF")
            tools = affected_tools(data, base_ref, pipeline)
            if pipeline == "release":
                obj = matrix_release_for_tools(data, tools)
            elif pipeline == "prefetch":
                obj = matrix_prefetch_for_tools(data, tools, "build")
            else:
                obj = matrix_arch_tool_for_tools(data, tools, pipeline)
        else:
            if pipeline == "release":
                obj = matrix_release(data)
            elif pipeline == "prefetch":
                obj = matrix_prefetch(data, "build")
            else:
                obj = matrix_arch_tool(data, pipeline)
        print(json.dumps(obj, separators=(",", ":")))

    elif cmd == "repos":
        print("\n".join(data["repos"].keys()))

    elif cmd == "tools":
        print("\n".join(data["tools"].keys()))

    elif cmd == "brew-deps":
        if len(argv) < 2:
            sys.exit("usage: manifest_cli.py brew-deps <pipeline>")
        print(" ".join(brew_deps(data, argv[1])))

    elif cmd == "get":
        if len(argv) < 2:
            sys.exit("usage: manifest_cli.py get <dotted.key>")
        val = resolve_dotted(data, argv[1])
        print(json.dumps(val) if isinstance(val, (dict, list)) else val)

    elif cmd == "repo-field":
        if len(argv) < 3:
            sys.exit("usage: manifest_cli.py repo-field <repo> <field>")
        repo, field = argv[1], argv[2]
        if repo not in data["repos"]:
            sys.exit(f"unknown repo: {repo}")
        print(fmt_scalar(data["repos"][repo].get(field)))

    elif cmd == "tool-field":
        if len(argv) < 3:
            sys.exit("usage: manifest_cli.py tool-field <tool> <field>")
        tool, field = argv[1], argv[2]
        if tool not in data["tools"]:
            sys.exit(f"unknown tool: {tool}")
        print(fmt_scalar(data["tools"][tool].get(field)))

    elif cmd == "models":
        if len(argv) < 3:
            sys.exit("usage: manifest_cli.py models <tool> <smoke|full>")
        emit_models(data, argv[1], argv[2])

    elif cmd == "hf-files":
        if len(argv) < 3:
            sys.exit("usage: manifest_cli.py hf-files <tool> <smoke|full>")
        emit_hf_files(data, argv[1], argv[2])

    elif cmd == "model-encoders":
        if len(argv) < 4:
            sys.exit("usage: manifest_cli.py model-encoders <tool> <smoke|full> <model_name>")
        emit_model_encoders(data, argv[1], argv[2], argv[3])

    elif cmd == "upstream-ref":
        if len(argv) < 2:
            sys.exit("usage: manifest_cli.py upstream-ref <repo>")
        repo = argv[1]
        if repo not in data["repos"]:
            sys.exit(f"unknown repo: {repo}")
        print(data["repos"][repo].get("upstream_ref", ""))

    elif cmd == "affected-tools":
        if "--base-ref" not in argv:
            sys.exit("usage: manifest_cli.py affected-tools --base-ref REF [pipeline]")
        idx = argv.index("--base-ref")
        if idx + 1 >= len(argv):
            sys.exit("--base-ref requires a value")
        base_ref = argv[idx + 1]
        pipeline = None
        positional = []
        skip = False
        for arg in argv[1:]:
            if skip:
                skip = False
                continue
            if arg == "--base-ref":
                skip = True
                continue
            positional.append(arg)
        if positional:
            pipeline = positional[0]
        print("\n".join(affected_tools(data, base_ref, pipeline)))

    elif cmd == "repo-patches":
        if len(argv) < 2:
            sys.exit("usage: manifest_cli.py repo-patches <repo>")
        repo = argv[1]
        if repo not in data["repos"]:
            sys.exit(f"unknown repo: {repo}")
        patches = data["repos"][repo].get("patches", [])
        for patch_path in patches:
            print(patch_path)

    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
