# AGENTS.md — scripts/

Shell and Python helpers for build, release, validation, and integration.

## Shell

- `#!/usr/bin/env bash`, `set -euo pipefail`, 4-space indent.
- Source [`lib.sh`](lib.sh) for `die`/`log`/`need`/`phase`/`check`/`harness_*`/`bench_*`/`run_capture`.
- Format with shfmt: `-i 4 -ci -sr`.
- **Stdout/stderr**: diagnostics go to stderr via `log`/`phase`/`detail`; stdout is reserved for values returned through command substitution (e.g. `SRC_DIR=$(ensure_source_tree …)`) and for `--type performance` summary blocks from `bench_emit`. Never `printf` logs to stdout.
- Manifest reads funnel through [`manifest_cli.py`](manifest_cli.py) — do not parse `manifest.json` ad hoc in shell.
- `cmake_ccache_args` in [`lib.sh`](lib.sh) enables ccache when on `PATH` (`CCACHE_DIR` defaults to `.ccache/` at repo root).

## Python

- Stdlib only, typed, `from __future__ import annotations`.
- Formatted by ruff.
- [`manifest_cli.py`](manifest_cli.py) is the manifest query layer for CI and validation scripts.

## Indentation

Enforced by `editorconfig-checker`: shell/Python multiples of 4.

## Layout

| Path | Role |
| --- | --- |
| `dist.sh` | Public manifest-driven pipeline CLI |
| `lib.sh` | Shared helpers (clone, build, HF fetch, harness + benchmark presentation, ccache) |
| `validate/` | Per-tool harness scripts |
