# 🗣️ omnivoice.cpp (Metal)

Metal-enabled [omnivoice.cpp](https://github.com/ServeurpersoCom/omnivoice.cpp) — a GGML-powered C++ port of OmniVoice for local text-to-speech and voice cloning, with a neural audio codec decoder.

## 📦 Shipped binaries

| Binary | Purpose |
| --- | --- |
| `omnivoice-tts` | Text → speech CLI (optional reference audio for voice cloning) |
| `omnivoice-codec` | Neural audio codec encode/decode (WAV ↔ tokens) |
| `tts-server` | HTTP server with embedded web UI |
| `quantize` | GGUF requantizer (BF16 → K-quants) |

## 🧱 Runtime dependencies

No Homebrew runtime dependencies. Models are GGUF files fetched from Hugging Face ([Serveurperso/OmniVoice-GGUF](https://huggingface.co/Serveurperso/OmniVoice-GGUF)): one TTS model file plus the codec/tokenizer file.

The manifest uses the default `ggml_path` (`ggml`), so source prep replaces the vendored `ServeurpersoCom/ggml` submodule with this distribution's reconciled Metal-on-Intel fork before build.

**Custom ggml ops:** the codec/DAC decoder relies on a fused `snake` activation and the `col2im_1d` transposed-convolution op. These (CPU + Metal kernels) live in the `adyranov/ggml` fork itself — not as per-tool patches — since they are shared with acestep.cpp's VAE and any other vocoder model. On Metal the `snake` chain is autofused and `col2im_1d` runs as a dedicated kernel, keeping codec decode resident on the GPU. The only app patch is a one-line CMake tweak that emits executables into `bin/`.

## 🧪 Validation

```sh
./scripts/dist.sh validate omnivoice-cpp            # smoke: base TTS (Q8_0) + Q8_0 codec
./scripts/dist.sh validate omnivoice-cpp --full     # base TTS (Q8_0) + F32 codec
```

Synthesis is non-deterministic, so the pass criterion is structural: `omnivoice-tts` writes a valid, non-trivial RIFF/WAVE file for the input text.

## 🍺 Homebrew

```sh
brew install adyranov/tap/omnivoice-cpp
```

(Available after the first release that includes this tool.)
