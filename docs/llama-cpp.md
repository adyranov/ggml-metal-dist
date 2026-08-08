# 🦙 llama-cpp (Metal)

Metal-enabled [llama.cpp](https://github.com/ggml-org/llama.cpp) built from the pinned upstream ref with **embedded patched ggml** from the ggml fork (not the Homebrew `ggml` formula).

## 📦 Shipped binaries

`llama`, `llama-cli`, `llama-completion`, `llama-server`, `llama-bench`,
`llama-quantize`, `llama-gguf-split`, `llama-mtmd-cli`, `llama-imatrix`,
`llama-perplexity`, `llama-tokenize`, `llama-tts`, `llama-export-lora`,
`llama-cvector-generator`, `llama-batched-bench`, `llama-fit-params`,
`llama-results`, `llama-debug-template-parser`, `llama-template-analysis`

## 🧱 Runtime dependencies

- **Embedded**: patched ggml is statically linked into the shipped tools
- **`openssl@3`**: HTTPS for `llama-server` (declared as `depends_on`, not bundled)

## 🧪 Validation

```sh
./scripts/dist.sh validate llama-cpp                      # smoke (default)
./scripts/dist.sh validate llama-cpp --full
./scripts/dist.sh validate llama-cpp --full --bin-dir /path/to/bin --no-build
./scripts/dist.sh validate llama-cpp --type performance --bin-dir /path/to/bin --no-build > bench.txt
```

Smoke: Qwen3-0.6B Q4_K_M, chat mode, checks output contains "Paris". Full: Qwen3.5-9B, Gemma-4-12B-it, and DeepSeek-Coder-V2-Lite (the sparse-MoE representative). Benchmark: `llama-bench` pp512/tg128 t/s per full-tier model.

## 🍺 Homebrew

```sh
brew install adyranov/tap/llama-cpp
```

Conflicts with official `llama.cpp` (`conflicts_with` + overlapping binaries).
Drop-in replacement: same command names (`llama-cli`, etc.).
