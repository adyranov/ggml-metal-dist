# 🎨 stable-diffusion-cpp (Metal)

Metal-enabled [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) with embedded reconciled ggml copied into the app source tree.

## 📦 Shipped binaries

`sd-cli` (primary CLI for image generation)

## 🧪 Validation

```sh
./scripts/dist.sh validate stable-diffusion-cpp            # SDXS-512 single GGUF (~650 MB), 1 step
./scripts/dist.sh validate stable-diffusion-cpp --full    # Z-Image-Turbo + FLUX suite
./scripts/dist.sh validate stable-diffusion-cpp --type performance --bin-dir /path/to/bin --no-build > bench.txt
```

Downloads model weights via the Hugging Face CLI. Full validation is GPU-heavy
(1024×1024). FLUX.1-schnell is pinned to Q4_0 because its Q8_0 diffusion
weights plus the T5 encoder exceed the 16 GB target budget.

## 🍺 Homebrew

```sh
brew install adyranov/tap/stable-diffusion-cpp
```

No official homebrew-core counterpart.
