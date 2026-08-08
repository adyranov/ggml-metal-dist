# 🚀 GGML Metal for macOS — GPU-accelerated AI/ML tools

**Metal (GPU) builds of popular `ggml`/`llama.cpp`-family AI tools for macOS.** A self-contained build, validation, and release pipeline that ships GPU-accelerated binaries for **local LLM inference, speech-to-text (ASR), text-to-speech (TTS) / voice cloning, image generation, and music generation** — all running on Apple's Metal backend instead of CPU.

Targets the broad Mac GPU range: **Apple Silicon (M-series)** and **Intel Macs with AMD Radeon discrete GPUs (including RDNA / RDNA2)**. Where upstream Metal support assumes Apple Silicon, the patched ggml fork aims to restore Metal on Intel + AMD Macs. All validation is best-effort and can't cover every GPU model.

**Self-contained:** clone this repo alone to build, validate, or cut releases. Upstream refs, the patched ggml fork, compatibility patches, and build flags live in [`manifest.json`](manifest.json).

## 📦 Repositories

This repo orchestrates Metal builds of these upstream projects (each pinned by `upstream_ref` in [`manifest.json`](manifest.json)):

| Repo | Role |
| --- | --- |
| [adyranov/ggml](https://github.com/adyranov/ggml) | Metal patch (`metal-intel-mac`), code only |
| [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | LLM inference (`llama-cpp`) |
| [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Speech-to-text / ASR (`whisper-cpp`) |
| [leejet/stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) | Image generation (`stable-diffusion-cpp`) |
| [CrispStrobe/CrispASR](https://github.com/CrispStrobe/CrispASR) | Unified multi-backend ASR CLI (`crispasr`) |
| [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) | Multi-model speech-to-text (`transcribe-cpp`) |
| [ServeurpersoCom/acestep.cpp](https://github.com/ServeurpersoCom/acestep.cpp) | Music generation (`acestep-cpp`) |
| [ServeurpersoCom/omnivoice.cpp](https://github.com/ServeurpersoCom/omnivoice.cpp) | Text-to-speech / voice cloning (`omnivoice-cpp`) |

App compatibility patches live under `patches/<app>/`. The patched ggml fork internals are documented in [`docs/ggml-metal-patch.md`](docs/ggml-metal-patch.md).

## 📥 Install (end users)

Prebuilt, Metal-enabled binaries are published as [GitHub Release](https://github.com/adyranov/ggml-metal-dist/releases) assets after each release. Requires **macOS 15 (Sequoia) or newer**.

```sh
brew tap adyranov/tap
brew install adyranov/tap/llama-cpp              # llama.cpp
brew install adyranov/tap/whisper-cpp            # whisper.cpp (needs sdl2)
brew install adyranov/tap/stable-diffusion-cpp   # stable-diffusion.cpp
brew install adyranov/tap/crispasr               # CrispASR
brew install adyranov/tap/transcribe-cpp         # transcribe.cpp (multi-model ASR)
brew install adyranov/tap/acestep-cpp            # acestep.cpp (music generation)
brew install adyranov/tap/omnivoice-cpp          # omnivoice.cpp (TTS / voice cloning)
```

Per-tool details: [llama-cpp](docs/llama-cpp.md) · [whisper-cpp](docs/whisper-cpp.md) · [stable-diffusion-cpp](docs/stable-diffusion-cpp.md) · [crispasr](docs/crispasr.md) · [transcribe-cpp](docs/transcribe-cpp.md) · [acestep-cpp](docs/acestep-cpp.md) · [omnivoice-cpp](docs/omnivoice-cpp.md).

## 🖥️ GPU compatibility & validation

Two Mac GPU families are targeted:

- **Apple Silicon (arm64)** — M-series unified-memory GPUs. The default, fully upstream-supported Metal path.
- **Intel Macs (x86_64) with AMD Radeon discrete GPUs** — RDNA2-class GPUs such as the Mac Pro (2019) MPX modules (Radeon Pro W6800X / W6800X Duo / W6900X) and eGPU / desktop Radeon RX 6000 cards (RX 6800, RX 6800 XT, RX 6900 XT, RX 6950 XT), as well as earlier RDNA and GCN Radeon Pro / RX parts. The `metal-intel-mac` ggml fork is meant to restore Metal acceleration that upstream gates behind Apple Silicon.

Validation builds each tool from its pinned upstream ref, runs a real inference workload on the GPU, and asserts the output (transcript text, generated image, or a valid audio WAV) — confirming the kernels actually execute on Metal rather than silently falling back to CPU.

All validation is best-effort and can't cover the full spectrum of Mac GPUs. Any given GPU model — Apple Silicon or Intel + AMD, and older or less common Radeon parts in particular — may not have been exercised directly: it may work, but isn't guaranteed.

## 🧰 Prerequisites (build & develop)

| Need it for | Install |
| --- | --- |
| Compiling (all tools) | Xcode Command Line Tools (`xcode-select --install`), CMake, Git |
| Build/runtime deps | [Homebrew](https://brew.sh) — `cmake`, `openssl@3` (llama), `sdl2` (whisper) |
| Running validation | Python 3, Hugging Face CLI — `pip install 'huggingface_hub[cli]'` |
| Linting (dev) | [pre-commit](https://pre-commit.com/) — `pip install pre-commit` |
| Runtime (any tool) | macOS 15 (Sequoia)+ |

Exact per-tool dependencies are declared in [`manifest.json`](manifest.json) and installed automatically in CI.

## 🚀 Quick start (developers)

```sh
# Smoke all tools by default (or pass a tool name for one)
./scripts/dist.sh validate

# Build release artifact (use the git tag you will push as VERSION)
VERSION=v26.6.0
./scripts/dist.sh build llama-cpp --arch "$(uname -m)" --version "$VERSION"
```

See `./scripts/dist.sh` (no args) for all subcommands: `plan-ci`, `plan-release`, `reconcile-ggml`, `prefetch`, `validate`, `build`, `publish-release`.

## 🏷️ Versioning

Releases use CalVer: **`vYY.M.BUILD`** (e.g. `v26.6.0`). Version numbers come from git tags only — they are not stored in `manifest.json`. Release CI is triggered manually via `workflow_dispatch`.

## 🧑‍💻 Developer setup

Install [pre-commit](https://pre-commit.com/) to run the same linters locally as CI:

```sh
pip install pre-commit
pre-commit install
pre-commit run --all-files   # optional: run all hooks once
```

Hooks cover shellcheck, shfmt, ruff, yamlfmt, yamllint, actionlint, gitleaks, typos, editorconfig-checker, and markdownlint.
[Renovate](https://docs.renovatebot.com/) bumps pre-commit hooks and GitHub Actions in grouped monthly PRs (see [`.github/renovate.json5`](.github/renovate.json5)).

## 📚 Documentation

See [`docs/README.md`](docs/README.md). AI agent rules: [`AGENTS.md`](AGENTS.md) (root) with nested files under `scripts/`, `docs/`, and `.github/workflows/`.
