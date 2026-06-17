# 🎙️ CrispASR (Metal)

Metal-enabled [CrispASR](https://github.com/CrispStrobe/CrispASR) — a whisper.cpp fork that unifies 28+ ASR backends in one `crispasr` CLI, with embedded patched ggml.

## 📦 Shipped binaries

| Binary | Purpose |
| --- | --- |
| `crispasr` | Unified ASR CLI (whisper, parakeet, canary, cohere, qwen3, …) |
| `crispasr-quantize` | Model-agnostic GGUF re-quantization |

Server mode, streaming (`--mic`), and `crispasr-diff` are not in the release package yet.

## 🧱 Runtime dependencies

No Homebrew runtime dependencies. Models are GGUF files fetched from Hugging Face during validation.

The manifest uses the default `ggml_path` (`ggml`), so source prep replaces CrispASR's vendored ggml with this distribution's reconciled Metal-on-Intel fork before build. CrispASR-specific gaps are handled with app patches under `patches/crispasr/` (API compat shims, IndexTTS vocoder AA path) — not by forking ggml per tool.

**Note:** CrispASR ships a customized ggml tree upstream. If a future release depends on new ggml APIs, add compat shims or refresh patches under `patches/crispasr/` — see [ggml-metal-patch.md](ggml-metal-patch.md).

## 🧪 Validation

```sh
./scripts/dist.sh validate crispasr            # smoke: whisper-tiny.en + parakeet 110M on samples/jfk.wav
./scripts/dist.sh validate crispasr --full     # + base.en, parakeet 0.6b-v3, cohere, qwen3-asr
```

Smoke uses `samples/jfk.wav` from the cloned source tree (or set `SAMPLE=`). Pass criterion: transcript contains `country`, `fellow`, and `americans` (case-insensitive).

## 🍺 Homebrew

```sh
brew install adyranov/tap/crispasr
```

(Available after the first release that includes this tool.)
