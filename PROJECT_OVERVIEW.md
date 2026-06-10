# speakrs_ffi — Project Overview

## Goal

A thin, stable **C FFI** around [speakrs](https://github.com/avencera/speakrs)
(speaker diarization in Rust; pyannote-level accuracy at 312–912× realtime on
Apple Silicon via CoreML) so that non-Rust consumers — first and foremost
**ReClip+** (Python/Flask, via `ctypes`) — can diarize audio without a Python
ML stack, a Rust toolchain at runtime, or any build-time network access.

## Architecture

```
consumer (Python ctypes / C CLI / anything) ──► C FFI ──► speakrs (Rust)
```

- The library is a **pure in-memory transform**: mono 16 kHz f32 PCM samples
  in, JSON string out. No file I/O, no audio decoding inside the library —
  callers decode with ffmpeg (`-f f32le -ac 1 -ar 16000`).
- Every failure, including Rust panics, returns as `{"ok":false,"error":...}`.
  Panics never unwind across the FFI boundary.
- `speakrs-diarize` (C CLI) dogfoods the header and linkage exactly as any
  external consumer would.

## Terminology

- **Diarization**: partitioning audio by *who spoke when* — acoustic only
  (voice timbre embeddings + clustering), no transcript involvement.
- **Turn/segment**: one `{start, end, speaker}` interval; speakers are
  anonymous labels (`SPEAKER_00`, …). Naming them from transcript context is
  the *consumer's* job (ReClip+ does it with a local LLM).
- **Execution mode**: `cpu` (ONNX Runtime), `coreml`/`coreml-fast` (native
  CoreML, macOS), `cuda`/`cuda-fast`, `migraphx`.

## Nix discipline (why the odd feature flags)

Nothing downloads during the build:
- `openblas-system` instead of the default static MKL/OpenBLAS (which fetch
  archives at build time) — links nixpkgs' openblas via pkg-config.
- `load-dynamic` instead of ort's default prebuilt-binary download — ONNX
  Runtime is dlopen'd at runtime from `ORT_DYLIB_PATH` (the flake wires it to
  nixpkgs' onnxruntime; CoreML mode never loads it at all).
- Models (`avencera/speakrs-models` on HuggingFace, no token) download at
  **runtime** on first use, or load offline from `models_dir`.

## Consumers

- ReClip+ (`../reclip`) — pulls this flake as an input; Python `ctypes` binding.
