# 🎤 whisper-cpp (Metal)

Metal-enabled [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with embedded patched ggml.

## 📦 Shipped binaries

Core: `whisper-cli`, `whisper-bench`, `whisper-server`, `whisper-quantize`

Interactive (require SDL2): `whisper-stream`, `whisper-command`,
`whisper-talk-llama`, `whisper-lsp`, `whisper-vad-speech-segments`

## 🧱 Runtime dependencies

**SDL2** (Simple DirectMedia Layer) provides microphone capture and audio playback.
Only the **interactive** tools above link against it. File-based transcription
(`whisper-cli`, `whisper-bench`, `whisper-server`) does not use SDL2 at runtime.

The formula declares `depends_on "sdl2"` for the interactive tools. Patched
ggml is statically linked into the shipped tools.

## 🧪 Validation

```sh
./scripts/dist.sh validate whisper-cpp            # tiny.en (~75 MB) on samples/jfk.wav
./scripts/dist.sh validate whisper-cpp --full
./scripts/dist.sh validate whisper-cpp --type performance --bin-dir /path/to/bin --no-build > bench.txt
```

Requires `samples/jfk.wav` from the cloned source tree (or set `SAMPLE=`).

## 🍺 Homebrew

```sh
brew install adyranov/tap/whisper-cpp
```

Shares the name `whisper-cpp` with homebrew-core — install via the tap path.
Conflicts with the official formula.
