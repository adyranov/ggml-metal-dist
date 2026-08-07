# AGENTS.md — .github/workflows/

GitHub Actions workflows for lint, validate, build, and release.

## Naming convention

- **`_` prefix** (e.g. `_validate.yml`): Reusable building blocks (`workflow_call` only).
- **No prefix** (e.g. `ci.yml`, `release.yml`): Trigger workflows that run on events (push, PR, dispatch).

## Security

- Pin actions to full SHA with a `# vX.Y.Z` comment.
- Top-level `permissions: contents: read` (elevate per-job only when needed).
- Pass `${{ }}` expressions via `env:`, never inline in `run:`.
- `persist-credentials: false` on checkout where applicable.

## Manifest-driven matrices

- Do not hand-edit tool/arch matrices.
- Generate through `scripts/dist.sh` plan commands after `jdx/mise-action`; `dist.sh` owns matrix and scope decisions.

## Caching

- Cache Homebrew downloads, pip, ccache, and Hugging Face models where workflows build or validate.
- Key caches on `manifest.json` hash (and tool/arch where relevant).
- Unit type: brew + ccache only (no model downloads).
- Build/integration/performance: all caches (brew, pip, ccache, HF models).
- HF models: `_prefetch.yml` (Ubuntu) downloads once per tool; macOS `_validate.yml` jobs restore the same key (`hf-models-${tier}-${tool}-${manifest_hash}`). Use `enableCrossOsArchive: true` on prefetch save and validate restore; validate restore is exact-key only (`fail-on-cache-miss: true`, no `restore-keys`). `actions/cache/*` uses the runner-injected `ACTIONS_RUNTIME_TOKEN`, not `GITHUB_TOKEN` `actions` scope — keep reusable workflows at `contents: read` only.

## Validation scope

- **`_prefetch.yml`**: Ubuntu job that runs `dist.sh prefetch` per tool (arch-independent matrix) and saves the HF cache.
- **`_validate.yml`**: Thin reusable workflow parameterized by a precomputed manifest matrix, `type`, and `tier`. Restores HF cache populated by `_prefetch.yml`, verifies files are present (`verify-hf-cache`), then builds/validates.
- **`ci.yml`**: PR/manual gate. Plans scope, prefetches models, reconciles ggml, and calls `_validate.yml`.
- **`release.yml`**: Manual release. Plans the release, prefetches models, reconciles ggml, validates, builds matrix artifacts, and publishes.

## Homebrew speedups (macOS jobs)

- Set `HOMEBREW_NO_AUTO_UPDATE: "1"` and `HOMEBREW_NO_INSTALL_CLEANUP: "1"`.
- Suggest/install `ccache`; set `CCACHE_DIR`, `CCACHE_BASEDIR`, and CMake compiler launchers.

## Related external skill

For deeper CI prompt-injection and agentic-actions auditing, see [trailofbits/skills `agentic-actions-auditor`](https://github.com/trailofbits/skills/tree/main/plugins/agentic-actions-auditor) and [`differential-review`](https://github.com/trailofbits/skills/tree/main/plugins/differential-review) (CC-BY-SA-4.0). Links only — fetch on demand.
