# 📚 Documentation

Central docs for the Metal-enabled ggml patch and the tools built from it. Agent rules for this tree: [`AGENTS.md`](AGENTS.md).

## 📑 Index

| Document | Description |
| --- | --- |
| [ggml-metal-patch.md](ggml-metal-patch.md) | 🧩 The ggml Metal patch: changes, env knobs, upstream tracking |
| [llama-cpp.md](llama-cpp.md) | 🦙 llama-cpp build targets, validation, Homebrew install |
| [whisper-cpp.md](whisper-cpp.md) | 🎤 whisper-cpp build targets, SDL2 dependency, validation |
| [stable-diffusion-cpp.md](stable-diffusion-cpp.md) | 🎨 stable-diffusion-cpp build targets and validation |

| [crispasr.md](crispasr.md) | 🎙️ CrispASR unified ASR CLI, validation, ggml injection |
| [transcribe-cpp.md](transcribe-cpp.md) | 🎙️ transcribe.cpp multi-model ASR, validation, ggml injection |
| [acestep-cpp.md](acestep-cpp.md) | 🎵 acestep.cpp music generation, validation, custom ggml ops |
| [omnivoice-cpp.md](omnivoice-cpp.md) | 🗣️ omnivoice.cpp TTS / voice cloning, validation |
| [release-process.md](release-process.md) | 🏷️ Versioning, CI workflows, cutting a release |

## 🚀 Quick start

> Just want the binaries? See [**Install (end users)**](../README.md#-install-end-users) in the main README. This section is for building and validating from source.

```sh
git clone https://github.com/adyranov/ggml-metal-dist.git
cd ggml-metal-dist

# Smoke all tools by default (builds from manifest refs and reconciles ggml locally)
./scripts/dist.sh validate

# Wipe work dir and rebuild from scratch; --verbose streams full sub-command output
./scripts/dist.sh validate llama-cpp --clean --verbose

# Full validation on your Mac against a built tarball (single tool)
VERSION=v26.6.0
./scripts/dist.sh build llama-cpp --arch "$(uname -m)" --version "$VERSION"
mkdir -p /tmp/llama-stage
tar -xzf "artifacts/llama-cpp-${VERSION}-$(uname -m)-apple-darwin.tar.gz" -C /tmp/llama-stage
./scripts/dist.sh validate llama-cpp --full --bin-dir /tmp/llama-stage/bin --no-build

# Performance: summary table on stdout (redirect to save or paste into a commit)
./scripts/dist.sh validate llama-cpp --type performance --bin-dir /tmp/llama-stage/bin --no-build > bench.txt
```

Nothing in this repo assumes sibling checkouts of ggml, llama.cpp, etc.

Model downloads use the Hugging Face hub cache. Override with `HF_HOME`, `HF_HUB_CACHE`
(or `HUGGINGFACE_HUB_CACHE`), and `HF_TOKEN` for gated repos. Validation logs cache
location and download progress automatically.
