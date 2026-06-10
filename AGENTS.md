# AGENTS.md

Guidance for AI agents working in **ggml-metal-dist**. Keep changes minimal, manifest-driven, and lint-clean.

## Overview

Self-contained build, validation, and release pipeline for Metal-enabled ggml tools on macOS (Intel + Apple Silicon, AMD Radeon, Intel integrated GPUs). This repo owns integration, CI, app compatibility patches, and docs; the ggml fork holds the Metal patch code.

[manifest.json](manifest.json) is the single source of truth — repos, pinned refs, build flags, and pipelines all live there.

## Project map

| Path                      | Purpose                                                                                              |
| ------------------------- | ---------------------------------------------------------------------------------------------------- |
| `manifest.json`           | SSOT: repos, `upstream_ref` tags, tools, cmake flags, pipelines                                       |
| `scripts/`                | `dist.sh` public pipeline CLI, `lib.sh`, `manifest_cli.py`, validation harnesses                     |
| `scripts/validate/`       | Per-tool smoke/full validation scripts                                                               |
| `scripts/manifest_cli.py` | Generates CI matrices from the manifest (typed, stdlib-only)                                         |
| `.github/workflows/`      | `lint`, `ci`, `release`; reusable: `_validate`                                                       |
| `docs/`                   | Patch internals, per-tool docs, release process                                                      |

## Commands

```sh
./scripts/dist.sh validate                  # smoke all tools from manifest
./scripts/dist.sh validate <tool>           # smoke single tool
./scripts/dist.sh validate <tool> --full    # full validation suite
./scripts/dist.sh build <tool> --arch $(uname -m) --version v26.6.0 # prebuilt tarball
python3 scripts/manifest_cli.py tools           # list tools
pre-commit run --all-files                   # run all linters (matches CI)
```

## Invariants

- **Manifest**: add or change tools by editing `manifest.json`, not workflows.
- **Versioning**: CalVer `vYY.M.BUILD` (e.g. `v26.6.0`) via git tags only — not in `manifest.json`. Manual `workflow_dispatch` triggers release CI.
- **Integration only**: do not edit upstream/vendored code from here; app changes must be manifest patches.
- **`upstream_ref` tags**: pinned to upstream release tags; Renovate opens PRs when new tags appear.
- **Secrets/artifacts**: never commit secrets, runner tokens, or build artifacts.
- **Linters**: never weaken hooks to pass; fix the underlying issue. Run `pre-commit run --all-files` before finishing.

## CLI tools

Use these modern replacements instead of legacy CLI tools for interactive/agent shell commands — they are faster with better defaults (respect `.gitignore`, colored/structured output). Pick the best tool for the task.

| Legacy              | Modern      | Notes                                        |
| ------------------- | ----------- | -------------------------------------------- |
| `grep`              | `rg`        | 10-100× faster, respects `.gitignore`        |
| `find`              | `fd`        | simpler syntax, ignores `.git/`              |
| `cat`/`less`        | `bat`       | syntax highlighting, paging                  |
| `ls`/`tree`         | `eza`       | git status, `eza --tree`                     |
| `sed`               | `sd`        | literal strings by default, no escaping hell |
| `sed`/`awk` on code | `ast-grep`  | structural (AST) search & rewrite            |
| `cut`/`awk` fields  | `choose`    | human-friendly field selection               |
| `diff` (git)        | `delta`     | syntax-highlighted, side-by-side             |
| `diff` (code)       | `difft`     | structural/AST diff (difftastic)             |
| `du`                | `dust`      | visual, sorted disk usage                    |
| `wc -l`/`cloc`      | `tokei`     | fast LOC/code stats                          |
| `ps`                | `procs`     | readable process listing                     |
| `curl`              | `xh`        | HTTPie-like, JSON auto-detect                |
| `tar`/`unzip`       | `ouch`      | one command for any archive                  |
| `xxd`/`hexdump`     | `hexyl`     | hex viewer for built binaries/tarballs       |
| `time`              | `hyperfine` | statistical benchmarking with warmup         |
| ad-hoc JSON/YAML    | `jq` / `yq` | query and edit JSON and YAML                 |

> **CI scripts** (`scripts/*.sh`, `.github/workflows/`) must still use POSIX tools (`grep`, `find`, `sed`) for portability — modern tools are for interactive/agent use only.
