# 🐦 parakeet-cpp (Metal)

Metal-enabled [parakeet.cpp](https://github.com/mudler/parakeet.cpp), a ggml-based C++ runtime for NVIDIA Parakeet ASR models.

## 📦 Shipped binaries

| Binary | Purpose |
| --- | --- |
| `parakeet-cli` | Inspect GGUF models, transcribe WAV files, quantize models, and run benchmark helpers |

The first integration packages the CLI only. Upstream `v0.2.0` does not define CMake install rules, so the release package copies the built `parakeet-cli` target directly.

## 🧱 Runtime dependencies

No Homebrew runtime dependencies are declared. Models are GGUF files fetched from Hugging Face during validation.

The manifest configures `ggml_path: third_party/ggml`, so source prep copies this distribution's reconciled ggml source into Parakeet before build. Metal is enabled via `-DPARAKEET_GGML_METAL=ON`.

## 🧪 Validation

```sh
./scripts/dist.sh validate parakeet-cpp
./scripts/dist.sh validate parakeet-cpp --full
```

Smoke validation downloads `tdt_ctc-110m-q4_k.gguf` from `mudler/parakeet-cpp-gguf`, runs:

```sh
parakeet-cli transcribe --model <model.gguf> --input tests/fixtures/speech.wav --decoder tdt
```

The transcript is normalized and compared with the expected LibriSpeech sentence from upstream's parity docs. Full validation currently uses the same 110M family at `q5_k`.
