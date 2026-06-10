# 🚀 GGML Metal for macOS

Build, validation, and release pipeline for Metal-enabled ggml tools on macOS — Intel + Apple Silicon, including AMD Radeon and Intel integrated GPUs.

**Self-contained:** clone this repo alone to build, validate, or cut releases. Upstream refs, the patched ggml fork, compatibility patches, and build flags live in [`manifest.json`](manifest.json).

## 📦 Repositories

| Repo                                                                              | Role                                       |
| --------------------------------------------------------------------------------- | ------------------------------------------ |
| [adyranov/ggml](https://github.com/adyranov/ggml)                                 | Metal patch (`metal-intel-mac`), code only |
| Upstream app repos                                                                | Build inputs pinned by `upstream_ref`      |
| `patches/<app>/`                                                                  | Local app compatibility patches            |
| **this repo**                                                                     | Integration, validation, CI, releases      |

## 📥 Install (end users)

Prebuilt, Metal-enabled binaries are published as GitHub Release assets after each release. Requires **macOS Sonoma (14) or newer**.

```sh
brew tap adyranov/tap
brew install adyranov/tap/llama-cpp          # llama.cpp
brew install adyranov/tap/whisper-cpp        # whisper.cpp (needs sdl2)
brew install adyranov/tap/stable-diffusion-cpp   # stable-diffusion.cpp
brew install adyranov/tap/parakeet-cpp       # parakeet.cpp
```

Per-tool details: [llama-cpp](docs/llama-cpp.md) · [whisper-cpp](docs/whisper-cpp.md) · [stable-diffusion-cpp](docs/stable-diffusion-cpp.md) · [parakeet-cpp](docs/parakeet-cpp.md).

## 🧰 Prerequisites (build & develop)

| Need it for             | Install                                                            |
| ----------------------- | ----------------------------------------------------------------- |
| Compiling (all tools)   | Xcode Command Line Tools (`xcode-select --install`), CMake, Git    |
| Build/runtime deps      | [Homebrew](https://brew.sh) — `cmake`, `openssl@3` (llama), `sdl2` (whisper) |
| Running validation      | Hugging Face CLI — `pip install 'huggingface_hub[cli]'`           |
| Runtime (any tool)      | macOS Sonoma (14)+                                                 |

Exact per-tool dependencies are declared in [`manifest.json`](manifest.json) and installed automatically in CI.

## 🚀 Quick start (developers)

```sh
# Smoke all tools by default (or pass a tool name for one)
./scripts/dist.sh validate

# Build release artifact (use the git tag you will push as VERSION)
VERSION=v26.6.0
./scripts/dist.sh build llama-cpp --arch "$(uname -m)" --version "$VERSION"


```

## 🧑‍💻 Developer setup

Install [pre-commit](https://pre-commit.com/) to run the same linters locally as CI:

```sh
pip install pre-commit
pre-commit install
pre-commit run --all-files   # optional: run all hooks once
```

Hooks cover shellcheck, shfmt, ruff, yamlfmt, yamllint, actionlint, zizmor, gitleaks, typos, editorconfig-checker, and markdownlint.
[Renovate](https://docs.renovatebot.com/) bumps pre-commit hooks and GitHub Actions in grouped monthly PRs (see [`.github/renovate.json5`](.github/renovate.json5)).

## 📚 Documentation

See [`docs/README.md`](docs/README.md). AI agent rules: [`AGENTS.md`](AGENTS.md) (root) with nested files under `scripts/`, `docs/`, and `.github/workflows/`.
