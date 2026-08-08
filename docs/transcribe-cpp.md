# 🎙️ transcribe.cpp (Metal)

Metal-enabled [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) — a C/C++ multi-model speech-to-text engine that runs diverse STT model families (Whisper, Parakeet, Canary, Qwen3-ASR, Cohere, …) from GGUF models on the ggml runtime, with an embedded patched ggml fork.

> **Supported.** `transcribe-cpp` ships in the release pipeline and installs via
> Homebrew after each release. Metal correctness is qualified on physical
> Intel + AMD Radeon hardware (see [Qualification record](#-qualification-record-u1-2026-08-07)).
> [CrispASR](crispasr.md) remains a supported ASR tool.

## 📦 Shipped binaries

| Binary | Purpose |
| --- | --- |
| `transcribe-cli` | Multi-family ASR CLI (`-m model.gguf audio.wav`) |

The quantize tool (`transcribe-quantize`) and server/streaming entry points are not in the release package yet.

## 🧱 Runtime dependencies

No Homebrew runtime dependencies. Models are GGUF files fetched from Hugging Face under the [`handy-computer`](https://huggingface.co/handy-computer) org during validation.

The manifest uses the default `ggml_path` (`ggml`): transcribe.cpp vendors ggml as a tracked subtree at `ggml/` (see `ggml/UPSTREAM`), so source prep replaces it with this distribution's reconciled Metal-on-Intel fork before build.

**Note:** transcribe.cpp vendors ggml v0.15.2 while the injected fork is pinned at `v0.18.1` — a three-minor-version gap. The pinned v0.1.3 source builds and links against the injected fork with **no compat patch** (patch count: 0), so `patches/transcribe-cpp/` is not needed yet. If a future refresh depends on new ggml APIs, add compat shims under `patches/transcribe-cpp/` — see [ggml-metal-patch.md](ggml-metal-patch.md).

## 🧪 Validation

```sh
./scripts/dist.sh validate transcribe-cpp            # smoke: whisper-tiny.en + parakeet 110m on samples/jfk.wav
./scripts/dist.sh validate transcribe-cpp --full     # + whisper-small.en, parakeet-tdt-0.6b-v2, cohere-transcribe-03-2026, qwen3-asr-1.7b
```

Smoke uses `samples/jfk.wav` from the cloned source tree (or set `SAMPLE=`). Every run forces `--backend metal` and asserts the effective backend is Metal — the CLI's canonical device label `backend: MTL0` — plus a transcript containing `country`, `fellow`, and `americans` (case-insensitive), confirming the kernels execute on Metal rather than silently falling back to CPU.

## 🎯 Full-tier fixtures and rationale

The full tier adds two fixtures alongside the qualified Whisper and Parakeet models:

- `cohere-transcribe-03-2026` (`handy-computer/cohere-transcribe-03-2026-gguf`, `cohere-transcribe-03-2026-Q8_0.gguf`, ~2.4 GB) — the audited English quality candidate.
- `qwen3-asr-1.7b` (`handy-computer/qwen3-asr-1.7b-gguf`, `qwen3-asr-1.7b-Q8_0.gguf`, ~2.1 GB) — the multilingual candidate.

Both fit the target GPU memory budget alongside the existing full-tier models. These fixtures assert only the transcript on `samples/jfk.wav`; no timestamps, streaming, or diarization claims are made by them.

## 🧾 Qualification record (U1, 2026-08-07)

**Status: promoted to supported release status.** Intel + AMD Radeon physical Metal qualification **passes** and is sufficient per the approved gate (Apple Silicon is not required). CrispASR remains a supported ASR tool and will be evaluated at the Phase 2 retirement gate.

The qualified record covers the existing Whisper + Parakeet model set (smoke `whisper-tiny.en` / `parakeet-tdt_ctc-110m`, full `whisper-small.en` / `parakeet-tdt-0.6b-v2`). `cohere-transcribe-03-2026` and `qwen3-asr-1.7b` are newly added full-tier fixtures; they are **not** part of this qualification record and are pending physical Intel + AMD Metal runs.

- **Refs:** `handy-computer/transcribe.cpp` `v0.1.3` (`a94e021`); injected `adyranov/ggml` `release/0.18.1` (`af8e8534`).
- **Build:** passes with `TRANSCRIBE_METAL=ON` against the injected fork; `transcribe-cli` links with Metal + CPU backends. Compat patches: **0**.
- **Models (SHA-256 of the validated files):**
  - smoke — `handy-computer/whisper-tiny.en-gguf` `whisper-tiny.en-Q8_0.gguf` (44 MB): `e8c9b73c06344307d8b346e07fbe93dd88d894627854bcff31523f1ce44394fa`
  - smoke — `handy-computer/parakeet-tdt_ctc-110m-gguf` `parakeet-tdt_ctc-110m-Q8_0.gguf` (135 MB): `7dd44c74a331d788a4e5f8b16913b3feb29ced22cf5613aad0e0f6cd30516296`
  - full — `handy-computer/whisper-small.en-gguf` `whisper-small.en-Q8_0.gguf`: `9614e6b7fda2d26018e4f268aece8ca25a83296ea0b534169a585b740bfd71ef`
  - full — `handy-computer/parakeet-tdt-0.6b-v2-gguf` `parakeet-tdt-0.6b-v2-Q8_0.gguf`: `f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa`
  - pending full — `handy-computer/cohere-transcribe-03-2026-gguf` `cohere-transcribe-03-2026-Q8_0.gguf`: `931916663432fd895423a4291a8400221802b288967ca2d435fc5e3141c9e71e`
  - pending full — `handy-computer/qwen3-asr-1.7b-gguf` `Qwen3-ASR-1.7B-Q8_0.gguf`: `9a0d81792dfea2d5f278b8a63deb3ea6e02139ce42c2301f32ea19c4f77526b7`
  - All resolve via the manifest Hugging Face mappings.
- **CPU smoke:** both smoke models transcribe `jfk.wav` with the asserted transcript (`And so my fellow Americans ask not what your country can do for you …`).
- **Intel + AMD Radeon physical run (PASS):**
  - **Host/GPU:** Intel x86_64 host with discrete AMD Radeon GPU; integrated GPU not exercised.
  - **Software:** macOS 26.6, x86_64, Metal 3.
  - **Backend evidence:** the harness forces `--backend metal` and asserts the effective backend is the canonical Metal device label `backend: MTL0`; the passing transcript assertion therefore confirms kernels ran on Metal rather than a CPU/Vulkan fallback.
  - **Command:** `./scripts/dist.sh validate transcribe-cpp --full --verbose 2>&1 | tee /tmp/transcribe-cpp-full.log` (sample `samples/jfk.wav`).
  - **Result:** PASS — smoke tier `whisper-tiny.en` and `parakeet-tdt_ctc-110m`, and full tier `whisper-small.en` and `parakeet-tdt-0.6b-v2`, all transcribe `jfk.wav` with the asserted transcript (`country`, `fellow`, `americans`) on `backend: MTL0`.
  - **Raw log:** `/tmp/transcribe-cpp-full.log` (available on the qualified host).
- **Apple Silicon physical run:** not required — the approved gate accepts Intel + AMD Radeon physical Metal evidence; no Apple Silicon host has been qualified (informational only).

## 📜 License and attribution

transcribe.cpp is MIT-licensed; vendored ggml and miniz are MIT (see `THIRD-PARTY-LICENSES.md` upstream). Validation models carry their own licenses: Whisper variants are Apache-2.0, Parakeet variants are CC-BY-4.0.

## 🍺 Homebrew

```sh
brew install adyranov/tap/transcribe-cpp
```

(Available after the first release that includes this tool.)
