# 🎵 acestep.cpp (Metal)

Metal-enabled [acestep.cpp](https://github.com/ServeurpersoCom/acestep.cpp) — a GGML-powered C++ port of [ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5) for local AI music generation (describe a song, get stereo 48 kHz audio).

## 📦 Shipped binaries

| Binary | Purpose |
| --- | --- |
| `ace-synth` | DiT + VAE: render audio codes into a WAV/MP3 track |
| `ace-lm` | LLM inference: caption → lyrics + audio codes |
| `ace-server` | HTTP server with embedded web UI (LM + synth + understand) |
| `ace-understand` | Reverse pipeline: audio → metadata + lyrics + codes |
| `neural-codec` | Oobleck VAE codec (encode/decode WAV ↔ latent) |
| `mp3-codec` | Standalone MP3 encoder/decoder |
| `quantize` | GGUF requantizer (BF16 → K-quants) |

## 🧱 Runtime dependencies

No Homebrew runtime dependencies. The web UI is embedded at build time from a committed `index.html.gz`, so no Node/npm is needed. Models are GGUF files fetched from Hugging Face ([Serveurperso/ACE-Step-1.5-GGUF](https://huggingface.co/Serveurperso/ACE-Step-1.5-GGUF)); a full generation needs one of each: LM, text encoder (Qwen3-Embedding), DiT, and VAE.

The manifest uses the default `ggml_path` (`ggml`), so source prep replaces the vendored `ServeurpersoCom/ggml` submodule with this distribution's reconciled Metal-on-Intel fork before build.

**Custom ggml ops:** the Oobleck VAE relies on a fused `snake` activation and the `col2im_1d` transposed-convolution op. These (CPU + Metal kernels) live in the `adyranov/ggml` fork itself — not as per-tool patches — because they are shared by every vocoder/DAC model (see also omnivoice.cpp). On Metal the `snake` chain (`mul → sin → sqr → mul → add`) is autofused and `col2im_1d` runs as a dedicated kernel, keeping the VAE decode resident on the GPU. The only app patch is a one-line CMake tweak that emits executables into `bin/`.

## 🧪 Validation

```sh
./scripts/dist.sh validate acestep-cpp            # smoke: 0.6B LM + turbo DiT (Q4_K_M), 8 steps
./scripts/dist.sh validate acestep-cpp --full     # 4B LM + turbo DiT (Q8_0)
```

Generation is non-deterministic, so the pass criterion is structural: `ace-lm` produces an audio-codes JSON and `ace-synth` writes a valid, non-trivial RIFF/WAVE file.

**CI note:** both hosted archs are excluded from model validation (`exclude_test_archs`). GitHub-hosted macOS runners expose reduced/virtualized Metal feature sets that cannot be treated as physical Metal qualification. Release artifacts are still built for both architectures; full ACE-Step model validation belongs on a manually managed Metal host.

## 🍺 Homebrew

```sh
brew install adyranov/tap/acestep-cpp
```

(Available after the first release that includes this tool.)
