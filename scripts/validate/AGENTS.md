# AGENTS.md — scripts/validate/

Per-tool validation harness. Invoked via [`../dist.sh`](../dist.sh) `validate`.

## Tiers

- **Smoke** (default): tiny models, fast runs, minimal op checks.
- **Full** (`--full`): larger models and deeper checks (no benchmarking).
- **Performance** (`--type performance`): performance capture only; uses the full model set.

## Benchmark

- Invoked via `--type performance` on [`../dist.sh`](../dist.sh); per-tool `bench_*` functions dispatch from the validate script CLI arguments.
- Use `bench_reset` / `bench_row` / `bench_emit` from [`../lib.sh`](../lib.sh); capture command output with `run_capture`.
- Summary table goes to **stdout** (commit-ready block); phases and warnings stay on **stderr**.
- Benchmark failures log a warning and record `n/a`; they do not fail fast like validation.

## Manifest-driven models

- Model lists come from `manifest.json` via `manifest_models "$TOOL" "$TIER"` — never hardcode repos, files, or steps in shell.
- Add or change models under `tools.<name>.models.smoke` / `tools.<name>.models.full` in the manifest.

## Hugging Face

- Use `hf_fetch` from [`../lib.sh`](../lib.sh).
- Respect `HF_HOME`, `HF_HUB_CACHE` (or `HUGGINGFACE_HUB_CACHE`), and `HF_TOKEN` for gated repos.
- Cache hits, downloads, and file sizes go to stderr via `detail` (visible with `--verbose`).
- Large HF downloads print a `==> hf | downloading …` line and stream progress; re-runs reuse cached snapshots when present.

## Harness conventions

- Use `phase` for section headers, `detail` for verbose-only progress, `check` for simple pass/fail commands, and `harness_record` / `harness_summary` from `lib.sh`.
- Fail fast: the first `harness_record fail` or `check` failure prints the summary and exits; all-mode stops on the first tool.
- Default output shows colored phase headers with emojis when stderr is a TTY; pass `--verbose` for `▶ cmd` lines, indented output, and `── section ──` markers.
- Set `NO_COLOR=1` to disable ANSI colors; `NO_EMOJI=1` to disable icons.
- Op-correctness for ggml lives in [`ggml.sh`](ggml.sh) — do not duplicate per dependent tool.

## Work directory

- Clones and builds live in `scripts/validate/work/<tool>` (gitignored).
- Re-runs reuse the existing checkout and do an incremental rebuild (idempotent).
- `--clean` removes the work dir for the tool and starts from scratch.
- SD output ONGs go to `scripts/validate/out/` (also gitignored).

## Smoke must stay small

- Prefer sub-GB downloads, low token/step counts, and skip heavy op suites in smoke tier.
